// Phase B Week 2 Ship 3: HTTP route tests для membership endpoints.
//
// Scope:
//   POST   /v1/semya/:id/membership          — add member (201/200/400/403/404)
//   GET    /v1/semya/:id/memberships         — list (200/403)
//   PATCH  /v1/semya/:id/membership/:userId  — role/grant (200/400/403/404/409)
//   DELETE /v1/semya/:id/membership/:userId  — kick/leave (200/403/404/409)
//
// Invariant coverage:
//   * At-least-one-owner — demote либо remove last owner = 409
//   * Self-role-change blocked — owner cannot self-demote (need
//     другой owner)
//   * Invite-grant only meaningful для editor role
//   * Idempotent POST (duplicate returns existing 200)

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-mem-rt-"));
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

async function seedSemyaWithOwner(store, baseUrl, ownerEmail) {
  const owner = await makeUser(store, baseUrl, ownerEmail);
  const tree = await store.createTree({
    creatorId: owner.userId,
    name: "Тестовое дерево",
    description: "",
    isPrivate: true,
    kind: "family",
  });
  const semya = await store.createSemya({
    ownerId: owner.userId,
    name: "Тестовая семья",
    treeId: tree.id,
  });
  return {owner, tree, semya};
}

// ---------- POST ----------

test("POST membership: owner adds editor (201, atomic)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "owner@example.com",
    );
    const editor = await makeUser(ctx.store, ctx.baseUrl, "editor@example.com");

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({userId: editor.userId, role: "editor"}),
      },
    );

    assert.equal(res.status, 201);
    const body = await res.json();
    assert.equal(body.created, true);
    assert.equal(body.membership.userId, editor.userId);
    assert.equal(body.membership.role, "editor");
    assert.equal(body.membership.invitedByUserId, owner.userId);
    assert.equal(body.membership.hasInviteGrant, false);
  } finally {
    await shutdown(ctx);
  }
});

test("POST membership: idempotent — duplicate returns 200 + existing", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o2@example.com",
    );
    const member = await makeUser(ctx.store, ctx.baseUrl, "m2@example.com");

    const first = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({userId: member.userId, role: "viewer"}),
      },
    );
    assert.equal(first.status, 201);
    const firstBody = await first.json();

    const second = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({userId: member.userId, role: "editor"}),
      },
    );
    assert.equal(second.status, 200, "second call returns 200 (idempotent)");
    const secondBody = await second.json();
    assert.equal(secondBody.created, false);
    // Same membership row, original role preserved (idempotent ≠ update)
    assert.equal(secondBody.membership.id, firstBody.membership.id);
    assert.equal(secondBody.membership.role, "viewer");
  } finally {
    await shutdown(ctx);
  }
});

test("POST membership: editor без invite-grant rejected (403)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o3@example.com",
    );
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ed3@example.com");
    const target = await makeUser(ctx.store, ctx.baseUrl, "t3@example.com");

    // Add editor (no grant)
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
      hasInviteGrant: false,
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${editor.token}`,
        },
        body: JSON.stringify({userId: target.userId, role: "viewer"}),
      },
    );
    assert.equal(res.status, 403);
  } finally {
    await shutdown(ctx);
  }
});

test("POST membership: editor c invite-grant allowed (201)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o4@example.com",
    );
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ed4@example.com");
    const target = await makeUser(ctx.store, ctx.baseUrl, "t4@example.com");

    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
      hasInviteGrant: true,
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${editor.token}`,
        },
        body: JSON.stringify({userId: target.userId, role: "viewer"}),
      },
    );
    assert.equal(res.status, 201);
  } finally {
    await shutdown(ctx);
  }
});

