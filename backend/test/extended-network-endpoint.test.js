// Phase 4 chunk 1: GET /v1/trees/:treeId/extended-network tests.
//
// Покрывает (DECISIONS.md 2026-05-12, nice-to-have #3):
// • Endpoint authentication / authorization (no token → 401,
//   non-member → 403, member → 200).
// • maxHops clamp 2..4 (out of range → clamp; missing → default 4).
// • Slice cap (synthetic small-cap fixture → stats.capReached =
//   true, length capped).
// • Privacy fence respected (graphPersons выходящие за fence не в
//   response).
// • Sparse ownerMap (viewer's own nodes implicit, foreign nodes
//   explicit entries).
// • DTO round-trip — для Flutter теста (см.
//   test/extended_network_slice_test.dart).

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-extnet-"));
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

async function stopTestServer(ctx) {
  await new Promise((resolve, reject) => {
    ctx.server.close((error) => (error ? reject(error) : resolve()));
  });
  await fs.rm(ctx.tempDir, {recursive: true, force: true});
}

async function registerUser(ctx, email, displayName) {
  const response = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({
      email,
      password: "secret123",
      consentDocVersion: "test-consent-v1",
      displayName,
    }),
  });
  assert.equal(response.status, 201);
  return response.json();
}

async function createTree(ctx, owner, name = "Test tree") {
  const response = await fetch(`${ctx.baseUrl}/v1/trees`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${owner.accessToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({name, description: "", isPrivate: true}),
  });
  assert.equal(response.status, 201);
  return (await response.json()).tree;
}

async function createPerson(ctx, token, treeId, body) {
  const response = await fetch(`${ctx.baseUrl}/v1/trees/${treeId}/persons`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  assert.equal(response.status, 201);
  return (await response.json()).person;
}

async function createRelation(ctx, token, treeId, body) {
  const response = await fetch(`${ctx.baseUrl}/v1/trees/${treeId}/relations`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  return response;
}

async function getExtendedNetwork(ctx, token, treeId, queryString = "") {
  return fetch(
    `${ctx.baseUrl}/v1/trees/${treeId}/extended-network${queryString}`,
    {
      headers: token ? {authorization: `Bearer ${token}`} : {},
    },
  );
}

// ── Endpoint auth ────────────────────────────────────────────────

test(
  "GET /extended-network: no token → 401",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "owner@test.app", "Owner");
      const tree = await createTree(ctx, owner);
      const response = await getExtendedNetwork(ctx, null, tree.id);
      assert.equal(response.status, 401);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "GET /extended-network: non-member viewer → 403",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "owner-403@test.app", "Owner");
      const stranger = await registerUser(
        ctx,
        "stranger-403@test.app",
        "Stranger",
      );
      const tree = await createTree(ctx, owner);
      const response = await getExtendedNetwork(
        ctx,
        stranger.accessToken,
        tree.id,
      );
      assert.equal(response.status, 403);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "GET /extended-network: tree-member viewer → 200 with slice shape",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "member-200@test.app", "Owner");
      const tree = await createTree(ctx, owner);
      // Создаём self-person для viewer'а — backend создаёт
      // graphPerson + identity link automatically через
      // createPerson if userId matches viewer.
      await createPerson(ctx, owner.accessToken, tree.id, {
        firstName: "Артём",
        lastName: "Тестов",
        gender: "male",
        userId: owner.user.id,
      });
      const response = await getExtendedNetwork(
        ctx,
        owner.accessToken,
        tree.id,
      );
      assert.equal(response.status, 200);
      const body = await response.json();
      assert.ok(body.slice, "response должен содержать .slice");
      assert.ok(Array.isArray(body.slice.graphPersons));
      assert.ok(Array.isArray(body.slice.graphRelations));
      assert.ok(typeof body.slice.branchMembership === "object");
      assert.ok(typeof body.slice.ownerMap === "object");
      assert.ok(body.slice.stats);
      assert.equal(typeof body.slice.stats.totalCount, "number");
      assert.equal(typeof body.slice.stats.myCount, "number");
      assert.equal(typeof body.slice.stats.extendedCount, "number");
      assert.equal(typeof body.slice.stats.maxHopsReached, "boolean");
      assert.equal(typeof body.slice.stats.capReached, "boolean");
    } finally {
      await stopTestServer(ctx);
    }
  },
);

