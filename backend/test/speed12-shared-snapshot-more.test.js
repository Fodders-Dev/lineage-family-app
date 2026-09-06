// SPEED-12 (docs/speed_measurement.md, раздел «SPEED-12»): распространяет
// readSharedSnapshot() (SPEED-11) на ещё восемь GET-путей поверх шести,
// уже переведённых SPEED-9 B/11 (persons/person/graph/gatherings/polls/
// stories). Метод и структура теста — как в speed9-b-single-read.test.js:
//
//   1. Идентичность на уровне стора: store-метод с prefetchedDb/db ===
//      без него (два независимых _read() одного и того же состояния на
//      FileStore).
//   2. Экономия: число _read() за реальный HTTP-запрос после фикса
//      меньше «наивной» до-фикса последовательности независимых вызовов.
//   3. Заморозка: readSharedSnapshot() отдаёт ЗАМОРОЖЕННЫЙ снимок — методы
//      должны принимать его без throw (это то, что реально ловит регресс:
//      до правки _writableCirclesViewForTree в этой же ветке listPosts
//      падал с "shared snapshot has no sessions" именно на frozen db,
//      а не на приватном _read()-клоне, который явно НЕ заморожен).

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-speed12-"));
  const dataPath = path.join(tempDir, "dev-db.json");
  const store = new FileStore(dataPath);
  await store.initialize();
  const realtimeHub = new RealtimeHub({store});
  const pushGateway = new PushGateway({store});

  // useSemyaModel читается один раз внутри createApp — включаем ДО
  // вызова, восстанавливаем сразу после (см. speed9-b-single-read.test.js).
  const prevFlag = process.env.RODNYA_FEDERATED_SEMYI_ENABLED;
  process.env.RODNYA_FEDERATED_SEMYI_ENABLED = "true";
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
  if (prevFlag === undefined) {
    delete process.env.RODNYA_FEDERATED_SEMYI_ENABLED;
  } else {
    process.env.RODNYA_FEDERATED_SEMYI_ENABLED = prevFlag;
  }

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

function authedGet(baseUrl, url, token) {
  return fetch(`${baseUrl}${url}`, {headers: {Authorization: `Bearer ${token}`}});
}

// Федеративная фикстура: дерево + семья + один person + один пост —
// достаточно для всех восьми маршрутов SPEED-12 (posts/search/graph/
// attributes/identity-suggestions используют то же дерево; onboarding-
// state/browse-token treeId-агностичны, но используют owner/tree тоже).
async function seedFixture(ctx, emailPrefix) {
  const owner = await makeUser(ctx.baseUrl, `${emailPrefix}-owner@example.com`);
  const tree = await ctx.store.createTree({
    creatorId: owner.userId,
    name: "Тест-дерево SPEED-12",
    description: "",
    isPrivate: true,
    kind: "family",
  });
  const semya = await ctx.store.createSemya({
    ownerId: owner.userId,
    name: "Семья SPEED-12",
    treeId: tree.id,
  });
  const person = await ctx.store.createPerson({
    treeId: tree.id,
    creatorId: owner.userId,
    personData: {firstName: "Пётр", lastName: "Снимков", gender: "male"},
  });
  const post = await ctx.store.createPost({
    treeId: tree.id,
    authorId: owner.userId,
    authorName: "Владелец",
    content: "Тестовый пост SPEED-12",
  });
  // graphPerson.id === identityId (см. owner-model-enforcement.test.js) —
  // резолвим через GET person, не руками, чтобы не зависеть от порядка
  // синка store.js:_syncPersonToGraph.
  const personRead = await authedGet(
    ctx.baseUrl,
    `/v1/trees/${tree.id}/persons/${person.id}`,
    owner.token,
  );
  assert.equal(personRead.status, 200);
  const graphPersonId = (await personRead.json()).person.identityId;
  assert.ok(graphPersonId, "person должен получить identityId при создании");

  return {owner, tree, semya, person, post, graphPersonId};
}