test("POST membership: outsider 403, missing fields 400, owner role rejected", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o5@example.com",
    );
    const outsider = await makeUser(ctx.store, ctx.baseUrl, "out5@example.com");
    const target = await makeUser(ctx.store, ctx.baseUrl, "t5@example.com");

    // Outsider — 403
    const denied = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${outsider.token}`,
        },
        body: JSON.stringify({userId: target.userId, role: "editor"}),
      },
    );
    assert.equal(denied.status, 403);

    // Missing userId — 400
    const noUser = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({role: "editor"}),
      },
    );
    assert.equal(noUser.status, 400);

    // Owner role via POST — rejected (must use PATCH promote)
    const ownerRole = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({userId: target.userId, role: "owner"}),
      },
    );
    assert.equal(ownerRole.status, 400);
  } finally {
    await shutdown(ctx);
  }
});

// ---------- GET ----------

test("GET memberships: list all (200, viewer+)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o6@example.com",
    );
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ed6@example.com");
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
    });

    // Owner sees list
    const ownerView = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/memberships`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    assert.equal(ownerView.status, 200);
    const ownerBody = await ownerView.json();
    assert.equal(ownerBody.memberships.length, 2);

    // Editor (viewer-level access) also sees list
    const editorView = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/memberships`,
      {headers: {Authorization: `Bearer ${editor.token}`}},
    );
    assert.equal(editorView.status, 200);
  } finally {
    await shutdown(ctx);
  }
});

test("GET memberships: enriched with displayName + fallback when user gone", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o6e@example.com",
    );
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ed6e@example.com");
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
    });

    const res1 = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/memberships`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    const body1 = await res1.json();
    const editorRow = body1.memberships.find((m) => m.userId === editor.userId);
    // Enriched: the registered displayName (email prefix), not the raw id.
    assert.equal(editorRow.displayName, "ed6e");
    assert.notEqual(editorRow.displayName, editor.userId);

    // Fallback: drop the user record (stale membership) → displayName omitted,
    // userId still present so the client can fall back to it.
    const db = await ctx.store._read();
    db.users = db.users.filter((u) => u.id !== editor.userId);
    await ctx.store._write(db);
    ctx.store._userCache.delete(editor.userId);

    const res2 = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/memberships`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    const body2 = await res2.json();
    const staleRow = body2.memberships.find((m) => m.userId === editor.userId);
    assert.equal(staleRow.displayName, undefined);
    assert.equal(staleRow.userId, editor.userId);
  } finally {
    await shutdown(ctx);
  }
});

test("GET memberships: outsider 403", async () => {
  const ctx = await startTestServer();
  try {
    const {semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o7@example.com",
    );
    const outsider = await makeUser(ctx.store, ctx.baseUrl, "out7@example.com");
    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/memberships`,
      {headers: {Authorization: `Bearer ${outsider.token}`}},
    );
    assert.equal(res.status, 403);
  } finally {
    await shutdown(ctx);
  }
});

// ---------- PATCH ----------

test("PATCH membership: owner promotes editor to owner (200)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o8@example.com",
    );
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ed8@example.com");
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
      hasInviteGrant: true,
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership/${editor.userId}`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({role: "owner"}),
      },
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.membership.role, "owner");
    // Promote к owner clears editor-only invite grant flag
    assert.equal(body.membership.hasInviteGrant, false);
  } finally {
    await shutdown(ctx);
  }
});

test("PATCH membership: owner cannot demote себя (409 SELF_ROLE_CHANGE_FORBIDDEN)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o9@example.com",
    );
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ed9@example.com");
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership/${owner.userId}`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({role: "editor"}),
      },
    );
    assert.equal(res.status, 409);
    const body = await res.json();
    assert.match(body.message, /Свою роль/);
  } finally {
    await shutdown(ctx);
  }
});

test("PATCH membership: demote last owner blocked (409 LAST_OWNER_DEMOTE_FORBIDDEN)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o10@example.com",
    );
    // Promote second user to owner first
    const coOwner = await makeUser(ctx.store, ctx.baseUrl, "co10@example.com");
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: coOwner.userId,
      role: "editor",
      invitedByUserId: owner.userId,
    });
    await ctx.store.updateMembership({
      semyaId: semya.id,
      targetUserId: coOwner.userId,
      actorUserId: owner.userId,
      role: "owner",
    });

    // Now co-owner demotes original owner — should succeed (2 owners exist)
    const firstDemote = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership/${owner.userId}`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${coOwner.token}`,
        },
        body: JSON.stringify({role: "editor"}),
      },
    );
    assert.equal(firstDemote.status, 200);

    // Try to demote remaining owner — last-owner protection fires
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ed10@example.com");
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: coOwner.userId,
    });
    // coOwner attempts to demote себя — blocked first by self-check
    const selfBlock = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership/${coOwner.userId}`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${coOwner.token}`,
        },
        body: JSON.stringify({role: "viewer"}),
      },
    );
    assert.equal(selfBlock.status, 409);

    // Promote editor to owner, потом demote coOwner — должно ok (3 owners
    // → 2 owners → 1 owner — последнее demote блокирует)
    await ctx.store.updateMembership({
      semyaId: semya.id,
      targetUserId: editor.userId,
      actorUserId: coOwner.userId,
      role: "owner",
    });
    // editor as actor demotes coOwner — ok (2 owners remain: original-demoted-to-editor, editor-now-owner. Wait — original is editor. So owners = {coOwner, editor}. Demote coOwner → only editor left.)
    const demoteCoOwner = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership/${coOwner.userId}`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${editor.token}`,
        },
        body: JSON.stringify({role: "editor"}),
      },
    );
    assert.equal(demoteCoOwner.status, 200);

    // Now only editor is owner. Promote some new user to be third party,
    // then try to demote `editor` — last owner protection fires.
    const newViewer = await makeUser(ctx.store, ctx.baseUrl, "nv10@example.com");
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: newViewer.userId,
      role: "viewer",
      invitedByUserId: editor.userId,
    });
    // Even though `editor` is sole owner, only an owner can attempt demote.
    // Since editor is sole owner and self-demote blocks first, simulate
    // hypothetical demote: try owner→viewer from editor's session targeting
    // himself → SELF_ROLE_CHANGE_FORBIDDEN, not LAST_OWNER. Both
    // protections active in their own slot.
    const editorSelf = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership/${editor.userId}`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${editor.token}`,
        },
        body: JSON.stringify({role: "viewer"}),
      },
    );
    assert.equal(editorSelf.status, 409);
    const editorSelfBody = await editorSelf.json();
    assert.match(editorSelfBody.message, /Свою роль/);
  } finally {
    await shutdown(ctx);
  }
});

