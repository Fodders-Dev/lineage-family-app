// SPEED-11: readSharedSnapshot() — общий read-only снимок для GET-
// маршрутов бёрста входа (persons/person/graph/gatherings/polls/stories),
// который requireTreeAccess (app.js) кладёт на req.storeSnapshot и
// прокидывает store-методам как prefetchedDb/db (паттерн SPEED-9 B).
// На PostgresStore попадание в кэш version-строки отдаёт ОДИН И ТОТ ЖЕ
// глубоко замороженный объект без structuredClone (~480 КБ на прод-блобе)
// и без SQL сессий — механизм и цифры в docs/speed_measurement.md,
// раздел SPEED-11.
//
// Этот файл доказывает:
//   1. Попадание в кэш: 0 SELECT данных, 0 SELECT сессий, тот же объект
//      на повторные вызовы (без клона).
//   2. Single-flight на попадании: N параллельных readSharedSnapshot()
//      делят один SELECT version.
//   3. Single-flight на промахе: N параллельных промахов делят один
//      SELECT данных+version, и все видят одинаково свежие данные.
//   4. Снимок иммутабелен: db.sessions бросает явную ошибку, прямая
//      запись top-level поля отклоняется, push на вложенном массиве
//      бросает TypeError.
//   5. Идентичность: каждый из 8 store-методов, которые requireTreeAccess
//      реально кормит этим снимком (findMembership/listPersons/
//      findPerson/listHiddenPersonIdsForCaller/getTreeGraphSnapshot/
//      listGatherings/listPolls/listStories), даёт результат, побайтово
//      совпадающий с вызовом на честном клоне — заморозка не меняет
//      ответ.
//   6. listStories чистит просроченные истории через _mutate (не
//      db.stories=...+_write(db), который на замороженном db либо
//      бросил бы, либо тихо не сохранился бы) — ответ уже без
//      просроченной записи, а уборка видна следующему чтению.
//
// НЕ покрыто здесь намеренно: HTTP end-to-end через createApp +
// PostgresStore (requireTreeAccess → readSharedSnapshot() → 6 реальных
// GET-маршрутов). pg-mem не реализует jsonb_array_elements внутри LATERAL
// (findTree, вызываемый requireTreeAccess на КАЖДОМ tree-scoped запросе,
// падает на этом до того, как код SPEED-11 вообще получает управление) —
// pre-existing ограничение тестового движка, не SPEED-11 (тот же провал
// был бы у любого теста, кто попробует так же; см. похожие оговорки про
// pg-mem в .claude/rules/backend-store.md). Проверено экспериментально
// при написании этого файла — HTTP-тест на PostgresStore+pg-mem падает с
// `column "data" does not exist` внутри findTree ещё до входа в
// readSharedSnapshot(). Реальную wiring-цепочку requireTreeAccess → 6
// маршрутов (тот же код, что и на проде) покрывает
// speed9-b-single-read.test.js на FileStore — там readSharedSnapshot()
// вызывается по-настоящему (это единственный способ её вызвать в
// продакшен-коде), просто её FileStore-реализация — это _read()+freeze,
// без «настоящего» механизма кэша (single-flight/переиспользование
// объекта), который проверяют тесты 1-4 здесь на PostgresStore.

const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");

const {newDb} = require("pg-mem");
const {PostgresStore} = require("../src/postgres-store");
const {buildPersonRecord, createPersonIdentityRecord} = require("../src/store");

// PostgresStore.createPerson (без userId) UPDATEт строку через scoped SQL с
// EXISTS(SELECT 1 FROM jsonb_array_elements(...)) — pg-mem не реализует
// jsonb_array_elements внутри такого предиката (пишет об этом сам движок:
// "please note pg-mem implements very few native functions"). Это
// pre-existing ограничение pg-mem, не связанное со SPEED-11 (тот же гэп
// был бы и без единой строки этой задачи — postgres-store.test.js обходит
// его фейковым pool'ом вместо настоящего SQL). Заводим person напрямую
// через _mutate — тот же итоговый db.persons/db.personIdentities, но
// через обычный _write()-UPSERT (простой JSON.stringify), который pg-mem
// прекрасно понимает.
async function seedPerson(store, {treeId, creatorId, personData}) {
  return store._mutate((db) => {
    const person = buildPersonRecord({treeId, creatorId, personData, userId: null});
    const identity = createPersonIdentityRecord({personIds: [person.id]});
    person.identityId = identity.id;
    db.persons.push(person);
    db.personIdentities.push(identity);
    return person;
  });
}

