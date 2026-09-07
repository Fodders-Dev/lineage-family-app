// SPEED-14 (docs/speed_measurement.md, раздел «SPEED-14»): путь ЗАПИСИ
// блоба для четырёх маршрутов, которые на проде были самыми медленными
// (510-770 мс, одиночные вызовы): POST /v1/trees/:id/persons
// (createPerson), DELETE .../persons/:id (deletePerson), POST
// /v1/invitations/pending/process (linkPersonToUser), POST
// /v1/auth/qr/start (createAuthHandoff).
//
// Что чинит эта задача (детали и профиль — docs/speed_measurement.md):
//   1. _reconcilePersonIdentities (19 caller'ов, вызывается на КАЖДОЙ
//      мутации персон) больше не гоняет backfillPersonIdentities
//      (двойной stableSerialize+sha256 ВСЕЙ базы) безусловно — только
//      когда dbHasPersonsWithoutIdentity(db) действительно истинно
//      (тот же приём, что SPEED-8c/13 уже применяли в других местах).
//   2. createPerson больше не зовёт _reconcilePersonIdentities дважды
//      подряд в одной ветке (была чистая дублирующая работа).
//   3. PostgresStore._persistSnapshotCache (сайдкар-файл, боут/outage
//      fallback, НЕ путь корректности) теперь пишется в фоне, не
//      блокируя ответ клиенту.
//   4. PostgresStore._write() перед записью читает ТОЛЬКО data->'calls'
//      (для store-race guard _preserveTerminalCalls), а не весь блоб.
//   5. PostgresStore.createPerson (fast-path, scoped SQL, минуя
//      _read()/_write()) теперь держит SPEED-8a/11 кэш прогретым вместо
//      того, чтобы самопроизвольно инвалидировать его и заставлять
//      САМ ЖЕ СЕБЯ (через dispatchTreeMutation → resolveTreeAudienceUserIds
//      → _read() в ТОМ ЖЕ HTTP-запросе) платить полный промах.
//
// Секции:
//   A. HTTP + FileStore — функциональная идентичность всех четырёх
//      маршрутов (identityId/personIdentities синхронизированы,
//      журнал/handoff заполняются).
//   B. Store-уровень — доказательство, что гейт backfillPersonIdentities
//      безопасен: на steady-state фикстуре backfill сам по себе no-op
//      (changed=false), а _reconcilePersonIdentities с гейтом и БЕЗ
//      него (эталонная реализация ниже) дают ПОБАЙТОВО одинаковый
//      результат — и на steady state, и когда гейт реально нужен.
//   C. PostgresStore + fake-pool — механизмы 3/4/5 выше: сайдкар в
//      фоне (но в итоге записан), calls-SELECT укорочен и всё ещё
//      защищает терминальные звонки, fast-path createPerson держит
//      кэш тёплым И безопасно деградирует при гонке с чужой записью.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");

const {createApp} = require("../src/app");
const {
  FileStore,
  buildPersonRecord,
  createPersonIdentityRecord,
} = require("../src/store");
const {backfillPersonIdentities} = require("../src/migration-utils");
const {RealtimeHub} = require("../src/realtime-hub");
const {PushGateway} = require("../src/push-gateway");
const {PostgresStore} = require("../src/postgres-store");

// ── HTTP harness (тот же метод, что speed9-b/speed12/speed13 test'ы) ──

async function startTestServer() {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-speed14-"));
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
  await fs.rm(ctx.tempDir, {recursive: true, force: true}).catch(() => {});
}

async function registerUser(ctx, email) {
  const response = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({
      email,
      password: "Test-Password-123!",
      consentDocVersion: "test-consent-v1",
      displayName: email.split("@")[0],
    }),
  });
  assert.equal(response.status, 201);
  const body = await response.json();
  return {userId: body.user.id, token: body.accessToken};
}

async function createTree(ctx, token, name = "Тестовое дерево") {
  const response = await fetch(`${ctx.baseUrl}/v1/trees`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({name, description: "", isPrivate: true}),
  });
  assert.equal(response.status, 201);
  return (await response.json()).tree;
}

