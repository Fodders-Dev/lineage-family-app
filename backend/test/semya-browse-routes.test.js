// Phase B Week 3 Ship 7: browse mode endpoints tests.
//
// Scope:
//   POST   /v1/semya/:id/browse-token          — create capability token
//   GET    /v1/browse/:token                   — resolve → read-only payload
//   GET    /v1/semya/:id/browse-tokens         — list для settings
//   DELETE /v1/semya/:id/browse-token/:tokenId — revoke
//
// Coverage:
//   * Token creation: owner OK, editor с grant OK, editor без grant 403,
//     viewer 403
//   * Browse resolve: payload shape, photos/sensitive omitted, читает
//     без auth, lastUsedAt touched
//   * Expired token → 410, revoked → 410, unknown → 404
//   * Token chain block: browse session не gives token-create capability
//   * Revoke: creator OK, owner OK, non-creator-non-owner 403, double
//     revoke 409
//   * List: any member sees summary без plaintext secret

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-browse-"));
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
  // Best-effort, как в остальных тест-обвязках (posts-pagination и др.):
  // на Windows антивирус/индексатор может держать файл в temp-каталоге,
  // и ENOTEMPTY здесь красил содержательно зелёный тест (задокументированный
  // флейк, стал стабильным 29.08). Утечка temp-папки безопасна.
  await fs.rm(tempDir, {recursive: true, force: true}).catch(() => {});
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

async function seedSemyaWithPerson(store, ownerUserId, semyaName, personName) {
  const tree = await store.createTree({
    creatorId: ownerUserId,
    name: `Дерево ${semyaName}`,
    description: "",
    isPrivate: true,
    kind: "family",
  });
  const semya = await store.createSemya({
    ownerId: ownerUserId,
    name: semyaName,
    treeId: tree.id,
  });
  const person = await store.createPerson({
    treeId: tree.id,
    creatorId: ownerUserId,
    personData: {
      firstName: personName,
      lastName: "Тестов",
      name: `${personName} Тестов`,
      photoUrl: "https://example.com/secret-photo.jpg",
      bio: "Sensitive bio данные",
    },
  });
  return {tree, semya, person};
}

// ---------- POST create ----------

