// Phase 6 chunk 1: kinship-checks tests.
//
// Covers (PHASE-6-PROPOSAL.md §2.5/§2.6 + DECISIONS.md 2026-05-13):
// • POST /kinship-checks — create pending; idempotent duplicate;
//   self-check forbidden; 30d rejection cooldown.
// • POST /kinship-checks/:id/respond — accept (BFS computed) /
//   reject; permission gate (only target).
// • GET /me/kinship-checks/received + /issued.
// • Expiry sweep (on-read, simulated via direct store mutation).
// • Notification dispatch на create/accept/reject.

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-kc-"));
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

async function createCheck(ctx, token, targetUserId) {
  return fetch(`${ctx.baseUrl}/v1/kinship-checks`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({targetUserId}),
  });
}

async function respond(ctx, token, checkId, decision) {
  return fetch(`${ctx.baseUrl}/v1/kinship-checks/${checkId}/respond`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({decision}),
  });
}

async function revoke(ctx, token, checkId) {
  return fetch(`${ctx.baseUrl}/v1/kinship-checks/${checkId}/revoke`, {
    method: "POST",
    headers: {authorization: `Bearer ${token}`},
  });
}

test("POST /kinship-checks: no auth → 401", async () => {
  const ctx = await startTestServer();
  try {
    const response = await fetch(`${ctx.baseUrl}/v1/kinship-checks`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({targetUserId: "x"}),
    });
    assert.equal(response.status, 401);
  } finally {
    await stopTestServer(ctx);
  }
});