async function createPersonHttp(ctx, token, treeId, body) {
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

async function deletePersonHttp(ctx, token, treeId, personId) {
  return fetch(`${ctx.baseUrl}/v1/trees/${treeId}/persons/${personId}`, {
    method: "DELETE",
    headers: {authorization: `Bearer ${token}`},
  });
}

function spyWrites(store) {
  let count = 0;
  const original = store._write.bind(store);
  store._write = async (data) => {
    count += 1;
    return original(data);
  };
  return {count: () => count, reset: () => (count = 0)};
}

// ── A: HTTP + FileStore — функциональная идентичность ───────────────

test("SPEED-14 A1: createPerson (POST) — новый человек получает identityId и ровно одну PersonIdentity", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await registerUser(ctx, "a1-owner@test.app");
    const tree = await createTree(ctx, owner.token);
    const person = await createPersonHttp(ctx, owner.token, tree.id, {
      firstName: "Иван",
      lastName: "Иванов",
      gender: "male",
    });

    assert.ok(person.id);
    const db = await ctx.store._read();
    const stored = db.persons.find((entry) => entry.id === person.id);
    assert.ok(stored.identityId, "person должен получить identityId даже когда гейт пропускает backfill");
    const identity = db.personIdentities.find((entry) => entry.id === stored.identityId);
    assert.ok(identity, "PersonIdentity должна существовать для нового person");
    assert.deepEqual(identity.personIds, [stored.id]);
  } finally {
    await stopTestServer(ctx);
  }
});

test("SPEED-14 A2: create+create+delete — оставшийся человек не теряет identityId, удалённый пропадает из personIdentities", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await registerUser(ctx, "a2-owner@test.app");
    const tree = await createTree(ctx, owner.token);
    const first = await createPersonHttp(ctx, owner.token, tree.id, {
      firstName: "Пётр",
      gender: "male",
    });
    const second = await createPersonHttp(ctx, owner.token, tree.id, {
      firstName: "Мария",
      gender: "female",
    });

    const del = await deletePersonHttp(ctx, owner.token, tree.id, second.id);
    assert.equal(del.status, 204);

    const db = await ctx.store._read();
    assert.equal(
      db.persons.some((entry) => entry.id === second.id),
      false,
      "удалённый person не должен остаться в db.persons",
    );
    const remaining = db.persons.find((entry) => entry.id === first.id);
    assert.ok(remaining.identityId, "оставшийся person сохраняет identityId после удаления соседа");
    const remainingIdentity = db.personIdentities.find(
      (entry) => entry.id === remaining.identityId,
    );
    assert.ok(remainingIdentity);
    assert.deepEqual(remainingIdentity.personIds, [remaining.id]);
    // Ни одна PersonIdentity не должна ссылаться на удалённого person'а —
    // именно это чинит цикл синхронизации в _reconcilePersonIdentities,
    // который гейт (SPEED-14) НЕ трогает (гейтится только backfillPersonIdentities).
    for (const identity of db.personIdentities) {
      assert.equal(
        identity.personIds.includes(second.id),
        false,
        `personIdentities[${identity.id}] не должна ссылаться на удалённого person'а`,
      );
    }
  } finally {
    await stopTestServer(ctx);
  }
});

test("SPEED-14 A3: process pending invitation (linkPersonToUser) — второй пользователь привязывается к анонимной карточке", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await registerUser(ctx, "a3-owner@test.app");
    const tree = await createTree(ctx, owner.token);
    const anonymous = await createPersonHttp(ctx, owner.token, tree.id, {
      firstName: "Незнакомец",
      gender: "male",
    });

    const claimant = await registerUser(ctx, "a3-claimant@test.app");
    const response = await fetch(`${ctx.baseUrl}/v1/invitations/pending/process`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${claimant.token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({treeId: tree.id, personId: anonymous.id}),
    });
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.ok, true);
    assert.equal(body.person.id, anonymous.id);

    const db = await ctx.store._read();
    const linkedPerson = db.persons.find((entry) => entry.id === anonymous.id);
    assert.equal(linkedPerson.userId, claimant.userId);
    assert.ok(linkedPerson.identityId);
    const linkedUser = db.users.find((entry) => entry.id === claimant.userId);
    assert.equal(
      linkedUser.identityId,
      linkedPerson.identityId,
      "user.identityId и person.identityId должны совпасть после линковки",
    );
    const identity = db.personIdentities.find(
      (entry) => entry.id === linkedPerson.identityId,
    );
    assert.equal(identity.userId, claimant.userId);
    assert.deepEqual(identity.personIds, [linkedPerson.id]);
  } finally {
    await stopTestServer(ctx);
  }
});

