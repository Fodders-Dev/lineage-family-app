// Phase 6 chunk 4a (PHASE-6-PROPOSAL.md §2.8 + DECISIONS 2026-05-14):
// `requiresOnboarding` flag in auth responses — post-signup redirect
// Option A simplified.

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-redir-"));
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

async function register(ctx, email) {
  const response = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({email, password: "secret123", consentDocVersion: "test-consent-v1", displayName: "Test"}),
  });
  const body = await response.json();
  return {status: response.status, body};
}

async function login(ctx, email) {
  const response = await fetch(`${ctx.baseUrl}/v1/auth/login`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({email, password: "secret123"}),
  });
  const body = await response.json();
  return {status: response.status, body};
}

async function patchOnboardingStep(ctx, token, step) {
  const response = await fetch(`${ctx.baseUrl}/v1/me/onboarding-state`, {
    method: "PATCH",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({currentStep: step}),
  });
  return response.json();
}

async function seedOnboarding(ctx, token) {
  const response = await fetch(`${ctx.baseUrl}/v1/onboarding/seed`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      profile: {name: "Ваня"},
      relatives: [{name: "Мама", relationToMe: "mother"}],
    }),
  });
  return response.json();
}

test("Phase 6 chunk 4a: requiresOnboarding flag in auth responses", async (t) => {
  const ctx = await startTestServer();
  t.after(() => stopTestServer(ctx));

  await t.test("fresh register → requiresOnboarding=true", async () => {
    const {status, body} = await register(ctx, "fresh@example.com");
    assert.equal(status, 201);
    assert.equal(body.requiresOnboarding, true);
    assert.ok(body.accessToken);
  });

  await t.test("legacy user (no record) login → requiresOnboarding=false", async () => {
    // Simulate pre-Phase-6 user: create directly via store без
    // going through /v1/auth/register (which now creates initial
    // onboarding state). Это shape, который существующие aккаунты
    // имеют на момент Phase 6 rollout.
    const legacyUser = await ctx.store.createUser({
      email: "legacy@example.com",
      password: "secret123",
      consentDocVersion: "test-consent-v1",
      displayName: "Legacy",
    });
    assert.ok(legacyUser.id);
    const {status, body} = await login(ctx, "legacy@example.com");
    assert.equal(status, 200);
    assert.equal(
      body.requiresOnboarding,
      false,
      "legacy user без onboardingStates record не должен redirect'ить",
    );
  });

  await t.test(
    "register-then-relogin (никогда не открывал wizard) → still true",
    async () => {
      // Funnel-leak guard: client crash после register, before opening
      // /setup. Backend persists initial state in register handler
      // → re-login returns flag=true → user redirects к wizard.
      await register(ctx, "crashed@example.com");
      const {body} = await login(ctx, "crashed@example.com");
      assert.equal(
        body.requiresOnboarding,
        true,
        "post-register state persists даже если client crashed pre-wizard",
      );
    },
  );

  await t.test("mid-wizard login → requiresOnboarding=true", async () => {
    const registerRes = await register(ctx, "midwizard@example.com");
    const token = registerRes.body.accessToken;
    // Simulate user starting wizard (PATCH к profile step) but не
    // finishing seed.
    await patchOnboardingStep(ctx, token, "profile");
    const {body} = await login(ctx, "midwizard@example.com");
    assert.equal(
      body.requiresOnboarding,
      true,
      "mid-wizard user должен resume в /setup",
    );
  });

  await t.test("login after seed completes → requiresOnboarding=false", async () => {
    const registerRes = await register(ctx, "completed@example.com");
    const token = registerRes.body.accessToken;
    await patchOnboardingStep(ctx, token, "profile");
    const seedRes = await seedOnboarding(ctx, token);
    assert.ok(seedRes.treeId, "seed должен вернуть treeId");
    const {body} = await login(ctx, "completed@example.com");
    assert.equal(
      body.requiresOnboarding,
      false,
      "completed user уже прошёл wizard — не redirect'ить",
    );
  });
});

test("Phase 6 chunk 4a: store.hasIncompleteOnboarding boundary cases", async (t) => {
  const ctx = await startTestServer();
  t.after(() => stopTestServer(ctx));

  await t.test("no record → false (legacy user)", async () => {
    // Bypass register endpoint (which now creates initial state row);
    // create user directly through store like Phase 1 era did.
    const legacyUser = await ctx.store.createUser({
      email: "leg2@example.com",
      password: "secret123",
      displayName: "Leg2",
    });
    const flag = await ctx.store.hasIncompleteOnboarding({
      userId: legacyUser.id,
    });
    assert.equal(flag, false);
  });

  await t.test("record with completed=false → true", async () => {
    const {body} = await register(ctx, "mid2@example.com");
    await patchOnboardingStep(ctx, body.accessToken, "relatives");
    const flag = await ctx.store.hasIncompleteOnboarding({
      userId: body.user.id,
    });
    assert.equal(flag, true);
  });

  await t.test("missing userId → false", async () => {
    const flag = await ctx.store.hasIncompleteOnboarding({userId: ""});
    assert.equal(flag, false);
  });
});
