// S2: курсорная пагинация GET /v1/posts — аддитивно. Без limit старый
// клиент получает прежний формат (массив всех постов); с limit —
// {posts, nextCursor}. Курсор стабилен при вставке новых постов и при
// равных createdAt (tie-break по id).

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-pag-"));
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
    dataPath,
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

/// Сид: дерево + 8 постов с детерминированными createdAt
/// (2026-01-01T00:01..08) — патчим JSON напрямую после создания.
async function seedFeed(ctx, owner) {
  const tree = await ctx.store.createTree({
    creatorId: owner.userId,
    name: "Тест-дерево",
    description: "",
    isPrivate: true,
    kind: "family",
  });
  const created = [];
  for (let i = 1; i <= 8; i++) {
    const post = await ctx.store.createPost({
      treeId: tree.id,
      authorId: owner.userId,
      authorName: "Автор",
      content: `Пост №${i}`,
    });
    created.push(post.id);
  }
  const db = JSON.parse(await fs.readFile(ctx.dataPath, "utf8"));
  for (let i = 0; i < created.length; i++) {
    const post = db.posts.find((entry) => entry.id === created[i]);
    post.createdAt = `2026-01-01T00:0${i + 1}:00.000Z`;
  }
  await fs.writeFile(ctx.dataPath, JSON.stringify(db, null, 2));
  // FileStore кэширует чтение — поднимем новый процессный кэш простым
  // способом: store читает файл на каждый _read, так что достаточно.
  return {tree, postIds: created};
}

async function fetchFeed(ctx, token, query = "") {
  const res = await fetch(`${ctx.baseUrl}/v1/posts${query}`, {
    headers: {Authorization: `Bearer ${token}`},
  });
  assert.equal(res.status, 200);
  return res.json();
}

test("без limit — прежний формат: массив всех постов", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.baseUrl, "a@rodnya.app");
    await seedFeed(ctx, owner);

    const body = await fetchFeed(ctx, owner.token);
    assert.ok(Array.isArray(body), "старый клиент ждёт массив");
    assert.equal(body.length, 8);
    assert.equal(body[0].content, "Пост №8"); // новейший первым
  } finally {
    await shutdown(ctx);
  }
});

test("limit+before: страницы без пересечений, конец — nextCursor=null", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.baseUrl, "b@rodnya.app");
    await seedFeed(ctx, owner);

    const page1 = await fetchFeed(ctx, owner.token, "?limit=3");
    assert.ok(Array.isArray(page1.posts));
    assert.equal(page1.posts.length, 3);
    assert.ok(page1.nextCursor, "есть продолжение");
    assert.deepEqual(
      page1.posts.map((p) => p.content),
      ["Пост №8", "Пост №7", "Пост №6"],
    );

    const page2 = await fetchFeed(
      ctx,
      owner.token,
      `?limit=3&before=${encodeURIComponent(page1.nextCursor)}`,
    );
    assert.deepEqual(
      page2.posts.map((p) => p.content),
      ["Пост №5", "Пост №4", "Пост №3"],
    );

    const page3 = await fetchFeed(
      ctx,
      owner.token,
      `?limit=3&before=${encodeURIComponent(page2.nextCursor)}`,
    );
    assert.deepEqual(
      page3.posts.map((p) => p.content),
      ["Пост №2", "Пост №1"],
    );
    assert.equal(page3.nextCursor, null);

    // Все 8 ровно по одному разу.
    const seen = [...page1.posts, ...page2.posts, ...page3.posts].map(
      (p) => p.id,
    );
    assert.equal(new Set(seen).size, 8);
  } finally {
    await shutdown(ctx);
  }
});

test("курсор стабилен при вставке нового поста между страницами", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.baseUrl, "c@rodnya.app");
    const {tree} = await seedFeed(ctx, owner);

    const page1 = await fetchFeed(ctx, owner.token, "?limit=3");
    assert.equal(page1.posts.length, 3);

    // Новый пост прилетает ПОСЛЕ того, как клиент забрал страницу 1.
    await ctx.store.createPost({
      treeId: tree.id,
      authorId: owner.userId,
      authorName: "Автор",
      content: "Свежий пост",
    });

    const page2 = await fetchFeed(
      ctx,
      owner.token,
      `?limit=3&before=${encodeURIComponent(page1.nextCursor)}`,
    );
    // Страница 2 продолжает СТАРУЮ ленту: без дублей и без пропусков,
    // свежий пост в неё не вклинивается (он новее курсора).
    assert.deepEqual(
      page2.posts.map((p) => p.content),
      ["Пост №5", "Пост №4", "Пост №3"],
    );
    const page1Ids = new Set(page1.posts.map((p) => p.id));
    assert.ok(page2.posts.every((p) => !page1Ids.has(p.id)));
  } finally {
    await shutdown(ctx);
  }
});

test("tie-break: равные createdAt не дублируются через границу страниц", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.baseUrl, "d@rodnya.app");
    const tree = await ctx.store.createTree({
      creatorId: owner.userId,
      name: "Тест-дерево",
      description: "",
      isPrivate: true,
      kind: "family",
    });
    const ids = [];
    for (let i = 1; i <= 3; i++) {
      const post = await ctx.store.createPost({
        treeId: tree.id,
        authorId: owner.userId,
        authorName: "Автор",
        content: `Близнец №${i}`,
      });
      ids.push(post.id);
    }
    // Все три — с ОДИНАКОВЫМ createdAt.
    const db = JSON.parse(await fs.readFile(ctx.dataPath, "utf8"));
    for (const id of ids) {
      db.posts.find((entry) => entry.id === id).createdAt =
        "2026-01-01T00:05:00.000Z";
    }
    await fs.writeFile(ctx.dataPath, JSON.stringify(db, null, 2));

    const seen = [];
    let cursor = null;
    for (let guard = 0; guard < 5; guard++) {
      const query = cursor
        ? `?limit=1&before=${encodeURIComponent(cursor)}`
        : "?limit=1";
      const page = await fetchFeed(ctx, owner.token, query);
      seen.push(...page.posts.map((p) => p.id));
      cursor = page.nextCursor;
      if (!cursor) break;
    }
    assert.equal(seen.length, 3, "все близнецы пришли");
    assert.equal(new Set(seen).size, 3, "каждый ровно один раз");
  } finally {
    await shutdown(ctx);
  }
});
