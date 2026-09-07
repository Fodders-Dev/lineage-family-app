// Phase B Week 2 Ship 2: HTTP route tests для semya endpoints.
//
// Scope:
//   POST   /v1/semya            — create семья (201)
//   GET    /v1/me/semya         — list (200)
//   GET    /v1/semya/:id        — details (200/403/404)
//   PATCH  /v1/semya/:id        — rename (200/400/403/404)
//   DELETE /v1/semya/:id        — soft-delete (200/403/404)
//
// Permission gate coverage: viewer/editor/owner role hierarchy
// (Ship 3 adds membership endpoints; Ship 2 tests use store-direct
// seeding для multi-role coverage).

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-semya-rt-"));
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

async function createUserWithToken(store, baseUrl, {email}) {
  const password = "Test-Password-123!";
  const displayName = email.split("@")[0];
  const registerRes = await fetch(`${baseUrl}/v1/auth/register`, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({email, password, displayName, consentDocVersion: "test-consent-v1"}),
  });
  if (registerRes.status !== 201) {
    const text = await registerRes.text();
    throw new Error(`register failed status=${registerRes.status} body=${text}`);
  }
  const body = await registerRes.json();
  return {userId: body.user.id, token: body.accessToken, email};
}

async function createTreeViaStore(store, userId) {
  return store.createTree({
    creatorId: userId,
    name: "Тестовое дерево",
    description: "",
    isPrivate: true,
    kind: "family",
  });
}

test("POST /v1/semya creates семья + atomic owner membership", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await createUserWithToken(ctx.store, ctx.baseUrl, {
      email: "owner@example.com",
    });
    const tree = await createTreeViaStore(ctx.store, owner.userId);

    const res = await fetch(`${ctx.baseUrl}/v1/semya`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${owner.token}`,
      },
      body: JSON.stringify({
        name: "Семья Ивановых",
        treeId: tree.id,
        description: "Test семья",
      }),
    });

    assert.equal(res.status, 201);
    const body = await res.json();
    assert.ok(body.semya.id);
    assert.equal(body.semya.name, "Семья Ивановых");
    assert.equal(body.semya.ownerId, owner.userId);
    assert.equal(body.semya.treeId, tree.id);
    assert.equal(body.semya.description, "Test семья");
    assert.equal(body.semya.deletedAt, null);

    // Owner membership exists
    const membership = await ctx.store.findMembership(
      body.semya.id,
      owner.userId,
    );
    assert.equal(membership?.role, "owner");
    assert.equal(membership?.hasInviteGrant, true);
  } finally {
    await shutdown(ctx);
  }
});

test("POST /v1/semya rejects дерево не-владельца (403)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await createUserWithToken(ctx.store, ctx.baseUrl, {
      email: "owner2@example.com",
    });
    const stranger = await createUserWithToken(ctx.store, ctx.baseUrl, {
      email: "stranger@example.com",
    });
    const tree = await createTreeViaStore(ctx.store, owner.userId);

    const res = await fetch(`${ctx.baseUrl}/v1/semya`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${stranger.token}`,
      },
      body: JSON.stringify({name: "Похищенная семья", treeId: tree.id}),
    });

    assert.equal(res.status, 403);
    const body = await res.json();
    assert.match(body.message, /дерево/i);
  } finally {
    await shutdown(ctx);
  }
});

test("POST /v1/semya rejects same tree twice (409 TREE_ALREADY_BOUND)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await createUserWithToken(ctx.store, ctx.baseUrl, {
      email: "owner3@example.com",
    });
    const tree = await createTreeViaStore(ctx.store, owner.userId);

    const first = await fetch(`${ctx.baseUrl}/v1/semya`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${owner.token}`,
      },
      body: JSON.stringify({name: "Первая", treeId: tree.id}),
    });
    assert.equal(first.status, 201);

    const second = await fetch(`${ctx.baseUrl}/v1/semya`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${owner.token}`,
      },
      body: JSON.stringify({name: "Вторая", treeId: tree.id}),
    });
    assert.equal(second.status, 409);
  } finally {
    await shutdown(ctx);
  }
});

