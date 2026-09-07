// Phase B Week 2 Ship 4: HTTP route tests для invitation endpoints.
//
// Scope:
//   POST   /v1/semya/:id/invitation            — create (201/200/400/403/404/409)
//   POST   /v1/invitation/:token/accept        — accept (200/403/404/409)
//   DELETE /v1/semya/:id/invitation/:invId     — revoke (200/403/404/409)
//
// State machine coverage:
//   * pending → accepted (happy path)
//   * pending → revoked (inviter либо owner)
//   * pending → expired (lazy on read — simulated via expiresInDays=0)
//   * Terminal-state transitions rejected (409)
//
// Notification dispatch verified для semya_invitation_received +
// semya_invitation_accepted.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");

const {createApp} = require("../src/app");
const {FileStore} = require("../src/store");
const {RealtimeHub} = require("../src/realtime-hub");
const {PushGateway} = require("../src/push-gateway");

async function startTestServer({emailSender} = {}) {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-inv-rt-"));
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
    // FE7: when a test wants to assert email dispatch it injects a
    // recording fake; otherwise createApp falls back to the real
    // (logger-transport) sender, which is a harmless no-op in tests.
    ...(emailSender ? {emailSender} : {}),
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

// ---------- GET list (FE3 2026-05-26) ----------
//
// Lightweight тонкий route wrapper around store.listInvitationsForSemya.
// Permission: viewer+ via requireSemyaAccess (outsider blocked).
// Returns ALL invitations (status mixed) — UI filters.

test("GET invitations: owner sees все 3 status кодов", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "list-owner@example.com",
    );
    const recA = await makeUser(ctx.store, ctx.baseUrl, "list-a@example.com");
    const recB = await makeUser(ctx.store, ctx.baseUrl, "list-b@example.com");
    const recC = await makeUser(ctx.store, ctx.baseUrl, "list-c@example.com");

    // Create 3 invitations: pending (A), revoked (B), accepted (C).
    const createPending = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({recipientUserId: recA.userId, role: "editor"}),
      },
    );
    assert.equal(createPending.status, 201);

    const createRevoked = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({recipientUserId: recB.userId, role: "viewer"}),
      },
    );
    const revokedBody = await createRevoked.json();
    await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation/${revokedBody.invitation.id}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );

    const createAccepted = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({recipientUserId: recC.userId, role: "viewer"}),
      },
    );
    const acceptedBody = await createAccepted.json();
    await fetch(
      `${ctx.baseUrl}/v1/invitation/${acceptedBody.invitation.token}/accept`,
      {
        method: "POST",
        headers: {Authorization: `Bearer ${recC.token}`},
      },
    );

    // GET list — owner sees все 3 statuses.
    const listRes = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitations`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    assert.equal(listRes.status, 200);
    const listBody = await listRes.json();
    assert.ok(Array.isArray(listBody.invitations));
    assert.equal(listBody.invitations.length, 3);
    const statuses = listBody.invitations.map((inv) => inv.status).sort();
    assert.deepEqual(statuses, ["accepted", "pending", "revoked"]);
  } finally {
    await shutdown(ctx);
  }
});

test("GET invitations: viewer member allowed", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "list-vo@example.com",
    );
    const viewer = await makeUser(ctx.store, ctx.baseUrl, "list-vv@example.com");
    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: viewer.userId,
      role: "viewer",
      actorUserId: owner.userId,
    });

    const listRes = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitations`,
      {headers: {Authorization: `Bearer ${viewer.token}`}},
    );
    assert.equal(listRes.status, 200);
  } finally {
    await shutdown(ctx);
  }
});

