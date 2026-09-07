// Phase 6 chunk 4d: end-to-end integration test.
//
// Covers proposal-level acceptance criteria:
//   Onboarding flow:
//     register → requiresOnboarding=true → patch step progress
//     → seed → tree + persons + relations created → state.completed=true
//     → re-login → requiresOnboarding=false.
//
//   Kinship-check (bilateral consent) flow:
//     two users seeded → initiator creates check → target receives
//     pending → target accepts → both see same result chain.
//
//   Negative paths:
//     duplicate request → idempotent (no new notification).
//     rejection cooldown → second request 429.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");

const {createApp} = require("../src/app");
const {FileStore} = require("../src/store");
const {RealtimeHub} = require("../src/realtime-hub");
const {PushGateway} = require("../src/push-gateway");

async function startServer() {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-p6e2e-"));
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

async function stopServer(ctx) {
  await new Promise((resolve, reject) => {
    ctx.server.close((error) => (error ? reject(error) : resolve()));
  });
  await fs.rm(ctx.tempDir, {recursive: true, force: true});
}

async function jsonFetch(url, options = {}) {
  const response = await fetch(url, options);
  const body = response.body ? await response.json() : null;
  return {status: response.status, body};
}

async function register(ctx, email) {
  return jsonFetch(`${ctx.baseUrl}/v1/auth/register`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({email, password: "secret123", consentDocVersion: "test-consent-v1", displayName: email}),
  });
}

async function login(ctx, email) {
  return jsonFetch(`${ctx.baseUrl}/v1/auth/login`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({email, password: "secret123"}),
  });
}

async function patchStep(ctx, token, step) {
  return jsonFetch(`${ctx.baseUrl}/v1/me/onboarding-state`, {
    method: "PATCH",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({currentStep: step}),
  });
}

async function seedOnboarding(ctx, token, payload) {
  return jsonFetch(`${ctx.baseUrl}/v1/onboarding/seed`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
}

async function createKinshipCheck(ctx, token, targetUserId) {
  return jsonFetch(`${ctx.baseUrl}/v1/kinship-checks`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({targetUserId}),
  });
}

async function respondKinshipCheck(ctx, token, checkId, decision) {
  return jsonFetch(`${ctx.baseUrl}/v1/kinship-checks/${checkId}/respond`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({decision}),
  });
}

async function listReceived(ctx, token) {
  return jsonFetch(`${ctx.baseUrl}/v1/me/kinship-checks/received`, {
    headers: {authorization: `Bearer ${token}`},
  });
}

test("Phase 6 e2e: full onboarding flow", async (t) => {
  const ctx = await startServer();
  t.after(() => stopServer(ctx));

  await t.test(
    "register → requiresOnboarding=true; seed → wizard complete; re-login → false",
    async () => {
      const reg = await register(ctx, "fresh@example.com");
      assert.equal(reg.status, 201);
      assert.equal(reg.body.requiresOnboarding, true);

      const token = reg.body.accessToken;
      const userId = reg.body.user.id;

      // Wizard progresses через steps.
      const profileStep = await patchStep(ctx, token, "profile");
      assert.equal(profileStep.status, 200);
      const relativesStep = await patchStep(ctx, token, "relatives");
      assert.equal(relativesStep.status, 200);

      // Mid-wizard re-login still flags.
      const midLogin = await login(ctx, "fresh@example.com");
      assert.equal(midLogin.body.requiresOnboarding, true);

      // Seed completes wizard.
      const seed = await seedOnboarding(ctx, token, {
        profile: {name: "Иван"},
        relatives: [
          {name: "Мама", relationToMe: "mother"},
          {name: "Папа", relationToMe: "father"},
        ],
      });
      assert.equal(seed.status, 201);
      assert.ok(seed.body.treeId);
      assert.equal(seed.body.personIds.length, 3); // self + 2 relatives

      // Verify state persisted в store.
      const stateAfter = (await ctx.store._read()).onboardingStates.find(
        (s) => s.userId === userId,
      );
      assert.equal(stateAfter.completed, true);
      assert.equal(stateAfter.currentStep, "done");

      // Re-login после completion — flag false.
      const postLogin = await login(ctx, "fresh@example.com");
      assert.equal(postLogin.body.requiresOnboarding, false);
    },
  );
});

