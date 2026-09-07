// Phase B Week 3 Ship 5: tree.semyaId reverse-FK + dual-write
// compat shim + useSemyaModel feature flag.
//
// Tests:
//   * createSemya writes tree.semyaId atomically (reverse FK)
//   * addMembership dual-writes к tree.memberIds[] + tree.members[]
//     (legacy alias)
//   * removeMembership splices из tree.memberIds[] (creator
//     preserved)
//   * Feature flag OFF — legacy requireTreeAccess preserves
//     pre-Phase-B behavior (creator + memberIds gate)
//   * Feature flag ON — bound tree (tree.semyaId set) uses семья
//     membership gate
//   * Feature flag ON — unbound tree (tree.semyaId null) falls
//     back к legacy gate (transition safety)
//   * Backward compat: existing tree-routes endpoints continue
//     working пока flag OFF AND bound tree access via legacy path

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");

const {createApp} = require("../src/app");
const {FileStore} = require("../src/store");
const {RealtimeHub} = require("../src/realtime-hub");
const {PushGateway} = require("../src/push-gateway");

async function startTestServer({useSemyaModel = false} = {}) {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-bind-"));
  const dataPath = path.join(tempDir, "dev-db.json");
  const store = new FileStore(dataPath);
  await store.initialize();
  const realtimeHub = new RealtimeHub({store});
  const pushGateway = new PushGateway({store});

  // Toggle feature flag via env var (read once at createApp).
  const prevFlag = process.env.RODNYA_FEDERATED_SEMYI_ENABLED;
  if (useSemyaModel) {
    process.env.RODNYA_FEDERATED_SEMYI_ENABLED = "true";
  } else {
    delete process.env.RODNYA_FEDERATED_SEMYI_ENABLED;
  }

  const app = createApp({
    store,
    config: {
      corsOrigin: "*",
      dataPath,
      mediaRootPath: path.join(tempDir, "uploads"),
    },
    realtimeHub,
    pushGateway,
  });

  // Restore env immediately после createApp читает (читается one-shot).
  if (prevFlag === undefined) {
    delete process.env.RODNYA_FEDERATED_SEMYI_ENABLED;
  } else {
    process.env.RODNYA_FEDERATED_SEMYI_ENABLED = prevFlag;
  }

  const server = await new Promise((resolve) => {
    const instance = app.listen(0, "127.0.0.1", () => resolve(instance));
  });
  realtimeHub.attach(server);
  return {
    baseUrl: `http://127.0.0.1:${server.address().port}`,
    server,
    store,
    tempDir,
  };
}

async function shutdown({server, tempDir}) {
  await new Promise((resolve) => server.close(resolve));
  await fs.rm(tempDir, {recursive: true, force: true});
}

async function makeUser(store, baseUrl, email) {
  const password = "Test-Password-123!";
  const displayName = email.split("@")[0];
  const res = await fetch(`${baseUrl}/v1/auth/register`, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({email, password, displayName, consentDocVersion: "test-consent-v1"}),
  });
  if (res.status !== 201) {
    const text = await res.text();
    throw new Error(`register failed status=${res.status} body=${text}`);
  }
  const body = await res.json();
  return {userId: body.user.id, token: body.accessToken, email};
}

// ---------------- Reverse-FK + dual-write store layer ----------------

test("Ship 5: createSemya writes tree.semyaId atomically", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "ts1@example.com");
    const tree = await ctx.store.createTree({
      creatorId: owner.userId,
      name: "Дерево",
      description: "",
      isPrivate: true,
      kind: "family",
    });

    // Pre-create: tree.semyaId should be null (default from createTree)
    const preTree = await ctx.store.findTree(tree.id);
    assert.equal(preTree.semyaId, null);

    const semya = await ctx.store.createSemya({
      ownerId: owner.userId,
      name: "Семья",
      treeId: tree.id,
    });

    // Post-create: tree.semyaId === semya.id
    const postTree = await ctx.store.findTree(tree.id);
    assert.equal(postTree.semyaId, semya.id);
  } finally {
    await shutdown(ctx);
  }
});

test("Ship 5: addMembership dual-writes tree.memberIds[]", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "ts2@example.com");
    const newMember = await makeUser(ctx.store, ctx.baseUrl, "ts2b@example.com");
    const tree = await ctx.store.createTree({
      creatorId: owner.userId,
      name: "Д",
      description: "",
      isPrivate: true,
      kind: "family",
    });
    const semya = await ctx.store.createSemya({
      ownerId: owner.userId,
      name: "С",
      treeId: tree.id,
    });

    // Pre-add: memberIds contains only creator
    let snapshot = await ctx.store.findTree(tree.id);
    assert.deepEqual(snapshot.memberIds, [owner.userId]);

    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: newMember.userId,
      role: "editor",
      invitedByUserId: owner.userId,
    });

    // Post-add: memberIds includes new member
    snapshot = await ctx.store.findTree(tree.id);
    assert.ok(snapshot.memberIds.includes(newMember.userId));
    assert.ok(snapshot.members.includes(newMember.userId));

    // Idempotent (no duplicate в memberIds)
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: newMember.userId,
      role: "editor",
      invitedByUserId: owner.userId,
    });
    snapshot = await ctx.store.findTree(tree.id);
    const occurrences = snapshot.memberIds.filter((id) => id === newMember.userId);
    assert.equal(occurrences.length, 1);
  } finally {
    await shutdown(ctx);
  }
});