async function countReads(store, fn) {
  const original = store._read.bind(store);
  let count = 0;
  store._read = async (...args) => {
    count += 1;
    return original(...args);
  };
  try {
    const result = await fn();
    return {count, result};
  } finally {
    store._read = original;
  }
}

// Аналогично countReads, но считает вызовы readSharedSnapshot()
// отдельно от _read() — нужно там, где маршрут дёргает несколько
// ДРУГИХ, вне периметра SPEED-12, честных _read() (findTree/
// findSemyaById/touchBrowseTokenLastUsed на FileStore не scoped) —
// точный факт «этот конкретный путь теперь идёт через
// readSharedSnapshot(), а не через _read()» надёжнее проверять так,
// чем завязываться на суммарное число чтений остальных helper'ов.
async function countSharedSnapshotCalls(store, fn) {
  const original = store.readSharedSnapshot.bind(store);
  let count = 0;
  store.readSharedSnapshot = async (...args) => {
    count += 1;
    return original(...args);
  };
  try {
    const result = await fn();
    return {count, result};
  } finally {
    store.readSharedSnapshot = original;
  }
}

// ──────────────────────────────────────────────────────────────────
// 1. Идентичность на уровне стора: prefetchedDb (обычный _read()-клон)
//    === без него. Дублирует ту же гарантию, что и speed9-b/speed11
//    для методов, которых там не было.
// ──────────────────────────────────────────────────────────────────

test(
  "SPEED-12: store-методы с prefetchedDb возвращают результат, идентичный вызову без db",
  async () => {
    const ctx = await startTestServer();
    try {
      const {owner, tree, person, graphPersonId} = await seedFixture(
        ctx,
        "identity",
      );
      const db = await ctx.store._read();

      assert.deepEqual(
        await ctx.store.listPosts({treeId: tree.id, viewerUserId: owner.userId, db}),
        await ctx.store.listPosts({treeId: tree.id, viewerUserId: owner.userId}),
      );

      assert.deepEqual(
        await ctx.store.listUserTrees(owner.userId, db),
        await ctx.store.listUserTrees(owner.userId),
      );

      assert.deepEqual(
        await ctx.store.getOnboardingState({userId: owner.userId}),
        await ctx.store.getOnboardingState({userId: owner.userId}),
      );

      assert.deepEqual(
        await ctx.store.searchPersonsForUser({userId: owner.userId, query: "Пётр", db}),
        await ctx.store.searchPersonsForUser({userId: owner.userId, query: "Пётр"}),
      );

      assert.deepEqual(
        await ctx.store.findGraphPersonByLegacy(person.id, db),
        await ctx.store.findGraphPersonByLegacy(person.id),
      );

      assert.deepEqual(
        await ctx.store.findGraphPersonById(graphPersonId, db),
        await ctx.store.findGraphPersonById(graphPersonId),
      );

      assert.deepEqual(
        await ctx.store.findBloodRelation({
          fromGraphPersonId: graphPersonId,
          toGraphPersonId: graphPersonId,
          db,
        }),
        await ctx.store.findBloodRelation({
          fromGraphPersonId: graphPersonId,
          toGraphPersonId: graphPersonId,
        }),
      );

      assert.deepEqual(
        await ctx.store.previewGraphPersonsByIds([graphPersonId], {
          viewerUserId: owner.userId,
          db,
        }),
        await ctx.store.previewGraphPersonsByIds([graphPersonId], {
          viewerUserId: owner.userId,
        }),
      );

      assert.deepEqual(
        await ctx.store.listUserAuthIdentities(owner.userId),
        await ctx.store.listUserAuthIdentities(owner.userId),
      );

      assert.deepEqual(
        await ctx.store.listProfileContributions(owner.userId, {}),
        await ctx.store.listProfileContributions(owner.userId, {}),
      );
    } finally {
      await shutdown(ctx);
    }
  },
);