test("POST /v1/semya validates missing fields (400)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await createUserWithToken(ctx.store, ctx.baseUrl, {
      email: "owner4@example.com",
    });

    const noName = await fetch(`${ctx.baseUrl}/v1/semya`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${owner.token}`,
      },
      body: JSON.stringify({treeId: "any"}),
    });
    assert.equal(noName.status, 400);

    const noTree = await fetch(`${ctx.baseUrl}/v1/semya`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${owner.token}`,
      },
      body: JSON.stringify({name: "Семья"}),
    });
    assert.equal(noTree.status, 400);
  } finally {
    await shutdown(ctx);
  }
});

test("GET /v1/me/semya returns мои семьи (200)", async () => {
  const ctx = await startTestServer();
  try {
    const userA = await createUserWithToken(ctx.store, ctx.baseUrl, {
      email: "a@example.com",
    });
    const userB = await createUserWithToken(ctx.store, ctx.baseUrl, {
      email: "b@example.com",
    });
    const treeA = await createTreeViaStore(ctx.store, userA.userId);
    const treeB = await createTreeViaStore(ctx.store, userB.userId);

    const semyaA = await ctx.store.createSemya({
      ownerId: userA.userId,
      name: "Семья A",
      treeId: treeA.id,
    });
    await ctx.store.createSemya({
      ownerId: userB.userId,
      name: "Семья B",
      treeId: treeB.id,
    });

    const res = await fetch(`${ctx.baseUrl}/v1/me/semya`, {
      headers: {Authorization: `Bearer ${userA.token}`},
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.semyi.length, 1);
    assert.equal(body.semyi[0].id, semyaA.id);
    assert.equal(body.semyi[0].name, "Семья A");
  } finally {
    await shutdown(ctx);
  }
});

test("GET /v1/semya/:id requires membership (403 для outsider, 200 для member)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await createUserWithToken(ctx.store, ctx.baseUrl, {
      email: "owner5@example.com",
    });
    const outsider = await createUserWithToken(ctx.store, ctx.baseUrl, {
      email: "outsider@example.com",
    });
    const tree = await createTreeViaStore(ctx.store, owner.userId);
    const semya = await ctx.store.createSemya({
      ownerId: owner.userId,
      name: "Закрытая",
      treeId: tree.id,
    });

    // Outsider 403
    const denied = await fetch(`${ctx.baseUrl}/v1/semya/${semya.id}`, {
      headers: {Authorization: `Bearer ${outsider.token}`},
    });
    assert.equal(denied.status, 403);

    // Owner 200 — receives semya + membership info
    const allowed = await fetch(`${ctx.baseUrl}/v1/semya/${semya.id}`, {
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    assert.equal(allowed.status, 200);
    const body = await allowed.json();
    assert.equal(body.semya.id, semya.id);
    assert.equal(body.membership.role, "owner");
  } finally {
    await shutdown(ctx);
  }
});

