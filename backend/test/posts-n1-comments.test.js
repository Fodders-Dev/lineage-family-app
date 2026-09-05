// SPEED-9 D: GET /v1/posts did Promise.all(page.map(listPostComments))
// — one independent _read() per post on the page, K+2 total for a page
// of K posts (post-routes.js, both the no-limit and limit branches).
// store.listPostCommentsForPosts(postIds) batches that into a single
// _read() for the whole page (store.js). This file proves two things:
//
//   1. listPostCommentsForPosts(postIds) returns, for every postId, a
//      result byte-identical to what listPostComments(postId) (the
//      pre-existing, still-used-elsewhere per-post method) returns on
//      the same db — including comments with reactions and threaded
//      replies, per the task's explicit fixture requirement.
//   2. GET /v1/posts (both the legacy no-limit shape and the paginated
//      {posts, nextCursor} shape) makes a constant number of _read()
//      calls regardless of how many posts are on the page — the N+1 is
//      actually gone at the HTTP layer, not just in the store method.

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-n1-"));
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
      displayName: email.split("@")[0],
    }),
  });
  assert.equal(res.status, 201);
  const body = await res.json();
  return {userId: body.user.id, token: body.accessToken};
}

// Дерево + 4 поста, каждый с 1-4 комментариями: часть — ответы
// (parentCommentId), часть — с реакциями от второго/третьего юзера.
// Асимметричные счётчики (1,2,3,4) — чтобы batched/per-post результат
// нельзя было случайно перепутать местами между постами.
async function seedFeedWithThreadsAndReactions(ctx, owner, others, postCount = 4) {
  const tree = await ctx.store.createTree({
    creatorId: owner.userId,
    name: "Тест-дерево",
    description: "",
    isPrivate: true,
    kind: "family",
  });
  const postIds = [];
  for (let i = 0; i < postCount; i++) {
    const post = await ctx.store.createPost({
      treeId: tree.id,
      authorId: owner.userId,
      authorName: "Автор",
      content: `Пост №${i}`,
    });
    postIds.push(post.id);
  }

  for (let i = 0; i < postIds.length; i++) {
    const postId = postIds[i];
    const commentCount = i + 1; // 1..4
    let lastCommentId = null;
    for (let c = 0; c < commentCount; c++) {
      const author = c % 2 === 0 ? owner : others[c % others.length];
      const comment = await ctx.store.addPostComment({
        postId,
        authorId: author.userId,
        authorName: "Комментатор",
        content: `comment ${c} on post ${i}`,
        // Каждый третий комментарий (кроме первого) — ответ на
        // предыдущий, чтобы фикстура реально содержала threading.
        parentCommentId: c > 0 && c % 3 === 2 ? lastCommentId : null,
      });
      lastCommentId = comment.id;
      // Каждый второй комментарий получает реакцию от другого юзера.
      if (c % 2 === 0) {
        await ctx.store.togglePostCommentReaction({
          postId,
          commentId: comment.id,
          userId: others[0].userId,
          emoji: "❤️",
        });
      }
    }
    await ctx.store.togglePostReaction({
      postId,
      userId: others[1 % others.length].userId,
      emoji: "👍",
    });
  }

  return {tree, postIds};
}

test(
  "listPostCommentsForPosts возвращает результат, идентичный listPostComments на каждый пост (реакции + ответы)",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await makeUser(ctx.baseUrl, "own-a@rodnya.app");
      const userB = await makeUser(ctx.baseUrl, "b-a@rodnya.app");
      const userC = await makeUser(ctx.baseUrl, "c-a@rodnya.app");
      const {postIds} = await seedFeedWithThreadsAndReactions(ctx, owner, [
        userB,
        userC,
      ]);

      const batched = await ctx.store.listPostCommentsForPosts(postIds);

      let sawReaction = false;
      let sawReply = false;
      for (const postId of postIds) {
        const single = await ctx.store.listPostComments(postId);
        const fromBatch = batched.get(postId);
        assert.deepEqual(
          fromBatch,
          single,
          `batched и per-post результат для поста ${postId} должны совпадать побайтово`,
        );
        assert.ok(fromBatch.length > 0, "у каждого поста фикстуры должны быть комментарии");
        if (fromBatch.some((c) => Array.isArray(c.reactions) && c.reactions.length > 0)) {
          sawReaction = true;
        }
        if (fromBatch.some((c) => c.parentCommentId)) {
          sawReply = true;
        }
      }
      assert.ok(sawReaction, "фикстура должна реально включать комментарий с реакцией");
      assert.ok(sawReply, "фикстура должна реально включать ответ (thread)");

      // Пустой список постов — валидный вход, батч не должен падать
      // и не должен трогать блоб зря.
      const empty = await ctx.store.listPostCommentsForPosts([]);
      assert.equal(empty.size, 0);
    } finally {
      await shutdown(ctx);
    }
  },
);