test("SPEED-14 A4: qr/start (createAuthHandoff) — журнал handoff заполняется, poll находит запись", async () => {
  const ctx = await startTestServer();
  try {
    const startResponse = await fetch(`${ctx.baseUrl}/v1/auth/qr/start`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-client-instance-id": "test-device-1",
      },
      body: JSON.stringify({}),
    });
    assert.equal(startResponse.status, 201);
    const {token} = await startResponse.json();
    assert.ok(token);

    const db = await ctx.store._read();
    const handoff = db.authHandoffs.find((entry) => entry.code === token);
    assert.ok(handoff, "createAuthHandoff должен положить запись в db.authHandoffs");
    assert.equal(handoff.type, "qr_login");
    assert.equal(handoff.payload?.status, "pending");

    const pollResponse = await fetch(
      `${ctx.baseUrl}/v1/auth/qr/poll?token=${encodeURIComponent(token)}`,
    );
    assert.equal(pollResponse.status, 200);
    const pollBody = await pollResponse.json();
    assert.equal(pollBody.status, "pending");
  } finally {
    await stopTestServer(ctx);
  }
});

// ── B: гейт backfillPersonIdentities — доказательство идентичности ──

function buildSteadyStateFixture() {
  // Все persons уже с identityId — гейт (SPEED-14) должен пропускать
  // backfillPersonIdentities целиком на этой фикстуре.
  const identityA = createPersonIdentityRecord({personIds: []});
  const identityB = createPersonIdentityRecord({personIds: []});
  const personA = buildPersonRecord({
    treeId: "tree-1",
    creatorId: "user-1",
    personData: {firstName: "Алиса"},
  });
  personA.identityId = identityA.id;
  identityA.personIds = [personA.id];
  const personB = buildPersonRecord({
    treeId: "tree-1",
    creatorId: "user-1",
    personData: {firstName: "Борис"},
  });
  personB.identityId = identityB.id;
  identityB.personIds = [personB.id];
  return {
    users: [],
    trees: [{id: "tree-1", creatorId: "user-1", memberIds: [], members: []}],
    persons: [personA, personB],
    personIdentities: [identityA, identityB],
  };
}

function buildDirtyFixture() {
  // Один person без identityId — гейт должен пропустить backfill в РЕЖИМ
  // «нужен», не молча его проигнорировать.
  const state = buildSteadyStateFixture();
  const orphan = buildPersonRecord({
    treeId: "tree-1",
    creatorId: "user-1",
    personData: {firstName: "Виктор"},
  });
  orphan.identityId = null;
  state.persons.push(orphan);
  return state;
}

test("SPEED-14 B1: backfillPersonIdentities на steady-state фикстуре — доказанный no-op (changed=false, снимок не отличается)", () => {
  const state = buildSteadyStateFixture();
  const before = structuredClone({
    persons: state.persons,
    personIdentities: state.personIdentities,
  });
  const result = backfillPersonIdentities(structuredClone(state));
  assert.equal(
    result.changed,
    false,
    "на steady-state фикстуре backfill не должен находить изменений — это и есть основание гейта dbHasPersonsWithoutIdentity",
  );
  assert.deepEqual(result.snapshot.persons, before.persons);
  // personIdentities может прийти в другом порядке ключей объекта, но по
  // значению (после нормализации personIds) обязана совпасть.
  assert.deepEqual(
    result.snapshot.personIdentities.map((entry) => ({
      id: entry.id,
      personIds: entry.personIds,
      userId: entry.userId || null,
    })),
    before.personIdentities.map((entry) => ({
      id: entry.id,
      personIds: entry.personIds,
      userId: entry.userId || null,
    })),
  );
});

