// Пункт 1 (30.08): «прочитать всё» одним запросом + курсорная пагинация
// ленты активности. E2E через HTTP на FileStore (дефолт api-уровня);
// табличная Postgres-сторона — в postgres-notification-tables.test.js.

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-notifpage-"));
  const dataPath = path.join(tempDir, "dev-db.json");
  const store = new FileStore(dataPath);
  await store.initialize();
  const realtimeHub = new RealtimeHub({store});
  const app = createApp({
    store,
    config: {
      corsOrigin: "*",
      dataPath,
      mediaRootPath: path.join(tempDir, "uploads"),
    },
    realtimeHub,
    pushGateway: new PushGateway({store}),
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
  await fs.rm(tempDir, {recursive: true, force: true}).catch(() => {});
}

async function makeUser(baseUrl, email) {
  const res = await fetch(`${baseUrl}/v1/auth/register`, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({
      email,
      password: "Test-Password-123!",
      consentDocVersion: "test-consent-v1",
      displayName: email.split("@")[0],
    }),
  });
  assert.equal(res.status, 201);
  const body = await res.json();
  return {userId: body.user.id, token: body.accessToken};
}

async function seedNotifications(store, userId, count) {
  const created = [];
  for (let i = 1; i <= count; i += 1) {
    const notification = await store.createNotification({
      userId,
      type: "generic",
      title: `Уведомление ${i}`,
      body: "-",
    });
    created.push(notification);
  }
  return created;
}

test("cursor-пагинация: страницы без дыр и дублей, легаси-формат нетронут", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.baseUrl, "page@rodnya.app");
    await seedNotifications(ctx.store, owner.userId, 7);
    const headers = {Authorization: `Bearer ${owner.token}`};

    // Легаси-формат: без cursor — прежний массив без nextCursor.
    const legacy = await fetch(`${ctx.baseUrl}/v1/notifications?limit=3`, {
      headers,
    }).then((res) => res.json());
    assert.equal(legacy.notifications.length, 3);
    assert.equal(legacy.nextCursor, undefined);

    // Страничный формат: собираем все 7 за 3 захода по 3.
    const seen = [];
    let cursor = "";
    for (let hop = 0; hop < 5; hop += 1) {
      const page = await fetch(
        `${ctx.baseUrl}/v1/notifications?limit=3&cursor=${encodeURIComponent(cursor)}`,
        {headers},
      ).then((res) => res.json());
      seen.push(...page.notifications.map((entry) => entry.id));
      if (!page.nextCursor) break;
      cursor = page.nextCursor;
    }
    assert.equal(seen.length, 7, "все уведомления собраны страницами");
    assert.equal(new Set(seen).size, 7, "без дублей");

    // Порядок: новые первыми.
    const first = await fetch(
      `${ctx.baseUrl}/v1/notifications?limit=1&cursor=`,
      {headers},
    ).then((res) => res.json());
    assert.equal(first.notifications[0].title, "Уведомление 7");
  } finally {
    await shutdown(ctx);
  }
});

test("read-all: один запрос гасит всё, идемпотентен, бейдж обнуляется", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.baseUrl, "readall@rodnya.app");
    await seedNotifications(ctx.store, owner.userId, 5);
    const headers = {
      "Content-Type": "application/json",
      Authorization: `Bearer ${owner.token}`,
    };

    const before = await fetch(`${ctx.baseUrl}/v1/notifications/unread-count`, {
      headers,
    }).then((res) => res.json());
    assert.equal(before.totalUnread, 5);

    const first = await fetch(`${ctx.baseUrl}/v1/notifications/read-all`, {
      method: "POST",
      headers,
    }).then((res) => res.json());
    assert.equal(first.marked, 5);

    const after = await fetch(`${ctx.baseUrl}/v1/notifications/unread-count`, {
      headers,
    }).then((res) => res.json());
    assert.equal(after.totalUnread, 0);

    // Повторный вызов — честный ноль, не ошибка.
    const second = await fetch(`${ctx.baseUrl}/v1/notifications/read-all`, {
      method: "POST",
      headers,
    }).then((res) => res.json());
    assert.equal(second.marked, 0);

    // История не исчезла: страничный запрос без статуса видит все 5 read.
    const page = await fetch(
      `${ctx.baseUrl}/v1/notifications?limit=10&cursor=`,
      {headers},
    ).then((res) => res.json());
    assert.equal(page.notifications.length, 5);
    assert.ok(page.notifications.every((entry) => entry.isRead === true));
  } finally {
    await shutdown(ctx);
  }
});

test("легаси base64-загрузка закрыта: 410, файл не создаётся", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.baseUrl, "legacy410@rodnya.app");
    const res = await fetch(`${ctx.baseUrl}/v1/media/upload`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${owner.token}`,
      },
      body: JSON.stringify({
        bucket: "posts",
        path: "legacy/fixed.bin",
        contentType: "application/octet-stream",
        fileBase64: Buffer.from("оригинал", "utf8").toString("base64"),
      }),
    });
    assert.equal(res.status, 410);
    const body = await res.json();
    assert.equal(body.code, "MEDIA_UPLOAD_LEGACY_SUNSET");
    assert.match(body.message, /обновите приложение/i);
    await assert.rejects(
      fs.access(path.join(ctx.tempDir, "uploads", "posts", "legacy", "fixed.bin")),
      "410 не должен ничего записывать на диск",
    );
  } finally {
    await shutdown(ctx);
  }
});
