const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");

const {createApp} = require("../src/app");
const {FileStore} = require("../src/store");
const {RealtimeHub} = require("../src/realtime-hub");
const {PushGateway} = require("../src/push-gateway");

async function startServer({configOverrides = {}} = {}) {
  const tempDir = await fs.mkdtemp(
    path.join(os.tmpdir(), "rodnya-auth-sessions-"),
  );
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
      ...configOverrides,
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
    realtimeHub,
    pushGateway,
    tempDir,
  };
}

async function stopServer(ctx) {
  await new Promise((resolve, reject) => {
    ctx.server.close((error) => (error ? reject(error) : resolve()));
  });
  await fs.rm(ctx.tempDir, {recursive: true, force: true});
}

async function registerWithDevice(baseUrl, suffix, deviceInfo, instanceId) {
  const response = await fetch(`${baseUrl}/v1/auth/register`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-client-instance-id": instanceId,
    },
    body: JSON.stringify({
      email: `user-${suffix}@rodnya.app`,
      password: "secret123",
      consentDocVersion: "test-consent-v1",
      displayName: `User ${suffix}`,
      deviceInfo,
    }),
  });
  assert.equal(response.status, 201);
  return response.json();
}

async function loginWithDevice(baseUrl, email, password, deviceInfo, instanceId) {
  const response = await fetch(`${baseUrl}/v1/auth/login`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-client-instance-id": instanceId,
    },
    body: JSON.stringify({email, password, deviceInfo}),
  });
  assert.equal(response.status, 200);
  return response.json();
}

test("login records device info and exposes it via /v1/auth/sessions", async () => {
  const ctx = await startServer();
  try {
    await registerWithDevice(
      ctx.baseUrl,
      "alice",
      {
        deviceName: "Alice iPhone",
        platform: "ios",
        // No osVersion here on purpose — mirrors an old client build that
        // predates the field; must show up as null, not crash the route.
        appVersion: "1.0.0",
      },
      "instance-alice-1",
    );

    const session2 = await loginWithDevice(
      ctx.baseUrl,
      "user-alice@rodnya.app",
      "secret123",
      {
        deviceName: "Alice MacBook",
        platform: "macos",
        osVersion: "14.4.1",
        appVersion: "1.0.0",
      },
      "instance-alice-2",
    );

    const listResponse = await fetch(`${ctx.baseUrl}/v1/auth/sessions`, {
      headers: {
        authorization: `Bearer ${session2.accessToken}`,
        "x-client-instance-id": "instance-alice-2",
      },
    });
    assert.equal(listResponse.status, 200);
    const listed = await listResponse.json();

    assert.equal(listed.sessions.length, 2);
    assert.ok(listed.currentSessionPublicId);

    const current = listed.sessions.find((s) => s.isCurrent);
    const other = listed.sessions.find((s) => !s.isCurrent);
    assert.equal(current.deviceName, "Alice MacBook");
    assert.equal(current.platform, "macos");
    assert.equal(current.osVersion, "14.4.1");
    assert.equal(other.deviceName, "Alice iPhone");
    assert.equal(other.platform, "ios");
    assert.equal(other.osVersion, null);
    assert.notEqual(current.sessionPublicId, other.sessionPublicId);
  } finally {
    await stopServer(ctx);
  }
});

test("re-login from same instanceId evicts previous session for that device", async () => {
  const ctx = await startServer();
  try {
    const first = await registerWithDevice(
      ctx.baseUrl,
      "bob",
      {deviceName: "Bob iPhone", platform: "ios"},
      "instance-bob-1",
    );

    const second = await loginWithDevice(
      ctx.baseUrl,
      "user-bob@rodnya.app",
      "secret123",
      {deviceName: "Bob iPhone", platform: "ios"},
      "instance-bob-1",
    );
    assert.notEqual(first.accessToken, second.accessToken);

    const listResponse = await fetch(`${ctx.baseUrl}/v1/auth/sessions`, {
      headers: {
        authorization: `Bearer ${second.accessToken}`,
        "x-client-instance-id": "instance-bob-1",
      },
    });
    const listed = await listResponse.json();
    assert.equal(listed.sessions.length, 1);
    assert.equal(listed.sessions[0].isCurrent, true);

    // The first token is now invalid
    const oldSessionResponse = await fetch(`${ctx.baseUrl}/v1/auth/session`, {
      headers: {authorization: `Bearer ${first.accessToken}`},
    });
    assert.equal(oldSessionResponse.status, 401);
  } finally {
    await stopServer(ctx);
  }
});