test("Ship 5: removeMembership splices tree.memberIds (creator preserved)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "ts3@example.com");
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ts3b@example.com");
    const tree = await ctx.store.createTree({
      creatorId: owner.userId,
      name: "Д",
      description: "",
      isPrivate: true,
      kind: "family",
    });
    const semya = await ctx.store.createSemya({
      ownerId: owner.userId,
      name: "С",
      treeId: tree.id,
    });
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
    });

    // Editor removes self (self-leave)
    await ctx.store.removeMembership({
      semyaId: semya.id,
      targetUserId: editor.userId,
      actorUserId: editor.userId,
    });

    const snapshot = await ctx.store.findTree(tree.id);
    assert.ok(!snapshot.memberIds.includes(editor.userId));
    assert.ok(!snapshot.members.includes(editor.userId));
    // Creator preserved
    assert.ok(snapshot.memberIds.includes(owner.userId));
  } finally {
    await shutdown(ctx);
  }
});

// ---------------- Feature flag OFF (default, legacy gate) ----------------

test("Ship 5: feature flag OFF — legacy tree.memberIds gate (pre-Phase-B back-compat)", async () => {
  const ctx = await startTestServer({useSemyaModel: false});
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "ts4@example.com");
    const outsider = await makeUser(ctx.store, ctx.baseUrl, "ts4b@example.com");
    const tree = await ctx.store.createTree({
      creatorId: owner.userId,
      name: "Д",
      description: "",
      isPrivate: true,
      kind: "family",
    });
    await ctx.store.createSemya({
      ownerId: owner.userId,
      name: "С",
      treeId: tree.id,
    });

    // Outsider with no membership tries to read tree — denied via
    // legacy gate (не in tree.memberIds).
    const denied = await fetch(`${ctx.baseUrl}/v1/trees/${tree.id}/persons`, {
      headers: {Authorization: `Bearer ${outsider.token}`},
    });
    assert.equal(denied.status, 403);

    // Owner (creator) — granted via legacy gate
    const allowed = await fetch(`${ctx.baseUrl}/v1/trees/${tree.id}/persons`, {
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    assert.equal(allowed.status, 200);
  } finally {
    await shutdown(ctx);
  }
});

// ---------------- Feature flag ON (Phase B model) ----------------

test("Ship 5: feature flag ON — bound tree uses семья membership", async () => {
  const ctx = await startTestServer({useSemyaModel: true});
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "ts5@example.com");
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ts5b@example.com");
    const outsider = await makeUser(ctx.store, ctx.baseUrl, "ts5c@example.com");
    const tree = await ctx.store.createTree({
      creatorId: owner.userId,
      name: "Д",
      description: "",
      isPrivate: true,
      kind: "family",
    });
    const semya = await ctx.store.createSemya({
      ownerId: owner.userId,
      name: "С",
      treeId: tree.id,
    });
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
    });

    // Owner — granted (member of семья)
    const ownerRead = await fetch(`${ctx.baseUrl}/v1/trees/${tree.id}/persons`, {
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    assert.equal(ownerRead.status, 200);

    // Editor — granted (member of семья)
    const editorRead = await fetch(`${ctx.baseUrl}/v1/trees/${tree.id}/persons`, {
      headers: {Authorization: `Bearer ${editor.token}`},
    });
    assert.equal(editorRead.status, 200);

    // Outsider — denied (not семья member)
    const denied = await fetch(`${ctx.baseUrl}/v1/trees/${tree.id}/persons`, {
      headers: {Authorization: `Bearer ${outsider.token}`},
    });
    assert.equal(denied.status, 403);
  } finally {
    await shutdown(ctx);
  }
});

test("Ship 5: feature flag ON — unbound tree (semyaId null) falls back legacy", async () => {
  // Transition safety: пока migration не накатилась, существующие
  // pre-Phase-B trees имеют semyaId = null (default). Feature flag
  // ON не должен ломать access к этим trees — fallback к legacy
  // creator+memberIds gate.
  const ctx = await startTestServer({useSemyaModel: true});
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "ts6@example.com");
    const tree = await ctx.store.createTree({
      creatorId: owner.userId,
      name: "Д",
      description: "",
      isPrivate: true,
      kind: "family",
    });
    // НЕ создаём семя — tree.semyaId остаётся null

    const verify = await ctx.store.findTree(tree.id);
    assert.equal(verify.semyaId, null);

    // Owner via legacy gate — should still work
    const res = await fetch(`${ctx.baseUrl}/v1/trees/${tree.id}/persons`, {
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    assert.equal(res.status, 200);
  } finally {
    await shutdown(ctx);
  }
});

