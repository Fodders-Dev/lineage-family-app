// Phase E1: «Встреча» (Gathering) CRUD route tests. Mirrors the
// deleted-posts harness (real app.listen + fetch). Covers create→201,
// list/read, validation (no title / no startAt → 400), circle
// visibility, and author-only delete.

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-gather-rt-"));
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
  if (res.status !== 201) {
    throw new Error(`register failed status=${res.status}`);
  }
  const body = await res.json();
  return {userId: body.user.id, token: body.accessToken, email};
}

async function seedTree(store, baseUrl, ownerEmail) {
  const owner = await makeUser(baseUrl, ownerEmail);
  const tree = await store.createTree({
    creatorId: owner.userId,
    name: "Тест-дерево",
    description: "",
    isPrivate: true,
    kind: "family",
  });
  return {owner, tree};
}

function createGathering(baseUrl, token, body) {
  return fetch(`${baseUrl}/v1/gatherings`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(body),
  });
}

function rsvp(baseUrl, token, gatheringId, body) {
  return fetch(`${baseUrl}/v1/gatherings/${gatheringId}/rsvp`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(body),
  });
}

test("POST /v1/gatherings creates a gathering (201)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree} = await seedTree(ctx.store, ctx.baseUrl, "g-create@example.com");
    const res = await createGathering(ctx.baseUrl, owner.token, {
      treeId: tree.id,
      title: "Шашлыки на даче",
      description: "Приезжайте всей семьёй",
      startAt: "2026-07-01T15:00:00.000Z",
      endAt: "2026-07-01T20:00:00.000Z",
      place: "Дача в Подмосковье",
      isAllDay: false,
    });
    assert.equal(res.status, 201);
    const body = await res.json();
    assert.ok(body.id);
    assert.equal(body.title, "Шашлыки на даче");
    assert.equal(body.startAt, "2026-07-01T15:00:00.000Z");
    assert.equal(body.place, "Дача в Подмосковье");
    assert.equal(body.authorId, owner.userId);
    assert.deepEqual(body.rsvps, []);
    assert.deepEqual(body.branchIds, [tree.id]);
  } finally {
    await shutdown(ctx);
  }
});

test("POST /v1/gatherings stores photos (deduped)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree} =
        await seedTree(ctx.store, ctx.baseUrl, "g-photos@example.com");
    const res = await createGathering(ctx.baseUrl, owner.token, {
      treeId: tree.id,
      title: "Фотовстреча",
      startAt: "2026-07-01T15:00:00.000Z",
      imageUrls: [
        "https://example.com/a.jpg",
        "https://example.com/a.jpg", // duplicate
        "https://example.com/b.jpg",
      ],
    });
    assert.equal(res.status, 201);
    const body = await res.json();
    assert.equal(body.imageUrls.length, 2);
    assert.ok(body.imageUrls.includes("https://example.com/a.jpg"));
    assert.ok(body.imageUrls.includes("https://example.com/b.jpg"));
  } finally {
    await shutdown(ctx);
  }
});

test("GET /v1/gatherings lists tree gatherings; GET /:id reads one", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree} = await seedTree(ctx.store, ctx.baseUrl, "g-list@example.com");
    const created = await (
      await createGathering(ctx.baseUrl, owner.token, {
        treeId: tree.id,
        title: "Семейный обед",
        startAt: "2026-08-10T11:00:00.000Z",
      })
    ).json();

    const listRes = await fetch(
      `${ctx.baseUrl}/v1/gatherings?treeId=${tree.id}`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    assert.equal(listRes.status, 200);
    const list = await listRes.json();
    assert.equal(list.length, 1);
    assert.equal(list[0].id, created.id);

    const oneRes = await fetch(`${ctx.baseUrl}/v1/gatherings/${created.id}`, {
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    assert.equal(oneRes.status, 200);
    assert.equal((await oneRes.json()).title, "Семейный обед");
  } finally {
    await shutdown(ctx);
  }
});

test("POST /v1/gatherings rejects missing title or startAt (400)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree} = await seedTree(ctx.store, ctx.baseUrl, "g-valid@example.com");

    const noTitle = await createGathering(ctx.baseUrl, owner.token, {
      treeId: tree.id,
      startAt: "2026-07-01T15:00:00.000Z",
    });
    assert.equal(noTitle.status, 400);

    const noStart = await createGathering(ctx.baseUrl, owner.token, {
      treeId: tree.id,
      title: "Без даты",
    });
    assert.equal(noStart.status, 400);
  } finally {
    await shutdown(ctx);
  }
});

