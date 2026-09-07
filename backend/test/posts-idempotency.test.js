// Шаг 5 bulk-upload: идемпотентный clientRequestId у POST /v1/posts.
// Клиентский таймаут НЕ отменяет уже летящий запрос — фоновая очередь
// ретраит с тем же localId, и без серверного дедупа семейная лента
// получала бы пост дважды. Паттерн — как clientMessageId у сообщений.

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-idem-"));
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

async function createPost(ctx, token, body) {
  const res = await fetch(`${ctx.baseUrl}/v1/posts`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(body),
  });
  return {status: res.status, body: await res.json()};
}

test("повтор с тем же clientRequestId возвращает тот же пост без дубля", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.baseUrl, "idem@rodnya.app");
    const tree = await ctx.store.createTree({
      creatorId: owner.userId,
      name: "Дерево",
      description: "",
      isPrivate: true,
      kind: "family",
    });

    const request = {
      treeId: tree.id,
      content: "Отпуск!",
      clientRequestId: "local-1756400000000000-1",
    };
    const first = await createPost(ctx, owner.token, request);
    assert.equal(first.status, 201);

    // Ретрай очереди после таймаута — тот же ключ, тот же автор.
    const second = await createPost(ctx, owner.token, request);
    assert.equal(second.status, 201);
    assert.equal(second.body.id, first.body.id);

    const feed = await fetch(`${ctx.baseUrl}/v1/posts`, {
      headers: {Authorization: `Bearer ${owner.token}`},
    }).then((res) => res.json());
    assert.equal(feed.length, 1);
  } finally {
    await shutdown(ctx);
  }
});

test("разные ключи и отсутствие ключа постят как раньше", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.baseUrl, "idem2@rodnya.app");
    const tree = await ctx.store.createTree({
      creatorId: owner.userId,
      name: "Дерево",
      description: "",
      isPrivate: true,
      kind: "family",
    });

    const withKeyA = await createPost(ctx, owner.token, {
      treeId: tree.id,
      content: "Первый",
      clientRequestId: "local-a",
    });
    const withKeyB = await createPost(ctx, owner.token, {
      treeId: tree.id,
      content: "Второй",
      clientRequestId: "local-b",
    });
    // Легаси-клиент без ключа — два одинаковых запроса = два поста
    // (прежнее поведение сохраняется).
    const bare1 = await createPost(ctx, owner.token, {
      treeId: tree.id,
      content: "Без ключа",
    });
    const bare2 = await createPost(ctx, owner.token, {
      treeId: tree.id,
      content: "Без ключа",
    });
    assert.equal(withKeyA.status, 201);
    assert.equal(withKeyB.status, 201);
    assert.notEqual(withKeyA.body.id, withKeyB.body.id);
    assert.notEqual(bare1.body.id, bare2.body.id);

    const feed = await fetch(`${ctx.baseUrl}/v1/posts`, {
      headers: {Authorization: `Bearer ${owner.token}`},
    }).then((res) => res.json());
    assert.equal(feed.length, 4);
  } finally {
    await shutdown(ctx);
  }
});

test("чужой ключ не дедупится: у каждого автора своё пространство", async () => {
  const ctx = await startTestServer();
  try {
    const alice = await makeUser(ctx.baseUrl, "alice-idem@rodnya.app");
    const bob = await makeUser(ctx.baseUrl, "bob-idem@rodnya.app");
    const aliceTree = await ctx.store.createTree({
      creatorId: alice.userId,
      name: "Дерево Алисы",
      description: "",
      isPrivate: true,
      kind: "family",
    });
    const bobTree = await ctx.store.createTree({
      creatorId: bob.userId,
      name: "Дерево Боба",
      description: "",
      isPrivate: true,
      kind: "family",
    });

    const fromAlice = await createPost(ctx, alice.token, {
      treeId: aliceTree.id,
      content: "От Алисы",
      clientRequestId: "shared-key",
    });
    const fromBob = await createPost(ctx, bob.token, {
      treeId: bobTree.id,
      content: "От Боба",
      clientRequestId: "shared-key",
    });
    assert.equal(fromAlice.status, 201);
    assert.equal(fromBob.status, 201);
    assert.notEqual(fromAlice.body.id, fromBob.body.id);
  } finally {
    await shutdown(ctx);
  }
});