test("Ship 5: feature flag ON — семья member without legacy tree.memberIds entry still granted", async () => {
  // The whole point of feature-flag ON path: семья membership =
  // source of truth, не tree.memberIds. Even если dual-write
  // shim не fired (e.g. existing pre-Ship-5 семья без compat
  // refresh), access path должен work через семья check.
  const ctx = await startTestServer({useSemyaModel: true});
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "ts7@example.com");
    const newMember = await makeUser(ctx.store, ctx.baseUrl, "ts7b@example.com");
    const tree = await ctx.store.createTree({
      creatorId: owner.userId,
      name: "Д",
      description: "",
      isPrivate: true,
      kind: "family",
    });
    const semya = await ctx.store.createSemya({
      ownerId: owner.userId,
      name: "С",
      treeId: tree.id,
    });
    // Manually add membership без dual-write (simulate edge:
    // membership row exists, tree.memberIds out-of-sync)
    const db = await ctx.store._read();
    db.semyaMembers.push({
      id: "manual-membership-id",
      semyaId: semya.id,
      userId: newMember.userId,
      role: "viewer",
      joinedAt: new Date().toISOString(),
      invitedByUserId: owner.userId,
      hasInviteGrant: false,
      hiddenAt: null,
    });
    await ctx.store._write(db);

    // Verify tree.memberIds does NOT include newMember
    const treeSnap = await ctx.store.findTree(tree.id);
    assert.ok(!treeSnap.memberIds.includes(newMember.userId));

    // Access via семья membership path — granted
    const res = await fetch(`${ctx.baseUrl}/v1/trees/${tree.id}/persons`, {
      headers: {Authorization: `Bearer ${newMember.token}`},
    });
    assert.equal(res.status, 200);
  } finally {
    await shutdown(ctx);
  }
});

test("Drift fix: legacy tree-invitation accept dual-writes семья membership (flag ON keeps access)", async () => {
  const ctx = await startTestServer({useSemyaModel: true});
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "drift-owner@example.com");
    const invitee = await makeUser(ctx.store, ctx.baseUrl, "drift-invitee@example.com");
    const tree = await ctx.store.createTree({
      creatorId: owner.userId,
      name: "Дерево",
      description: "",
      isPrivate: true,
      kind: "family",
    });
    await ctx.store.createSemya({
      ownerId: owner.userId,
      name: "Семья",
      treeId: tree.id,
    });

    const invitation = await ctx.store.createTreeInvitation({
      treeId: tree.id,
      userId: invitee.userId,
      invitedByUserId: owner.userId,
    });
    await ctx.store.respondToTreeInvitation(invitation.id, true);

    // Легаси-accept обязан создать членство в семье (роль viewer, как в
    // миграции), иначе с флагом ON invitee ловил бы 403 на все роуты дерева.
    const semyaAfter = await ctx.store.findSemyaByTreeId?.(tree.id);
    const state = JSON.parse(
      await fs.readFile(path.join(ctx.tempDir, "dev-db.json"), "utf8"),
    );
    const membership = (state.semyaMembers || []).find(
      (entry) => entry.userId === invitee.userId,
    );
    assert.ok(membership, "membership not created by legacy accept");
    assert.equal(membership.role, "viewer");
    assert.equal(membership.hiddenAt, null);

    // И реальный HTTP-доступ с флагом ON: дерево открывается, не 403.
    const res = await fetch(`${ctx.baseUrl}/v1/trees/${tree.id}/persons`, {
      headers: {authorization: `Bearer ${invitee.token}`},
    });
    assert.equal(res.status, 200);
    void semyaAfter;
  } finally {
    await shutdown(ctx);
  }
});

test("Drift fix: legacy re-join после kick снимает hiddenAt (re-invite семантика)", async () => {
  const ctx = await startTestServer({useSemyaModel: true});
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "rejoin-owner@example.com");
    const member = await makeUser(ctx.store, ctx.baseUrl, "rejoin-member@example.com");
    const tree = await ctx.store.createTree({
      creatorId: owner.userId,
      name: "Дерево",
      description: "",
      isPrivate: true,
      kind: "family",
    });
    const semya = await ctx.store.createSemya({
      ownerId: owner.userId,
      name: "Семья",
      treeId: tree.id,
    });
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: member.userId,
      role: "viewer",
      invitedByUserId: owner.userId,
    });
    await ctx.store.removeMembership({
      semyaId: semya.id,
      targetUserId: member.userId,
      actorUserId: owner.userId,
    });

    const invitation = await ctx.store.createTreeInvitation({
      treeId: tree.id,
      userId: member.userId,
      invitedByUserId: owner.userId,
    });
    await ctx.store.respondToTreeInvitation(invitation.id, true);

    const state = JSON.parse(
      await fs.readFile(path.join(ctx.tempDir, "dev-db.json"), "utf8"),
    );
    const membership = (state.semyaMembers || []).find(
      (entry) => entry.userId === member.userId,
    );
    assert.ok(membership);
    assert.equal(membership.hiddenAt, null, "kick не снят при re-join");
  } finally {
    await shutdown(ctx);
  }
});
