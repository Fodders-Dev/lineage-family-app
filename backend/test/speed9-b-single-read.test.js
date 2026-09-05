// SPEED-9 B: один _read() на HTTP-запрос для горячих путей чтения
// (docs/speed9_proposal.md §4, §6.2 — «Вариант B»; docs/speed_measurement.md,
// раздел «SPEED-9 B»).
//
// На федеративном дереве (tree.semyaId set — прод-default,
// RODNYA_FEDERATED_SEMYI_ENABLED=true) requireTreeAccess (app.js) сам
// читает блоб внутри findMembership (не переопределён в PostgresStore —
// см. анализ). До фикса каждый store-метод ниже по цепочке
// (listPersons/findPerson/getTreeGraphSnapshot/listGatherings/listPolls/
// listStories/listHiddenPersonIdsForCaller) читал блоб СНОВА. После
// фикса requireTreeAccess кладёт уже прочитанный снимок на
// req.storeSnapshot, а обработчик передаёт его этим методам через
// новый опциональный параметр db.
//
// Этот файл доказывает две вещи для каждого из шести маршрутов бёрста
// входа:
//   1. Идентичность: store-метод, вызванный С прочитанным заранее db,
//      возвращает результат, побайтово (deepEqual) совпадающий с тем
//      же методом, вызванным БЕЗ db (собственный свежий _read()) — на
//      FileStore каждый _read() — независимый JSON.parse, так что это
//      реальное сравнение двух независимых чтений одного и того же
//      неизменного состояния, а не сравнение объекта с самим собой.
//   2. Экономия: число _read() за реальный HTTP-запрос (после фикса)
//      меньше, чем у «наивной» до-фикса последовательности вызовов
//      (findTree → findMembership без db → listX без db) — числа
//      подтверждены прогоном (see docs/speed_measurement.md, SPEED-9 B):
//      persons 4→2, person-detail 3→2, graph 3→2, gatherings/polls/
//      stories 4→3 (разница меньше, чем для persons/detail/graph,
//      потому что listUserTrees на FileStore тоже делает собственный
//      _read() — эта функция вне периметра задачи, на PostgresStore она
//      уже scoped SQL, там разница ровно 2→1, как и у остальных).

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-speed9b-"));
  const dataPath = path.join(tempDir, "dev-db.json");
  const store = new FileStore(dataPath);
  await store.initialize();
  const realtimeHub = new RealtimeHub({store});
  const pushGateway = new PushGateway({store});

  // useSemyaModel читается один раз внутри createApp — включаем ДО
  // вызова, восстанавливаем сразу после (как semya-tree-binding.test.js).
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

// Федеративная фикстура: дерево + семья (владелец получает
// membership с role="owner" автоматически внутри createSemya) + один
// person + одна скрытая (для caller'а) запись + gathering/poll/story,
// чтобы у каждого из шести маршрутов было что вернуть.
async function seedFederatedFixture(ctx, emailPrefix) {
  const owner = await makeUser(ctx.baseUrl, `${emailPrefix}-owner@example.com`);
  const tree = await ctx.store.createTree({
    creatorId: owner.userId,
    name: "Тест-дерево",
    description: "",
    isPrivate: true,
    kind: "family",
  });
  const semya = await ctx.store.createSemya({
    ownerId: owner.userId,
    name: "Семья",
    treeId: tree.id,
  });
  const person = await ctx.store.createPerson({
    treeId: tree.id,
    creatorId: owner.userId,
    personData: {firstName: "Иван", lastName: "Тестов", gender: "male"},
  });
  const hiddenPerson = await ctx.store.createPerson({
    treeId: tree.id,
    creatorId: owner.userId,
    personData: {firstName: "Скрытый", lastName: "Тестов", gender: "male"},
  });
  await ctx.store.addHidePerson({
    semyaId: semya.id,
    userId: owner.userId,
    personId: hiddenPerson.id,
  });

  const gathering = await ctx.store.createGathering({
    treeId: tree.id,
    authorId: owner.userId,
    authorName: "Владелец",
    title: "Событие",
    startAt: "2026-07-01T15:00:00.000Z",
  });
  const poll = await ctx.store.createPoll({
    treeId: tree.id,
    authorId: owner.userId,
    authorName: "Владелец",
    question: "Вопрос?",
    options: ["Да", "Нет"],
  });
  const story = await ctx.store.createStory({
    treeId: tree.id,
    authorId: owner.userId,
    authorName: "Владелец",
    type: "text",
    text: "Текст истории",
  });

  return {owner, tree, semya, person, hiddenPerson, gathering, poll, story};
}

