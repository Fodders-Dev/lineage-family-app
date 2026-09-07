// Ship Q1 (2026-05-25): onboarding skip endpoint + state semantics.
//
// User-blocking issue: registration wizard mandatory blocks user от
// reaching main app (chats, calls). Skip endpoint lets user defer
// wizard, banner на home reminds к completion. Backend marks
// skipped=true; session.requiresOnboarding=false through
// hasIncompleteOnboarding's skip-aware check.
//
// Test coverage:
//   * POST /v1/me/onboarding-state/skip happy path
//   * Idempotent re-call returns same state
//   * No-op если already completed (completion overrides skip)
//   * hasIncompleteOnboarding returns false post-skip
//   * Re-entering wizard через PATCH currentStep='done' clears
//     skipped flag (completion overrides skip)
//   * getOnboardingState returns skipped/skippedAt fields
//   * Backward-compat: pre-Q1 records без skipped field default к
//     skipped=false при read

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-skip-"));
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

async function makeUser(baseUrl, email) {
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
  return {userId: body.user.id, token: body.accessToken};
}

test(
  "Skip endpoint: sets state.skipped=true + skippedAt timestamp (200)",
  async () => {
    const ctx = await startTestServer();
    try {
      const user = await makeUser(ctx.baseUrl, "skip1@example.com");

      const res = await fetch(
        `${ctx.baseUrl}/v1/me/onboarding-state/skip`,
        {
          method: "POST",
          headers: {Authorization: `Bearer ${user.token}`},
        },
      );
      assert.equal(res.status, 200);
      const body = await res.json();
      assert.equal(body.state.skipped, true);
      assert.ok(body.state.skippedAt, "skippedAt timestamp set");
      assert.equal(body.state.completed, false);
      assert.equal(body.state.currentStep, "welcome");
    } finally {
      await shutdown(ctx);
    }
  },
);

test(
  "Skip endpoint: idempotent re-call no-ops (same state, no mutation)",
  async () => {
    const ctx = await startTestServer();
    try {
      const user = await makeUser(ctx.baseUrl, "skip2@example.com");

      const first = await fetch(
        `${ctx.baseUrl}/v1/me/onboarding-state/skip`,
        {
          method: "POST",
          headers: {Authorization: `Bearer ${user.token}`},
        },
      );
      const firstBody = await first.json();
      const firstSkippedAt = firstBody.state.skippedAt;

      // Brief wait чтобы timestamp difference было observable если bug
      await new Promise((r) => setTimeout(r, 10));

      const second = await fetch(
        `${ctx.baseUrl}/v1/me/onboarding-state/skip`,
        {
          method: "POST",
          headers: {Authorization: `Bearer ${user.token}`},
        },
      );
      const secondBody = await second.json();
      assert.equal(secondBody.state.skipped, true);
      assert.equal(
        secondBody.state.skippedAt,
        firstSkippedAt,
        "skippedAt unchanged on idempotent re-call",
      );
    } finally {
      await shutdown(ctx);
    }
  },
);