// ──────────────────────────────────────────────────────────────────
// 2. Заморозка: readSharedSnapshot() (реально ЗАМОРОЖЕННЫЙ снимок, не
//    просто «db-параметр передан») не ломает ни один из методов. Это
//    регресс-тест на баг _writableCirclesViewForTree ({...db} дёргала
//    throw-геттер db.sessions на frozen db) — воспроизводится ТОЛЬКО с
//    настоящим readSharedSnapshot(), не с обычным _read().
// ──────────────────────────────────────────────────────────────────

test(
  "SPEED-12: методы принимают readSharedSnapshot() (заморожен) без throw и дают тот же результат",
  async () => {
    const ctx = await startTestServer();
    try {
      const {owner, tree, graphPersonId} = await seedFixture(ctx, "frozen");
      const shared = await ctx.store.readSharedSnapshot();
      assert.ok(Object.isFrozen(shared), "readSharedSnapshot() должен быть заморожен");
      assert.throws(() => shared.sessions, /shared snapshot has no sessions/);

      const viaShared = await ctx.store.listPosts({
        treeId: tree.id,
        viewerUserId: owner.userId,
        db: shared,
      });
      const viaFresh = await ctx.store.listPosts({
        treeId: tree.id,
        viewerUserId: owner.userId,
      });
      assert.deepEqual(viaShared, viaFresh);
      assert.equal(viaShared.length, 1, "фикстура создаёт ровно один пост");

      // Остальные read-only методы SPEED-12 — тот же снимок, тот же
      // договор (не мутирует, не падает).
      assert.deepEqual(
        await ctx.store.searchPersonsForUser({userId: owner.userId, query: "Пётр", db: shared}),
        await ctx.store.searchPersonsForUser({userId: owner.userId, query: "Пётр"}),
      );
      assert.deepEqual(
        await ctx.store.findGraphPersonById(graphPersonId, shared),
        await ctx.store.findGraphPersonById(graphPersonId),
      );
      assert.deepEqual(
        await ctx.store.findBloodRelation({
          fromGraphPersonId: graphPersonId,
          toGraphPersonId: graphPersonId,
          db: shared,
        }),
        {chain: [graphPersonId], edges: [], label: "Это вы", degree: 0},
      );
    } finally {
      await shutdown(ctx);
    }
  },
);

// ──────────────────────────────────────────────────────────────────
// 3. Экономия _read() + идентичность HTTP-ответа на реальных маршрутах.
// ──────────────────────────────────────────────────────────────────

test("SPEED-12: GET /v1/posts — один readSharedSnapshot() вместо трёх независимых чтений", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree, post} = await seedFixture(ctx, "posts");
    const url = `/v1/posts?treeId=${tree.id}`;
    await authedGet(ctx.baseUrl, url, owner.token); // прогрев auth-кэша

    const after = await countReads(ctx.store, async () => {
      const res = await authedGet(ctx.baseUrl, url, owner.token);
      assert.equal(res.status, 200);
      return res.json();
    });
    assert.equal(after.result.length, 1);
    assert.equal(after.result[0].id, post.id);
    // findTree (requireTreeAccess, не scoped на FileStore) + 1 общий
    // снимок на listUserTrees/listPosts/listPostCommentsForPosts.
    assert.equal(after.count, 2, `ожидали 2 _read(), получили ${after.count}`);

    const before = await countReads(ctx.store, async () => {
      await ctx.store.findTree(tree.id);
      await ctx.store.listUserTrees(owner.userId);
      await ctx.store.listPosts({treeId: tree.id, viewerUserId: owner.userId});
      await ctx.store.listPostCommentsForPosts([post.id]);
    });
    assert.ok(after.count < before.count, `${after.count} vs ${before.count}`);
  } finally {
    await shutdown(ctx);
  }
});