function buildStore(seededState) {
  const memDb = newDb();
  const {Pool} = memDb.adapters.createPg();
  const rawPool = new Pool();
  const counters = {snapshotSelects: 0, versionSelects: 0, sessionSelects: 0};
  const pool = {
    counters,
    query: (sql, params) => {
      let effectiveParams = params;
      const text = String(sql);
      if (
        text.includes("ON CONFLICT (id) DO NOTHING") &&
        Array.isArray(params) &&
        params[0] === "default"
      ) {
        effectiveParams = [params[0], JSON.stringify(seededState)];
      }
      // "SELECT data, version FROM" и "SELECT version FROM" не являются
      // подстроками друг друга (между SELECT и version у первого стоит
      // "data, ") — считаем их раздельно, порядок проверки не важен.
      if (text.includes("SELECT data, version FROM")) {
        counters.snapshotSelects += 1;
      } else if (text.includes("SELECT version FROM")) {
        counters.versionSelects += 1;
      }
      if (text.includes("SELECT session_data")) {
        counters.sessionSelects += 1;
      }
      return rawPool.query(sql, effectiveParams);
    },
  };
  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
    snapshotCachePath: null,
  });
  return {store, pool, rawPool};
}

const SEED = {
  users: [],
  trees: [],
};

// Федеративная фикстура на голом сторе (без HTTP) — дерево + семья
// (владелец получает membership role="owner" автоматически внутри
// createSemya) + видимый person + скрытая для caller'а запись +
// gathering/poll/story, плюс одна ПРОСРОЧЕННАЯ история (expiresAt в
// прошлом — createStory не отклоняет прошедший expiresAt, эту проверку
// делает только HTTP-роут) для теста уборки в listStories.
async function seedFixture(store, prefix) {
  const owner = await store.createUser({
    email: `${prefix}-owner-${crypto.randomUUID()}@example.com`,
    password: "Test-Password-123!",
    displayName: "Владелец",
  });
  const tree = await store.createTree({
    creatorId: owner.id,
    name: "Тест-дерево",
    description: "",
    isPrivate: true,
    kind: "family",
  });
  const semya = await store.createSemya({
    ownerId: owner.id,
    name: "Семья",
    treeId: tree.id,
  });
  const person = await seedPerson(store, {
    treeId: tree.id,
    creatorId: owner.id,
    personData: {firstName: "Иван", lastName: "Тестов", gender: "male"},
  });
  const hiddenPerson = await seedPerson(store, {
    treeId: tree.id,
    creatorId: owner.id,
    personData: {firstName: "Скрытый", lastName: "Тестов", gender: "male"},
  });
  await store.addHidePerson({
    semyaId: semya.id,
    userId: owner.id,
    personId: hiddenPerson.id,
  });
  const gathering = await store.createGathering({
    treeId: tree.id,
    authorId: owner.id,
    authorName: "Владелец",
    title: "Событие",
    startAt: "2026-07-01T15:00:00.000Z",
  });
  const poll = await store.createPoll({
    treeId: tree.id,
    authorId: owner.id,
    authorName: "Владелец",
    question: "Вопрос?",
    options: ["Да", "Нет"],
  });
  const story = await store.createStory({
    treeId: tree.id,
    authorId: owner.id,
    authorName: "Владелец",
    type: "text",
    text: "Свежая история",
  });
  const expiredStory = await store.createStory({
    treeId: tree.id,
    authorId: owner.id,
    authorName: "Владелец",
    type: "text",
    text: "Просроченная история",
    expiresAt: new Date(Date.now() - 60_000).toISOString(),
  });
  return {
    owner,
    tree,
    semya,
    person,
    hiddenPerson,
    gathering,
    poll,
    story,
    expiredStory,
  };
}

// Как в speed9-b-single-read.test.js: getTreeGraphSnapshot нестабилен на
// updatedAt между двумя вызовами без мутации между ними (pre-existing,
// вне периметра SPEED-11/SPEED-9 B) — сравниваем без updatedAt/createdAt.
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

// ──────────────────────────────────────────────────────────────────
// 1-4. Механизм: попадание без клона/SQL, single-flight, иммутабельность.
// ──────────────────────────────────────────────────────────────────

