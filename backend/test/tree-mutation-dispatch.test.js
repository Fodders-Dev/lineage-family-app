// Phase 6.5+ auto-refresh: tree mutation dispatch tests.
//
// Covers:
// • store.resolveTreeAudienceUserIds composition (owner +
//   members + edit-grant holders + identity-linked, actor excluded).
// • 5 tree-routes mutation endpoints dispatch `tree_mutated`
//   silent notification к audience.
// • Self-skip: actor НЕ receives push для own mutation.
// • Silent flag flows через notification → mapped notification →
//   exposes к client.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");

const {createApp} = require("../src/app");
const {FileStore} = require("../src/store");
const {RealtimeHub} = require("../src/realtime-hub");
const {PushGateway} = require("../src/push-gateway");

async function startTestServer() {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-tmd-"));
  const dataPath = path.join(tempDir, "dev-db.json");
  const store = new FileStore(dataPath);
  await store.initialize();
  const realtimeHub = new RealtimeHub({store});
  const pushGateway = new PushGateway({store});
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

async function stopTestServer(ctx) {
  await new Promise((resolve, reject) => {
    ctx.server.close((error) => (error ? reject(error) : resolve()));
  });
  await fs.rm(ctx.tempDir, {recursive: true, force: true});
}

async function registerUser(ctx, email) {
  const response = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({email, password: "secret123", consentDocVersion: "test-consent-v1", displayName: email}),
  });
  assert.equal(response.status, 201);
  return response.json();
}

async function createTree(ctx, token, name = "Тестовое дерево") {
  const response = await fetch(`${ctx.baseUrl}/v1/trees`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({name}),
  });
  assert.equal(response.status, 201);
  return response.json();
}

async function createPerson(ctx, token, treeId, name = "Иван") {
  return fetch(`${ctx.baseUrl}/v1/trees/${treeId}/persons`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({firstName: name}),
  });
}

function findNotifications(db, userId, type) {
  return (db.notifications || []).filter(
    (n) => n.userId === userId && n.type === type,
  );
}

// ── store.resolveTreeAudienceUserIds ─────────────────────────────

test(
  "resolveTreeAudienceUserIds: owner + members included, actor excluded",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "owner@a.app");
      const treeResp = await createTree(ctx, owner.accessToken);
      const treeId = treeResp.tree.id;

      // Add a member directly via store mutation (simulates Phase 3.4
      // member add либо tree invitation accept).
      const db = await ctx.store._read();
      const tree = db.trees.find((t) => t.id === treeId);
      const member = await registerUser(ctx, "member@a.app");
      tree.memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
      tree.memberIds.push(member.user.id);
      await ctx.store._write(db);

      const audience = await ctx.store.resolveTreeAudienceUserIds(treeId, {
        excludeUserId: owner.user.id,
      });
      assert.deepEqual(audience.sort(), [member.user.id].sort());

      const audienceNoExclude = await ctx.store.resolveTreeAudienceUserIds(
        treeId,
      );
      assert.deepEqual(
        audienceNoExclude.sort(),
        [owner.user.id, member.user.id].sort(),
      );
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "resolveTreeAudienceUserIds: non-existent treeId → empty array",
  async () => {
    const ctx = await startTestServer();
    try {
      const audience = await ctx.store.resolveTreeAudienceUserIds(
        "ghost-tree-id",
      );
      assert.deepEqual(audience, []);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "resolveTreeAudienceUserIds: edit-grant holder included",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "owner-eg@a.app");
      const grantee = await registerUser(ctx, "grantee-eg@a.app");
      const treeResp = await createTree(ctx, owner.accessToken);
      const treeId = treeResp.tree.id;

      // Create a person to host edit-grant on. _syncGraphFromLegacy
      // creates corresponding graphPerson — legacyTreeIds carries
      // treeId через identity propagation так что audience-query
      // detects it на этом tree.
      const personResp = await createPerson(
        ctx,
        owner.accessToken,
        treeId,
        "GranteeAnchor",
      );
      const personBody = await personResp.json();
      const personId = personBody.person.id;

      const db = await ctx.store._read();
      const person = db.persons.find((p) => p.id === personId);
      assert.ok(person?.identityId, "person should have identityId set");
      const graphPersonId = person.identityId;

      db.graphPersonEditGrants = db.graphPersonEditGrants || [];
      db.graphPersonEditGrants.push({
        id: "g-test-1",
        graphPersonId,
        granteeUserId: grantee.user.id,
        scopes: ["edit"],
        revokedAt: null,
      });
      await ctx.store._write(db);

      const audience = await ctx.store.resolveTreeAudienceUserIds(treeId, {
        excludeUserId: owner.user.id,
      });
      assert.ok(
        audience.includes(grantee.user.id),
        "edit-grant holder должен быть в audience",
      );
    } finally {
      await stopTestServer(ctx);
    }
  },
);

// ── Endpoint dispatch tests ──────────────────────────────────────

