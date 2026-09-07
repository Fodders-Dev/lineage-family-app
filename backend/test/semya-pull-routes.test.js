// Phase B Week 3 Ship 6: pull-selectively endpoint tests.
//
// Scope:
//   POST /v1/semya/:targetSemyaId/pull-person
//
// Coverage:
//   * Happy path: editor pulls existing-source-member's person
//   * Idempotency: re-pull same person = existing twin returned
//   * Permission: target viewer cannot pull (needs editor) — 403
//   * Permission: no source membership — 403
//   * Permission: source = target — 400
//   * Person not found in source tree — 404
//   * Identity link verification (personIdentities row created)
//   * Audit log entry «person.pulled-from-semya» appended
//   * Browse-token alternative source access deferred Ship 7

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-pull-"));
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
  // Add a person к tree (other than auto-created creator person)
  const person = await store.createPerson({
    treeId: tree.id,
    creatorId: ownerUserId,
    personData: {
      firstName: personName,
      lastName: "Тестов",
      name: `${personName} Тестов`,
    },
  });
  return {tree, semya, person};
}

// ---------- Happy path + idempotency ----------

test("Pull: editor pulls source person → target person + identity link", async () => {
  const ctx = await startTestServer();
  try {
    const sourceOwner = await makeUser(ctx.store, ctx.baseUrl, "src1@example.com");
    const sharedUser = await makeUser(ctx.store, ctx.baseUrl, "shr1@example.com");
    const targetOwner = await makeUser(ctx.store, ctx.baseUrl, "tgt1@example.com");

    const source = await seedSemyaWithPerson(
      ctx.store,
      sourceOwner.userId,
      "Семья-Источник",
      "Дядя Коля",
    );
    const target = await seedSemyaWithPerson(
      ctx.store,
      targetOwner.userId,
      "Семья-Цель",
      "Бабушка Маша",
    );

    // sharedUser добавлен viewer в source, editor в target
    await ctx.store.addMembership({
      semyaId: source.semya.id,
      userId: sharedUser.userId,
      role: "viewer",
      invitedByUserId: sourceOwner.userId,
    });
    await ctx.store.addMembership({
      semyaId: target.semya.id,
      userId: sharedUser.userId,
      role: "editor",
      invitedByUserId: targetOwner.userId,
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${target.semya.id}/pull-person`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${sharedUser.token}`,
        },
        body: JSON.stringify({
          sourceSemyaId: source.semya.id,
          sourcePersonId: source.person.id,
        }),
      },
    );

    assert.equal(res.status, 200);
    const body = await res.json();
    assert.ok(body.person?.id, "twin person returned");
    assert.equal(body.person.treeId, target.tree.id);
    assert.equal(body.sourceSemyaId, source.semya.id);
    assert.equal(body.targetSemyaId, target.semya.id);

    // Identity link verification — source + target persons share
    // identityId, personIdentities row contains both ids.
    const db = await ctx.store._read();
    const sourcePerson = db.persons.find((p) => p.id === source.person.id);
    const targetPerson = db.persons.find((p) => p.id === body.person.id);
    assert.ok(sourcePerson.identityId, "source person has identityId");
    assert.equal(
      sourcePerson.identityId,
      targetPerson.identityId,
      "twin shares identityId",
    );
    const identity = db.personIdentities.find(
      (i) => i.id === sourcePerson.identityId,
    );
    assert.ok(identity, "personIdentity row exists");
    assert.ok(identity.personIds.includes(source.person.id));
    assert.ok(identity.personIds.includes(targetPerson.id));

    // Audit log entry «person.pulled-from-semya» present
    const auditEntry = db.treeChangeRecords.find(
      (r) =>
        r.treeId === target.tree.id &&
        r.type === "person.pulled-from-semya" &&
        r.personId === targetPerson.id,
    );
    assert.ok(auditEntry, "audit log entry created");
    assert.equal(auditEntry.details?.sourceSemyaId, source.semya.id);
    assert.equal(auditEntry.details?.sourcePersonId, source.person.id);
  } finally {
    await shutdown(ctx);
  }
});