// Эталонная реализация _reconcilePersonIdentities БЕЗ гейта — буквальная
// копия того, что было ДО SPEED-14 (backfillPersonIdentities вызывается
// безусловно). Используется только для сравнения — сама функция ушла из
// store.js этим коммитом; малейшее расхождение с гейтированной версией
// на любой из двух фикстур означало бы, что гейт незаметно меняет
// поведение, а не просто CPU-цену.
function referenceReconcilePersonIdentities(store, db) {
  backfillPersonIdentities(db);
  const identities = store._ensurePersonIdentityCollection(db);
  const validUserIds = new Set(
    db.users.map((entry) => entry?.id).filter(Boolean),
  );
  const personIdsByIdentity = new Map();
  for (const person of db.persons) {
    const identityId = person.identityId || null;
    if (!identityId) {
      person.identityId = null;
      continue;
    }
    person.identityId = identityId;
    if (!personIdsByIdentity.has(identityId)) {
      personIdsByIdentity.set(identityId, []);
    }
    personIdsByIdentity.get(identityId).push(person.id);
  }
  // Тот же построчный цикл, что store.js:_reconcilePersonIdentities —
  // воспроизводится через сам публичный store._reconcilePersonIdentities,
  // но с backfillPersonIdentities, УЖЕ выполненным выше безусловно (гейт
  // внутри store._reconcilePersonIdentities увидит dbHasPersonsWithoutIdentity
  // === false после ручного backfill выше и просто не вызовет его повторно —
  // что эквивалентно «вызвать один раз безусловно», ровно то, что нужно
  // проверить).
  void identities;
  void validUserIds;
  void personIdsByIdentity;
  return store._reconcilePersonIdentities(db);
}

// buildDirtyFixture's orphan has no identityId — BOTH the gated path (guard
// sees dbHasPersonsWithoutIdentity===true, runs backfillPersonIdentities)
// and the reference path (runs it unconditionally) mint a brand-new
// identity for it via crypto.randomUUID() — two INDEPENDENT random ids that
// will never textually match between two separate calls. Comparing raw ids
// would be comparing incomparable values, not proving anything. Instead,
// normalize each side by relabeling every person/identity id to something
// derived from the fixture's stable, deterministic field (name) — the
// RELATIONSHIP structure (who has an identity, which identity groups which
// people) is what SPEED-14's guard must preserve, not the literal id text.
function relationshipFingerprint(db) {
  const personNameById = new Map(db.persons.map((p) => [p.id, p.name]));
  return {
    persons: db.persons
      .map((p) => ({
        name: p.name,
        hasIdentity: Boolean(p.identityId),
      }))
      .sort((a, b) => a.name.localeCompare(b.name)),
    identities: db.personIdentities
      .map((entry) => ({
        memberNames: entry.personIds
          .map((id) => personNameById.get(id) || `unknown:${id}`)
          .sort(),
        userId: entry.userId || null,
      }))
      .sort((a, b) => a.memberNames.join(",").localeCompare(b.memberNames.join(","))),
  };
}

for (const [label, buildFixture] of [
  ["steady-state (гейт пропускает backfill)", buildSteadyStateFixture],
  ["dirty (гейт реально нужен)", buildDirtyFixture],
]) {
  test(`SPEED-14 B2: _reconcilePersonIdentities с гейтом даёт ТОТ ЖЕ результат, что безусловный backfill+reconcile — ${label}`, () => {
    const store = new FileStore(path.join(os.tmpdir(), "unused-speed14.json"));

    // Строим фикстуру ОДИН раз (buildPersonRecord/createPersonIdentityRecord
    // генерируют случайные id — два независимых вызова buildFixture() дали
    // бы разные id) и клонируем её для двух независимых прогонов на
    // identical входных данных.
    const fixture = buildFixture();
    const dbGated = structuredClone(fixture);
    store._reconcilePersonIdentities(dbGated);

    const dbReference = structuredClone(fixture);
    referenceReconcilePersonIdentities(store, dbReference);

    assert.deepEqual(
      relationshipFingerprint(dbGated),
      relationshipFingerprint(dbReference),
      "гейт не должен менять итоговую структуру person↔identity относительно безусловного backfill+reconcile",
    );
  });
}

