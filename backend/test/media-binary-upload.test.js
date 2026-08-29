// Бинарная загрузка PUT /v1/media/object: тело = байты файла, метаданные в
// query и Content-Type. Легаси base64-путь POST /v1/media/upload обязан
// работать как раньше (его шлют клиенты до OTA).

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-binup-"));
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
      publicApiUrl: "https://api.rodnya-tree.ru",
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
    tempDir,
  };
}

async function shutdown({server, tempDir}) {
  await new Promise((resolve) => server.close(resolve));
  await fs.rm(tempDir, {recursive: true, force: true}).catch(() => {});
}

async function makeUser(baseUrl) {
  const res = await fetch(`${baseUrl}/v1/auth/register`, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({
      email: `bin-${Math.random().toString(36).slice(2)}@rodnya.app`,
      password: "Test-Password-123!",
      displayName: "Загрузчик",
    }),
  });
  assert.equal(res.status, 201);
  const body = await res.json();
  return {token: body.accessToken};
}

test("PUT /v1/media/object сохраняет байты как есть и отдаёт url", async () => {
  const ctx = await startTestServer();
  try {
    const {token} = await makeUser(ctx.baseUrl);
    // JPEG-магия в начале — проверяем, что байты не покорёжены кодировками.
    const payload = Buffer.concat([
      Buffer.from([0xff, 0xd8, 0xff, 0xe0]),
      Buffer.from("рodnya-binary-payload", "utf8"),
    ]);

    const res = await fetch(
      `${ctx.baseUrl}/v1/media/object?bucket=posts&path=trip/photo-1.jpg`,
      {
        method: "PUT",
        headers: {
          "Content-Type": "image/jpeg",
          Authorization: `Bearer ${token}`,
        },
        body: payload,
      },
    );
    assert.equal(res.status, 201);
    const body = await res.json();
    assert.equal(body.bucket, "posts");
    assert.equal(body.path, "trip/photo-1.jpg");
    assert.equal(body.contentType, "image/jpeg");
    assert.equal(body.size, payload.length);
    assert.ok(String(body.url || "").length > 0);

    const saved = await fs.readFile(
      path.join(ctx.tempDir, "uploads", "posts", "trip", "photo-1.jpg"),
    );
    assert.deepEqual(saved, payload);
  } finally {
    await shutdown(ctx);
  }
});

test("PUT /v1/media/object: валидация и авторизация", async () => {
  const ctx = await startTestServer();
  try {
    const {token} = await makeUser(ctx.baseUrl);
    const authHeaders = {
      "Content-Type": "image/jpeg",
      Authorization: `Bearer ${token}`,
    };

    // Без токена — 401.
    const noAuth = await fetch(
      `${ctx.baseUrl}/v1/media/object?bucket=posts&path=a.jpg`,
      {method: "PUT", headers: {"Content-Type": "image/jpeg"}, body: "x"},
    );
    assert.equal(noAuth.status, 401);

    // Без bucket/path — 400.
    const noParams = await fetch(`${ctx.baseUrl}/v1/media/object`, {
      method: "PUT",
      headers: authHeaders,
      body: "x",
    });
    assert.equal(noParams.status, 400);

    // Пустое тело — 400.
    const empty = await fetch(
      `${ctx.baseUrl}/v1/media/object?bucket=posts&path=a.jpg`,
      {method: "PUT", headers: authHeaders},
    );
    assert.equal(empty.status, 400);

    // Побег из media-каталога — 400 (resolveMediaFilePath).
    const escape = await fetch(
      `${ctx.baseUrl}/v1/media/object?bucket=posts&path=..%2F..%2Fpwn.txt`,
      {method: "PUT", headers: authHeaders, body: "x"},
    );
    assert.equal(escape.status, 400);
  } finally {
    await shutdown(ctx);
  }
});

test("легаси base64-путь работает как раньше", async () => {
  const ctx = await startTestServer();
  try {
    const {token} = await makeUser(ctx.baseUrl);
    const payload = Buffer.from("legacy-base64-payload", "utf8");
    const res = await fetch(`${ctx.baseUrl}/v1/media/upload`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        bucket: "posts",
        path: "legacy/file.bin",
        contentType: "application/octet-stream",
        fileBase64: payload.toString("base64"),
      }),
    });
    assert.equal(res.status, 201);
    const saved = await fs.readFile(
      path.join(ctx.tempDir, "uploads", "posts", "legacy", "file.bin"),
    );
    assert.deepEqual(saved, payload);
  } finally {
    await shutdown(ctx);
  }
});