test("PATCH /v1/auth/sessions/:publicId renames a session", async () => {
  const ctx = await startServer();
  try {
    await registerWithDevice(
      ctx.baseUrl,
      "carol",
      {deviceName: "Old name", platform: "ios"},
      "instance-carol-1",
    );
    const session2 = await loginWithDevice(
      ctx.baseUrl,
      "user-carol@rodnya.app",
      "secret123",
      {deviceName: "Carol Mac", platform: "macos"},
      "instance-carol-2",
    );

    const listResponse = await fetch(`${ctx.baseUrl}/v1/auth/sessions`, {
      headers: {
        authorization: `Bearer ${session2.accessToken}`,
        "x-client-instance-id": "instance-carol-2",
      },
    });
    const listed = await listResponse.json();
    const otherPublicId = listed.sessions.find((s) => !s.isCurrent)
      .sessionPublicId;

    const patchResponse = await fetch(
      `${ctx.baseUrl}/v1/auth/sessions/${otherPublicId}`,
      {
        method: "PATCH",
        headers: {
          authorization: `Bearer ${session2.accessToken}`,
          "x-client-instance-id": "instance-carol-2",
          "content-type": "application/json",
        },
        body: JSON.stringify({deviceName: "Renamed iPhone"}),
      },
    );
    assert.equal(patchResponse.status, 200);
    const patched = await patchResponse.json();
    assert.equal(patched.session.deviceName, "Renamed iPhone");
  } finally {
    await stopServer(ctx);
  }
});

test("DELETE /v1/auth/sessions/:publicId revokes a remote session", async () => {
  const ctx = await startServer();
  try {
    const first = await registerWithDevice(
      ctx.baseUrl,
      "dave",
      {deviceName: "Dave iPhone", platform: "ios"},
      "instance-dave-1",
    );
    const second = await loginWithDevice(
      ctx.baseUrl,
      "user-dave@rodnya.app",
      "secret123",
      {deviceName: "Dave Mac", platform: "macos"},
      "instance-dave-2",
    );

    const listResponse = await fetch(`${ctx.baseUrl}/v1/auth/sessions`, {
      headers: {
        authorization: `Bearer ${second.accessToken}`,
        "x-client-instance-id": "instance-dave-2",
      },
    });
    const listed = await listResponse.json();
    const otherPublicId = listed.sessions.find((s) => !s.isCurrent)
      .sessionPublicId;

    // Cannot revoke own session via this endpoint
    const ownPublicId = listed.currentSessionPublicId;
    const selfResponse = await fetch(
      `${ctx.baseUrl}/v1/auth/sessions/${ownPublicId}`,
      {
        method: "DELETE",
        headers: {
          authorization: `Bearer ${second.accessToken}`,
          "x-client-instance-id": "instance-dave-2",
        },
      },
    );
    assert.equal(selfResponse.status, 400);

    // Revoke the iPhone session
    const deleteResponse = await fetch(
      `${ctx.baseUrl}/v1/auth/sessions/${otherPublicId}`,
      {
        method: "DELETE",
        headers: {
          authorization: `Bearer ${second.accessToken}`,
          "x-client-instance-id": "instance-dave-2",
        },
      },
    );
    assert.equal(deleteResponse.status, 204);

    // First device's token must now fail
    const firstSession = await fetch(`${ctx.baseUrl}/v1/auth/session`, {
      headers: {authorization: `Bearer ${first.accessToken}`},
    });
    assert.equal(firstSession.status, 401);
  } finally {
    await stopServer(ctx);
  }
});