test(
  "SPEED-11: readSharedSnapshot() на попадании — 0 SELECT данных, 0 SELECT сессий, тот же объект",
  async () => {
    const {store, pool} = buildStore(SEED);
    await store.initialize();
    await store.readSharedSnapshot(); // прогрев (после буста кэш уже тёплый)
    const before = {...pool.counters};

    const first = await store.readSharedSnapshot();
    const second = await store.readSharedSnapshot();

    assert.equal(
      pool.counters.snapshotSelects,
      before.snapshotSelects,
      "попадание не должно читать блоб",
    );
    assert.equal(
      pool.counters.sessionSelects,
      before.sessionSelects,
      "readSharedSnapshot никогда не читает сессии",
    );
    assert.ok(
      first === second,
      "оба попадания должны отдавать строго один и тот же объект — без клона",
    );
  },
);

test("SPEED-11: снимок и его коллекции глубоко заморожены", async () => {
  const {store} = buildStore(SEED);
  await store.initialize();
  const snapshot = await store.readSharedSnapshot();
  assert.ok(Object.isFrozen(snapshot), "снимок заморожен");
  assert.ok(Object.isFrozen(snapshot.persons), "вложенные массивы заморожены");
  assert.ok(Object.isFrozen(snapshot.trees), "вложенные массивы заморожены");
});

test(
  "SPEED-11: db.sessions на снимке бросает явную ошибку вместо тихой отдачи устаревших данных",
  async () => {
    const {store} = buildStore(SEED);
    await store.initialize();
    const snapshot = await store.readSharedSnapshot();
    assert.throws(() => snapshot.sessions, /shared snapshot has no sessions/);
  },
);

test(
  "SPEED-11: снимок доказуемо иммутабелен — top-level запись отклоняется, push бросает",
  async () => {
    const {store} = buildStore(SEED);
    await store.initialize();
    const snapshot = await store.readSharedSnapshot();
    assert.equal(
      Reflect.set(snapshot, "trees", []),
      false,
      "top-level свойство снимка нельзя переписать (mode-независимая проверка)",
    );
    assert.throws(
      () => snapshot.persons.push({id: "hack"}),
      TypeError,
      "push на замороженном массиве всегда бросает, независимо от strict mode",
    );
  },
);

test(
  "SPEED-11: конкурентный бёрст попаданий — один SELECT version на всех",
  async () => {
    const {store, pool} = buildStore(SEED);
    await store.initialize();
    await store.readSharedSnapshot();
    const before = pool.counters.versionSelects;

    const results = await Promise.all(
      Array.from({length: 10}, () => store.readSharedSnapshot()),
    );

    assert.equal(
      pool.counters.versionSelects - before,
      1,
      "10 параллельных попаданий должны схлопнуться в 1 SELECT version",
    );
    assert.ok(
      results.every((entry) => entry === results[0]),
      "все 10 параллельных вызовов должны получить один и тот же объект",
    );
  },
);

test(
  "SPEED-11: конкурентный бёрст промахов — один SELECT данных на всех, и все видят свежие данные",
  async () => {
    const {store, pool, rawPool} = buildStore(SEED);
    await store.initialize();
    await store.readSharedSnapshot();

    // Сторонняя запись мимо этого store-инстанса — как в
    // postgres-read-cache.test.js «сторонняя запись инвалидирует кэш».
    await rawPool.query(
      `UPDATE "public"."rodnya_state"
          SET data = $2::jsonb, version = version + 1
        WHERE id = $1`,
      [
        "default",
        JSON.stringify({
          ...SEED,
          users: [{id: "user-2", email: "x@y", profile: {displayName: "X"}}],
        }),
      ],
    );

    const before = pool.counters.snapshotSelects;
    const results = await Promise.all(
      Array.from({length: 8}, () => store.readSharedSnapshot()),
    );

    assert.equal(
      pool.counters.snapshotSelects - before,
      1,
      "8 параллельных промахов должны схлопнуться в 1 SELECT данных+version",
    );
    assert.ok(
      results.every((entry) => entry === results[0]),
      "все промахи должны сойтись на одном пересчитанном снимке",
    );
    assert.ok(
      results[0].users.some((u) => u.id === "user-2"),
      "промах обязан подтянуть данные сторонней записи, а не старый кэш",
    );
  },
);

// ──────────────────────────────────────────────────────────────────
// 5. Идентичность: снимок vs честный клон — для всех 8 store-методов,
//    которые requireTreeAccess реально кормит этим снимком.
// ──────────────────────────────────────────────────────────────────