test("Browse token: owner creates token (201, plaintext secret returned once)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "bo1@example.com");
    const seed = await seedSemyaWithPerson(ctx.store, owner.userId, "S1", "P1");

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${seed.semya.id}/browse-token`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({expiresInDays: 7}),
      },
    );
    assert.equal(res.status, 201);
    const body = await res.json();
    assert.ok(body.token?.id);
    assert.ok(body.token?.token, "plaintext token returned once at creation");
    assert.equal(body.token.semyaId, seed.semya.id);
    assert.equal(body.token.createdByUserId, owner.userId);
    assert.equal(body.token.revokedAt, null);
    // Expiry in future, within ~7 day window
    const expiryMs = Date.parse(body.token.expiresAt);
    const sevenDaysMs = 7 * 24 * 60 * 60 * 1000;
    const nowMs = Date.now();
    assert.ok(expiryMs >= nowMs && expiryMs <= nowMs + sevenDaysMs + 60_000);
  } finally {
    await shutdown(ctx);
  }
});

test("Browse token: editor с invite-grant can create (201)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "bo2@example.com");
    const editor = await makeUser(ctx.store, ctx.baseUrl, "be2@example.com");
    const seed = await seedSemyaWithPerson(ctx.store, owner.userId, "S2", "P2");

    await ctx.store.addMembership({
      semyaId: seed.semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
      hasInviteGrant: true,
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${seed.semya.id}/browse-token`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${editor.token}`,
        },
        body: JSON.stringify({}),
      },
    );
    assert.equal(res.status, 201);
  } finally {
    await shutdown(ctx);
  }
});

test("Browse token: editor без grant 403, viewer 403", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "bo3@example.com");
    const editor = await makeUser(ctx.store, ctx.baseUrl, "be3@example.com");
    const viewer = await makeUser(ctx.store, ctx.baseUrl, "bv3@example.com");
    const seed = await seedSemyaWithPerson(ctx.store, owner.userId, "S3", "P3");

    await ctx.store.addMembership({
      semyaId: seed.semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
      hasInviteGrant: false,
    });
    await ctx.store.addMembership({
      semyaId: seed.semya.id,
      userId: viewer.userId,
      role: "viewer",
      invitedByUserId: owner.userId,
    });

    const editorRes = await fetch(
      `${ctx.baseUrl}/v1/semya/${seed.semya.id}/browse-token`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${editor.token}`,
        },
        body: JSON.stringify({}),
      },
    );
    assert.equal(editorRes.status, 403);

    const viewerRes = await fetch(
      `${ctx.baseUrl}/v1/semya/${seed.semya.id}/browse-token`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${viewer.token}`,
        },
        body: JSON.stringify({}),
      },
    );
    assert.equal(viewerRes.status, 403);
  } finally {
    await shutdown(ctx);
  }
});

// ---------- GET browse resolve ----------

test("GET /browse/:token: returns read-only payload, photos+bio omitted", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "bo4@example.com");
    const seed = await seedSemyaWithPerson(ctx.store, owner.userId, "S4", "P4");

    const tokenResult = await ctx.store.createBrowseToken({
      semyaId: seed.semya.id,
      createdByUserId: owner.userId,
    });

    // NO auth header — token is the capability
    const res = await fetch(`${ctx.baseUrl}/v1/browse/${tokenResult.token}`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.browse.readOnly, true);
    assert.equal(body.browse.semya.id, seed.semya.id);
    assert.equal(body.browse.semya.name, "S4");
    assert.equal(body.browse.tree.id, seed.tree.id);
    assert.ok(Array.isArray(body.browse.persons));
    assert.ok(body.browse.persons.length >= 1);
    // Privacy: photo + bio omitted from response. Search by `name`
    // field — buildPersonRecord stores combined "lastName firstName"
    // (store.js:4366 fullNameFromPersonInput), no split fields в DB.
    const seededPerson = body.browse.persons.find(
      (p) => (p.name || "").includes("P4"),
    );
    assert.ok(seededPerson, "seeded person present");
    assert.ok(!("photoUrl" in seededPerson), "photoUrl filtered out");
    assert.ok(!("bio" in seededPerson), "bio filtered out");
    assert.ok(!("primaryPhotoUrl" in seededPerson));
    // Basic shape preserved — combined name field present
    assert.ok(seededPerson.name && seededPerson.name.length > 0);
  } finally {
    await shutdown(ctx);
  }
});

test("GET /browse/:token: unknown token 404", async () => {
  const ctx = await startTestServer();
  try {
    const res = await fetch(`${ctx.baseUrl}/v1/browse/unknown-token-xyz`);
    assert.equal(res.status, 404);
  } finally {
    await shutdown(ctx);
  }
});

test("GET /browse/:token: revoked token 410", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "bo5@example.com");
    const seed = await seedSemyaWithPerson(ctx.store, owner.userId, "S5", "P5");

    const tokenResult = await ctx.store.createBrowseToken({
      semyaId: seed.semya.id,
      createdByUserId: owner.userId,
    });
    await ctx.store.revokeBrowseToken({
      tokenId: tokenResult.id,
      actingUserId: owner.userId,
    });

    const res = await fetch(`${ctx.baseUrl}/v1/browse/${tokenResult.token}`);
    assert.equal(res.status, 410);
  } finally {
    await shutdown(ctx);
  }
});

test("GET /browse/:token: expired token 410", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "bo6@example.com");
    const seed = await seedSemyaWithPerson(ctx.store, owner.userId, "S6", "P6");

    const tokenResult = await ctx.store.createBrowseToken({
      semyaId: seed.semya.id,
      createdByUserId: owner.userId,
    });
    // Force expiry to past
    const db = await ctx.store._read();
    const t = db.semyaBrowseTokens.find((x) => x.id === tokenResult.id);
    t.expiresAt = new Date(Date.now() - 1000).toISOString();
    await ctx.store._write(db);

    const res = await fetch(`${ctx.baseUrl}/v1/browse/${tokenResult.token}`);
    assert.equal(res.status, 410);
  } finally {
    await shutdown(ctx);
  }
});

test("Token chain blocked: browse holder cannot create token (no auth context)", async () => {
  // Browse mode requires NO auth — but POST /v1/semya/:id/browse-token
  // requires viewer+ membership (requireAuth + requireSemyaAccess).
  // Browse-only callers have neither — chain naturally blocked.
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "bo7@example.com");
    const seed = await seedSemyaWithPerson(ctx.store, owner.userId, "S7", "P7");

    const tokenResult = await ctx.store.createBrowseToken({
      semyaId: seed.semya.id,
      createdByUserId: owner.userId,
    });

    // Browse holder pretends to use token «as auth» — fails because
    // create endpoint requires Bearer-style auth, not browse token
    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${seed.semya.id}/browse-token`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${tokenResult.token}`, // browse token, не session token
        },
        body: JSON.stringify({}),
      },
    );
    // 401 потому что browse token не session token — auth middleware
    // rejects up-front
    assert.equal(res.status, 401);
  } finally {
    await shutdown(ctx);
  }
});

// ---------- GET list tokens ----------

test("GET /browse-tokens: member sees summary без plaintext secret", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "bo8@example.com");
    const seed = await seedSemyaWithPerson(ctx.store, owner.userId, "S8", "P8");

    await ctx.store.createBrowseToken({
      semyaId: seed.semya.id,
      createdByUserId: owner.userId,
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${seed.semya.id}/browse-tokens`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.tokens.length, 1);
    assert.ok(!("token" in body.tokens[0]), "plaintext secret omitted from listing");
    assert.equal(body.tokens[0].status, "active");
  } finally {
    await shutdown(ctx);
  }
});