test(
  "Skip endpoint: completion overrides skip — wizard finished, skip flag cleared",
  async () => {
    const ctx = await startTestServer();
    try {
      const user = await makeUser(ctx.baseUrl, "skip3@example.com");

      // Skip first
      await fetch(`${ctx.baseUrl}/v1/me/onboarding-state/skip`, {
        method: "POST",
        headers: {Authorization: `Bearer ${user.token}`},
      });

      // Now complete wizard via PATCH currentStep='done'
      const done = await fetch(
        `${ctx.baseUrl}/v1/me/onboarding-state`,
        {
          method: "PATCH",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${user.token}`,
          },
          body: JSON.stringify({currentStep: "done"}),
        },
      );
      const doneBody = await done.json();
      assert.equal(doneBody.state.completed, true);
      assert.equal(
        doneBody.state.skipped,
        false,
        "completion clears skip flag",
      );
      assert.equal(doneBody.state.skippedAt, null);

      // Subsequent skip — no-op (completion takes precedence)
      const skipAgain = await fetch(
        `${ctx.baseUrl}/v1/me/onboarding-state/skip`,
        {
          method: "POST",
          headers: {Authorization: `Bearer ${user.token}`},
        },
      );
      const skipAgainBody = await skipAgain.json();
      assert.equal(skipAgainBody.state.completed, true);
      assert.equal(skipAgainBody.state.skipped, false);
    } finally {
      await shutdown(ctx);
    }
  },
);

test(
  "GET state returns skipped/skippedAt fields (backward-compat default false)",
  async () => {
    const ctx = await startTestServer();
    try {
      const user = await makeUser(ctx.baseUrl, "skip4@example.com");

      // Fresh user — no record yet, default fields present
      const fresh = await fetch(
        `${ctx.baseUrl}/v1/me/onboarding-state`,
        {headers: {Authorization: `Bearer ${user.token}`}},
      );
      const freshBody = await fresh.json();
      assert.equal(freshBody.state.skipped, false);
      assert.equal(freshBody.state.skippedAt, null);

      // After skip
      await fetch(`${ctx.baseUrl}/v1/me/onboarding-state/skip`, {
        method: "POST",
        headers: {Authorization: `Bearer ${user.token}`},
      });
      const after = await fetch(
        `${ctx.baseUrl}/v1/me/onboarding-state`,
        {headers: {Authorization: `Bearer ${user.token}`}},
      );
      const afterBody = await after.json();
      assert.equal(afterBody.state.skipped, true);
      assert.ok(afterBody.state.skippedAt);
    } finally {
      await shutdown(ctx);
    }
  },
);

test(
  "hasIncompleteOnboarding returns false для skipped state (unblocks mama)",
  async () => {
    const ctx = await startTestServer();
    try {
      const user = await makeUser(ctx.baseUrl, "skip5@example.com");

      // Register flow auto-creates onboardingStates row с
      // currentStep='welcome' (см. auth-session-routes.js:101).
      // Поэтому fresh-from-register user HAS state record и
      // hasIncompleteOnboarding returns true.
      const midWizard = await ctx.store.hasIncompleteOnboarding({
        userId: user.userId,
      });
      assert.equal(
        midWizard,
        true,
        "newly-registered user requires onboarding",
      );

      // After skip — returns false (мама unblocked)
      await fetch(`${ctx.baseUrl}/v1/me/onboarding-state/skip`, {
        method: "POST",
        headers: {Authorization: `Bearer ${user.token}`},
      });
      const afterSkip = await ctx.store.hasIncompleteOnboarding({
        userId: user.userId,
      });
      assert.equal(
        afterSkip,
        false,
        "skipped user no longer requires onboarding — unblocks mama",
      );
    } finally {
      await shutdown(ctx);
    }
  },
);

test(
  "Session response: requiresOnboarding=false after skip (unblocks redirect)",
  async () => {
    const ctx = await startTestServer();
    try {
      const user = await makeUser(ctx.baseUrl, "skip6@example.com");

      // Force wizard-pending state
      await fetch(`${ctx.baseUrl}/v1/me/onboarding-state`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${user.token}`,
        },
        body: JSON.stringify({currentStep: "welcome"}),
      });

      // Login response должна carry requiresOnboarding=true
      const loginRes = await fetch(`${ctx.baseUrl}/v1/auth/login`, {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({
          email: "skip6@example.com",
          password: "Test-Password-123!",
        }),
      });
      const loginBody = await loginRes.json();
      assert.equal(loginBody.requiresOnboarding, true);

      // Skip
      await fetch(`${ctx.baseUrl}/v1/me/onboarding-state/skip`, {
        method: "POST",
        headers: {Authorization: `Bearer ${loginBody.accessToken}`},
      });

      // Re-login — requiresOnboarding теперь false
      const reLogin = await fetch(`${ctx.baseUrl}/v1/auth/login`, {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({
          email: "skip6@example.com",
          password: "Test-Password-123!",
        }),
      });
      const reLoginBody = await reLogin.json();
      assert.equal(
        reLoginBody.requiresOnboarding,
        false,
        "session.requiresOnboarding=false after skip → no /setup redirect",
      );
    } finally {
      await shutdown(ctx);
    }
  },
);

test(
  "Skip endpoint: requires auth (401 unauthenticated)",
  async () => {
    const ctx = await startTestServer();
    try {
      const res = await fetch(
        `${ctx.baseUrl}/v1/me/onboarding-state/skip`,
        {method: "POST"},
      );
      assert.equal(res.status, 401);
    } finally {
      await shutdown(ctx);
    }
  },
);
