// Ship Q4a (2026-05-28): deletedPersons HTTP route tests.
//
// Per PHASE-Q4A-SOFT-DELETE-DESIGN (ec12804) Path 2 architecture.
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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-dp-rt-"));
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

async function seedTreeWithPerson(store, baseUrl, ownerEmail) {
  const owner = await makeUser(store, baseUrl, ownerEmail);
  const tree = await store.createTree({
    creatorId: owner.userId,
    name: "Тест",
    description: "",
    isPrivate: true,
    kind: "family",
  });
  const person = await store.createPerson({
    treeId: tree.id,
    creatorId: owner.userId,
    personData: {
      name: "Иван Иванов",
      gender: "male",
      birthDate: "1990-01-01",
    },
  });
  return {owner, tree, person};
}

test("soft-delete moves person к deletedPersons + remains queryable through restore endpoint", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree, person} = await seedTreeWithPerson(
      ctx.store,
      ctx.baseUrl,
      "q4a-soft@example.com",
    );

    // Delete via existing endpoint (now soft-delete semantically).
    const delRes = await fetch(
      `${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(delRes.status, 204);

    // Subsequent GET tree persons — soft-deleted not visible (95
    // read sites preserved by Path 2 architecture). createTree
    // auto-adds creator self-person (store.js:7643) → tree has
    // 1 person remaining (creator self) post-DELETE Иван.
    const treeRes = await fetch(
      `${ctx.baseUrl}/v1/trees/${tree.id}/persons`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    const treeBody = await treeRes.json();
    assert.equal(treeBody.persons.length, 1);
    assert.equal(treeBody.persons[0].userId, owner.userId);

    // Deleted person discoverable через каркас. Only Иван — creator
    // self never deleted.
    const listRes = await fetch(
      `${ctx.baseUrl}/v1/me/deleted-persons`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    assert.equal(listRes.status, 200);
    const listBody = await listRes.json();
    assert.equal(listBody.deletedPersons.length, 1);
    assert.equal(listBody.deletedPersons[0].originalPersonId, person.id);
    assert.equal(listBody.deletedPersons[0].snapshot.name, "Иван Иванов");
    assert.equal(listBody.deletedPersons[0].deletedByUserId, owner.userId);
    assert.ok(listBody.deletedPersons[0].hardDeleteScheduledAt);
    assert.ok(listBody.deletedPersons[0].earliestHardDelete);
  } finally {
    await shutdown(ctx);
  }
});

test("restore moves snapshot back к live persons", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree, person} = await seedTreeWithPerson(
      ctx.store,
      ctx.baseUrl,
      "q4a-restore@example.com",
    );
    await fetch(`${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });

    const listRes = await fetch(`${ctx.baseUrl}/v1/me/deleted-persons`, {
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    const deletedId = (await listRes.json()).deletedPersons[0].id;

    const restoreRes = await fetch(
      `${ctx.baseUrl}/v1/deleted-persons/${deletedId}/restore`,
      {
        method: "POST",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(restoreRes.status, 200);

    // Person back в live tree. Tree has 2 persons total: creator
    // self (auto-added by createTree) + restored Иван.
    const treeRes = await fetch(
      `${ctx.baseUrl}/v1/trees/${tree.id}/persons`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    const treeBody = await treeRes.json();
    assert.equal(treeBody.persons.length, 2);
    const restored = treeBody.persons.find((p) => p.id === person.id);
    assert.ok(restored);
    assert.equal(restored.name, "Иван Иванов");

    // Pending list пустой (restored row filtered).
    const list2 = await fetch(`${ctx.baseUrl}/v1/me/deleted-persons`, {
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    assert.equal((await list2.json()).deletedPersons.length, 0);
  } finally {
    await shutdown(ctx);
  }
});

test("restore двойной call returns 409 ALREADY_RESTORED", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree, person} = await seedTreeWithPerson(
      ctx.store,
      ctx.baseUrl,
      "q4a-double-restore@example.com",
    );
    await fetch(`${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    const deletedId = (
      await (
        await fetch(`${ctx.baseUrl}/v1/me/deleted-persons`, {
          headers: {Authorization: `Bearer ${owner.token}`},
        })
      ).json()
    ).deletedPersons[0].id;
    // First restore succeeds.
    const first = await fetch(
      `${ctx.baseUrl}/v1/deleted-persons/${deletedId}/restore`,
      {
        method: "POST",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(first.status, 200);
    // Second rejected.
    const second = await fetch(
      `${ctx.baseUrl}/v1/deleted-persons/${deletedId}/restore`,
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
    const {owner, tree, person} = await seedTreeWithPerson(
      ctx.store,
      ctx.baseUrl,
      "q4a-floor@example.com",
    );
    await fetch(`${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    const deletedId = (
      await (
        await fetch(`${ctx.baseUrl}/v1/me/deleted-persons`, {
          headers: {Authorization: `Bearer ${owner.token}`},
        })
      ).json()
    ).deletedPersons[0].id;
    // Immediately try hard-purge — within 3h floor.
    const purgeRes = await fetch(
      `${ctx.baseUrl}/v1/deleted-persons/${deletedId}`,
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

test("hard-purge succeeds after floor (test override via direct store mutation)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree, person} = await seedTreeWithPerson(
      ctx.store,
      ctx.baseUrl,
      "q4a-purge@example.com",
    );
    await fetch(`${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    // Force floor passage by mutating earliestHardDelete directly.
    const db = await ctx.store._read();
    db.deletedPersons[0].earliestHardDelete = "2020-01-01T00:00:00.000Z";
    await ctx.store._write(db);
    const deletedId = db.deletedPersons[0].id;

    const purgeRes = await fetch(
      `${ctx.baseUrl}/v1/deleted-persons/${deletedId}`,
      {
        method: "DELETE",
        headers: {Authorization: `Bearer ${owner.token}`},
      },
    );
    assert.equal(purgeRes.status, 200);

    // List now empty (row physically removed).
    const listAfter = await (
      await fetch(`${ctx.baseUrl}/v1/me/deleted-persons`, {
        headers: {Authorization: `Bearer ${owner.token}`},
      })
    ).json();
    assert.equal(listAfter.deletedPersons.length, 0);
  } finally {
    await shutdown(ctx);
  }
});

test("unauthorized list rejected с 401", async () => {
  const ctx = await startTestServer();
  try {
    const res = await fetch(`${ctx.baseUrl}/v1/me/deleted-persons`);
    assert.equal(res.status, 401);
  } finally {
    await shutdown(ctx);
  }
});

test("hard-delete-job sweep purges past retention + past floor", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree, person} = await seedTreeWithPerson(
      ctx.store,
      ctx.baseUrl,
      "q4a-job-sweep@example.com",
    );
    await fetch(`${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    // Force both timestamps past — simulating row past 30d + 3h floor.
    const db = await ctx.store._read();
    db.deletedPersons[0].hardDeleteScheduledAt = "2020-01-01T00:00:00.000Z";
    db.deletedPersons[0].earliestHardDelete = "2020-01-01T00:00:00.000Z";
    await ctx.store._write(db);

    // Run hardDeleteExpired manually.
    const summary = await ctx.store.hardDeleteExpired({
      now: new Date(),
      retentionDays: 30,
      dryRun: false,
    });
    assert.equal(summary.deleted.deletedPersons, 1);
    const dbAfter = await ctx.store._read();
    assert.equal(dbAfter.deletedPersons.length, 0);
  } finally {
    await shutdown(ctx);
  }
});

test("hard-delete-job respects 3h floor — skips rows с future earliestHardDelete", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree, person} = await seedTreeWithPerson(
      ctx.store,
      ctx.baseUrl,
      "q4a-job-floor@example.com",
    );
    await fetch(`${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    // Scheduled in past, but floor in future — должен NOT purge.
    const db = await ctx.store._read();
    db.deletedPersons[0].hardDeleteScheduledAt = "2020-01-01T00:00:00.000Z";
    db.deletedPersons[0].earliestHardDelete = new Date(
      Date.now() + 3_600_000,
    ).toISOString();
    await ctx.store._write(db);

    const summary = await ctx.store.hardDeleteExpired({
      now: new Date(),
      retentionDays: 30,
      dryRun: false,
    });
    assert.equal(summary.deleted.deletedPersons, 0);
    const dbAfter = await ctx.store._read();
    assert.equal(dbAfter.deletedPersons.length, 1);
  } finally {
    await shutdown(ctx);
  }
});
