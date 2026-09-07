// Ship Q4a (2026-05-28, Ship 30b): deletedPosts HTTP route tests.
//
// Mirror persons pattern (test/deleted-persons-routes.test.js).
// Covers full lifecycle: soft-delete → list → restore либо hard-purge.

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-dp2-rt-"));
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

async function makeUser(store, baseUrl, email) {
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
  return {userId: body.user.id, token: body.accessToken, email};
}

async function seedTreeWithPost(store, baseUrl, ownerEmail) {
  const owner = await makeUser(store, baseUrl, ownerEmail);
  const tree = await store.createTree({
    creatorId: owner.userId,
    name: "Тест-дерево",
    description: "",
    isPrivate: true,
    kind: "family",
  });
  const post = await store.createPost({
    treeId: tree.id,
    authorId: owner.userId,
    authorName: owner.email.split("@")[0],
    content: "Тестовая публикация",
  });
  return {owner, tree, post};
}

test("soft-delete post moves к deletedPosts + listable", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, post} = await seedTreeWithPost(
      ctx.store,
      ctx.baseUrl,
      "q4a-post-soft@example.com",
    );

    const delRes = await fetch(`${ctx.baseUrl}/v1/posts/${post.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    assert.equal(delRes.status, 204);

    // Author sees own deleted post.
    const listRes = await fetch(`${ctx.baseUrl}/v1/me/deleted-posts`, {
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    assert.equal(listRes.status, 200);
    const body = await listRes.json();
    assert.equal(body.deletedPosts.length, 1);
    assert.equal(body.deletedPosts[0].originalPostId, post.id);
    assert.equal(body.deletedPosts[0].snapshot.content, "Тестовая публикация");
    assert.equal(body.deletedPosts[0].deletedByUserId, owner.userId);
    assert.ok(body.deletedPosts[0].hardDeleteScheduledAt);
    assert.ok(body.deletedPosts[0].earliestHardDelete);
  } finally {
    await shutdown(ctx);
  }
});

test("restore post puts it back into live posts", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, post} = await seedTreeWithPost(
      ctx.store,
      ctx.baseUrl,
      "q4a-post-restore@example.com",
    );
    await fetch(`${ctx.baseUrl}/v1/posts/${post.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    const deletedId = (
      await (
        await fetch(`${ctx.baseUrl}/v1/me/deleted-posts`, {
          headers: {Authorization: `Bearer ${owner.token}`},
        })
      ).json()
    ).deletedPosts[0].id;

    const restoreRes = await fetch(
      `${ctx.baseUrl}/v1/deleted-posts/${deletedId}/restore`,
      {
        method: "POST",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(restoreRes.status, 200);

    // Pending list empty after restore.
    const list2 = await (
      await fetch(`${ctx.baseUrl}/v1/me/deleted-posts`, {
        headers: {Authorization: `Bearer ${owner.token}`},
      })
    ).json();
    assert.equal(list2.deletedPosts.length, 0);

    // Post snapshot back в db.posts (direct store check — public list
    // requires tree/circle context unnecessary для round-trip verify).
    const db = await ctx.store._read();
    const restored = db.posts.find((p) => p.id === post.id);
    assert.ok(restored);
    assert.equal(restored.content, "Тестовая публикация");
  } finally {
    await shutdown(ctx);
  }
});

test("restore двойной call returns 409 ALREADY_RESTORED", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, post} = await seedTreeWithPost(
      ctx.store,
      ctx.baseUrl,
      "q4a-post-double-restore@example.com",
    );
    await fetch(`${ctx.baseUrl}/v1/posts/${post.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    const deletedId = (
      await (
        await fetch(`${ctx.baseUrl}/v1/me/deleted-posts`, {
          headers: {Authorization: `Bearer ${owner.token}`},
        })
      ).json()
    ).deletedPosts[0].id;
    const first = await fetch(
      `${ctx.baseUrl}/v1/deleted-posts/${deletedId}/restore`,
      {
        method: "POST",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(first.status, 200);
    const second = await fetch(
      `${ctx.baseUrl}/v1/deleted-posts/${deletedId}/restore`,
      {
        method: "POST",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(second.status, 409);
  } finally {
    await shutdown(ctx);
  }
});

test("hard-purge before earliestHardDelete returns 409 FLOOR_NOT_MET", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, post} = await seedTreeWithPost(
      ctx.store,
      ctx.baseUrl,
      "q4a-post-floor@example.com",
    );
    await fetch(`${ctx.baseUrl}/v1/posts/${post.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    const deletedId = (
      await (
        await fetch(`${ctx.baseUrl}/v1/me/deleted-posts`, {
          headers: {Authorization: `Bearer ${owner.token}`},
        })
      ).json()
    ).deletedPosts[0].id;
    const purgeRes = await fetch(
      `${ctx.baseUrl}/v1/deleted-posts/${deletedId}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(purgeRes.status, 409);
  } finally {
    await shutdown(ctx);
  }
});

test("hard-purge succeeds after floor (test override)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, post} = await seedTreeWithPost(
      ctx.store,
      ctx.baseUrl,
      "q4a-post-purge@example.com",
    );
    await fetch(`${ctx.baseUrl}/v1/posts/${post.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    const db = await ctx.store._read();
    db.deletedPosts[0].earliestHardDelete = "2020-01-01T00:00:00.000Z";
    await ctx.store._write(db);
    const deletedId = db.deletedPosts[0].id;

    const purgeRes = await fetch(
      `${ctx.baseUrl}/v1/deleted-posts/${deletedId}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(purgeRes.status, 200);
    const listAfter = await (
      await fetch(`${ctx.baseUrl}/v1/me/deleted-posts`, {
        headers: {Authorization: `Bearer ${owner.token}`},
      })
    ).json();
    assert.equal(listAfter.deletedPosts.length, 0);
  } finally {
    await shutdown(ctx);
  }
});

test("unauthorized list rejected с 401", async () => {
  const ctx = await startTestServer();
  try {
    const res = await fetch(`${ctx.baseUrl}/v1/me/deleted-posts`);
    assert.equal(res.status, 401);
  } finally {
    await shutdown(ctx);
  }
});

test("hard-delete-job sweep purges past retention + past floor", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, post} = await seedTreeWithPost(
      ctx.store,
      ctx.baseUrl,
      "q4a-post-job-sweep@example.com",
    );
    await fetch(`${ctx.baseUrl}/v1/posts/${post.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    const db = await ctx.store._read();
    db.deletedPosts[0].hardDeleteScheduledAt = "2020-01-01T00:00:00.000Z";
    db.deletedPosts[0].earliestHardDelete = "2020-01-01T00:00:00.000Z";
    await ctx.store._write(db);

    const summary = await ctx.store.hardDeleteExpired({
      now: new Date(),
      retentionDays: 30,
      dryRun: false,
    });
    assert.equal(summary.deleted.deletedPosts, 1);
    const dbAfter = await ctx.store._read();
    assert.equal(dbAfter.deletedPosts.length, 0);
  } finally {
    await shutdown(ctx);
  }
});

test("hard-delete-job respects 3h floor — skips rows с future earliestHardDelete", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, post} = await seedTreeWithPost(
      ctx.store,
      ctx.baseUrl,
      "q4a-post-job-floor@example.com",
    );
    await fetch(`${ctx.baseUrl}/v1/posts/${post.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    const db = await ctx.store._read();
    db.deletedPosts[0].hardDeleteScheduledAt = "2020-01-01T00:00:00.000Z";
    db.deletedPosts[0].earliestHardDelete = new Date(
      Date.now() + 3_600_000,
    ).toISOString();
    await ctx.store._write(db);

    const summary = await ctx.store.hardDeleteExpired({
      now: new Date(),
      retentionDays: 30,
      dryRun: false,
    });
    assert.equal(summary.deleted.deletedPosts, 0);
    const dbAfter = await ctx.store._read();
    assert.equal(dbAfter.deletedPosts.length, 1);
  } finally {
    await shutdown(ctx);
  }
});

test("non-author hard-purge rejected with 403 FORBIDDEN", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, post} = await seedTreeWithPost(
      ctx.store,
      ctx.baseUrl,
      "q4a-post-other-author@example.com",
    );
    await fetch(`${ctx.baseUrl}/v1/posts/${post.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    const db = await ctx.store._read();
    db.deletedPosts[0].earliestHardDelete = "2020-01-01T00:00:00.000Z";
    await ctx.store._write(db);
    const deletedId = db.deletedPosts[0].id;

    // Different user tries к hard-purge.
    const other = await makeUser(ctx.store, ctx.baseUrl, "q4a-post-outsider@example.com");
    const purgeRes = await fetch(
      `${ctx.baseUrl}/v1/deleted-posts/${deletedId}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${other.token}`},
      },
    );
    assert.equal(purgeRes.status, 403);
  } finally {
    await shutdown(ctx);
  }
});