test("QR login: device A approves device B's QR token, B polls and gets auth", async () => {
  const ctx = await startServer();
  try {
    // Device A: create user and login normally
    const deviceA = await registerWithDevice(
      ctx.baseUrl,
      "qr",
      {deviceName: "Old iPhone", platform: "ios"},
      "instance-qr-A",
    );

    // Device B (unauth): start QR
    const startResponse = await fetch(`${ctx.baseUrl}/v1/auth/qr/start`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-client-instance-id": "instance-qr-B",
      },
      body: JSON.stringify({
        deviceInfo: {
          deviceName: "New Mac",
          platform: "macos",
          osVersion: "14.5",
          appVersion: "1.2.3",
        },
      }),
    });
    assert.equal(startResponse.status, 201);
    const {token, expiresAt} = await startResponse.json();
    assert.ok(token);
    assert.ok(expiresAt);

    // Device B polls — pending
    const poll1 = await fetch(`${ctx.baseUrl}/v1/auth/qr/poll?token=${token}`);
    assert.equal(poll1.status, 200);
    const poll1Body = await poll1.json();
    assert.equal(poll1Body.status, "pending");

    // Device A approves
    const approveResponse = await fetch(`${ctx.baseUrl}/v1/auth/qr/approve`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${deviceA.accessToken}`,
        "content-type": "application/json",
        "x-client-instance-id": "instance-qr-A",
      },
      body: JSON.stringify({token}),
    });
    assert.equal(approveResponse.status, 200);
    const approved = await approveResponse.json();
    assert.ok(approved.sessionPublicId);

    // Device B polls — approved, gets auth
    const poll2 = await fetch(`${ctx.baseUrl}/v1/auth/qr/poll?token=${token}`);
    assert.equal(poll2.status, 200);
    const poll2Body = await poll2.json();
    assert.equal(poll2Body.status, "approved");
    assert.ok(poll2Body.auth.accessToken);
    assert.equal(poll2Body.auth.user.id, deviceA.user.id);

    // Polling again returns expired (single use)
    const poll3 = await fetch(`${ctx.baseUrl}/v1/auth/qr/poll?token=${token}`);
    assert.equal(poll3.status, 410);

    // Device B's new session shows up in /v1/auth/sessions
    const listResponse = await fetch(`${ctx.baseUrl}/v1/auth/sessions`, {
      headers: {
        authorization: `Bearer ${poll2Body.auth.accessToken}`,
        "x-client-instance-id": "instance-qr-B",
      },
    });
    const listed = await listResponse.json();
    const newSession = listed.sessions.find((s) => s.isCurrent);
    assert.equal(newSession.deviceName, "New Mac");
    assert.equal(newSession.platform, "macos");
    // Guards the qr/approve handler's explicit field whitelist — it's the
    // one call site that rebuilds deviceContext key-by-key instead of
    // forwarding readDeviceContext()'s object wholesale, so a new field is
    // silently dropped there unless the whitelist is updated too.
    assert.equal(newSession.osVersion, "14.5");
    assert.equal(newSession.appVersion, "1.2.3");
  } finally {
    await stopServer(ctx);
  }
});

test("QR login: cannot approve without auth, cannot start without instanceId", async () => {
  const ctx = await startServer();
  try {
    // Cannot start without instanceId
    const noInstance = await fetch(`${ctx.baseUrl}/v1/auth/qr/start`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({deviceInfo: {deviceName: "X"}}),
    });
    assert.equal(noInstance.status, 400);

    // Approve without auth
    const noAuth = await fetch(`${ctx.baseUrl}/v1/auth/qr/approve`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({token: "anything"}),
    });
    assert.equal(noAuth.status, 401);
  } finally {
    await stopServer(ctx);
  }
});

test("registerPushDevice links to current session via sessionPublicId", async () => {
  const ctx = await startServer();
  try {
    const session = await registerWithDevice(
      ctx.baseUrl,
      "push",
      {deviceName: "Push iPhone", platform: "ios"},
      "instance-push-1",
    );

    const registerResponse = await fetch(`${ctx.baseUrl}/v1/push/devices`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${session.accessToken}`,
        "content-type": "application/json",
        "x-client-instance-id": "instance-push-1",
      },
      body: JSON.stringify({
        provider: "rustore",
        token: "rustore-token-1",
        platform: "android",
      }),
    });
    assert.equal(registerResponse.status, 201);
    const {device} = await registerResponse.json();
    assert.ok(device.sessionPublicId);

    const sessionsListResponse = await fetch(`${ctx.baseUrl}/v1/auth/sessions`, {
      headers: {
        authorization: `Bearer ${session.accessToken}`,
        "x-client-instance-id": "instance-push-1",
      },
    });
    const listed = await sessionsListResponse.json();
    assert.equal(device.sessionPublicId, listed.currentSessionPublicId);
  } finally {
    await stopServer(ctx);
  }
});