test("SPEED-12: GET /v1/persons/search — один readSharedSnapshot() вместо двух", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, person} = await seedFixture(ctx, "search");
    const url = "/v1/persons/search?q=Пётр";
    await authedGet(ctx.baseUrl, url, owner.token);

    const after = await countReads(ctx.store, async () => {
      const res = await authedGet(ctx.baseUrl, url, owner.token);
      assert.equal(res.status, 200);
      return res.json();
    });
    assert.ok(after.result.persons.some((p) => p.id === person.id));
    assert.equal(after.count, 1, `ожидали 1 _read(), получили ${after.count}`);

    const before = await countReads(ctx.store, async () => {
      const found = await ctx.store.searchPersonsForUser({
        userId: owner.userId,
        query: "Пётр",
      });
      await ctx.store.filterLegacyPersonsByGraphVisibility(found, owner.userId);
    });
    assert.ok(after.count < before.count, `${after.count} vs ${before.count}`);
  } finally {
    await shutdown(ctx);
  }
});

test("SPEED-12: GET /v1/graph/relation — один readSharedSnapshot() вместо пяти", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, graphPersonId} = await seedFixture(ctx, "relation");
    const url = `/v1/graph/relation?from=${graphPersonId}&to=${graphPersonId}`;
    await authedGet(ctx.baseUrl, url, owner.token);

    const after = await countReads(ctx.store, async () => {
      const res = await authedGet(ctx.baseUrl, url, owner.token);
      assert.equal(res.status, 200);
      return res.json();
    });
    assert.equal(after.result.found, true);
    assert.equal(after.result.label, "Это вы");
    assert.equal(after.count, 1, `ожидали 1 _read(), получили ${after.count}`);

    const before = await countReads(ctx.store, async () => {
      await ctx.store.findGraphPersonById(graphPersonId);
      await ctx.store.findGraphPersonById(graphPersonId);
      await ctx.store.findBloodRelation({
        fromGraphPersonId: graphPersonId,
        toGraphPersonId: graphPersonId,
      });
      await ctx.store.previewGraphPersonsByIds([graphPersonId], {
        viewerUserId: owner.userId,
      });
    });
    assert.ok(after.count < before.count, `${after.count} vs ${before.count}`);
  } finally {
    await shutdown(ctx);
  }
});

test("SPEED-12: GET /v1/graph-persons/:id — один readSharedSnapshot() вместо двух", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, graphPersonId} = await seedFixture(ctx, "gpread");
    const url = `/v1/graph-persons/${graphPersonId}`;
    await authedGet(ctx.baseUrl, url, owner.token);

    const after = await countReads(ctx.store, async () => {
      const res = await authedGet(ctx.baseUrl, url, owner.token);
      assert.equal(res.status, 200);
      return res.json();
    });
    assert.equal(after.result.graphPerson.id, graphPersonId);
    assert.equal(after.count, 1, `ожидали 1 _read(), получили ${after.count}`);
  } finally {
    await shutdown(ctx);
  }
});

test(
  "SPEED-12: GET /v1/trees/:id/persons/:id/attributes — req.storeSnapshot вместо отдельного чтения",
  async () => {
    const ctx = await startTestServer();
    try {
      const {owner, tree, person} = await seedFixture(ctx, "attrs");
      const url = `/v1/trees/${tree.id}/persons/${person.id}/attributes`;
      await authedGet(ctx.baseUrl, url, owner.token);

      const after = await countReads(ctx.store, async () => {
        const res = await authedGet(ctx.baseUrl, url, owner.token);
        assert.equal(res.status, 200);
        return res.json();
      });
      assert.ok(Array.isArray(after.result.attributes));
      // findTree (requireTreeAccess, не scoped на FileStore — вне
      // периметра) + readSharedSnapshot() для membership+гейта +
      // listPersonAttributes (свой честный _read(), НЕ переведён —
      // материализует attribute-строки на frozen db он не может, см.
      // docs/speed_measurement.md SPEED-12) = 3. Было бы 4 (ещё и
      // findGraphPersonByLegacy своим отдельным _read()).
      assert.equal(after.count, 3, `ожидали 3 _read(), получили ${after.count}`);

      const before = await countReads(ctx.store, async () => {
        await ctx.store.findTree(tree.id);
        await ctx.store.findGraphPersonByLegacy(person.id);
        await ctx.store._read();
        await ctx.store.listPersonAttributes({treeId: tree.id, personId: person.id});
      });
      assert.ok(after.count < before.count, `${after.count} vs ${before.count}`);
    } finally {
      await shutdown(ctx);
    }
  },
);