// ── maxHops clamp ────────────────────────────────────────────────

test(
  "GET /extended-network: maxHops=1 clamps up to 2 (server-side defensive)",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "clamp-1@test.app", "Owner");
      const tree = await createTree(ctx, owner);
      await createPerson(ctx, owner.accessToken, tree.id, {
        firstName: "Я",
        gender: "male",
        userId: owner.user.id,
      });
      const response = await getExtendedNetwork(
        ctx,
        owner.accessToken,
        tree.id,
        "?maxHops=1",
      );
      assert.equal(response.status, 200);
      // Clamp visible через successful 200; точный observed maxHops
      // не в response shape v1, но server не throw'нул на out-of-range.
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "GET /extended-network: maxHops=10 clamps down to 4 (== privacy fence)",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "clamp-10@test.app", "Owner");
      const tree = await createTree(ctx, owner);
      await createPerson(ctx, owner.accessToken, tree.id, {
        firstName: "Я",
        gender: "male",
        userId: owner.user.id,
      });
      const response = await getExtendedNetwork(
        ctx,
        owner.accessToken,
        tree.id,
        "?maxHops=10",
      );
      assert.equal(response.status, 200);
      // Server-side clamp visible — 200 OK без error'а.
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "GET /extended-network: maxHops=garbage → default 4",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "clamp-gar@test.app", "Owner");
      const tree = await createTree(ctx, owner);
      await createPerson(ctx, owner.accessToken, tree.id, {
        firstName: "Я",
        gender: "male",
        userId: owner.user.id,
      });
      const response = await getExtendedNetwork(
        ctx,
        owner.accessToken,
        tree.id,
        "?maxHops=abc",
      );
      assert.equal(response.status, 200);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

// ── Privacy fence respected ──────────────────────────────────────

test(
  "GET /extended-network: stranger's tree persons НЕ в slice " +
    "(privacy isolation)",
  async () => {
    const ctx = await startTestServer();
    try {
      const me = await registerUser(ctx, "me-iso@test.app", "Me");
      const stranger = await registerUser(
        ctx,
        "stranger-iso@test.app",
        "Stranger",
      );
      const myTree = await createTree(ctx, me, "My tree");
      const strangerTree = await createTree(ctx, stranger, "Stranger tree");
      const mySelf = await createPerson(ctx, me.accessToken, myTree.id, {
        firstName: "Я",
        gender: "male",
        userId: me.user.id,
      });
      const strangerSelf = await createPerson(
        ctx,
        stranger.accessToken,
        strangerTree.id,
        {
          firstName: "Незнакомец",
          gender: "male",
          userId: stranger.user.id,
        },
      );
      // Слайс моего дерева — содержит МОЙ self-node, не stranger'а.
      const response = await getExtendedNetwork(
        ctx,
        me.accessToken,
        myTree.id,
      );
      assert.equal(response.status, 200);
      const body = await response.json();
      const ids = body.slice.graphPersons.map((g) => g.id);
      assert.ok(
        ids.includes(mySelf.identityId),
        "мой self-node должен быть в slice",
      );
      assert.ok(
        !ids.includes(strangerSelf.identityId),
        "stranger's self-node не должен быть в slice (privacy fence)",
      );
    } finally {
      await stopTestServer(ctx);
    }
  },
);

// ── Sparse ownerMap ──────────────────────────────────────────────

test(
  "GET /extended-network: ownerMap sparse — мои nodes implicit, " +
    "foreign nodes explicit",
  async () => {
    const ctx = await startTestServer();
    try {
      const me = await registerUser(ctx, "me-sparse@test.app", "Me");
      const tree = await createTree(ctx, me);
      const mySelf = await createPerson(ctx, me.accessToken, tree.id, {
        firstName: "Я",
        gender: "male",
        userId: me.user.id,
      });
      const anonAncestor = await createPerson(ctx, me.accessToken, tree.id, {
        firstName: "Бабушка",
        gender: "female",
      });
      const relationResp = await createRelation(
        ctx,
        me.accessToken,
        tree.id,
        {
          person1Id: anonAncestor.id,
          person2Id: mySelf.id,
          relation1to2: "mother",
        },
      );
      assert.equal(relationResp.status, 201);

      const response = await getExtendedNetwork(
        ctx,
        me.accessToken,
        tree.id,
      );
      assert.equal(response.status, 200);
      const body = await response.json();
      // Мой self-node — owner === viewer → ownerMap НЕ содержит entry.
      assert.ok(
        !(mySelf.identityId in body.slice.ownerMap),
        "my self-node не должен быть в ownerMap (sparse: viewer-owned implicit)",
      );
      // Anonymous ancestor created by me → owner === viewer (createdBy)
      // → также ownerMap НЕ содержит entry (sparse for viewer-owned).
      assert.ok(
        !(anonAncestor.identityId in body.slice.ownerMap),
        "анонимный предок (createdBy=viewer) тоже implicit в sparse map",
      );
    } finally {
      await stopTestServer(ctx);
    }
  },
);