test(
  "POST /kinship-checks: self-check → 409 forbidden",
  async () => {
    const ctx = await startTestServer();
    try {
      const user = await registerUser(ctx, "self@test.app");
      const response = await createCheck(ctx, user.accessToken, user.user.id);
      assert.equal(response.status, 409);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /kinship-checks: target not found → 404",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init@test.app");
      const response = await createCheck(
        ctx,
        initiator.accessToken,
        "ghost-user-id",
      );
      assert.equal(response.status, 404);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /kinship-checks: success → 201 + pending check + target notification",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init-ok@test.app");
      const target = await registerUser(ctx, "target-ok@test.app");
      const response = await createCheck(
        ctx,
        initiator.accessToken,
        target.user.id,
      );
      assert.equal(response.status, 201);
      const body = await response.json();
      assert.equal(body.check.status, "pending");
      assert.equal(body.check.initiatorUserId, initiator.user.id);
      assert.equal(body.check.targetUserId, target.user.id);
      assert.equal(body.created, true);
      assert.ok(body.check.expiresAt);

      // Notification dispatched к target.
      const db = await ctx.store._read();
      const notification = db.notifications.find(
        (n) =>
          n.userId === target.user.id && n.type === "kinship_check_received",
      );
      assert.ok(notification, "target должен получить kinship_check_received");
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /kinship-checks: duplicate pending → 200 + same id + no new notification",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init-dup@test.app");
      const target = await registerUser(ctx, "target-dup@test.app");
      const r1 = await createCheck(ctx, initiator.accessToken, target.user.id);
      const b1 = await r1.json();
      const r2 = await createCheck(ctx, initiator.accessToken, target.user.id);
      assert.equal(r2.status, 200);
      const b2 = await r2.json();
      assert.equal(b2.created, false);
      assert.equal(b2.check.id, b1.check.id);

      // Only one notification dispatched.
      const db = await ctx.store._read();
      const notifications = db.notifications.filter(
        (n) =>
          n.userId === target.user.id && n.type === "kinship_check_received",
      );
      assert.equal(notifications.length, 1);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /kinship-checks/:id/respond: only target can respond → 403 other",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init-perm@test.app");
      const target = await registerUser(ctx, "target-perm@test.app");
      const stranger = await registerUser(ctx, "stranger@test.app");
      const r1 = await createCheck(ctx, initiator.accessToken, target.user.id);
      const b1 = await r1.json();
      const response = await respond(
        ctx,
        stranger.accessToken,
        b1.check.id,
        "accepted",
      );
      assert.equal(response.status, 403);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST .../respond: target accepts → check.status=accepted + result + notification",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init-acc@test.app");
      const target = await registerUser(ctx, "target-acc@test.app");
      const r1 = await createCheck(ctx, initiator.accessToken, target.user.id);
      const b1 = await r1.json();

      const r2 = await respond(
        ctx,
        target.accessToken,
        b1.check.id,
        "accepted",
      );
      assert.equal(r2.status, 200);
      const b2 = await r2.json();
      assert.equal(b2.check.status, "accepted");
      assert.ok(b2.check.respondedAt);
      assert.ok(b2.check.result, "result должен быть populated");
      // No direct relation between fresh accounts → found=false
      // либо unable to determine.
      assert.equal(typeof b2.check.result.found, "boolean");

      // Notification dispatched к initiator.
      const db = await ctx.store._read();
      const notification = db.notifications.find(
        (n) =>
          n.userId === initiator.user.id &&
          n.type === "kinship_check_confirmed",
      );
      assert.ok(notification);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST .../respond: target rejects → check.status=rejected + decline notification",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init-rej@test.app");
      const target = await registerUser(ctx, "target-rej@test.app");
      const r1 = await createCheck(ctx, initiator.accessToken, target.user.id);
      const b1 = await r1.json();

      const r2 = await respond(
        ctx,
        target.accessToken,
        b1.check.id,
        "rejected",
      );
      assert.equal(r2.status, 200);
      const b2 = await r2.json();
      assert.equal(b2.check.status, "rejected");

      const db = await ctx.store._read();
      const notification = db.notifications.find(
        (n) =>
          n.userId === initiator.user.id && n.type === "kinship_check_declined",
      );
      assert.ok(notification);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST .../respond: already responded → 409 conflict",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init-twice@test.app");
      const target = await registerUser(ctx, "target-twice@test.app");
      const r1 = await createCheck(ctx, initiator.accessToken, target.user.id);
      const b1 = await r1.json();
      await respond(ctx, target.accessToken, b1.check.id, "accepted");
      const r2 = await respond(
        ctx,
        target.accessToken,
        b1.check.id,
        "rejected",
      );
      assert.equal(r2.status, 409);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /kinship-checks: rejection cooldown 30d after declined → 429",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init-cool@test.app");
      const target = await registerUser(ctx, "target-cool@test.app");
      const r1 = await createCheck(ctx, initiator.accessToken, target.user.id);
      const b1 = await r1.json();
      await respond(ctx, target.accessToken, b1.check.id, "rejected");

      // Re-request immediately → 429.
      const r2 = await createCheck(ctx, initiator.accessToken, target.user.id);
      assert.equal(r2.status, 429);
      const b2 = await r2.json();
      assert.ok(b2.retryAfterMs > 0);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "GET /me/kinship-checks/received + /issued: separation",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init-list@test.app");
      const target = await registerUser(ctx, "target-list@test.app");
      await createCheck(ctx, initiator.accessToken, target.user.id);

      // Initiator's issued.
      const issued = await fetch(
        `${ctx.baseUrl}/v1/me/kinship-checks/issued`,
        {headers: {authorization: `Bearer ${initiator.accessToken}`}},
      );
      const issuedBody = await issued.json();
      assert.equal(issuedBody.checks.length, 1);
      assert.equal(issuedBody.checks[0].initiatorUserId, initiator.user.id);

      // Target's received.
      const received = await fetch(
        `${ctx.baseUrl}/v1/me/kinship-checks/received`,
        {headers: {authorization: `Bearer ${target.accessToken}`}},
      );
      const receivedBody = await received.json();
      assert.equal(receivedBody.checks.length, 1);
      assert.equal(receivedBody.checks[0].targetUserId, target.user.id);

      // Initiator NOT в received.
      const initiatorReceived = await fetch(
        `${ctx.baseUrl}/v1/me/kinship-checks/received`,
        {headers: {authorization: `Bearer ${initiator.accessToken}`}},
      );
      const initiatorReceivedBody = await initiatorReceived.json();
      assert.equal(initiatorReceivedBody.checks.length, 0);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "expiry sweep: pending check past 14d → status=expired on-read",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init-exp@test.app");
      const target = await registerUser(ctx, "target-exp@test.app");
      const r1 = await createCheck(ctx, initiator.accessToken, target.user.id);
      const b1 = await r1.json();

      // Mutate expiresAt в past.
      const db = await ctx.store._read();
      const idx = db.kinshipChecks.findIndex((c) => c.id === b1.check.id);
      db.kinshipChecks[idx].expiresAt = new Date(
        Date.now() - 86_400_000,
      ).toISOString(); // yesterday
      await ctx.store._write(db);

      // Trigger sweep via list endpoint.
      const list = await fetch(
        `${ctx.baseUrl}/v1/me/kinship-checks/issued`,
        {headers: {authorization: `Bearer ${initiator.accessToken}`}},
      );
      const listBody = await list.json();
      assert.equal(listBody.checks[0].status, "expired");
    } finally {
      await stopTestServer(ctx);
    }
  },
);

// ── Phase 6.5: revoke ─────────────────────────────────────────────