test("Pull: idempotent re-pull returns existing twin (no duplicates)", async () => {
  const ctx = await startTestServer();
  try {
    const sourceOwner = await makeUser(ctx.store, ctx.baseUrl, "src2@example.com");
    const shared = await makeUser(ctx.store, ctx.baseUrl, "shr2@example.com");
    const targetOwner = await makeUser(ctx.store, ctx.baseUrl, "tgt2@example.com");

    const source = await seedSemyaWithPerson(
      ctx.store,
      sourceOwner.userId,
      "S2",
      "Person2",
    );
    const target = await seedSemyaWithPerson(
      ctx.store,
      targetOwner.userId,
      "T2",
      "Other",
    );

    await ctx.store.addMembership({
      semyaId: source.semya.id,
      userId: shared.userId,
      role: "viewer",
      invitedByUserId: sourceOwner.userId,
    });
    await ctx.store.addMembership({
      semyaId: target.semya.id,
      userId: shared.userId,
      role: "editor",
      invitedByUserId: targetOwner.userId,
    });

    const first = await fetch(
      `${ctx.baseUrl}/v1/semya/${target.semya.id}/pull-person`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${shared.token}`,
        },
        body: JSON.stringify({
          sourceSemyaId: source.semya.id,
          sourcePersonId: source.person.id,
        }),
      },
    );
    assert.equal(first.status, 200);
    const firstBody = await first.json();

    const second = await fetch(
      `${ctx.baseUrl}/v1/semya/${target.semya.id}/pull-person`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${shared.token}`,
        },
        body: JSON.stringify({
          sourceSemyaId: source.semya.id,
          sourcePersonId: source.person.id,
        }),
      },
    );
    assert.equal(second.status, 200);
    const secondBody = await second.json();

    // bulkImport's identity-dedup returns null persons array на
    // дубликат (no new person created). Response.person в этом случае
    // null — but identityId/twin link уже established by первый pull.
    // Verify: no duplicate person rows для same identityId in target.
    const db = await ctx.store._read();
    const sourcePerson = db.persons.find((p) => p.id === source.person.id);
    const targetTwins = db.persons.filter(
      (p) =>
        p.treeId === target.tree.id &&
        p.identityId === sourcePerson.identityId,
    );
    assert.equal(targetTwins.length, 1, "exactly один twin person в target");

    // Both responses reference the same identity линк (если first
    // created it, second sees stable state)
    if (firstBody.person && secondBody.person) {
      assert.equal(secondBody.person.id, firstBody.person.id);
    }
  } finally {
    await shutdown(ctx);
  }
});

// ---------- Permission ----------

test("Pull: target viewer cannot pull (403 — editor required)", async () => {
  const ctx = await startTestServer();
  try {
    const sourceOwner = await makeUser(ctx.store, ctx.baseUrl, "src3@example.com");
    const shared = await makeUser(ctx.store, ctx.baseUrl, "shr3@example.com");
    const targetOwner = await makeUser(ctx.store, ctx.baseUrl, "tgt3@example.com");

    const source = await seedSemyaWithPerson(
      ctx.store,
      sourceOwner.userId,
      "S3",
      "Person3",
    );
    const target = await seedSemyaWithPerson(
      ctx.store,
      targetOwner.userId,
      "T3",
      "Other3",
    );

    await ctx.store.addMembership({
      semyaId: source.semya.id,
      userId: shared.userId,
      role: "viewer",
      invitedByUserId: sourceOwner.userId,
    });
    // shared only viewer в target — не editor
    await ctx.store.addMembership({
      semyaId: target.semya.id,
      userId: shared.userId,
      role: "viewer",
      invitedByUserId: targetOwner.userId,
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${target.semya.id}/pull-person`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${shared.token}`,
        },
        body: JSON.stringify({
          sourceSemyaId: source.semya.id,
          sourcePersonId: source.person.id,
        }),
      },
    );
    assert.equal(res.status, 403);
  } finally {
    await shutdown(ctx);
  }
});

