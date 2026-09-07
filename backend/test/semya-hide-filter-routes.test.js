// Phase B Week 3 Ship 8: hide-filter endpoints + tree-routes
// filtering tests. Privacy-critical — high coverage required.
//
// Scope:
//   GET   /v1/me/semya/:id/hide-filter      — list (200/403/404)
//   PATCH /v1/me/semya/:id/hide-filter      — batched add/remove
//   GET   /v1/trees/:treeId/persons         — verify filtering applies
//
// Privacy coverage:
//   * Hide adds → person disappears from caller's view
//   * Hide removes → person reappears
//   * Cross-user isolation: мама hides, Артём still sees
//   * Cross-семя isolation: hiding в семе X не hides twin в семе Y
//   * Idempotency: re-add existing = no-op (no error, count 0)
//   * Idempotency: remove non-existent = no-op
//   * Unknown personId hide accepted (no validation — orphan hide
//     row harmless, filter just doesn't match anything)
//   * Empty body → 400
//   * Tree без bound семя: filter doesn't fire (no semyaId →
//     listHiddenPersonIdsForCaller not called)

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-hide-"));
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

// ---------- GET hide-filter ----------

test("GET hide-filter: empty initially (200)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "hf1@example.com");
    const seed = await seedSemyaWithPerson(
      ctx.store,
      owner.userId,
      "S1",
      "P1",
    );

    const res = await fetch(
      `${ctx.baseUrl}/v1/me/semya/${seed.semya.id}/hide-filter`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.deepEqual(body.hiddenPersonIds, []);
  } finally {
    await shutdown(ctx);
  }
});

test("GET hide-filter: outsider 403", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "hf2@example.com");
    const outsider = await makeUser(ctx.store, ctx.baseUrl, "out2@example.com");
    const seed = await seedSemyaWithPerson(
      ctx.store,
      owner.userId,
      "S2",
      "P2",
    );

    const res = await fetch(
      `${ctx.baseUrl}/v1/me/semya/${seed.semya.id}/hide-filter`,
      {headers: {Authorization: `Bearer ${outsider.token}`}},
    );
    assert.equal(res.status, 403);
  } finally {
    await shutdown(ctx);
  }
});

// ---------- PATCH hide-filter ----------

test("PATCH hide-filter: add → person disappears from tree-routes view", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "hf3@example.com");
    const seed = await seedSemyaWithPerson(
      ctx.store,
      owner.userId,
      "S3",
      "P3",
    );

    // Before hide — verify person visible in tree GET
    const before = await fetch(
      `${ctx.baseUrl}/v1/trees/${seed.tree.id}/persons`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    assert.equal(before.status, 200);
    const beforeBody = await before.json();
    const sawBefore = beforeBody.persons.find((p) => p.id === seed.person.id);
    assert.ok(sawBefore, "person visible before hide");

    // Add hide
    const patch = await fetch(
      `${ctx.baseUrl}/v1/me/semya/${seed.semya.id}/hide-filter`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({add: [seed.person.id]}),
      },
    );
    assert.equal(patch.status, 200);
    const patchBody = await patch.json();
    assert.deepEqual(patchBody.hiddenPersonIds, [seed.person.id]);
    assert.equal(patchBody.addedCount, 1);
    assert.equal(patchBody.removedCount, 0);

    // After hide — person filtered out
    const after = await fetch(
      `${ctx.baseUrl}/v1/trees/${seed.tree.id}/persons`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    const afterBody = await after.json();
    const sawAfter = afterBody.persons.find((p) => p.id === seed.person.id);
    assert.ok(!sawAfter, "person filtered out after hide");
  } finally {
    await shutdown(ctx);
  }
});

test("PATCH hide-filter: remove → person reappears", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "hf4@example.com");
    const seed = await seedSemyaWithPerson(
      ctx.store,
      owner.userId,
      "S4",
      "P4",
    );

    // Add then remove
    await fetch(
      `${ctx.baseUrl}/v1/me/semya/${seed.semya.id}/hide-filter`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({add: [seed.person.id]}),
      },
    );

    const remove = await fetch(
      `${ctx.baseUrl}/v1/me/semya/${seed.semya.id}/hide-filter`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({remove: [seed.person.id]}),
      },
    );
    assert.equal(remove.status, 200);
    const removeBody = await remove.json();
    assert.deepEqual(removeBody.hiddenPersonIds, []);
    assert.equal(removeBody.removedCount, 1);

    // Person visible again
    const after = await fetch(
      `${ctx.baseUrl}/v1/trees/${seed.tree.id}/persons`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    const afterBody = await after.json();
    assert.ok(afterBody.persons.find((p) => p.id === seed.person.id));
  } finally {
    await shutdown(ctx);
  }
});