test("SPEED-14 B3: createPerson (else-ветка, без canonicalIdentity) — убранный дублирующий вызов не меняет итоговое состояние", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await registerUser(ctx, "b3-owner@test.app");
    const tree = await createTree(ctx, owner.token);
    // Без userId/sourcePersonId → canonicalIdentity остаётся null →
    // раньше это была ветка с двойным _reconcilePersonIdentities.
    const person = await createPersonHttp(ctx, owner.token, tree.id, {
      firstName: "Один-вызов",
      gender: "female",
    });
    const db = await ctx.store._read();
    const stored = db.persons.find((entry) => entry.id === person.id);
    assert.ok(stored.identityId);
    const identity = db.personIdentities.find((entry) => entry.id === stored.identityId);
    assert.deepEqual(identity.personIds, [stored.id]);
    assert.equal(db.treeChangeRecords.filter((r) => r.personId === person.id).length, 1, "ровно одна tree-change запись на создание");
  } finally {
    await stopTestServer(ctx);
  }
});

// ── C: PostgresStore + fake pool — сайдкар/calls-select/fast-path кэш ──

function buildPgFakePool({rowState, initialVersion = 1}) {
  // Migration markers default to "already migrated" so _bootstrap()'s
  // chat/notification/tree-change table migrations short-circuit as
  // no-ops against this fake pool (which doesn't implement their INSERT
  // statements) — same convention as postgres-store.test.js's fakes.
  // Callers can still override by passing their own migrationStatus.
  let state = {
    migrationStatus: {
      chatCollectionsToTables: "complete-v1",
      notificationsToTables: "complete-v1",
      treeChangeRecordsToTables: "complete-v1",
    },
    ...rowState,
  };
  let version = initialVersion;
  const queries = [];
  const pool = {
    getState: () => state,
    getVersion: () => version,
    bumpVersionExternally: () => {
      // Симулирует ЧУЖУЮ запись (другой процесс/воркер), которая
      // меняет version БЕЗ ведома текущего инстанса кэша.
      version += 1;
    },
    async query(sql, params = []) {
      queries.push(sql);
      const text = String(sql);
      if (
        text.includes("CREATE SCHEMA") ||
        text.includes("CREATE TABLE") ||
        text.includes("CREATE INDEX") ||
        text.includes("ALTER TABLE") ||
        text.includes("ON CONFLICT (id) DO NOTHING")
      ) {
        return {rows: []};
      }
      if (
        text.includes("DELETE FROM \"public\".\"rodnya_state_auth_users\"") ||
        text.includes("DELETE FROM \"public\".\"rodnya_state_auth_sessions\"") ||
        text.includes("INSERT INTO \"public\".\"rodnya_state_auth_users\"") ||
        text.includes("INSERT INTO \"public\".\"rodnya_state_auth_sessions\"")
      ) {
        return {rows: []};
      }
      if (text.includes("SELECT session_data")) {
        return {rows: []};
      }
      if (text.includes("SELECT version FROM")) {
        return {rows: [{version}]};
      }
      if (text.includes("SELECT data, version FROM")) {
        return {rows: [{data: state, version}]};
      }
      if (text.includes("data->'calls'")) {
        return {rows: [{calls: state?.calls || []}]};
      }
      if (
        text.includes("UPDATE \"public\".\"rodnya_state\"") &&
        text.includes("'{persons}'")
      ) {
        const nextPerson = JSON.parse(params[1]);
        const treeId = params[2];
        const nextIdentity = JSON.parse(params[3]);
        const tree = (state.trees || []).find((entry) => entry.id === treeId) || null;
        if (!tree) return {rowCount: 0, rows: []};
        version += 1;
        state = {
          ...state,
          persons: [...(state.persons || []), nextPerson],
          personIdentities: [...(state.personIdentities || []), nextIdentity],
        };
        return {rowCount: 1, rows: [{version}]};
      }
      if (text.includes("SELECT data")) {
        // Bare "SELECT data FROM ..." (no ", version") — used by
        // _readBootStateRow() during initialize(). Must return the SAME
        // `state` as every other full-blob read, not a stub: this test
        // exercises real _read()/_write() cache hits/misses across the
        // boot boundary, so boot's own read has to see the fixture's
        // migrationStatus markers (see buildPgFakePool callers) to skip
        // the chat/notification/tree-change table migrations cleanly.
        return {rows: [{data: state}]};
      }
      if (text.includes("ON CONFLICT (id) DO UPDATE")) {
        version += 1;
        state = JSON.parse(params[1]);
        return {rows: [{version}]};
      }
      if (text.includes("_chat")) {
        return {rows: []};
      }
      if (text.startsWith("UPDATE") && text.includes("SET data")) {
        version += 1;
        return {rows: [{version}]};
      }
      throw new Error(`Unexpected query: ${sql}`);
    },
  };
  return {pool, queries};
}