test("GET invitations: outsider rejected (403/404)", async () => {
  const ctx = await startTestServer();
  try {
    const {semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "list-os@example.com",
    );
    const outsider = await makeUser(ctx.store, ctx.baseUrl, "list-out@example.com");

    const listRes = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitations`,
      {headers: {Authorization: `Bearer ${outsider.token}`}},
    );
    // requireSemyaAccess returns 403 (or 404 if treated as not-found).
    assert.ok(
      listRes.status === 403 || listRes.status === 404,
      `expected 403/404 outsider rejection, got ${listRes.status}`,
    );
  } finally {
    await shutdown(ctx);
  }
});

// ---------- POST create ----------

test("POST invitation: owner creates pending для existing user (201)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io1@example.com",
    );
    const recipient = await makeUser(ctx.store, ctx.baseUrl, "ir1@example.com");

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({
          recipientUserId: recipient.userId,
          role: "editor",
        }),
      },
    );
    assert.equal(res.status, 201);
    const body = await res.json();
    assert.equal(body.created, true);
    assert.equal(body.invitation.status, "pending");
    assert.equal(body.invitation.recipientUserId, recipient.userId);
    assert.equal(body.invitation.role, "editor");
    assert.equal(body.invitation.inviterUserId, owner.userId);
    assert.ok(body.invitation.token, "token returned");
    assert.ok(body.invitation.expiresAt);
  } finally {
    await shutdown(ctx);
  }
});

test("POST invitation: idempotent re-create returns existing pending (200)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io2@example.com",
    );
    const recipient = await makeUser(ctx.store, ctx.baseUrl, "ir2@example.com");

    const first = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({
          recipientUserId: recipient.userId,
          role: "viewer",
        }),
      },
    );
    assert.equal(first.status, 201);
    const firstBody = await first.json();

    const second = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({
          recipientUserId: recipient.userId,
          role: "editor", // attempt role bump
        }),
      },
    );
    assert.equal(second.status, 200);
    const secondBody = await second.json();
    assert.equal(secondBody.created, false);
    assert.equal(secondBody.invitation.id, firstBody.invitation.id);
    // Original role preserved (idempotent ≠ update; use revoke+resend для role bump)
    assert.equal(secondBody.invitation.role, "viewer");
  } finally {
    await shutdown(ctx);
  }
});

test("POST invitation: editor с invite-grant allowed (201)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io3@example.com",
    );
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ie3@example.com");
    const recipient = await makeUser(ctx.store, ctx.baseUrl, "ir3@example.com");

    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
      hasInviteGrant: true,
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${editor.token}`,
        },
        body: JSON.stringify({
          recipientUserId: recipient.userId,
          role: "viewer",
        }),
      },
    );
    assert.equal(res.status, 201);
  } finally {
    await shutdown(ctx);
  }
});

