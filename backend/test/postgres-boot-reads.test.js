// SPEED-9 C-boot: _bootstrap() читает строку состояния ОДИН раз и
// прокидывает разобранное {state, version} через backfill/миграции вместо
// того, чтобы каждый шаг делал свой SELECT data FROM + normalizeDbState
// (было ≥5 полных чтений+парсингов блоба на каждый рестарт процесса — см.
// docs/speed9_proposal.md §5). Харнесс — как в postgres-read-cache.test.js
// (buildStore на pg-mem, счётчик поверх pool.query); гочи pg-mem — см.
// docs/speed_measurement.md (разделы SPEED-6/7/8a): partial-индексы и
// LATERAL jsonb_array_elements внутри cross-join не работают на pg-mem,
// поэтому _hydrateAuthProjectionTablesFromStateRow здесь ВСЕГДА уходит в
// свой fallback-путь — это ортогонально тому, что мы проверяем.
const test = require("node:test");
const assert = require("node:assert/strict");

const {newDb} = require("pg-mem");
const {PostgresStore} = require("../src/postgres-store");

// Считаем ЛЮБОЙ полный SELECT блоба — оба литерала, которые встречаются в
// коде ("SELECT data FROM ..." у бут-шагов и "SELECT data, version FROM
// ..." у _read()/_loadSnapshot()) — но не "SELECT version FROM" (дешёвая
// проверка версии без блоба, её остаётся сколько угодно).
const BLOB_SELECT_RE = /^SELECT data(,\s*version)?\s+FROM/;