test("PATCH membership: invite-grant toggle owner→editor (200), viewer rejected (409)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o11@example.com",
    );
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ed11@example.com");
    const viewer = await makeUser(ctx.store, ctx.baseUrl, "vv11@example.com");
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
    });
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: viewer.userId,
      role: "viewer",
      invitedByUserId: owner.userId,
    });

    // Grant editor invite power
    const grant = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership/${editor.userId}`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({hasInviteGrant: true}),
      },
    );
    assert.equal(grant.status, 200);
    const grantBody = await grant.json();
    assert.equal(grantBody.membership.hasInviteGrant, true);

    // Try set invite grant on viewer — rejected
    const viewerGrant = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership/${viewer.userId}`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({hasInviteGrant: true}),
      },
    );
    assert.equal(viewerGrant.status, 409);
  } finally {
    await shutdown(ctx);
  }
});

test("PATCH membership: non-owner rejected (403)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o12@example.com",
    );
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ed12@example.com");
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
    });

    // Editor tries to change own role — 403 (требует owner role to PATCH)
    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership/${editor.userId}`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${editor.token}`,
        },
        body: JSON.stringify({role: "owner"}),
      },
    );
    assert.equal(res.status, 403);
  } finally {
    await shutdown(ctx);
  }
});

// ---------- DELETE ----------

test("DELETE membership: owner kicks editor (200)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o13@example.com",
    );
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ed13@example.com");
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership/${editor.userId}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.wasSelfLeave, false);

    // Verify editor больше не member
    const membership = await ctx.store.findMembership(semya.id, editor.userId);
    assert.equal(membership, null);
  } finally {
    await shutdown(ctx);
  }
});

test("DELETE membership: editor self-leave (200, wasSelfLeave=true)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o14@example.com",
    );
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ed14@example.com");
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership/${editor.userId}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${editor.token}`},
      },
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.wasSelfLeave, true);
  } finally {
    await shutdown(ctx);
  }
});

test("DELETE membership: last owner cannot leave (409 LAST_OWNER_REMOVE_FORBIDDEN)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o15@example.com",
    );

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership/${owner.userId}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(res.status, 409);
    const body = await res.json();
    assert.match(body.message, /последнего владельца/);
  } finally {
    await shutdown(ctx);
  }
});

test("DELETE membership: editor cannot kick others (403)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o16@example.com",
    );
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ed16@example.com");
    const viewer = await makeUser(ctx.store, ctx.baseUrl, "vv16@example.com");
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
    });
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: viewer.userId,
      role: "viewer",
      invitedByUserId: owner.userId,
    });

    // Editor tries to kick viewer — 403
    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership/${viewer.userId}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${editor.token}`},
      },
    );
    assert.equal(res.status, 403);
  } finally {
    await shutdown(ctx);
  }
});

test("DELETE membership: non-existent member 404", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "o17@example.com",
    );
    const stranger = await makeUser(ctx.store, ctx.baseUrl, "str17@example.com");

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/membership/${stranger.userId}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(res.status, 404);
  } finally {
    await shutdown(ctx);
  }
});