test("PushGateway dispatchNotification respects targetSessionPublicId", async () => {
  const ctx = await startServer();
  try {
    // Two device sessions for one user, two push devices.
    const sessionA = await registerWithDevice(
      ctx.baseUrl,
      "fanout",
      {deviceName: "Mac", platform: "macos"},
      "instance-fanout-A",
    );
    const sessionB = await loginWithDevice(
      ctx.baseUrl,
      "user-fanout@rodnya.app",
      "secret123",
      {deviceName: "iPhone", platform: "ios"},
      "instance-fanout-B",
    );

    await fetch(`${ctx.baseUrl}/v1/push/devices`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${sessionA.accessToken}`,
        "content-type": "application/json",
        "x-client-instance-id": "instance-fanout-A",
      },
      body: JSON.stringify({
        provider: "rustore",
        token: "device-A-push",
        platform: "macos",
      }),
    });
    await fetch(`${ctx.baseUrl}/v1/push/devices`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${sessionB.accessToken}`,
        "content-type": "application/json",
        "x-client-instance-id": "instance-fanout-B",
      },
      body: JSON.stringify({
        provider: "rustore",
        token: "device-B-push",
        platform: "ios",
      }),
    });

    const sessionsList = await fetch(`${ctx.baseUrl}/v1/auth/sessions`, {
      headers: {
        authorization: `Bearer ${sessionB.accessToken}`,
        "x-client-instance-id": "instance-fanout-B",
      },
    }).then((r) => r.json());
    const sessionBPublicId = sessionsList.currentSessionPublicId;

    const notification = await ctx.store.createNotification({
      userId: sessionA.user.id,
      type: "test",
      title: "t",
      body: "b",
      data: {},
    });
    const deliveries = await ctx.pushGateway.dispatchNotification(
      notification,
      {targetSessionPublicId: sessionBPublicId},
    );
    assert.equal(deliveries.length, 1);
  } finally {
    await stopServer(ctx);
  }
});

test("QR start is rate-limited via the auth bucket", async () => {
  const ctx = await startServer({
    configOverrides: {
      authRateLimitMax: 3,
      rateLimitWindowMs: 60_000,
    },
  });
  try {
    async function startOnce(suffix) {
      const response = await fetch(`${ctx.baseUrl}/v1/auth/qr/start`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-client-instance-id": `instance-rl-${suffix}`,
        },
        body: JSON.stringify({deviceInfo: {deviceName: "Rate Limit"}}),
      });
      return response.status;
    }

    assert.equal(await startOnce("1"), 201);
    assert.equal(await startOnce("2"), 201);
    assert.equal(await startOnce("3"), 201);
    // 4th call within the same window for the same IP must be 429.
    assert.equal(await startOnce("4"), 429);
  } finally {
    await stopServer(ctx);
  }
});