test(
  "SPEED-12: GET .../identity-suggestions — переиспользует req.storeSnapshot от requireTreeAccess",
  async () => {
    const ctx = await startTestServer();
    try {
      const {owner, tree, person} = await seedFixture(ctx, "sugg");
      const url = `/v1/trees/${tree.id}/persons/${person.id}/identity-suggestions`;
      await authedGet(ctx.baseUrl, url, owner.token);

      const after = await countReads(ctx.store, async () => {
        const res = await authedGet(ctx.baseUrl, url, owner.token);
        assert.equal(res.status, 200);
        return res.json();
      });
      assert.deepEqual(after.result.suggestions, []); // единственное дерево — нечего предлагать
      // findTree (requireTreeAccess, не scoped на FileStore) +
      // readSharedSnapshot() для membership+findCrossTreeSuggestionsForPerson+
      // filterLegacyPersonsByGraphVisibility = 2. Было бы 3 (ещё один
      // отдельный _read() под сам SPEED-8d батч).
      assert.equal(after.count, 2, `ожидали 2 _read(), получили ${after.count}`);

      const before = await countReads(ctx.store, async () => {
        await ctx.store.findTree(tree.id);
        await ctx.store._read();
      });
      assert.ok(after.count <= before.count, `${after.count} vs ${before.count}`);
    } finally {
      await shutdown(ctx);
    }
  },
);

test("SPEED-12: GET /v1/me/onboarding-state — readSharedSnapshot()", async () => {
  const ctx = await startTestServer();
  try {
    const {owner} = await seedFixture(ctx, "onboard");
    const url = "/v1/me/onboarding-state";
    await authedGet(ctx.baseUrl, url, owner.token);

    const after = await countReads(ctx.store, async () => {
      const res = await authedGet(ctx.baseUrl, url, owner.token);
      assert.equal(res.status, 200);
      return res.json();
    });
    assert.ok(after.result.state);
    assert.equal(after.count, 1, `ожидали 1 _read(), получили ${after.count}`);
  } finally {
    await shutdown(ctx);
  }
});

test("SPEED-12: GET /v1/browse/:token (публичный, без auth) — readSharedSnapshot()", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree, semya, person} = await seedFixture(ctx, "browse");
    const token = await ctx.store.createBrowseToken({
      semyaId: semya.id,
      createdByUserId: owner.userId,
    });
    const url = `/v1/browse/${token.token}`;
    await fetch(`${ctx.baseUrl}${url}`);

    // Маршрут дёргает ещё findBrowseTokenByValue/findSemyaById/findTree/
    // touchBrowseTokenLastUsed — все не scoped на FileStore и вне
    // периметра SPEED-12 (их трогала бы отдельная задача). Проверяем
    // ИМЕННО то, что изменила эта задача: persons/relations теперь
    // читаются через readSharedSnapshot(), а не голый _read().
    const after = await countSharedSnapshotCalls(ctx.store, async () => {
      const res = await fetch(`${ctx.baseUrl}${url}`);
      assert.equal(res.status, 200);
      return res.json();
    });
    assert.ok(after.result.browse.persons.some((p) => p.id === person.id));
    assert.equal(after.result.browse.tree.id, tree.id);
    assert.equal(
      after.count,
      1,
      `ожидали 1 readSharedSnapshot(), получили ${after.count}`,
    );
  } finally {
    await shutdown(ctx);
  }
});