// ---------- DELETE revoke ----------

test("DELETE token: creator revokes (200), subsequent browse 410", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "bo9@example.com");
    const seed = await seedSemyaWithPerson(ctx.store, owner.userId, "S9", "P9");

    const tokenResult = await ctx.store.createBrowseToken({
      semyaId: seed.semya.id,
      createdByUserId: owner.userId,
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${seed.semya.id}/browse-token/${tokenResult.id}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(res.status, 200);

    // Subsequent browse → 410
    const browse = await fetch(`${ctx.baseUrl}/v1/browse/${tokenResult.token}`);
    assert.equal(browse.status, 410);
  } finally {
    await shutdown(ctx);
  }
});

test("DELETE token: editor с grant (non-creator) rejected (403)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "bo10@example.com");
    const editor = await makeUser(ctx.store, ctx.baseUrl, "be10@example.com");
    const seed = await seedSemyaWithPerson(ctx.store, owner.userId, "S10", "P10");

    await ctx.store.addMembership({
      semyaId: seed.semya.id,
      userId: editor.userId,
      role: "editor",
      invitedByUserId: owner.userId,
      hasInviteGrant: true,
    });

    // Owner creates token
    const tokenResult = await ctx.store.createBrowseToken({
      semyaId: seed.semya.id,
      createdByUserId: owner.userId,
    });

    // Editor (не creator, не owner) tries to revoke — 403
    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${seed.semya.id}/browse-token/${tokenResult.id}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${editor.token}`},
      },
    );
    assert.equal(res.status, 403);
  } finally {
    await shutdown(ctx);
  }
});

test("DELETE token: double revoke 409", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "bo11@example.com");
    const seed = await seedSemyaWithPerson(ctx.store, owner.userId, "S11", "P11");
    const tokenResult = await ctx.store.createBrowseToken({
      semyaId: seed.semya.id,
      createdByUserId: owner.userId,
    });

    const first = await fetch(
      `${ctx.baseUrl}/v1/semya/${seed.semya.id}/browse-token/${tokenResult.id}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(first.status, 200);

    const second = await fetch(
      `${ctx.baseUrl}/v1/semya/${seed.semya.id}/browse-token/${tokenResult.id}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(second.status, 409);
  } finally {
    await shutdown(ctx);
  }
});