// Pre-existing (не связанное с SPEED-9 B) обнаружение: у дерева с
// 2+ persons без связей между ними GET /v1/trees/:id/graph
// пересобирает `people[].updatedAt` заново на каждый вызов, и это
// пересобранное значение иногда «дрожит» на несколько миллисекунд
// между двумя ПОДРЯД идущими вызовами БЕЗ прокидывания db вообще
// (подтверждено: воспроизводится и без единой строки из SPEED-9 B,
// см. probe_graph_diff4.js в scratch-каталоге агента — не входит в
// репозиторий). Природа не установлена (не nowIso() в billboard-коде
// buildTreeGraphSnapshot/buildFamilyUnits/resolveBranchBlocks — там
// нет таймстемпов вообще), чинить в рамках SPEED-9 B не входит в
// периметр задачи (не трогать _syncGraphFromLegacy/graph-слой сверх
// уже сделанного в SPEED-9 A). Чтобы тест на идентичность результата
// не был flaky по этой посторонней причине, сравниваем без
// `updatedAt`/`createdAt` — токовый facts (id/name/relations/
// familyUnits/branchBlocks/warnings) сравниваются побайтово.
function stripVolatileTimestamps(value) {
  if (Array.isArray(value)) {
    return value.map(stripVolatileTimestamps);
  }
  if (value && typeof value === "object") {
    const clone = {};
    for (const [key, val] of Object.entries(value)) {
      if (key === "updatedAt" || key === "createdAt") continue;
      clone[key] = stripVolatileTimestamps(val);
    }
    return clone;
  }
  return value;
}