// _read() count is compared BETWEEN two page sizes in the same
// authenticated session, rather than asserted against a hardcoded
// magic number — findSession/findUserById cache internally (cache hit
// = 0 extra _read()), so the exact baseline constant is incidental to
// auth-cache warmth, not to the N+1 fix under test. What SPEED-9 D
// actually promises is: the count does NOT grow with the number of
// posts on the page. Comparing a small page against a 3x bigger page
// in the SAME session (same cache warmth) isolates exactly that.
async function countReadsForPostsRequest(ctx, url, token) {
  const originalRead = ctx.store._read.bind(ctx.store);
  let readCalls = 0;
  ctx.store._read = async (...args) => {
    readCalls += 1;
    return originalRead(...args);
  };
  try {
    const res = await fetch(url, {headers: {Authorization: `Bearer ${token}`}});
    assert.equal(res.status, 200);
    return {readCalls, body: await res.json()};
  } finally {
    ctx.store._read = originalRead;
  }
}

// findSession/findUserById cache on first hit (cache MISS costs one
// extra _read(), cache HIT costs zero) — an uncounted warm-up request
// with the same token puts both caches in the SAME (warm) state
// before either measured call, so a leftover cold-start read on the
// FIRST measured request can't be mistaken for an N+1 regression.
async function warmAuthCache(ctx, url, token) {
  const res = await fetch(url, {headers: {Authorization: `Bearer ${token}`}});
  assert.equal(res.status, 200);
}

test(
  "GET /v1/posts без limit: число _read() не растёт с размером страницы (N+1 устранён)",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await makeUser(ctx.baseUrl, "own-b@rodnya.app");
      const userB = await makeUser(ctx.baseUrl, "b-b@rodnya.app");
      const userC = await makeUser(ctx.baseUrl, "c-b@rodnya.app");
      // 9 постов — заметно больше "3+" из задачи, чтобы разница
      // К=3 vs К=9 была бы видна, если бы N+1 ещё оставался.
      const {tree, postIds} = await seedFeedWithThreadsAndReactions(
        ctx,
        owner,
        [userB, userC],
        9,
      );
      assert.equal(postIds.length, 9);

      // Первый запрос — на дереве с ОДНИМ постом (K=1), второй — на
      // полных 9. Оба через тот же прогретый auth-кэш (тот же
      // владелец, тот же токен), так что разница в readCalls может
      // объясняться ТОЛЬКО количеством постов на странице.
      const smallTree = await ctx.store.createTree({
        creatorId: owner.userId,
        name: "Малое дерево",
        description: "",
        isPrivate: true,
        kind: "family",
      });
      const soloPost = await ctx.store.createPost({
        treeId: smallTree.id,
        authorId: owner.userId,
        authorName: "Автор",
        content: "Один пост",
      });
      await ctx.store.addPostComment({
        postId: soloPost.id,
        authorId: owner.userId,
        authorName: "Автор",
        content: "Один комментарий",
      });

      await warmAuthCache(
        ctx,
        `${ctx.baseUrl}/v1/posts?treeId=${encodeURIComponent(smallTree.id)}`,
        owner.token,
      );

      const small = await countReadsForPostsRequest(
        ctx,
        `${ctx.baseUrl}/v1/posts?treeId=${encodeURIComponent(smallTree.id)}`,
        owner.token,
      );
      assert.equal(small.body.length, 1);

      const big = await countReadsForPostsRequest(
        ctx,
        `${ctx.baseUrl}/v1/posts?treeId=${encodeURIComponent(tree.id)}`,
        owner.token,
      );
      assert.equal(big.body.length, 9);
      for (const post of big.body) {
        assert.equal(typeof post.commentCount, "number");
        assert.ok(post.commentCount > 0);
      }

      assert.equal(
        big.readCalls,
        small.readCalls,
        `_read() не должен расти с 1 до 9 постов на странице (было бы K+const до фикса): ${small.readCalls} vs ${big.readCalls}`,
      );
    } finally {
      await shutdown(ctx);
    }
  },
);