test(
  "SPEED-11: 8 store-методов с замороженным снимком дают тот же результат, что с честным клоном",
  async () => {
    const {store} = buildStore(SEED);
    await store.initialize();
    const fixture = await seedFixture(store, "identity");
    const {owner, tree, semya, person} = fixture;

    const snapshot = await store.readSharedSnapshot();
    const clone = await store._read();

    // findMembership
    assertSameIgnoringVolatileTimestamps(
      await store.findMembership(semya.id, owner.id, snapshot),
      await store.findMembership(semya.id, owner.id, clone),
      "findMembership",
    );

    // listPersons
    assertSameIgnoringVolatileTimestamps(
      await store.listPersons(tree.id, snapshot),
      await store.listPersons(tree.id, clone),
      "listPersons",
    );

    // findPerson
    assertSameIgnoringVolatileTimestamps(
      await store.findPerson(tree.id, person.id, snapshot),
      await store.findPerson(tree.id, person.id, clone),
      "findPerson",
    );

    // listHiddenPersonIdsForCaller
    assertSameIgnoringVolatileTimestamps(
      await store.listHiddenPersonIdsForCaller(semya.id, owner.id, snapshot),
      await store.listHiddenPersonIdsForCaller(semya.id, owner.id, clone),
      "listHiddenPersonIdsForCaller",
    );

    // getTreeGraphSnapshot
    assertSameIgnoringVolatileTimestamps(
      await store.getTreeGraphSnapshot(tree.id, {
        viewerUserId: owner.id,
        db: snapshot,
      }),
      await store.getTreeGraphSnapshot(tree.id, {
        viewerUserId: owner.id,
        db: clone,
      }),
      "getTreeGraphSnapshot",
    );

    // listGatherings
    assertSameIgnoringVolatileTimestamps(
      await store.listGatherings({
        treeId: tree.id,
        viewerUserId: owner.id,
        db: snapshot,
      }),
      await store.listGatherings({
        treeId: tree.id,
        viewerUserId: owner.id,
        db: clone,
      }),
      "listGatherings",
    );

    // listPolls
    assertSameIgnoringVolatileTimestamps(
      await store.listPolls({treeId: tree.id, viewerUserId: owner.id, db: snapshot}),
      await store.listPolls({treeId: tree.id, viewerUserId: owner.id, db: clone}),
      "listPolls",
    );

    // listStories — обе стороны видят одинаково отфильтрованный (без
    // просроченной) список, замороженный db не мешает.
    assertSameIgnoringVolatileTimestamps(
      await store.listStories({treeId: tree.id, viewerUserId: owner.id, db: snapshot}),
      await store.listStories({treeId: tree.id, viewerUserId: owner.id, db: clone}),
      "listStories",
    );
  },
);

// ──────────────────────────────────────────────────────────────────
// 6. listStories: уборка просроченных историй через _mutate, а не
//    db.stories=...+_write(db) — не бросает на замороженном db, и
//    результат уборки виден следующему чтению.
// ──────────────────────────────────────────────────────────────────

test(
  "SPEED-11: listStories с замороженным db отфильтровывает просроченную историю и не бросает",
  async () => {
    const {store} = buildStore(SEED);
    await store.initialize();
    const {tree, owner, story, expiredStory} = await seedFixture(store, "cleanup");

    const snapshot = await store.readSharedSnapshot();
    const result = await store.listStories({
      treeId: tree.id,
      viewerUserId: owner.id,
      db: snapshot,
    });

    const ids = result.map((entry) => entry.id);
    assert.ok(ids.includes(story.id), "свежая история должна остаться в ответе");
    assert.ok(
      !ids.includes(expiredStory.id),
      "просроченная история не должна попасть в ответ",
    );
  },
);

test(
  "SPEED-11: уборка просроченных историй через _mutate видна следующему чтению",
  async () => {
    const {store} = buildStore(SEED);
    await store.initialize();
    const {tree, owner, expiredStory} = await seedFixture(store, "cleanup-persist");

    const snapshot = await store.readSharedSnapshot();
    await store.listStories({treeId: tree.id, viewerUserId: owner.id, db: snapshot});

    // Версия должна была измениться (_mutate — реальный UPSERT), так что
    // readSharedSnapshot() честно перечитывает, а не отдаёт старый кэш.
    const after = await store.readSharedSnapshot();
    assert.ok(
      !after.stories.some((entry) => entry.id === expiredStory.id),
      "просроченная история должна реально исчезнуть из персистентного состояния, не только из ответа",
    );
  },
);