test("GET /v1/semya/:id returns 404 для несуществующих семей", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await createUserWithToken(ctx.store, ctx.baseUrl, {
      email: "owner6@example.com",
    });
    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/00000000-0000-0000-0000-000000000000`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    assert.equal(res.status, 404);
  } finally {
    await shutdown(ctx);
  }
});

test("PATCH /v1/semya/:id rename (owner only, 200/403)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await createUserWithToken(ctx.store, ctx.baseUrl, {
      email: "owner7@example.com",
    });
    const tree = await createTreeViaStore(ctx.store, owner.userId);
    const semya = await ctx.store.createSemya({
      ownerId: owner.userId,
      name: "Старое имя",
      treeId: tree.id,
    });

    // Owner can rename
    const renamed = await fetch(`${ctx.baseUrl}/v1/semya/${semya.id}`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${owner.token}`,
      },
      body: JSON.stringify({name: "Новое имя", description: "Updated"}),
    });
    assert.equal(renamed.status, 200);
    const body = await renamed.json();
    assert.equal(body.semya.name, "Новое имя");
    assert.equal(body.semya.description, "Updated");
    // updatedAt bumps
    assert.notEqual(body.semya.updatedAt, semya.updatedAt);

    // Non-member 403
    const stranger = await createUserWithToken(ctx.store, ctx.baseUrl, {
      email: "stranger2@example.com",
    });
    const denied = await fetch(`${ctx.baseUrl}/v1/semya/${semya.id}`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${stranger.token}`,
      },
      body: JSON.stringify({name: "Hacked"}),
    });
    assert.equal(denied.status, 403);
  } finally {
    await shutdown(ctx);
  }
});

test("PATCH /v1/semya/:id rejects пустое тело (400)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await createUserWithToken(ctx.store, ctx.baseUrl, {
      email: "owner8@example.com",
    });
    const tree = await createTreeViaStore(ctx.store, owner.userId);
    const semya = await ctx.store.createSemya({
      ownerId: owner.userId,
      name: "Имя",
      treeId: tree.id,
    });

    const res = await fetch(`${ctx.baseUrl}/v1/semya/${semya.id}`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${owner.token}`,
      },
      body: JSON.stringify({}),
    });
    assert.equal(res.status, 400);
  } finally {
    await shutdown(ctx);
  }
});

test("DELETE /v1/semya/:id soft-deletes (owner only, members lose access)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await createUserWithToken(ctx.store, ctx.baseUrl, {
      email: "owner9@example.com",
    });
    const tree = await createTreeViaStore(ctx.store, owner.userId);
    const semya = await ctx.store.createSemya({
      ownerId: owner.userId,
      name: "Будет удалена",
      treeId: tree.id,
    });

    // Verify visible before delete
    const before = await fetch(`${ctx.baseUrl}/v1/me/semya`, {
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    const beforeBody = await before.json();
    assert.equal(beforeBody.semyi.length, 1);

    // Delete
    const del = await fetch(`${ctx.baseUrl}/v1/semya/${semya.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    assert.equal(del.status, 200);
    const delBody = await del.json();
    assert.ok(delBody.semya.deletedAt);

    // After delete — owner no longer sees семья в списке
    const after = await fetch(`${ctx.baseUrl}/v1/me/semya`, {
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    const afterBody = await after.json();
    assert.equal(afterBody.semyi.length, 0);

    // Direct GET returns 404 (soft-deleted treated as not-found)
    const detail = await fetch(`${ctx.baseUrl}/v1/semya/${semya.id}`, {
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    assert.equal(detail.status, 404);
  } finally {
    await shutdown(ctx);
  }
});

test("DELETE /v1/semya/:id rejects non-owner (403)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await createUserWithToken(ctx.store, ctx.baseUrl, {
      email: "owner10@example.com",
    });
    const stranger = await createUserWithToken(ctx.store, ctx.baseUrl, {
      email: "stranger3@example.com",
    });
    const tree = await createTreeViaStore(ctx.store, owner.userId);
    const semya = await ctx.store.createSemya({
      ownerId: owner.userId,
      name: "Защищённая",
      treeId: tree.id,
    });

    const res = await fetch(`${ctx.baseUrl}/v1/semya/${semya.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${stranger.token}`},
    });
    assert.equal(res.status, 403);

    // Semya still exists
    const still = await ctx.store.findSemyaById(semya.id);
    assert.equal(still?.deletedAt, null);
  } finally {
    await shutdown(ctx);
  }
});

test("Unauthorized requests rejected (401)", async () => {
  const ctx = await startTestServer();
  try {
    const res = await fetch(`${ctx.baseUrl}/v1/me/semya`);
    assert.equal(res.status, 401);
  } finally {
    await shutdown(ctx);
  }
});