test(
  "POST /kinship-checks/:id/revoke: initiator revokes own pending → 200 + revoked + target notification",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init-revoke@test.app");
      const target = await registerUser(ctx, "target-revoke@test.app");
      const r1 = await createCheck(ctx, initiator.accessToken, target.user.id);
      const b1 = await r1.json();

      const response = await revoke(ctx, initiator.accessToken, b1.check.id);
      assert.equal(response.status, 200);
      const body = await response.json();
      assert.equal(body.check.status, "revoked");
      assert.ok(body.check.revokedAt, "revokedAt должен быть populated");

      // Target receives kinship_check_revoked notification.
      const db = await ctx.store._read();
      const notification = db.notifications.find(
        (n) =>
          n.userId === target.user.id && n.type === "kinship_check_revoked",
      );
      assert.ok(
        notification,
        "target должен получить kinship_check_revoked",
      );
      assert.equal(
        notification.data.kinshipCheckId,
        b1.check.id,
        "notification.data carries kinshipCheckId",
      );
      assert.equal(notification.data.status, "revoked");
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /kinship-checks/:id/revoke: non-initiator (random user) → 403",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init-rev-403@test.app");
      const target = await registerUser(ctx, "target-rev-403@test.app");
      const stranger = await registerUser(ctx, "stranger-rev@test.app");
      const r1 = await createCheck(ctx, initiator.accessToken, target.user.id);
      const b1 = await r1.json();

      const response = await revoke(ctx, stranger.accessToken, b1.check.id);
      assert.equal(response.status, 403);

      // Original pending unchanged.
      const list = await fetch(
        `${ctx.baseUrl}/v1/me/kinship-checks/issued`,
        {headers: {authorization: `Bearer ${initiator.accessToken}`}},
      );
      const listBody = await list.json();
      assert.equal(listBody.checks[0].status, "pending");
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /kinship-checks/:id/revoke: target tries to revoke → 403 (only initiator)",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init-revt-403@test.app");
      const target = await registerUser(ctx, "target-revt-403@test.app");
      const r1 = await createCheck(ctx, initiator.accessToken, target.user.id);
      const b1 = await r1.json();

      const response = await revoke(ctx, target.accessToken, b1.check.id);
      assert.equal(response.status, 403);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /kinship-checks/:id/revoke: already accepted → 409 (cannot revoke after respond)",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init-rev-acc@test.app");
      const target = await registerUser(ctx, "target-rev-acc@test.app");
      const r1 = await createCheck(ctx, initiator.accessToken, target.user.id);
      const b1 = await r1.json();
      await respond(ctx, target.accessToken, b1.check.id, "accepted");

      const response = await revoke(ctx, initiator.accessToken, b1.check.id);
      assert.equal(response.status, 409);
      const body = await response.json();
      assert.equal(body.currentStatus, "accepted");
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /kinship-checks/:id/revoke: already rejected → 409",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init-rev-rej@test.app");
      const target = await registerUser(ctx, "target-rev-rej@test.app");
      const r1 = await createCheck(ctx, initiator.accessToken, target.user.id);
      const b1 = await r1.json();
      await respond(ctx, target.accessToken, b1.check.id, "rejected");

      const response = await revoke(ctx, initiator.accessToken, b1.check.id);
      assert.equal(response.status, 409);
      const body = await response.json();
      assert.equal(body.currentStatus, "rejected");
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /kinship-checks/:id/revoke: idempotent re-call → 409 NOT_PENDING (no double notification)",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init-rev-idem@test.app");
      const target = await registerUser(ctx, "target-rev-idem@test.app");
      const r1 = await createCheck(ctx, initiator.accessToken, target.user.id);
      const b1 = await r1.json();

      // First revoke — success.
      const first = await revoke(ctx, initiator.accessToken, b1.check.id);
      assert.equal(first.status, 200);

      // Second revoke на already-revoked → 409.
      const second = await revoke(ctx, initiator.accessToken, b1.check.id);
      assert.equal(second.status, 409);
      const secondBody = await second.json();
      assert.equal(secondBody.currentStatus, "revoked");

      // Only one revoked notification dispatched (no double).
      const db = await ctx.store._read();
      const revokedNotifications = db.notifications.filter(
        (n) =>
          n.userId === target.user.id && n.type === "kinship_check_revoked",
      );
      assert.equal(
        revokedNotifications.length,
        1,
        "exactly one kinship_check_revoked notification",
      );
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /kinship-checks/:id/revoke: non-existent check → 404",
  async () => {
    const ctx = await startTestServer();
    try {
      const initiator = await registerUser(ctx, "init-rev-404@test.app");
      const response = await revoke(
        ctx,
        initiator.accessToken,
        "ghost-check-id-deadbeef",
      );
      assert.equal(response.status, 404);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /kinship-checks/:id/revoke: no auth → 401",
  async () => {
    const ctx = await startTestServer();
    try {
      const response = await fetch(
        `${ctx.baseUrl}/v1/kinship-checks/some-id/revoke`,
        {method: "POST"},
      );
      assert.equal(response.status, 401);
    } finally {
      await stopTestServer(ctx);
    }
  },
);