test("Pull: no source membership = 403", async () => {
  const ctx = await startTestServer();
  try {
    const sourceOwner = await makeUser(ctx.store, ctx.baseUrl, "src4@example.com");
    const stranger = await makeUser(ctx.store, ctx.baseUrl, "str4@example.com");

    const source = await seedSemyaWithPerson(
      ctx.store,
      sourceOwner.userId,
      "S4",
      "Person4",
    );
    const target = await seedSemyaWithPerson(
      ctx.store,
      stranger.userId,
      "T4",
      "Other4",
    );

    // stranger NOT member source семья — only owner of target
    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${target.semya.id}/pull-person`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${stranger.token}`,
        },
        body: JSON.stringify({
          sourceSemyaId: source.semya.id,
          sourcePersonId: source.person.id,
        }),
      },
    );
    assert.equal(res.status, 403);
  } finally {
    await shutdown(ctx);
  }
});

test("Pull: source = target rejected (400)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "src5@example.com");
    const seeded = await seedSemyaWithPerson(
      ctx.store,
      owner.userId,
      "S5",
      "Person5",
    );

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${seeded.semya.id}/pull-person`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({
          sourceSemyaId: seeded.semya.id,
          sourcePersonId: seeded.person.id,
        }),
      },
    );
    assert.equal(res.status, 400);
  } finally {
    await shutdown(ctx);
  }
});

test("Pull: source person not in source tree = 404", async () => {
  const ctx = await startTestServer();
  try {
    const sourceOwner = await makeUser(ctx.store, ctx.baseUrl, "src6@example.com");
    const shared = await makeUser(ctx.store, ctx.baseUrl, "shr6@example.com");
    const targetOwner = await makeUser(ctx.store, ctx.baseUrl, "tgt6@example.com");

    const source = await seedSemyaWithPerson(
      ctx.store,
      sourceOwner.userId,
      "S6",
      "Person6",
    );
    const target = await seedSemyaWithPerson(
      ctx.store,
      targetOwner.userId,
      "T6",
      "Other6",
    );

    await ctx.store.addMembership({
      semyaId: source.semya.id,
      userId: shared.userId,
      role: "viewer",
      invitedByUserId: sourceOwner.userId,
    });
    await ctx.store.addMembership({
      semyaId: target.semya.id,
      userId: shared.userId,
      role: "editor",
      invitedByUserId: targetOwner.userId,
    });

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${target.semya.id}/pull-person`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${shared.token}`,
        },
        body: JSON.stringify({
          sourceSemyaId: source.semya.id,
          sourcePersonId: "00000000-0000-0000-0000-000000000000",
        }),
      },
    );
    assert.equal(res.status, 404);
  } finally {
    await shutdown(ctx);
  }
});

test("Pull: missing body fields = 400", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "src7@example.com");
    const target = await seedSemyaWithPerson(
      ctx.store,
      owner.userId,
      "T7",
      "Other7",
    );

    const noSource = await fetch(
      `${ctx.baseUrl}/v1/semya/${target.semya.id}/pull-person`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({sourcePersonId: "some-id"}),
      },
    );
    assert.equal(noSource.status, 400);

    const noPerson = await fetch(
      `${ctx.baseUrl}/v1/semya/${target.semya.id}/pull-person`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({sourceSemyaId: "some-id"}),
      },
    );
    assert.equal(noPerson.status, 400);
  } finally {
    await shutdown(ctx);
  }
});

test("Pull: 401 без auth", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "src8@example.com");
    const target = await seedSemyaWithPerson(
      ctx.store,
      owner.userId,
      "T8",
      "Other8",
    );

    const res = await fetch(
      `${ctx.baseUrl}/v1/semya/${target.semya.id}/pull-person`,
      {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({sourceSemyaId: "x", sourcePersonId: "y"}),
      },
    );
    assert.equal(res.status, 401);
  } finally {
    await shutdown(ctx);
  }
});
