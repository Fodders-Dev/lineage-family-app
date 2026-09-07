// Ревью бинарной загрузки (P2): трейлинг-слеш не должен уводить PUT
// /v1/media/object/ мимо upload-бакета rate-limit'а в щедрый mutation.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");

const {createApp} = require("../src/app");
const {FileStore} = require("../src/store");
const {RealtimeHub} = require("../src/realtime-hub");
const {PushGateway} = require("../src/push-gateway");

test("PUT /v1/media/object/ (со слешем) считается в upload-бакете", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-binrl-"));
  const dataPath = path.join(tempDir, "dev-db.json");
  const store = new FileStore(dataPath);
  await store.initialize();
  const app = createApp({
    store,
    config: {
      corsOrigin: "*",
      dataPath,
      mediaRootPath: path.join(tempDir, "uploads"),
      uploadRateLimitMax: 1,
      rateLimitWindowMs: 60_000,
    },
    realtimeHub: new RealtimeHub({store}),
    pushGateway: new PushGateway({store}),
  });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, "127.0.0.1", () => resolve(instance));
  });
  try {
    const baseUrl = `http://127.0.0.1:${server.address().port}`;
    const reg = await fetch(`${baseUrl}/v1/auth/register`, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({
        email: "rl@rodnya.app",
        password: "Test-Password-123!",
        consentDocVersion: "test-consent-v1",
        displayName: "РЛ",
      }),
    });
    const {accessToken} = await reg.json();
    const put = (suffix, name) =>
      fetch(`${baseUrl}/v1/media/object${suffix}?bucket=posts&path=${name}`, {
        method: "PUT",
        headers: {
          "Content-Type": "application/octet-stream",
          Authorization: `Bearer ${accessToken}`,
        },
        body: "x",
      });

    // Лимит 1: первый запрос проходит, второй — 429 даже СО слешем.
    const first = await put("/", "rl-1.bin");
    assert.equal(first.status, 201);
    const second = await put("/", "rl-2.bin");
    assert.equal(second.status, 429,
      "слеш в конце пути не должен обходить upload-лимит");
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await fs.rm(tempDir, {recursive: true, force: true}).catch(() => {});
  }
});