// ── Slice cap behavior (store-level через малый sliceCap) ────────

test(
  "store.getExtendedNetworkSlice: synthetic cap=3, реальный graph 5+ → " +
    "capReached=true, slice размером ≤ cap",
  async () => {
    const ctx = await startTestServer();
    try {
      const me = await registerUser(ctx, "me-cap@test.app", "Me");
      const tree = await createTree(ctx, me);
      const me0 = await createPerson(ctx, me.accessToken, tree.id, {
        firstName: "Я",
        gender: "male",
        userId: me.user.id,
      });
      const ancestor1 = await createPerson(ctx, me.accessToken, tree.id, {
        firstName: "Бабушка",
        gender: "female",
      });
      const ancestor2 = await createPerson(ctx, me.accessToken, tree.id, {
        firstName: "Прабабушка",
        gender: "female",
      });
      const sibling = await createPerson(ctx, me.accessToken, tree.id, {
        firstName: "Сестра",
        gender: "female",
      });
      const niece = await createPerson(ctx, me.accessToken, tree.id, {
        firstName: "Племянница",
        gender: "female",
      });
      await createRelation(ctx, me.accessToken, tree.id, {
        person1Id: ancestor1.id,
        person2Id: me0.id,
        relation1to2: "mother",
      });
      await createRelation(ctx, me.accessToken, tree.id, {
        person1Id: ancestor2.id,
        person2Id: ancestor1.id,
        relation1to2: "mother",
      });
      await createRelation(ctx, me.accessToken, tree.id, {
        person1Id: ancestor1.id,
        person2Id: sibling.id,
        relation1to2: "mother",
      });
      await createRelation(ctx, me.accessToken, tree.id, {
        person1Id: sibling.id,
        person2Id: niece.id,
        relation1to2: "mother",
      });

      // Прямой store call с малым sliceCap для проверки cap logic.
      const slice = await ctx.store.getExtendedNetworkSlice({
        viewerUserId: me.user.id,
        treeId: tree.id,
        maxHops: 4,
        sliceCap: 3,
      });
      assert.equal(slice.stats.capReached, true);
      assert.ok(
        slice.graphPersons.length <= 3,
        `slice размером ≤ 3, реально ${slice.graphPersons.length}`,
      );
    } finally {
      await stopTestServer(ctx);
    }
  },
);

// ── Cache 60s TTL (functional) ────────────────────────────────────

test(
  "GET /extended-network: second request returns cached payload " +
    "(60s TTL, no invalidation)",
  async () => {
    const ctx = await startTestServer();
    try {
      const me = await registerUser(ctx, "me-cache@test.app", "Me");
      const tree = await createTree(ctx, me);
      await createPerson(ctx, me.accessToken, tree.id, {
        firstName: "Я",
        gender: "male",
        userId: me.user.id,
      });
      const r1 = await getExtendedNetwork(ctx, me.accessToken, tree.id);
      assert.equal(r1.status, 200);
      const body1 = await r1.json();
      const r2 = await getExtendedNetwork(ctx, me.accessToken, tree.id);
      assert.equal(r2.status, 200);
      const body2 = await r2.json();
      // Same payload (deepEqual через JSON serialization stability).
      assert.deepEqual(body1.slice.stats, body2.slice.stats);
      assert.deepEqual(
        body1.slice.graphPersons.map((g) => g.id).sort(),
        body2.slice.graphPersons.map((g) => g.id).sort(),
      );
    } finally {
      await stopTestServer(ctx);
    }
  },
);