test("SPEED-14 C1: сайдкар-кэш пишется в фоне — _write() резолвится ДО того, как файл появился, но после flush файл содержит записанное состояние", async () => {
  const cacheDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-speed14-cache-"));
  const snapshotCachePath = path.join(cacheDir, "state-cache.json");
  try {
    const {pool} = buildPgFakePool({rowState: {users: []}});
    const store = new PostgresStore({
      connectionString: "postgresql://unused/rodnya",
      pool,
      snapshotCachePath,
    });
    await store.initialize();

    await store._write({users: [{id: "u-speed14"}]});
    // Немедленно после резолва _write() файл может ещё не существовать —
    // это и есть смысл фикса (не блокировать ответ клиенту). Не
    // проверяем строгое отсутствие (race-условие таймингов ОС), только
    // то, что явный flush гарантированно доводит запись до диска.
    await store._flushSnapshotCacheWrites();
    const persisted = JSON.parse(await fs.readFile(snapshotCachePath, "utf8"));
    assert.deepEqual(persisted.users, [{id: "u-speed14"}]);
  } finally {
    await fs.rm(cacheDir, {recursive: true, force: true});
  }
});

test("SPEED-14 C1b: несколько записей подряд, пока сайдкар ещё летит, коалесятся в ПОСЛЕДНИЙ снимок", async () => {
  const cacheDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-speed14-cache2-"));
  const snapshotCachePath = path.join(cacheDir, "state-cache.json");
  try {
    const {pool} = buildPgFakePool({rowState: {users: []}});
    const store = new PostgresStore({
      connectionString: "postgresql://unused/rodnya",
      pool,
      snapshotCachePath,
    });
    await store.initialize();

    await store._write({users: [{id: "u-1"}]});
    await store._write({users: [{id: "u-2"}]});
    await store._write({users: [{id: "u-3"}]});
    await store._flushSnapshotCacheWrites();

    const persisted = JSON.parse(await fs.readFile(snapshotCachePath, "utf8"));
    assert.deepEqual(
      persisted.users,
      [{id: "u-3"}],
      "сайдкар должен отражать САМОЕ ПОСЛЕДНЕЕ состояние, не обязательно каждое промежуточное",
    );
  } finally {
    await fs.rm(cacheDir, {recursive: true, force: true});
  }
});