function buildCountingStore(seededState) {
  const memDb = newDb();
  const {Pool} = memDb.adapters.createPg();
  const rawPool = new Pool();
  const counters = {blobSelects: 0};
  const pool = {
    counters,
    query: (sql, params) => {
      const text = String(sql).replace(/\s+/g, " ").trim();
      let effectiveParams = params;
      if (
        text.includes("ON CONFLICT (id) DO NOTHING") &&
        Array.isArray(params) &&
        params[0] === "default"
      ) {
        effectiveParams = [params[0], JSON.stringify(seededState)];
      }
      if (BLOB_SELECT_RE.test(text)) {
        counters.blobSelects += 1;
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

async function readRowVersion(rawPool) {
  const result = await rawPool.query(
    'SELECT version FROM "public"."rodnya_state" WHERE id = $1',
    ["default"],
  );
  return Number(result.rows[0].version);
}

const MIGRATED_MARKERS = {
  chatCollectionsToTables: "complete-v1",
  notificationsToTables: "complete-v1",
  treeChangeRecordsToTables: "complete-v1",
};

test("SPEED-9 C-boot: уже мигрированное состояние — ровно 1 SELECT блоба за initialize()", async () => {
  const seed = {
    users: [{id: "user-1", email: "ivan@rodnya-tree.ru", profile: {displayName: "Иван"}}],
    trees: [],
    // persons/personIdentities уже согласованы — backfill тоже no-op.
    persons: [{id: "p1", treeId: "t1", identityId: "id-1"}],
    personIdentities: [{id: "id-1", userId: null, personIds: ["p1"]}],
    migrationStatus: {...MIGRATED_MARKERS},
  };
  const {store, pool, rawPool} = buildCountingStore(seed);

  await store.initialize();
  assert.equal(
    pool.counters.blobSelects,
    1,
    "на уже мигрированном состоянии бут должен читать блоб ровно один раз",
  );

  const rowVersion = await readRowVersion(rawPool);
  assert.equal(
    store._cachedVersion,
    rowVersion,
    "кэш после буста должен быть подтверждён версией строки (иначе первый _read() промахнётся)",
  );
  assert.ok(store._cachedState, "_cachedState должен быть заполнен после буста");

  // Прогретый кэш должен пережить fallback auth-hydrate (pg-mem не умеет
  // LATERAL jsonb_array_elements в этом cross-join — см. заголовок файла).
  const authUsers = await rawPool.query(
    'SELECT id FROM "public"."rodnya_state_auth_users"',
  );
  assert.deepEqual(authUsers.rows.map((row) => row.id), ["user-1"]);

  pool.counters.blobSelects = 0;
  const state = await store._read();
  assert.equal(
    pool.counters.blobSelects,
    0,
    "первый настоящий _read() после буста должен попасть в кэш — 0 SQL-чтений блоба",
  );
  assert.equal(state.users[0].id, "user-1");
  assert.equal(state.persons[0].identityId, "id-1");
});

test("SPEED-9 C-boot: легаси-состояние без миграций — миграции выполняются с ровно 1 SELECT блоба", async () => {
  const seed = {
    users: [{id: "user-1", email: "ivan@rodnya-tree.ru"}],
    trees: [],
    chats: [
      {
        id: "chat_group-1",
        type: "group",
        title: "Семья",
        participantIds: ["user-1"],
      },
    ],
    messages: [
      {
        id: "m1",
        chatId: "chat_group-1",
        senderId: "user-1",
        text: "Привет",
        clientMessageId: "cli-1",
        createdAt: "2026-04-21T10:00:00.000Z",
      },
    ],
    notifications: [
      {
        id: "n1",
        userId: "user-1",
        type: "generic",
        title: "Заголовок",
        body: "Текст",
        createdAt: "2026-04-21T10:00:00.000Z",
      },
    ],
    // migrationStatus отсутствует целиком — все три миграции обязаны
    // реально отработать (не no-op), а не просто прочитать маркер.
  };
  const {store, pool, rawPool} = buildCountingStore(seed);

  await store.initialize();
  assert.equal(
    pool.counters.blobSelects,
    1,
    "даже когда все три миграции реально выполняются, блоб читается один раз — остальные шаги используют прокинутое состояние",
  );

  // Итоговые таблицы/маркеры/проекция — как до SPEED-9 C-boot (проверено
  // exhaustively в postgres-chat-tables/-notification-tables/-tree-change-
  // tables.test.js, которые остались зелёными без правок; здесь — smoke).
  const finalState = await store._read();
  assert.equal(finalState.migrationStatus.chatCollectionsToTables, "complete-v1");
  assert.equal(finalState.migrationStatus.notificationsToTables, "complete-v1");
  assert.equal(finalState.migrationStatus.treeChangeRecordsToTables, "complete-v1");
  assert.deepEqual(finalState.messages, []);
  assert.deepEqual(finalState.notifications, []);

  const chatMessages = await rawPool.query(
    'SELECT id FROM "public"."rodnya_state_chat_messages"',
  );
  assert.deepEqual(chatMessages.rows.map((row) => row.id), ["m1"]);

  const notificationRows = await rawPool.query(
    'SELECT id FROM "public"."rodnya_state_notifications"',
  );
  assert.deepEqual(notificationRows.rows.map((row) => row.id), ["n1"]);

  const chatProjection = await rawPool.query(
    'SELECT id FROM "public"."rodnya_state_chats_projection"',
  );
  assert.deepEqual(chatProjection.rows.map((row) => row.id), ["chat_group-1"]);
});

test("SPEED-9 C-boot: backfill меняет persons — следующие шаги видят записанное, не устаревшее", async () => {
  const seed = {
    users: [{id: "user-1", email: "ivan@rodnya-tree.ru"}],
    trees: [{id: "t1", name: "Наше дерево"}],
    // persons без identityId — backfill обязан его проставить (changed=true).
    persons: [{id: "p1", treeId: "t1", name: "Иван"}],
    personIdentities: [],
    // Остальные миграции — no-op, чтобы изолировать эффект backfill.
    migrationStatus: {...MIGRATED_MARKERS},
  };
  const {store, pool, rawPool} = buildCountingStore(seed);

  await store.initialize();
  assert.equal(
    pool.counters.blobSelects,
    1,
    "backfill написал строку — но это не должно стоить ЕЩЁ одного чтения кому-то ниже по цепочке",
  );

  assert.ok(
    store._cachedState.persons[0].identityId,
    "backfill обязан проставить identityId в состоянии, прокинутом дальше",
  );
  assert.equal(store._cachedState.personIdentities.length, 1);

  // Свежесть подтверждена НЕ только в памяти (_cachedState), но и в самой
  // строке БД — а _cachedVersion обязан совпадать с версией ПОСЛЕ этой
  // записи (RETURNING version с UPDATE backfill'а), не с версией ДО неё.
  const row = await rawPool.query(
    'SELECT data, version FROM "public"."rodnya_state" WHERE id = $1',
    ["default"],
  );
  assert.ok(
    row.rows[0].data.persons[0].identityId,
    "identityId обязан быть записан в саму строку, не только в in-memory кэш",
  );
  assert.equal(Number(row.rows[0].version), store._cachedVersion);

  // Раз кэш подтверждён версией строки — первый настоящий _read() читает
  // из кэша, а не заново промахивается.
  pool.counters.blobSelects = 0;
  const state = await store._read();
  assert.equal(pool.counters.blobSelects, 0);
  assert.equal(state.persons[0].identityId, store._cachedState.personIdentities[0].id);
});

test("SPEED-9 C-boot: общий снимок недоступен на старте — деградация к прежнему поведению (каждый шаг сам читает)", async () => {
  const seed = {
    users: [{id: "user-1", email: "ivan@rodnya-tree.ru"}],
    trees: [],
    persons: [],
    personIdentities: [],
    migrationStatus: {...MIGRATED_MARKERS},
  };
  const memDb = newDb();
  const {Pool} = memDb.adapters.createPg();
  const rawPool = new Pool();
  let failedTop = false;
  let ownReadsAfterTopFailure = 0;
  const pool = {
    query: (sql, params) => {
      const text = String(sql).replace(/\s+/g, " ").trim();
      let effectiveParams = params;
      if (
        text.includes("ON CONFLICT (id) DO NOTHING") &&
        Array.isArray(params) &&
        params[0] === "default"
      ) {
        effectiveParams = [params[0], JSON.stringify(seed)];
      }
      if (text.startsWith("SELECT data FROM")) {
        if (!failedTop) {
          failedTop = true;
          return Promise.reject(new Error("connection reset (boot snapshot)"));
        }
        ownReadsAfterTopFailure += 1;
      }
      return rawPool.query(sql, effectiveParams);
    },
  };
  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
    snapshotCachePath: null,
  });

  // Не должен бросить — общий снимок недоступен один раз, но каждый шаг
  // (backfill/auth-hydrate fallback/чат/notification/tree-change/projection)
  // самостоятельно читает блоб и успешно завершает бут старым способом.
  await store.initialize();
  assert.equal(failedTop, true, "сценарий требует упавшего общего снимка");
  assert.ok(
    ownReadsAfterTopFailure >= 5,
    `ожидали независимые чтения каждого шага после провала общего снимка, было ${ownReadsAfterTopFailure}`,
  );

  // Кэш не прогрет (общий снимок не удался) — первый _read() честно читает.
  assert.equal(store._cachedVersion, null);
  const state = await store._read();
  assert.equal(state.users[0].id, "user-1");
});