test("OAuth callback receives device context via query-param fallback (Telegram-style)", async () => {
  // Telegram callbacks are GET requests hit by the user's browser; the
  // Flutter app appends device info as query params on the callback URL.
  // We simulate this by calling /v1/auth/qr/start (which uses the same
  // readDeviceContext helper) with deviceInfo only in query params, no
  // headers, no body — and verifying the resulting handoff carries them.
  const ctx = await startServer();
  try {
    const url = new URL(`${ctx.baseUrl}/v1/auth/qr/start`);
    url.searchParams.set("instanceId", "instance-query-only");
    url.searchParams.set("deviceName", "Browser-launched device");
    url.searchParams.set("platform", "windows");
    url.searchParams.set("appVersion", "9.9.9");

    const response = await fetch(url.toString(), {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({}),
    });
    assert.equal(response.status, 201);
    const {token} = await response.json();
    assert.ok(token);

    // Now register the user that will approve, then approve, then poll the
    // resulting session to verify it inherited the query-only device info.
    const deviceA = await registerWithDevice(
      ctx.baseUrl,
      "qr-query",
      {deviceName: "Approver", platform: "macos"},
      "instance-qr-query-A",
    );

    const approveResponse = await fetch(`${ctx.baseUrl}/v1/auth/qr/approve`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${deviceA.accessToken}`,
        "x-client-instance-id": "instance-qr-query-A",
      },
      body: JSON.stringify({token}),
    });
    assert.equal(approveResponse.status, 200);

    const pollResponse = await fetch(
      `${ctx.baseUrl}/v1/auth/qr/poll?token=${token}`,
    );
    assert.equal(pollResponse.status, 200);
    const polled = await pollResponse.json();
    assert.equal(polled.status, "approved");
    assert.ok(polled.auth?.accessToken);

    // Confirm the new session shows the query-only device info in the list.
    const listResponse = await fetch(`${ctx.baseUrl}/v1/auth/sessions`, {
      headers: {
        authorization: `Bearer ${polled.auth.accessToken}`,
        "x-client-instance-id": "instance-query-only",
      },
    });
    const listed = await listResponse.json();
    const current = listed.sessions.find((s) => s.isCurrent);
    assert.ok(current, "current session must be present");
    assert.equal(current.deviceName, "Browser-launched device");
    assert.equal(current.platform, "windows");
    assert.equal(current.appVersion, "9.9.9");
  } finally {
    await stopServer(ctx);
  }
});

test("регистрация пишет consentAt/consentDocVersion; без поля — 400 requiresConsent", async () => {
  const ctx = await startServer();
  try {
    // Новый клиент: чекбокс отправляет версию документов.
    const withConsent = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        email: "consent@rodnya.app",
        password: "secret123",
        displayName: "Согласный",
        consentDocVersion: "terms-2026-06-12",
      }),
    });
    assert.equal(withConsent.status, 201);
    const withConsentBody = await withConsent.json();

    // 152-ФЗ: гейт безусловный (07.09.2026, по аналогии с Google/VK) —
    // без consentDocVersion аккаунт не создаётся, даже у старых клиентов.
    // (consentDocVersion сознательно отсутствует — это и есть проверяемый
    // случай; не добавлять его сюда обратно.)
    const legacy = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        email: "legacy@rodnya.app",
        password: "secret123",
        displayName: "Старый клиент",
      }),
    });
    assert.equal(legacy.status, 400);
    const legacyBody = await legacy.json();
    assert.equal(legacyBody.requiresConsent, true);
    assert.equal(legacyBody.provider, "email");

    const db = JSON.parse(
      await fs.readFile(path.join(ctx.tempDir, "dev-db.json"), "utf8"),
    );
    const consentedUser = db.users.find(
      (user) => user.id === withConsentBody.user.id,
    );
    assert.equal(consentedUser.consentDocVersion, "terms-2026-06-12");
    assert.ok(
      consentedUser.consentAt,
      "момент согласия фиксируется сервером",
    );

    const legacyUser = db.users.find(
      (user) => user.email === "legacy@rodnya.app",
    );
    assert.equal(legacyUser, undefined, "без согласия аккаунт не создаётся");
  } finally {
    await stopServer(ctx);
  }
});

test("PushGateway marks unsupported push providers as failed", async () => {
  const ctx = await startServer();
  try {
    const session = await registerWithDevice(
      ctx.baseUrl,
      "unsupported-push",
      {deviceName: "Huawei", platform: "android"},
      "instance-unsupported-push",
    );

    const deviceResponse = await fetch(`${ctx.baseUrl}/v1/push/devices`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${session.accessToken}`,
        "content-type": "application/json",
        "x-client-instance-id": "instance-unsupported-push",
      },
      body: JSON.stringify({
        provider: "huawei",
        token: "huawei-token-1",
        platform: "android",
      }),
    });
    assert.equal(deviceResponse.status, 201);

    const notification = await ctx.store.createNotification({
      userId: session.user.id,
      type: "test",
      title: "t",
      body: "b",
      data: {},
    });
    await ctx.pushGateway.dispatchNotification(notification);

    const deliveries = await ctx.store.listPushDeliveries(session.user.id, {
      limit: 1,
    });
    assert.equal(deliveries.length, 1);
    assert.equal(deliveries[0].provider, "huawei");
    assert.equal(deliveries[0].status, "failed");
    assert.equal(
      deliveries[0].lastError,
      "unsupported_push_provider:huawei",
    );
  } finally {
    await stopServer(ctx);
  }
});