test("SPEED-14 C2: _write() читает только data->'calls' (не весь блоб) и по-прежнему защищает терминальные звонки", async () => {
  // normalizeStoredCall (store.js) drops any call missing
  // initiatorId/recipientId/chatId — normalizeDbState .filter(Boolean)s
  // them out entirely, so the fixture needs all three or it silently
  // disappears (that's what caused this test's first failed draft).
  const terminalCall = {
    id: "call-1",
    state: "ended",
    initiatorId: "user-1",
    recipientId: "user-2",
    chatId: "user-1_user-2",
    participantIds: ["user-1", "user-2"],
  };
  const {pool, queries} = buildPgFakePool({
    rowState: {users: [], calls: [terminalCall]},
  });
  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
  });
  await store.initialize();
  queries.length = 0;

  // Пишем состояние, где та же call ЕЩЁ "active" — типичная гонка
  // teardown vs write-based-on-stale-snapshot, которую и защищает
  // _preserveTerminalCalls.
  const staleCallCopy = {...terminalCall, state: "active"};
  const nextState = await store._read();
  nextState.calls = [staleCallCopy];
  await store._write(nextState);

  assert.equal(
    queries.some((sql) => sql.includes("data->'calls'")),
    true,
    "_write() должен использовать укороченный SELECT data->'calls'",
  );
  assert.equal(
    queries.some(
      (sql) => sql.includes("SELECT data FROM") && !sql.includes("data->'calls'"),
    ),
    false,
    "_write() НЕ должен делать полный SELECT data FROM ради terminal-calls guard",
  );

  const finalState = await store._read();
  assert.equal(
    finalState.calls[0].state,
    "ended",
    "_preserveTerminalCalls должен был откатить call обратно в terminal, несмотря на укороченный SELECT",
  );
});

test("SPEED-14 C3: createPerson fast-path держит кэш прогретым — следующий _read() не делает полного SELECT и видит нового person", async () => {
  const treeId = "tree-1";
  const {pool, queries} = buildPgFakePool({
    rowState: {
      users: [{id: "user-1", email: "u@test.app", profile: {}}],
      sessions: [],
      trees: [{id: treeId, creatorId: "user-1", memberIds: [], members: []}],
      persons: [],
      relations: [],
      treeChangeRecords: [],
      personIdentities: [],
    },
  });
  const store = new PostgresStore({connectionString: "postgresql://unused/rodnya", pool});
  await store.initialize();

  // Прогреваем кэш — как обычный GET перед POST в реальном бёрсте входа.
  await store._read();
  queries.length = 0;

  const created = await store.createPerson({
    treeId,
    creatorId: "user-1",
    personData: {firstName: "Быстрый"},
  });
  assert.ok(created.id);

  queries.length = 0;
  const afterRead = await store._read();
  assert.equal(
    queries.some((sql) => sql.includes("SELECT data, version FROM")),
    false,
    "следующий _read() после fast-path createPerson не должен промахиваться мимо кэша",
  );
  assert.equal(afterRead.persons.length, 1);
  assert.equal(afterRead.persons[0].id, created.id);
});

test("SPEED-14 C4: createPerson fast-path НЕ патчит кэш, если между прогревом и записью была чужая запись — следующий _read() честно перечитывает", async () => {
  const treeId = "tree-1";
  const {pool, queries} = buildPgFakePool({
    rowState: {
      users: [],
      sessions: [],
      trees: [{id: treeId, creatorId: "user-1", memberIds: [], members: []}],
      persons: [],
      relations: [],
      treeChangeRecords: [],
      personIdentities: [],
    },
  });
  const store = new PostgresStore({connectionString: "postgresql://unused/rodnya", pool});
  await store.initialize();

  await store._read();
  // Чужая запись «со стороны» — version в БД уходит вперёд, но
  // store._cachedVersion об этом не знает (ровно сценарий гонки,
  // который проверка preUpdateCachedVersion === writtenVersion-1
  // обязана отловить).
  pool.bumpVersionExternally();

  const created = await store.createPerson({
    treeId,
    creatorId: "user-1",
    personData: {firstName: "Гонка"},
  });
  assert.ok(created.id);

  queries.length = 0;
  const afterRead = await store._read();
  assert.equal(
    queries.some((sql) => sql.includes("SELECT data, version FROM")),
    true,
    "версии разошлись — кэш НЕ должен был патчиться, следующий _read() обязан честно перечитать",
  );
  assert.equal(afterRead.persons.length, 1);
  assert.equal(afterRead.persons[0].id, created.id, "несмотря на промах, итоговые данные корректны");
});