test("POST invitation: editor без grant rejected (403)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io4@example.com",
    );
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ie4@example.com");
    const recipient = await makeUser(ctx.store, ctx.baseUrl, "ir4@example.com");

    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
      hasInviteGrant: false,
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${editor.token}`,
        },
        body: JSON.stringify({
          recipientUserId: recipient.userId,
          role: "viewer",
        }),
      },
    );
    assert.equal(res.status, 403);
  } finally {
    await shutdown(ctx);
  }
});

test("POST invitation: already-member returns 409", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io5@example.com",
    );
    const recipient = await makeUser(ctx.store, ctx.baseUrl, "ir5@example.com");

    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: recipient.userId,
      role: "viewer",
      invitedByUserId: owner.userId,
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({
          recipientUserId: recipient.userId,
          role: "editor",
        }),
      },
    );
    assert.equal(res.status, 409);
  } finally {
    await shutdown(ctx);
  }
});

test("POST invitation: missing recipient/role/owner-role rejected (400)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io6@example.com",
    );

    const noRecipient = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({role: "editor"}),
      },
    );
    assert.equal(noRecipient.status, 400);

    const ownerRole = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({
          recipientUserId: "anyone",
          role: "owner",
        }),
      },
    );
    assert.equal(ownerRole.status, 400);
  } finally {
    await shutdown(ctx);
  }
});

// FE7 (2026-06-03): email-addressed invitation теперь AUTO-DISPATCHES
// тёплое accept-link письмо (раньше «stored без auto-dispatch»). Inject
// recording fake emailSender и проверяем вызов + acceptUrl + резолв
// semyaName/inviterName.
function recordingEmailSender() {
  const sent = [];
  return {
    sent,
    async sendSemyaInvitationEmail(args) {
      sent.push(args);
      return {ok: true, messageId: "test-msg-id", usingLogger: false};
    },
    // createApp's password-reset path also touches the sender — keep a
    // no-op so injecting this fake never breaks an unrelated route.
    async sendPasswordResetEmail() {
      return {ok: true, messageId: "test-pwd-id", usingLogger: false};
    },
  };
}

test("POST invitation: with recipientEmail dispatches warm accept-link email (201)", async () => {
  const fakeEmail = recordingEmailSender();
  const ctx = await startTestServer({emailSender: fakeEmail});
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io7@example.com",
    );
    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({
          recipientEmail: "newuser@example.com",
          role: "viewer",
        }),
      },
    );
    assert.equal(res.status, 201);
    const body = await res.json();
    assert.equal(body.invitation.recipientEmail, "newuser@example.com");
    assert.equal(body.invitation.recipientUserId, null);
    assert.ok(body.invitation.token, "token returned для manual share");

    // Exactly one email, к recipientEmail, с deep-link acceptUrl carrying
    // the invitation token, + resolved semyaName + inviterName.
    assert.equal(fakeEmail.sent.length, 1);
    const sent = fakeEmail.sent[0];
    assert.equal(sent.to, "newuser@example.com");
    assert.match(sent.acceptUrl, /\/invite\//);
    assert.ok(
      sent.acceptUrl.includes(encodeURIComponent(body.invitation.token)),
      `acceptUrl должен нести token, got ${sent.acceptUrl}`,
    );
    assert.equal(sent.semyaName, "Тестовая семья");
    assert.equal(sent.role, "viewer");
    // Owner registered с displayName = email local-part ("io7").
    assert.equal(sent.inviterName, "io7");
  } finally {
    await shutdown(ctx);
  }
});

test("POST invitation: recipientUserId-only does NOT dispatch email", async () => {
  const fakeEmail = recordingEmailSender();
  const ctx = await startTestServer({emailSender: fakeEmail});
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io7b@example.com",
    );
    const recipient = await makeUser(ctx.store, ctx.baseUrl, "ir7b@example.com");
    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({
          recipientUserId: recipient.userId,
          role: "editor",
        }),
      },
    );
    assert.equal(res.status, 201);
    // userId-targeted → push-notified, NOT emailed.
    assert.equal(fakeEmail.sent.length, 0);
  } finally {
    await shutdown(ctx);
  }
});

test("POST invitation: idempotent re-POST does NOT re-dispatch email", async () => {
  const fakeEmail = recordingEmailSender();
  const ctx = await startTestServer({emailSender: fakeEmail});
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io7c@example.com",
    );
    const payload = JSON.stringify({
      recipientEmail: "idem-rcpt@example.com",
      role: "viewer",
    });
    const first = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: payload,
      },
    );
    assert.equal(first.status, 201);

    const second = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: payload,
      },
    );
    assert.equal(second.status, 200);
    const secondBody = await second.json();
    assert.equal(secondBody.created, false);

    // Email shipped only on the first (created) call, not the re-POST.
    assert.equal(fakeEmail.sent.length, 1);
  } finally {
    await shutdown(ctx);
  }
});

// ---------- POST accept ----------

test("POST accept: recipient accepts → membership created (200)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io8@example.com",
    );
    const recipient = await makeUser(ctx.store, ctx.baseUrl, "ir8@example.com");

    const create = await ctx.store.createInvitation({
      semyaId: semya.id,
      inviterUserId: owner.userId,
      recipientUserId: recipient.userId,
      role: "editor",
    });
    const token = create.invitation.token;

    const res = await fetch(`${ctx.baseUrl}/v1/invitation/${token}/accept`, {
      method: "POST",
      headers: {Authorization: `Bearer ${recipient.token}`},
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.invitation.status, "accepted");
    assert.equal(body.membership.userId, recipient.userId);
    assert.equal(body.membership.role, "editor");
    assert.equal(body.membership.semyaId, semya.id);

    // Verify membership row exists
    const found = await ctx.store.findMembership(semya.id, recipient.userId);
    assert.equal(found?.role, "editor");
  } finally {
    await shutdown(ctx);
  }
});

test("POST accept: accepted twice rejected (409 INVITATION_NOT_PENDING)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io9@example.com",
    );
    const recipient = await makeUser(ctx.store, ctx.baseUrl, "ir9@example.com");

    const create = await ctx.store.createInvitation({
      semyaId: semya.id,
      inviterUserId: owner.userId,
      recipientUserId: recipient.userId,
      role: "viewer",
    });

    // First accept ok
    const first = await fetch(
      `${ctx.baseUrl}/v1/invitation/${create.invitation.token}/accept`,
      {
        method: "POST",
        headers: {Authorization: `Bearer ${recipient.token}`},
      },
    );
    assert.equal(first.status, 200);

    // Second accept rejected
    const second = await fetch(
      `${ctx.baseUrl}/v1/invitation/${create.invitation.token}/accept`,
      {
        method: "POST",
        headers: {Authorization: `Bearer ${recipient.token}`},
      },
    );
    assert.equal(second.status, 409);
  } finally {
    await shutdown(ctx);
  }
});

test("POST accept: wrong recipient rejected (403 WRONG_RECIPIENT)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io10@example.com",
    );
    const intended = await makeUser(ctx.store, ctx.baseUrl, "ir10@example.com");
    const stranger = await makeUser(ctx.store, ctx.baseUrl, "is10@example.com");

    const create = await ctx.store.createInvitation({
      semyaId: semya.id,
      inviterUserId: owner.userId,
      recipientUserId: intended.userId,
      role: "editor",
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/invitation/${create.invitation.token}/accept`,
      {
        method: "POST",
        headers: {Authorization: `Bearer ${stranger.token}`},
      },
    );
    assert.equal(res.status, 403);
  } finally {
    await shutdown(ctx);
  }
});