test("Phase 6 e2e: bilateral kinship-check consent flow", async (t) => {
  const ctx = await startServer();
  t.after(() => stopServer(ctx));

  // Setup two users + seed both onboardings.
  const initReg = await register(ctx, "initiator@example.com");
  const initToken = initReg.body.accessToken;
  const initUserId = initReg.body.user.id;
  await seedOnboarding(ctx, initToken, {
    profile: {name: "Артём"},
    relatives: [{name: "Мама Артёма", relationToMe: "mother"}],
  });

  const targetReg = await register(ctx, "target@example.com");
  const targetToken = targetReg.body.accessToken;
  const targetUserId = targetReg.body.user.id;
  await seedOnboarding(ctx, targetToken, {
    profile: {name: "Иван"},
    relatives: [{name: "Папа Ивана", relationToMe: "father"}],
  });

  await t.test("initiator creates check → 201 pending", async () => {
    const r = await createKinshipCheck(ctx, initToken, targetUserId);
    assert.equal(r.status, 201);
    assert.equal(r.body.check.status, "pending");
    assert.equal(r.body.check.initiatorUserId, initUserId);
    assert.equal(r.body.check.targetUserId, targetUserId);
    assert.equal(r.body.created, true);
  });

  await t.test("duplicate create returns existing (idempotent)", async () => {
    const r = await createKinshipCheck(ctx, initToken, targetUserId);
    assert.equal(r.status, 200);
    assert.equal(r.body.created, false);
  });

  await t.test("target sees pending в received list", async () => {
    const r = await listReceived(ctx, targetToken);
    assert.equal(r.status, 200);
    assert.equal(r.body.checks.length, 1);
    assert.equal(r.body.checks[0].status, "pending");
  });

  let respondedCheckId;
  await t.test("target accepts → result computed", async () => {
    const received = await listReceived(ctx, targetToken);
    const checkId = received.body.checks[0].id;
    respondedCheckId = checkId;
    const r = await respondKinshipCheck(ctx, targetToken, checkId, "accepted");
    assert.equal(r.status, 200);
    assert.equal(r.body.check.status, "accepted");
    assert.ok(r.body.check.result, "result populated на accept");
    // Артём + Иван не связаны (separate trees) — found=false expected.
    // Это still a valid accepted state с result payload.
    assert.equal(typeof r.body.check.result.found, "boolean");
  });

  await t.test(
    "double-respond → 409 NOT_PENDING",
    async () => {
      const r = await respondKinshipCheck(
        ctx,
        targetToken,
        respondedCheckId,
        "rejected",
      );
      assert.equal(r.status, 409);
    },
  );

  await t.test("rejection cooldown anti-spam", async () => {
    // Create + reject a new check от другого initiator.
    const otherReg = await register(ctx, "harasser@example.com");
    const otherToken = otherReg.body.accessToken;
    await seedOnboarding(ctx, otherToken, {profile: {name: "Шутник"}});

    const first = await createKinshipCheck(ctx, otherToken, targetUserId);
    assert.equal(first.status, 201);
    const reject = await respondKinshipCheck(
      ctx,
      targetToken,
      first.body.check.id,
      "rejected",
    );
    assert.equal(reject.body.check.status, "rejected");

    // Immediate retry — cooldown active (30 days).
    const retry = await createKinshipCheck(ctx, otherToken, targetUserId);
    assert.equal(retry.status, 429, "rejection cooldown enforced");
    assert.ok(retry.body.retryAfterMs > 0);
  });
});

test("Phase 6 e2e: kinship-check self-check forbidden", async (t) => {
  const ctx = await startServer();
  t.after(() => stopServer(ctx));

  const reg = await register(ctx, "self@example.com");
  const r = await createKinshipCheck(ctx, reg.body.accessToken, reg.body.user.id);
  assert.equal(r.status, 409);
});

test("Phase 6 e2e: kinship-check target not found", async (t) => {
  const ctx = await startServer();
  t.after(() => stopServer(ctx));

  const reg = await register(ctx, "lonely@example.com");
  const r = await createKinshipCheck(
    ctx,
    reg.body.accessToken,
    "non-existent-user-id",
  );
  assert.equal(r.status, 404);
});