function assertSameIgnoringVolatileTimestamps(actual, expected, message) {
  assert.deepEqual(
    stripVolatileTimestamps(actual),
    stripVolatileTimestamps(expected),
    message,
  );
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

// ──────────────────────────────────────────────────────────────────
// 1. Идентичность на уровне стора: с prefetchedDb === без него.
// ──────────────────────────────────────────────────────────────────

test(
  "SPEED-9 B: store-методы с prefetchedDb возвращают результат, идентичный вызову без db",
  async () => {
    const ctx = await startTestServer();
    try {
      const {owner, tree, semya, person} = await seedFederatedFixture(
        ctx,
        "identity",
      );
      const db = await ctx.store._read();

      // findMembership
      assertSameIgnoringVolatileTimestamps(
        await ctx.store.findMembership(semya.id, owner.userId, db),
        await ctx.store.findMembership(semya.id, owner.userId),
      );

      // listPersons
      assertSameIgnoringVolatileTimestamps(
        await ctx.store.listPersons(tree.id, db),
        await ctx.store.listPersons(tree.id),
      );

      // findPerson
      assertSameIgnoringVolatileTimestamps(
        await ctx.store.findPerson(tree.id, person.id, db),
        await ctx.store.findPerson(tree.id, person.id),
      );

      // listHiddenPersonIdsForCaller
      assertSameIgnoringVolatileTimestamps(
        await ctx.store.listHiddenPersonIdsForCaller(semya.id, owner.userId, db),
        await ctx.store.listHiddenPersonIdsForCaller(semya.id, owner.userId),
      );

      // getTreeGraphSnapshot
      assertSameIgnoringVolatileTimestamps(
        await ctx.store.getTreeGraphSnapshot(tree.id, {
          viewerUserId: owner.userId,
          db,
        }),
        await ctx.store.getTreeGraphSnapshot(tree.id, {
          viewerUserId: owner.userId,
        }),
      );

      // listGatherings
      assertSameIgnoringVolatileTimestamps(
        await ctx.store.listGatherings({
          treeId: tree.id,
          viewerUserId: owner.userId,
          db,
        }),
        await ctx.store.listGatherings({
          treeId: tree.id,
          viewerUserId: owner.userId,
        }),
      );

      // listPolls
      assertSameIgnoringVolatileTimestamps(
        await ctx.store.listPolls({
          treeId: tree.id,
          viewerUserId: owner.userId,
          db,
        }),
        await ctx.store.listPolls({treeId: tree.id, viewerUserId: owner.userId}),
      );

      // listStories
      assertSameIgnoringVolatileTimestamps(
        await ctx.store.listStories({
          treeId: tree.id,
          viewerUserId: owner.userId,
          db,
        }),
        await ctx.store.listStories({
          treeId: tree.id,
          viewerUserId: owner.userId,
        }),
      );
    } finally {
      await shutdown(ctx);
    }
  },
);

// ──────────────────────────────────────────────────────────────────
// 2. Экономия _read() + идентичность HTTP-ответа на реальных
//    маршрутах бёрста входа (федеративное дерево).
// ──────────────────────────────────────────────────────────────────

function authedGet(baseUrl, url, token) {
  return fetch(`${baseUrl}${url}`, {headers: {Authorization: `Bearer ${token}`}});
}

test(
  "SPEED-9 B: GET /v1/trees/:id/persons — 1 _read() вместо 2-3 (федеративное дерево)",
  async () => {
    const ctx = await startTestServer();
    try {
      const {owner, tree, person} = await seedFederatedFixture(ctx, "persons");
      const url = `/v1/trees/${tree.id}/persons`;

      // Прогрев auth-кэша (findSession/findUserById), чтобы разница в
      // readCalls объяснялась ТОЛЬКО этим маршрутом.
      await authedGet(ctx.baseUrl, url, owner.token);

      const after = await countReads(ctx.store, async () => {
        const res = await authedGet(ctx.baseUrl, url, owner.token);
        assert.equal(res.status, 200);
        return res.json();
      });

      // Скрытый person не должен попасть в ответ — фильтр по
      // семейному hide-list продолжает работать со снимком requireTreeAccess.
      const ids = after.result.persons.map((p) => p.id);
      assert.ok(ids.includes(person.id));

      // after.count = findTree (собственный _read(), не тронут этой
      // задачей) + 1 общий снимок requireTreeAccess. Было бы 4 (findTree +
      // findMembership + listPersons + listHiddenPersonIdsForCaller),
      // каждый со своим _read().
      assert.equal(after.count, 2, `ожидали 2 _read(), получили ${after.count}`);

      const before = await countReads(ctx.store, async () => {
        await ctx.store.findTree(tree.id);
        const membership = await ctx.store.findMembership(
          (await ctx.store.findTree(tree.id)).semyaId,
          owner.userId,
        );
        assert.ok(membership);
        await ctx.store.listPersons(tree.id);
        await ctx.store.listHiddenPersonIdsForCaller(
          (await ctx.store.findTree(tree.id)).semyaId,
          owner.userId,
        );
      });
      assert.ok(
        after.count < before.count,
        `после фикса должно быть меньше _read(), чем в наивной последовательности: ${after.count} vs ${before.count}`,
      );
    } finally {
      await shutdown(ctx);
    }
  },
);

test(
  "SPEED-9 B: GET /v1/trees/:id/persons/:personId — 1 _read() вместо 2 (федеративное дерево)",
  async () => {
    const ctx = await startTestServer();
    try {
      const {owner, tree, person} = await seedFederatedFixture(ctx, "person-detail");
      const url = `/v1/trees/${tree.id}/persons/${person.id}`;
      await authedGet(ctx.baseUrl, url, owner.token);

      const after = await countReads(ctx.store, async () => {
        const res = await authedGet(ctx.baseUrl, url, owner.token);
        assert.equal(res.status, 200);
        return res.json();
      });
      assert.equal(after.result.person.id, person.id);
      assert.equal(after.count, 2, `ожидали 2 _read(), получили ${after.count}`);

      const before = await countReads(ctx.store, async () => {
        const tr = await ctx.store.findTree(tree.id);
        await ctx.store.findMembership(tr.semyaId, owner.userId);
        await ctx.store.findPerson(tree.id, person.id);
      });
      assert.ok(after.count < before.count, `${after.count} vs ${before.count}`);
    } finally {
      await shutdown(ctx);
    }
  },
);

test(
  "SPEED-9 B: GET /v1/trees/:id/graph — 1 _read() вместо 2 (федеративное дерево)",
  async () => {
    const ctx = await startTestServer();
    try {
      const {owner, tree} = await seedFederatedFixture(ctx, "graph");
      const url = `/v1/trees/${tree.id}/graph`;
      await authedGet(ctx.baseUrl, url, owner.token);

      const after = await countReads(ctx.store, async () => {
        const res = await authedGet(ctx.baseUrl, url, owner.token);
        assert.equal(res.status, 200);
        return res.json();
      });
      assert.ok(after.result.snapshot);
      assert.equal(after.count, 2, `ожидали 2 _read(), получили ${after.count}`);

      const before = await countReads(ctx.store, async () => {
        const tr = await ctx.store.findTree(tree.id);
        await ctx.store.findMembership(tr.semyaId, owner.userId);
        await ctx.store.getTreeGraphSnapshot(tree.id, {viewerUserId: owner.userId});
      });
      assert.ok(after.count < before.count, `${after.count} vs ${before.count}`);
    } finally {
      await shutdown(ctx);
    }
  },
);

test(
  "SPEED-9 B: GET /v1/gatherings?treeId= — не растёт лишним _read() поверх listUserTrees (федеративное дерево)",
  async () => {
    const ctx = await startTestServer();
    try {
      const {owner, tree, gathering} = await seedFederatedFixture(ctx, "gatherings");
      const url = `/v1/gatherings?treeId=${tree.id}`;
      await authedGet(ctx.baseUrl, url, owner.token);

      const after = await countReads(ctx.store, async () => {
        const res = await authedGet(ctx.baseUrl, url, owner.token);
        assert.equal(res.status, 200);
        return res.json();
      });
      assert.ok(after.result.some((g) => g.id === gathering.id));
      // 3 = findTree (не тронут) + 1 общий снимок requireTreeAccess +
      // listUserTrees (FileStore-only, не overridden; на PostgresStore
      // scoped SQL = 0, там было бы ровно 2). listGatherings переиспользует
      // снимок — 0 дополнительных _read().
      assert.equal(after.count, 3, `ожидали 3 _read(), получили ${after.count}`);

      const before = await countReads(ctx.store, async () => {
        const tr = await ctx.store.findTree(tree.id);
        await ctx.store.findMembership(tr.semyaId, owner.userId);
        await ctx.store.listUserTrees(owner.userId);
        await ctx.store.listGatherings({treeId: tree.id, viewerUserId: owner.userId});
      });
      assert.ok(after.count < before.count, `${after.count} vs ${before.count}`);
    } finally {
      await shutdown(ctx);
    }
  },
);

test(
  "SPEED-9 B: GET /v1/polls?treeId= — не растёт лишним _read() поверх listUserTrees (федеративное дерево)",
  async () => {
    const ctx = await startTestServer();
    try {
      const {owner, tree, poll} = await seedFederatedFixture(ctx, "polls");
      const url = `/v1/polls?treeId=${tree.id}`;
      await authedGet(ctx.baseUrl, url, owner.token);

      const after = await countReads(ctx.store, async () => {
        const res = await authedGet(ctx.baseUrl, url, owner.token);
        assert.equal(res.status, 200);
        return res.json();
      });
      assert.ok(after.result.some((p) => p.id === poll.id));
      assert.equal(after.count, 3, `ожидали 3 _read(), получили ${after.count}`);

      const before = await countReads(ctx.store, async () => {
        const tr = await ctx.store.findTree(tree.id);
        await ctx.store.findMembership(tr.semyaId, owner.userId);
        await ctx.store.listUserTrees(owner.userId);
        await ctx.store.listPolls({treeId: tree.id, viewerUserId: owner.userId});
      });
      assert.ok(after.count < before.count, `${after.count} vs ${before.count}`);
    } finally {
      await shutdown(ctx);
    }
  },
);

test(
  "SPEED-9 B: GET /v1/stories?treeId= — не растёт лишним _read() поверх listUserTrees (федеративное дерево)",
  async () => {
    const ctx = await startTestServer();
    try {
      const {owner, tree, story} = await seedFederatedFixture(ctx, "stories");
      const url = `/v1/stories?treeId=${tree.id}`;
      await authedGet(ctx.baseUrl, url, owner.token);

      const after = await countReads(ctx.store, async () => {
        const res = await authedGet(ctx.baseUrl, url, owner.token);
        assert.equal(res.status, 200);
        return res.json();
      });
      assert.ok(after.result.some((s) => s.id === story.id));
      assert.equal(after.count, 3, `ожидали 3 _read(), получили ${after.count}`);

      const before = await countReads(ctx.store, async () => {
        const tr = await ctx.store.findTree(tree.id);
        await ctx.store.findMembership(tr.semyaId, owner.userId);
        await ctx.store.listUserTrees(owner.userId);
        await ctx.store.listStories({treeId: tree.id, viewerUserId: owner.userId});
      });
      assert.ok(after.count < before.count, `${after.count} vs ${before.count}`);
    } finally {
      await shutdown(ctx);
    }
  },
);

// ──────────────────────────────────────────────────────────────────
// 3. req.storeSnapshot реально переиспользуется (не просто совпадение
//    счётчика) — тот же объект приходит и в findMembership, и в
//    listPersons/listHiddenPersonIdsForCaller за один HTTP-запрос.
// ──────────────────────────────────────────────────────────────────

test(
  "SPEED-9 B: requireTreeAccess и listPersons/listHiddenPersonIdsForCaller получают ОДИН И ТОТ ЖЕ объект db за один запрос",
  async () => {
    const ctx = await startTestServer();
    try {
      const {owner, tree} = await seedFederatedFixture(ctx, "snapshot-identity");

      const seenDbs = [];
      const originalFindMembership = ctx.store.findMembership.bind(ctx.store);
      const originalListPersons = ctx.store.listPersons.bind(ctx.store);
      const originalListHidden = ctx.store.listHiddenPersonIdsForCaller.bind(
        ctx.store,
      );
      ctx.store.findMembership = async (semyaId, userId, db) => {
        seenDbs.push(db);
        return originalFindMembership(semyaId, userId, db);
      };
      ctx.store.listPersons = async (treeId, db) => {
        seenDbs.push(db);
        return originalListPersons(treeId, db);
      };
      ctx.store.listHiddenPersonIdsForCaller = async (semyaId, userId, db) => {
        seenDbs.push(db);
        return originalListHidden(semyaId, userId, db);
      };

      try {
        const res = await authedGet(
          ctx.baseUrl,
          `/v1/trees/${tree.id}/persons`,
          owner.token,
        );
        assert.equal(res.status, 200);
      } finally {
        ctx.store.findMembership = originalFindMembership;
        ctx.store.listPersons = originalListPersons;
        ctx.store.listHiddenPersonIdsForCaller = originalListHidden;
      }

      assert.equal(seenDbs.length, 3, "все три метода должны быть вызваны");
      assert.ok(
        seenDbs.every((db) => db != null),
        "ни один вызов не должен получить пустой db — снимок requireTreeAccess должен дойти до каждого",
      );
      assert.ok(
        seenDbs[0] === seenDbs[1] && seenDbs[1] === seenDbs[2],
        "findMembership, listPersons и listHiddenPersonIdsForCaller должны получить строго один и тот же объект db",
      );
    } finally {
      await shutdown(ctx);
    }
  },
);

// ──────────────────────────────────────────────────────────────────
// 4. Обратная совместимость: не-федеративный путь (флаг выключен) не
//    трогает req.storeSnapshot вообще — существующие вызовы без db
//    ведут себя как раньше.
// ──────────────────────────────────────────────────────────────────

test(
  "SPEED-9 B: не-федеративное дерево (флаг выключен) — requireTreeAccess не читает блоб и не трогает req.storeSnapshot",
  async () => {
    const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-speed9b-legacy-"));
    const dataPath = path.join(tempDir, "dev-db.json");
    const store = new FileStore(dataPath);
    await store.initialize();
    const realtimeHub = new RealtimeHub({store});
    const pushGateway = new PushGateway({store});
    delete process.env.RODNYA_FEDERATED_SEMYI_ENABLED;
    const app = createApp({
      store,
      config: {corsOrigin: "*", dataPath, mediaRootPath: path.join(tempDir, "uploads")},
      realtimeHub,
      pushGateway,
    });
    const server = await new Promise((resolve) => {
      const instance = app.listen(0, "127.0.0.1", () => resolve(instance));
    });
    realtimeHub.attach(server);
    const baseUrl = `http://127.0.0.1:${server.address().port}`;
    try {
      const owner = await makeUser(baseUrl, "legacy-owner@example.com");
      const tree = await store.createTree({
        creatorId: owner.userId,
        name: "Легаси-дерево",
        description: "",
        isPrivate: true,
        kind: "family",
      });
      // tree.semyaId остаётся null — legacy creator+memberIds gate.
      const person = await store.createPerson({
        treeId: tree.id,
        creatorId: owner.userId,
        personData: {firstName: "Пётр", lastName: "Легаси", gender: "male"},
      });

      const res = await authedGet(baseUrl, `/v1/trees/${tree.id}/persons`, owner.token);
      assert.equal(res.status, 200);
      const body = await res.json();
      assert.ok(body.persons.some((p) => p.id === person.id));
    } finally {
      await new Promise((resolve) => server.close(resolve));
      await fs.rm(tempDir, {recursive: true, force: true}).catch(() => {});
    }
  },
);