test("POST accept: unknown token 404", async () => {
  const ctx = await startTestServer();
  try {
    const recipient = await makeUser(
      ctx.store,
      ctx.baseUrl,
      "ir11@example.com",
    );
    const res = await fetch(
      `${ctx.baseUrl}/v1/invitation/nonexistent-token/accept`,
      {
        method: "POST",
        headers: {Authorization: `Bearer ${recipient.token}`},
      },
    );
    assert.equal(res.status, 404);
  } finally {
    await shutdown(ctx);
  }
});

test("POST accept: expired invitation rejected (409 lazy expiry)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io12@example.com",
    );
    const recipient = await makeUser(
      ctx.store,
      ctx.baseUrl,
      "ir12@example.com",
    );

    // Create with already-past expiry via direct DB manipulation
    // (simpler than waiting 30 days)
    const create = await ctx.store.createInvitation({
      semyaId: semya.id,
      inviterUserId: owner.userId,
      recipientUserId: recipient.userId,
      role: "editor",
    });
    // Mutate to expire in past
    const db = await ctx.store._read();
    const inv = db.semyaInvitations.find((i) => i.id === create.invitation.id);
    inv.expiresAt = new Date(Date.now() - 1000).toISOString();
    await ctx.store._write(db);

    const res = await fetch(
      `${ctx.baseUrl}/v1/invitation/${create.invitation.token}/accept`,
      {
        method: "POST",
        headers: {Authorization: `Bearer ${recipient.token}`},
      },
    );
    assert.equal(res.status, 409);
  } finally {
    await shutdown(ctx);
  }
});

// ---------- DELETE revoke ----------

test("DELETE invitation: inviter revokes (200)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io13@example.com",
    );
    const recipient = await makeUser(
      ctx.store,
      ctx.baseUrl,
      "ir13@example.com",
    );

    const create = await ctx.store.createInvitation({
      semyaId: semya.id,
      inviterUserId: owner.userId,
      recipientUserId: recipient.userId,
      role: "editor",
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation/${create.invitation.id}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.invitation.status, "revoked");
    assert.equal(body.invitation.revokedByUserId, owner.userId);

    // Subsequent accept rejected
    const acceptAfter = await fetch(
      `${ctx.baseUrl}/v1/invitation/${create.invitation.token}/accept`,
      {
        method: "POST",
        headers: {Authorization: `Bearer ${recipient.token}`},
      },
    );
    assert.equal(acceptAfter.status, 409);
  } finally {
    await shutdown(ctx);
  }
});