test(
  "GET /v1/posts?limit=K: число _read() не растёт с K (пагинация, N+1 устранён)",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await makeUser(ctx.baseUrl, "own-c@rodnya.app");
      const userB = await makeUser(ctx.baseUrl, "b-c@rodnya.app");
      const userC = await makeUser(ctx.baseUrl, "c-c@rodnya.app");
      const {tree, postIds} = await seedFeedWithThreadsAndReactions(
        ctx,
        owner,
        [userB, userC],
        9,
      );
      assert.equal(postIds.length, 9);

      await warmAuthCache(
        ctx,
        `${ctx.baseUrl}/v1/posts?treeId=${encodeURIComponent(tree.id)}&limit=3`,
        owner.token,
      );

      const small = await countReadsForPostsRequest(
        ctx,
        `${ctx.baseUrl}/v1/posts?treeId=${encodeURIComponent(tree.id)}&limit=3`,
        owner.token,
      );
      assert.equal(small.body.posts.length, 3);

      const big = await countReadsForPostsRequest(
        ctx,
        `${ctx.baseUrl}/v1/posts?treeId=${encodeURIComponent(tree.id)}&limit=9`,
        owner.token,
      );
      assert.equal(big.body.posts.length, 9);
      for (const post of big.body.posts) {
        assert.equal(typeof post.commentCount, "number");
      }

      assert.equal(
        big.readCalls,
        small.readCalls,
        `_read() не должен расти с limit=3 до limit=9: ${small.readCalls} vs ${big.readCalls}`,
      );
    } finally {
      await shutdown(ctx);
    }
  },
);

test(
  "GET /v1/posts (limit и без limit) отдаёт тот же commentCount, что и прямой store.listPostComments по каждому посту — форма ответа не изменилась",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await makeUser(ctx.baseUrl, "own-d@rodnya.app");
      const userB = await makeUser(ctx.baseUrl, "b-d@rodnya.app");
      const userC = await makeUser(ctx.baseUrl, "c-d@rodnya.app");
      const {tree, postIds} = await seedFeedWithThreadsAndReactions(ctx, owner, [
        userB,
        userC,
      ]);

      const expectedCounts = new Map();
      for (const postId of postIds) {
        const comments = await ctx.store.listPostComments(postId);
        expectedCounts.set(postId, comments.length);
      }

      const noLimitRes = await fetch(
        `${ctx.baseUrl}/v1/posts?treeId=${encodeURIComponent(tree.id)}`,
        {headers: {Authorization: `Bearer ${owner.token}`}},
      );
      const noLimitBody = await noLimitRes.json();
      for (const post of noLimitBody) {
        assert.equal(
          post.commentCount,
          expectedCounts.get(post.id),
          `commentCount для ${post.id} (без limit) должен совпасть с прямым listPostComments`,
        );
      }

      const limitRes = await fetch(
        `${ctx.baseUrl}/v1/posts?treeId=${encodeURIComponent(tree.id)}&limit=10`,
        {headers: {Authorization: `Bearer ${owner.token}`}},
      );
      const limitBody = await limitRes.json();
      for (const post of limitBody.posts) {
        assert.equal(
          post.commentCount,
          expectedCounts.get(post.id),
          `commentCount для ${post.id} (limit=10) должен совпасть с прямым listPostComments`,
        );
      }
    } finally {
      await shutdown(ctx);
    }
  },
);