test("GET /v1/gatherings is gated by tree access (non-member → 403)", async () => {
  // Visibility model mirrors posts: a whole-tree gathering uses the
  // permissive all_tree circle at the store gate, so the real boundary
  // for non-members is route-level requireTreeAccess. (Finer custom-
  // circle visibility reuses _canUserViewCirclePost verbatim — covered
  // by the post visibility tests.)
  const ctx = await startTestServer();
  try {
    const {owner, tree} = await seedTree(ctx.store, ctx.baseUrl, "g-vis-owner@example.com");
    await createGathering(ctx.baseUrl, owner.token, {
      treeId: tree.id,
      title: "Только для семьи",
      startAt: "2026-09-01T10:00:00.000Z",
    });

    // Owner (tree member) sees it.
    const ownerList = await fetch(
      `${ctx.baseUrl}/v1/gatherings?treeId=${tree.id}`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    assert.equal(ownerList.status, 200);
    assert.equal((await ownerList.json()).length, 1);

    // A stranger who is not on the tree is refused outright.
    const stranger = await makeUser(ctx.baseUrl, "g-vis-stranger@example.com");
    const strangerList = await fetch(
      `${ctx.baseUrl}/v1/gatherings?treeId=${tree.id}`,
      {headers: {Authorization: `Bearer ${stranger.token}`}},
    );
    assert.equal(strangerList.status, 403);
  } finally {
    await shutdown(ctx);
  }
});

test("POST rsvp upserts the responder's row (last-write-wins)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree} =
        await seedTree(ctx.store, ctx.baseUrl, "g-rsvp@example.com");
    const created = await (
      await createGathering(ctx.baseUrl, owner.token, {
        treeId: tree.id,
        title: "Семейный сбор",
        startAt: "2026-07-01T15:00:00.000Z",
      })
    ).json();

    // First response: yes + brings 2 extra people.
    const first = await rsvp(ctx.baseUrl, owner.token, created.id, {
      status: "yes",
      headcount: 2,
    });
    assert.equal(first.status, 200);
    let body = await first.json();
    assert.equal(body.rsvps.length, 1);
    assert.equal(body.rsvps[0].status, "yes");
    assert.equal(body.rsvps[0].headcount, 2);
    assert.equal(body.rsvps[0].userId, owner.userId);

    // Change of mind → same row updated, not a duplicate.
    const second = await rsvp(ctx.baseUrl, owner.token, created.id, {
      status: "no",
    });
    assert.equal(second.status, 200);
    body = await second.json();
    assert.equal(body.rsvps.length, 1);
    assert.equal(body.rsvps[0].status, "no");
    assert.equal(body.rsvps[0].headcount, 0);
  } finally {
    await shutdown(ctx);
  }
});

test("POST rsvp rejects an invalid status (400)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree} =
        await seedTree(ctx.store, ctx.baseUrl, "g-rsvp-bad@example.com");
    const created = await (
      await createGathering(ctx.baseUrl, owner.token, {
        treeId: tree.id,
        title: "Встреча",
        startAt: "2026-07-01T15:00:00.000Z",
      })
    ).json();

    const res = await rsvp(ctx.baseUrl, owner.token, created.id, {
      status: "banana",
    });
    assert.equal(res.status, 400);
  } finally {
    await shutdown(ctx);
  }
});

test("POST rsvp is gated by tree access (non-member → 403)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree} =
        await seedTree(ctx.store, ctx.baseUrl, "g-rsvp-owner@example.com");
    const created = await (
      await createGathering(ctx.baseUrl, owner.token, {
        treeId: tree.id,
        title: "Встреча",
        startAt: "2026-07-01T15:00:00.000Z",
      })
    ).json();

    const stranger = await makeUser(ctx.baseUrl, "g-rsvp-stranger@example.com");
    const res = await rsvp(ctx.baseUrl, stranger.token, created.id, {
      status: "yes",
    });
    assert.equal(res.status, 403);
  } finally {
    await shutdown(ctx);
  }
});

test("deleteGathering only by author; author delete returns 204", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree} = await seedTree(ctx.store, ctx.baseUrl, "g-del-owner@example.com");
    const created = await (
      await createGathering(ctx.baseUrl, owner.token, {
        treeId: tree.id,
        title: "Удаляемая встреча",
        startAt: "2026-10-05T09:00:00.000Z",
      })
    ).json();

    // Non-author cannot delete (store guard → false, route maps → 403).
    const stranger = await makeUser(ctx.baseUrl, "g-del-stranger@example.com");
    const refused = await ctx.store.deleteGathering(created.id, stranger.userId);
    assert.equal(refused, false);
    assert.ok(await ctx.store.findGathering(created.id));

    // Author deletes via HTTP → 204, then it's gone.
    const delRes = await fetch(`${ctx.baseUrl}/v1/gatherings/${created.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    assert.equal(delRes.status, 204);
    assert.equal(await ctx.store.findGathering(created.id), null);
  } finally {
    await shutdown(ctx);
  }
});