test(
  "POST /trees/:id/persons: dispatches tree_mutated to audience minus actor",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "owner-pa@a.app");
      const member = await registerUser(ctx, "member-pa@a.app");
      const stranger = await registerUser(ctx, "stranger-pa@a.app");
      const treeResp = await createTree(ctx, owner.accessToken);
      const treeId = treeResp.tree.id;

      const db = await ctx.store._read();
      const tree = db.trees.find((t) => t.id === treeId);
      tree.memberIds = [member.user.id];
      await ctx.store._write(db);

      const response = await createPerson(
        ctx,
        owner.accessToken,
        treeId,
        "Артём",
      );
      assert.equal(response.status, 201);

      const dbAfter = await ctx.store._read();
      const memberNotifs = findNotifications(
        dbAfter,
        member.user.id,
        "tree_mutated",
      );
      assert.equal(memberNotifs.length, 1, "member should receive 1");
      assert.equal(memberNotifs[0].silent, true, "silent flag set");
      assert.equal(memberNotifs[0].data.treeId, treeId);
      assert.equal(memberNotifs[0].data.kind, "person_added");
      assert.equal(memberNotifs[0].data.actorUserId, owner.user.id);

      const ownerNotifs = findNotifications(
        dbAfter,
        owner.user.id,
        "tree_mutated",
      );
      assert.equal(ownerNotifs.length, 0, "actor (owner) self-skip");

      const strangerNotifs = findNotifications(
        dbAfter,
        stranger.user.id,
        "tree_mutated",
      );
      assert.equal(strangerNotifs.length, 0, "non-audience stranger skipped");
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "DELETE /trees/:id/persons/:pid: dispatches person_deleted",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "owner-pd@a.app");
      const member = await registerUser(ctx, "member-pd@a.app");
      const treeResp = await createTree(ctx, owner.accessToken);
      const treeId = treeResp.tree.id;

      const db = await ctx.store._read();
      db.trees.find((t) => t.id === treeId).memberIds = [member.user.id];
      await ctx.store._write(db);

      const personResp = await createPerson(
        ctx,
        owner.accessToken,
        treeId,
        "Иван",
      );
      const personBody = await personResp.json();
      const personId = personBody.person.id;

      // Clear notifications from add to isolate delete dispatch.
      const dbClear = await ctx.store._read();
      dbClear.notifications = [];
      await ctx.store._write(dbClear);

      const deleteResp = await fetch(
        `${ctx.baseUrl}/v1/trees/${treeId}/persons/${personId}`,
        {
          method: "DELETE",
          headers: {authorization: `Bearer ${owner.accessToken}`},
        },
      );
      assert.equal(deleteResp.status, 204);

      const dbAfter = await ctx.store._read();
      const memberNotifs = findNotifications(
        dbAfter,
        member.user.id,
        "tree_mutated",
      );
      assert.equal(memberNotifs.length, 1);
      assert.equal(memberNotifs[0].data.kind, "person_deleted");
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST + DELETE /trees/:id/relations: dispatches relation_added then relation_deleted",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "owner-r@a.app");
      const member = await registerUser(ctx, "member-r@a.app");
      const treeResp = await createTree(ctx, owner.accessToken);
      const treeId = treeResp.tree.id;

      const db = await ctx.store._read();
      db.trees.find((t) => t.id === treeId).memberIds = [member.user.id];
      await ctx.store._write(db);

      const p1 = await (await createPerson(
        ctx,
        owner.accessToken,
        treeId,
        "Иван",
      )).json();
      const p2 = await (await createPerson(
        ctx,
        owner.accessToken,
        treeId,
        "Мария",
      )).json();

      // Reset notifications between person-adds and relation-add.
      const dbClear = await ctx.store._read();
      dbClear.notifications = [];
      await ctx.store._write(dbClear);

      const relResp = await fetch(
        `${ctx.baseUrl}/v1/trees/${treeId}/relations`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${owner.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            person1Id: p1.person.id,
            person2Id: p2.person.id,
            relation1to2: "spouse",
            relation2to1: "spouse",
          }),
        },
      );
      assert.equal(relResp.status, 201);
      const relBody = await relResp.json();
      const relationId = relBody.relation.id;

      let dbAfter = await ctx.store._read();
      let memberNotifs = findNotifications(
        dbAfter,
        member.user.id,
        "tree_mutated",
      );
      assert.equal(memberNotifs.length, 1);
      assert.equal(memberNotifs[0].data.kind, "relation_added");

      // Delete the relation.
      const dbClear2 = await ctx.store._read();
      dbClear2.notifications = [];
      await ctx.store._write(dbClear2);

      const delResp = await fetch(
        `${ctx.baseUrl}/v1/trees/${treeId}/relations/${relationId}`,
        {
          method: "DELETE",
          headers: {authorization: `Bearer ${owner.accessToken}`},
        },
      );
      assert.equal(delResp.status, 204);

      dbAfter = await ctx.store._read();
      memberNotifs = findNotifications(
        dbAfter,
        member.user.id,
        "tree_mutated",
      );
      assert.equal(memberNotifs.length, 1);
      assert.equal(memberNotifs[0].data.kind, "relation_deleted");
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "notification.silent flag survives mapNotification round-trip к client GET",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "owner-s@a.app");
      const member = await registerUser(ctx, "member-s@a.app");
      const treeResp = await createTree(ctx, owner.accessToken);
      const treeId = treeResp.tree.id;

      const db = await ctx.store._read();
      db.trees.find((t) => t.id === treeId).memberIds = [member.user.id];
      await ctx.store._write(db);

      await createPerson(ctx, owner.accessToken, treeId, "Test");

      // Member fetches own notifications.
      const listResp = await fetch(
        `${ctx.baseUrl}/v1/notifications`,
        {headers: {authorization: `Bearer ${member.accessToken}`}},
      );
      assert.equal(listResp.status, 200);
      const listBody = await listResp.json();
      const treeMutatedNotif = (listBody.notifications || []).find(
        (n) => n.type === "tree_mutated",
      );
      assert.ok(treeMutatedNotif, "found tree_mutated в client response");
      assert.equal(
        treeMutatedNotif.silent,
        true,
        "silent flag exposed via mapNotification",
      );
    } finally {
      await stopTestServer(ctx);
    }
  },
);