test("PATCH hide-filter: cross-user isolation (мама hides, Артём sees)", async () => {
  const ctx = await startTestServer();
  try {
    const artem = await makeUser(ctx.store, ctx.baseUrl, "artem@example.com");
    const mama = await makeUser(ctx.store, ctx.baseUrl, "mama@example.com");
    const seed = await seedSemyaWithPerson(
      ctx.store,
      artem.userId,
      "СемьяИвановых",
      "ДядяКоля",
    );

    // Мама joins as editor
    await ctx.store.addMembership({
      semyaId: seed.semya.id,
      userId: mama.userId,
      role: "editor",
      invitedByUserId: artem.userId,
    });

    // Мама hides дядю Колю
    const mamaHide = await fetch(
      `${ctx.baseUrl}/v1/me/semya/${seed.semya.id}/hide-filter`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${mama.token}`,
        },
        body: JSON.stringify({add: [seed.person.id]}),
      },
    );
    assert.equal(mamaHide.status, 200);

    // Мама's view — дядя Коля скрыт
    const mamaView = await fetch(
      `${ctx.baseUrl}/v1/trees/${seed.tree.id}/persons`,
      {headers: {Authorization: `Bearer ${mama.token}`}},
    );
    const mamaBody = await mamaView.json();
    assert.ok(!mamaBody.persons.find((p) => p.id === seed.person.id));

    // Артёма view — дядя Коля всё ещё visible
    const artemView = await fetch(
      `${ctx.baseUrl}/v1/trees/${seed.tree.id}/persons`,
      {headers: {Authorization: `Bearer ${artem.token}`}},
    );
    const artemBody = await artemView.json();
    assert.ok(artemBody.persons.find((p) => p.id === seed.person.id));

    // Артём hide-filter list — empty (he didn't hide)
    const artemFilter = await fetch(
      `${ctx.baseUrl}/v1/me/semya/${seed.semya.id}/hide-filter`,
      {headers: {Authorization: `Bearer ${artem.token}`}},
    );
    const artemFilterBody = await artemFilter.json();
    assert.deepEqual(artemFilterBody.hiddenPersonIds, []);
  } finally {
    await shutdown(ctx);
  }
});

test("PATCH hide-filter: cross-семя isolation — twin not auto-hidden", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "hf6@example.com");
    const sourceSeed = await seedSemyaWithPerson(
      ctx.store,
      owner.userId,
      "СемьяA",
      "ТвинЧеловек",
    );
    const targetSeed = await seedSemyaWithPerson(
      ctx.store,
      owner.userId,
      "СемьяB",
      "OtherPerson",
    );

    // Pull twin from source to target (creates twin link)
    const pull = await fetch(
      `${ctx.baseUrl}/v1/semya/${targetSeed.semya.id}/pull-person`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({
          sourceSemyaId: sourceSeed.semya.id,
          sourcePersonId: sourceSeed.person.id,
        }),
      },
    );
    assert.equal(pull.status, 200);
    const pullBody = await pull.json();
    const twinId = pullBody.person.id;

    // Hide twin в target семе
    await fetch(
      `${ctx.baseUrl}/v1/me/semya/${targetSeed.semya.id}/hide-filter`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({add: [twinId]}),
      },
    );

    // Target view — twin hidden
    const targetView = await fetch(
      `${ctx.baseUrl}/v1/trees/${targetSeed.tree.id}/persons`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    const targetBody = await targetView.json();
    assert.ok(!targetBody.persons.find((p) => p.id === twinId));

    // Source view — original NOT hidden (cross-семя isolation)
    const sourceView = await fetch(
      `${ctx.baseUrl}/v1/trees/${sourceSeed.tree.id}/persons`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    const sourceBody = await sourceView.json();
    assert.ok(sourceBody.persons.find((p) => p.id === sourceSeed.person.id));
  } finally {
    await shutdown(ctx);
  }
});

test("PATCH hide-filter: idempotent add (existing hide = no-op)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "hf7@example.com");
    const seed = await seedSemyaWithPerson(
      ctx.store,
      owner.userId,
      "S7",
      "P7",
    );

    const first = await fetch(
      `${ctx.baseUrl}/v1/me/semya/${seed.semya.id}/hide-filter`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({add: [seed.person.id]}),
      },
    );
    const firstBody = await first.json();
    assert.equal(firstBody.addedCount, 1);

    const second = await fetch(
      `${ctx.baseUrl}/v1/me/semya/${seed.semya.id}/hide-filter`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({add: [seed.person.id]}),
      },
    );
    const secondBody = await second.json();
    assert.equal(secondBody.addedCount, 0, "duplicate add no-op");
    assert.equal(secondBody.hiddenPersonIds.length, 1);
  } finally {
    await shutdown(ctx);
  }
});

test("PATCH hide-filter: idempotent remove (unknown personId = no-op)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "hf8@example.com");
    const seed = await seedSemyaWithPerson(
      ctx.store,
      owner.userId,
      "S8",
      "P8",
    );

    const res = await fetch(
      `${ctx.baseUrl}/v1/me/semya/${seed.semya.id}/hide-filter`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({
          remove: ["00000000-0000-0000-0000-000000000000"],
        }),
      },
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.removedCount, 0);
  } finally {
    await shutdown(ctx);
  }
});

test("PATCH hide-filter: unknown personId hide accepted (orphan harmless)", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "hf9@example.com");
    const seed = await seedSemyaWithPerson(
      ctx.store,
      owner.userId,
      "S9",
      "P9",
    );

    const res = await fetch(
      `${ctx.baseUrl}/v1/me/semya/${seed.semya.id}/hide-filter`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({
          add: ["00000000-0000-0000-0000-000000000000"],
        }),
      },
    );
    // Orphan hide allowed — filter just doesn't match anything.
    // Validation deferred (would require store roundtrip per personId).
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.addedCount, 1);
    // Real person в tree still visible — orphan hide doesn't affect
    const view = await fetch(
      `${ctx.baseUrl}/v1/trees/${seed.tree.id}/persons`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    const viewBody = await view.json();
    assert.ok(viewBody.persons.find((p) => p.id === seed.person.id));
  } finally {
    await shutdown(ctx);
  }
});

test("PATCH hide-filter: empty body = 400", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "hf10@example.com");
    const seed = await seedSemyaWithPerson(
      ctx.store,
      owner.userId,
      "S10",
      "P10",
    );

    const res = await fetch(
      `${ctx.baseUrl}/v1/me/semya/${seed.semya.id}/hide-filter`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({}),
      },
    );
    assert.equal(res.status, 400);
  } finally {
    await shutdown(ctx);
  }
});

test("PATCH hide-filter: batched add+remove в одной call", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "hf11@example.com");
    const tree = await ctx.store.createTree({
      creatorId: owner.userId,
      name: "Дерево11",
      description: "",
      isPrivate: true,
      kind: "family",
    });
    const semya = await ctx.store.createSemya({
      ownerId: owner.userId,
      name: "S11",
      treeId: tree.id,
    });
    const personA = await ctx.store.createPerson({
      treeId: tree.id,
      creatorId: owner.userId,
      personData: {firstName: "A", name: "PersonA"},
    });
    const personB = await ctx.store.createPerson({
      treeId: tree.id,
      creatorId: owner.userId,
      personData: {firstName: "B", name: "PersonB"},
    });

    // First — add A
    await fetch(
      `${ctx.baseUrl}/v1/me/semya/${semya.id}/hide-filter`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({add: [personA.id]}),
      },
    );

    // Batched: add B, remove A
    const batched = await fetch(
      `${ctx.baseUrl}/v1/me/semya/${semya.id}/hide-filter`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${owner.token}`,
        },
        body: JSON.stringify({add: [personB.id], remove: [personA.id]}),
      },
    );
    assert.equal(batched.status, 200);
    const body = await batched.json();
    assert.deepEqual(body.hiddenPersonIds, [personB.id]);
    assert.equal(body.addedCount, 1);
    assert.equal(body.removedCount, 1);
  } finally {
    await shutdown(ctx);
  }
});

test("Tree-routes: unbound tree (no semyaId) filter не fires", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await makeUser(ctx.store, ctx.baseUrl, "hf12@example.com");
    // Tree без semya wrap
    const tree = await ctx.store.createTree({
      creatorId: owner.userId,
      name: "Unbound",
      description: "",
      isPrivate: true,
      kind: "family",
    });
    const person = await ctx.store.createPerson({
      treeId: tree.id,
      creatorId: owner.userId,
      personData: {firstName: "Unbound", name: "UnboundPerson"},
    });

    // Direct DB hint — verify tree.semyaId is null/undefined
    const verifyTree = await ctx.store.findTree(tree.id);
    assert.ok(!verifyTree.semyaId, "tree unbound");

    // GET persons returns person — no filter applies
    const res = await fetch(
      `${ctx.baseUrl}/v1/trees/${tree.id}/persons`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.ok(body.persons.find((p) => p.id === person.id));
  } finally {
    await shutdown(ctx);
  }
});