test("DELETE invitation: editor-с-grant cannot revoke owner's invitation (403)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io14@example.com",
    );
    const editor = await makeUser(ctx.store, ctx.baseUrl, "ie14@example.com");
    const recipient = await makeUser(
      ctx.store,
      ctx.baseUrl,
      "ir14@example.com",
    );

    await ctx.store.addMembership({
      semyaId: semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
      hasInviteGrant: true,
    });

    // Owner creates invitation
    const create = await ctx.store.createInvitation({
      semyaId: semya.id,
      inviterUserId: owner.userId,
      recipientUserId: recipient.userId,
      role: "viewer",
    });

    // Editor (с grant — can invite, но не owner) tries to revoke — 403
    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation/${create.invitation.id}`,
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

test("DELETE invitation: revoke twice rejected (409)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io15@example.com",
    );
    const recipient = await makeUser(
      ctx.store,
      ctx.baseUrl,
      "ir15@example.com",
    );

    const create = await ctx.store.createInvitation({
      semyaId: semya.id,
      inviterUserId: owner.userId,
      recipientUserId: recipient.userId,
      role: "editor",
    });

    const first = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation/${create.invitation.id}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(first.status, 200);

    const second = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation/${create.invitation.id}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(second.status, 409);
  } finally {
    await shutdown(ctx);
  }
});

// ---------- GET /v1/me/pending-invitations (FE9 2026-05-27) ----------
//
// Surface для onboarding wizard к detect «у вас есть приглашение в семью».
// Auth: requireAuth only (anyone authenticated может ask). Matches по
// recipientUserId либо recipientEmail (sans recipientUserId set).
// Soft-deleted семья invitations filtered out.

test("GET /v1/me/pending-invitations: empty список когда никого не пригласили", async () => {
  const ctx = await startTestServer();
  try {
    const user = await makeUser(ctx.store, ctx.baseUrl, "fe9-empty@example.com");
    const res = await fetch(`${ctx.baseUrl}/v1/me/pending-invitations`, {
      headers: {Authorization: `Bearer ${user.token}`},
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.deepEqual(body.invitations, []);
  } finally {
    await shutdown(ctx);
  }
});

test("GET /v1/me/pending-invitations: returns explicit userId-targeted invitation с semyaName", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "fe9-owner@example.com",
    );
    const recipient = await makeUser(
      ctx.store,
      ctx.baseUrl,
      "fe9-recipient@example.com",
    );
    // Owner creates invitation explicitly targeting recipient by userId.
    const createRes = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({
          recipientUserId: recipient.userId,
          role: "editor",
        }),
      },
    );
    assert.equal(createRes.status, 201);
    // Recipient fetches own pending.
    const res = await fetch(`${ctx.baseUrl}/v1/me/pending-invitations`, {
      headers: {Authorization: `Bearer ${recipient.token}`},
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.invitations.length, 1);
    const inv = body.invitations[0];
    assert.equal(inv.semyaId, semya.id);
    assert.equal(inv.semyaName, "Тестовая семья");
    assert.equal(inv.recipientUserId, recipient.userId);
    assert.equal(inv.status, "pending");
    assert.equal(inv.role, "editor");
  } finally {
    await shutdown(ctx);
  }
});

test("GET /v1/me/pending-invitations: matches email-only invitation (sent before user registered) after recipient signs up", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "fe9-email-owner@example.com",
    );
    // Owner creates email-only invitation BEFORE recipient registers.
    const createRes = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({
          recipientEmail: "fe9-late-arrival@example.com",
          role: "viewer",
        }),
      },
    );
    assert.equal(createRes.status, 201);
    // Recipient registers с тем же email.
    const recipient = await makeUser(
      ctx.store,
      ctx.baseUrl,
      "fe9-late-arrival@example.com",
    );
    const res = await fetch(`${ctx.baseUrl}/v1/me/pending-invitations`, {
      headers: {Authorization: `Bearer ${recipient.token}`},
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.invitations.length, 1);
    assert.equal(body.invitations[0].recipientEmail, "fe9-late-arrival@example.com");
    assert.equal(body.invitations[0].recipientUserId, null);
  } finally {
    await shutdown(ctx);
  }
});

test("GET /v1/me/pending-invitations: filters out non-pending statuses", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "fe9-filter-owner@example.com",
    );
    const recipient = await makeUser(
      ctx.store,
      ctx.baseUrl,
      "fe9-filter-recipient@example.com",
    );
    // Create + accept invitation → status=accepted.
    const createRes = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({
          recipientUserId: recipient.userId,
          role: "editor",
        }),
      },
    );
    const created = await createRes.json();
    await fetch(`${ctx.baseUrl}/v1/invitation/${created.invitation.token}/accept`, {
      method: "POST",
      headers: {Authorization: `Bearer ${recipient.token}`},
    });
    // Pending list now должна быть пустой.
    const res = await fetch(`${ctx.baseUrl}/v1/me/pending-invitations`, {
      headers: {Authorization: `Bearer ${recipient.token}`},
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.invitations.length, 0);
  } finally {
    await shutdown(ctx);
  }
});

test("GET /v1/me/pending-invitations: unauthorized rejected", async () => {
  const ctx = await startTestServer();
  try {
    const res = await fetch(`${ctx.baseUrl}/v1/me/pending-invitations`);
    assert.equal(res.status, 401);
  } finally {
    await shutdown(ctx);
  }
});

test("DELETE invitation: outsider can't even probe IDs (403 via семья access)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, semya} = await seedSemyaWithOwner(
      ctx.store,
      ctx.baseUrl,
      "io16@example.com",
    );
    const outsider = await makeUser(
      ctx.store,
      ctx.baseUrl,
      "out16@example.com",
    );
    const recipient = await makeUser(
      ctx.store,
      ctx.baseUrl,
      "ir16@example.com",
    );

    const create = await ctx.store.createInvitation({
      semyaId: semya.id,
      inviterUserId: owner.userId,
      recipientUserId: recipient.userId,
      role: "editor",
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${semya.id}/invitation/${create.invitation.id}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${outsider.token}`},
      },
    );
    // requireSemyaAccess returns 403 first (outsider не member вообще)
    assert.equal(res.status, 403);
  } finally {
    await shutdown(ctx);
  }
});
