// SPEED-8b: treeChangeRecords + hardDeleteAudit поверх таблиц на pg-mem —
// НАСТОЯЩИЙ SQL стора: бут-миграция блоб→таблицы (бэкап, маркер,
// идемпотентность), чтение истории с фильтрами, история статьи, дренаж
// новых записей из унаследованных путей, табличные операции хуков
// (слияние дублей, псевдонимизация deleteUser, ретенция details, prune
// аудита), применяемые _write после UPSERT.
const test = require("node:test");
const assert = require("node:assert/strict");

const {newDb} = require("pg-mem");
const {PostgresStore} = require("../src/postgres-store");

const USERS = [
  {id: "user-1", email: "ivan@rodnya-tree.ru", profile: {displayName: "Иван"}},
  {id: "user-2", email: "anna@rodnya-tree.ru", profile: {displayName: "Анна"}},
];
const TREE = {
  id: "tree-1",
  name: "Наше дерево",
  creatorId: "user-1",
  memberIds: ["user-1", "user-2"],
  createdAt: "2026-04-01T10:00:00.000Z",
  updatedAt: "2026-04-01T10:00:00.000Z",
};
const PERSONS = [
  {id: "person-1", treeId: "tree-1", name: "Пётр", firstName: "Пётр", createdAt: "2026-04-01T10:00:00.000Z"},
  {id: "person-2", treeId: "tree-1", name: "Мария", firstName: "Мария", createdAt: "2026-04-01T10:00:00.000Z"},
];

function record(overrides) {
  return {
    id: overrides.id,
    treeId: overrides.treeId || "tree-1",
    actorId: overrides.actorId ?? "user-1",
    type: overrides.type || "person.updated",
    personId: overrides.personId ?? "person-1",
    personIds: overrides.personIds || [overrides.personId ?? "person-1"],
    relationId: null,
    mediaId: null,
    createdAt: overrides.createdAt || "2026-08-01T10:00:00.000Z",
    details: overrides.details || {},
  };
}

const RECORDS_TABLE = `"public"."rodnya_state_tree_change_records"`;
const AUDIT_TABLE = `"public"."rodnya_state_hard_delete_audit"`;
const BACKUPS_TABLE = `"public"."rodnya_state_tree_change_backups"`;
const STATE_TABLE = `"public"."rodnya_state"`;

function buildStore(seededState) {
  const memDb = newDb();
  const {Pool} = memDb.adapters.createPg();
  const rawPool = new Pool();
  const pool = {
    query: (sql, params) => {
      let effectiveParams = params;
      if (
        String(sql).includes("ON CONFLICT (id) DO NOTHING") &&
        Array.isArray(params) &&
        params[0] === "default"
      ) {
        effectiveParams = [params[0], JSON.stringify(seededState)];
      }
      return rawPool.query(sql, effectiveParams);
    },
  };
  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
    snapshotCachePath: null,
  });
  return {store, rawPool};
}

function seed(extra = {}) {
  return {
    users: USERS,
    trees: [TREE],
    persons: PERSONS,
    treeChangeRecords: [
      record({id: "rec-old-heavy", createdAt: "2026-05-01T10:00:00.000Z",
        details: {before: {name: "A"}, after: {name: "B"}, note: "keep"}}),
      record({id: "rec-new-heavy", createdAt: "2026-08-20T10:00:00.000Z",
        details: {before: {name: "B"}, after: {name: "C"}}}),
      record({id: "rec-article-old", type: "article.updated", personId: "person-2",
        personIds: ["person-2"], createdAt: "2026-05-02T10:00:00.000Z",
        details: {before: {text: "старый"}, after: {text: "новый"}}}),
      record({id: "rec-anna", actorId: "user-2", personId: "person-2",
        personIds: ["person-2", "person-1"], createdAt: "2026-08-10T10:00:00.000Z"}),
      // Битая запись (без id) — остаётся только в бэкапе.
      {treeId: "tree-1", type: "broken", createdAt: "2026-08-01T10:00:00.000Z"},
    ],
    hardDeleteAudit: [
      {entityType: "person", entityId: "gone-1", hardDeletedAt: "2026-03-01T00:00:00.000Z"},
      {entityType: "person", entityId: "gone-2", hardDeletedAt: "2026-08-25T00:00:00.000Z"},
    ],
    ...extra,
  };
}

async function stateRow(rawPool) {
  const result = await rawPool.query(`SELECT data FROM ${STATE_TABLE} WHERE id = $1`, ["default"]);
  const raw = result.rows[0].data;
  return typeof raw === "string" ? JSON.parse(raw) : raw;
}

test("миграция: блоб → таблицы, бэкап, маркер, идемпотентность", async () => {
  const {store, rawPool} = buildStore(seed());
  await store.initialize();

  const rows = await rawPool.query(`SELECT id, tree_id, actor_id, type, person_id FROM ${RECORDS_TABLE} ORDER BY id`);
  assert.deepEqual(rows.rows.map((r) => r.id), ["rec-anna", "rec-article-old", "rec-new-heavy", "rec-old-heavy"]);
  assert.equal(rows.rows.find((r) => r.id === "rec-anna").actor_id, "user-2");
  assert.equal(rows.rows.find((r) => r.id === "rec-article-old").type, "article.updated");

  const audit = await rawPool.query(`SELECT hard_deleted_at FROM ${AUDIT_TABLE} ORDER BY hard_deleted_at`);
  assert.equal(audit.rows.length, 2);

  const backup = await rawPool.query(`SELECT id, backup_data FROM ${BACKUPS_TABLE}`);
  assert.equal(backup.rows.length, 1);
  assert.equal(backup.rows[0].id, "pre-migration-complete-v1");
  const backupData = typeof backup.rows[0].backup_data === "string"
    ? JSON.parse(backup.rows[0].backup_data) : backup.rows[0].backup_data;
  assert.equal(backupData.treeChangeRecords.length, 5, "битая запись тоже в бэкапе");
  assert.equal(backupData.hardDeleteAudit.length, 2);

  const state = await stateRow(rawPool);
  assert.deepEqual(state.treeChangeRecords, []);
  assert.deepEqual(state.hardDeleteAudit, []);
  assert.equal(state.migrationStatus.treeChangeRecordsToTables, "complete-v1");

  // Повторный бут — ничего не дублирует и не перезаписывает бэкап.
  const {store: again, rawPool: againPool} = buildStore(seed());
  await again.initialize();
  await again.initialize();
  const againRows = await againPool.query(`SELECT count(*)::int AS n FROM ${RECORDS_TABLE}`);
  assert.equal(againRows.rows[0].n, 4);
});

test("listTreeChangeRecords: фильтры и порядок — из таблицы", async () => {
  const {store} = buildStore(seed());
  const all = await store.listTreeChangeRecords("tree-1");
  assert.deepEqual(all.map((r) => r.id), ["rec-new-heavy", "rec-anna", "rec-article-old", "rec-old-heavy"], "новые первыми");

  const byPerson = await store.listTreeChangeRecords("tree-1", {personId: "person-1"});
  assert.deepEqual(byPerson.map((r) => r.id).sort(), ["rec-anna", "rec-new-heavy", "rec-old-heavy"].sort(),
    "personIds участвует в фильтре");
  const byType = await store.listTreeChangeRecords("tree-1", {type: "article.updated"});
  assert.deepEqual(byType.map((r) => r.id), ["rec-article-old"]);
  const byActor = await store.listTreeChangeRecords("tree-1", {actorId: "user-2"});
  assert.deepEqual(byActor.map((r) => r.id), ["rec-anna"]);
  assert.deepEqual(await store.listTreeChangeRecords("tree-nope"), []);
});

test("getArticleHistory: только article.* по человеку; чужой id → PERSON_NOT_FOUND", async () => {
  const {store} = buildStore(seed());
  const history = await store.getArticleHistory({personId: "person-2"});
  assert.deepEqual(history.map((r) => r.id), ["rec-article-old"]);
  await assert.rejects(store.getArticleHistory({personId: "ghost"}), /PERSON_NOT_FOUND/);
});

test("appendTreeChangeRecord: запись рождается в блобе и дренируется в таблицу", async () => {
  const {store, rawPool} = buildStore(seed());
  const created = await store.appendTreeChangeRecord({
    treeId: "tree-1",
    actorId: "user-1",
    type: "person.pulled-from-semya",
    personId: "person-1",
  });
  const row = await rawPool.query(`SELECT type FROM ${RECORDS_TABLE} WHERE id = $1`, [created.id]);
  assert.equal(row.rows[0]?.type, "person.pulled-from-semya");
  const state = await stateRow(rawPool);
  assert.deepEqual(state.treeChangeRecords, [], "в блобе не задерживается");
  const listed = await store.listTreeChangeRecords("tree-1", {type: "person.pulled-from-semya"});
  assert.equal(listed.length, 1);
});

test("слияние дублей: хук переписывает personId/personIds в таблице", async () => {
  const {store, rawPool} = buildStore(seed());
  const db = await store._read();
  store._rewriteTreeChangeRecordsForMerge(db, {
    treeId: "tree-1",
    duplicatePersonId: "person-1",
    preferredPersonId: "person-9",
  });
  await store._write(db);

  const rows = await rawPool.query(`SELECT id, person_id, record_data FROM ${RECORDS_TABLE} ORDER BY id`);
  const byId = Object.fromEntries(rows.rows.map((r) => [r.id, r]));
  assert.equal(byId["rec-old-heavy"].person_id, "person-9");
  const anna = typeof byId["rec-anna"].record_data === "string"
    ? JSON.parse(byId["rec-anna"].record_data) : byId["rec-anna"].record_data;
  assert.deepEqual(anna.personIds.sort(), ["person-2", "person-9"].sort());
  assert.equal(byId["rec-article-old"].person_id, "person-2", "чужого человека не трогаем");
});

test("deleteUser: актор псевдонимизирован в таблице, записи остаются", async () => {
  const {store, rawPool} = buildStore(seed());
  await store.deleteUser("user-2");
  const rows = await rawPool.query(`SELECT id, actor_id, record_data FROM ${RECORDS_TABLE} WHERE id = $1`, ["rec-anna"]);
  assert.equal(rows.rows.length, 1, "запись не удалена");
  assert.equal(rows.rows[0].actor_id, "deleted-user");
  const data = typeof rows.rows[0].record_data === "string"
    ? JSON.parse(rows.rows[0].record_data) : rows.rows[0].record_data;
  assert.equal(data.actorId, "deleted-user");
  assert.equal(data.actorName, null);
});

test("hardDeleteExpired: срез тяжёлых details у старых НЕ-article записей и prune аудита — в таблицах", async () => {
  const {store, rawPool} = buildStore(seed());
  await store.hardDeleteExpired({
    now: new Date("2026-09-01T00:00:00.000Z"),
    auditRetentionDays: 90,
    logRetention: {treeChangeDetailDays: 30},
  });

  const rows = await rawPool.query(`SELECT id, record_data FROM ${RECORDS_TABLE} ORDER BY id`);
  const data = Object.fromEntries(rows.rows.map((r) => [r.id,
    typeof r.record_data === "string" ? JSON.parse(r.record_data) : r.record_data]));
  assert.deepEqual(data["rec-old-heavy"].details, {note: "keep"}, "старая — before/after срезаны, остальное цело");
  assert.deepEqual(Object.keys(data["rec-new-heavy"].details).sort(), ["after", "before"], "свежая — не тронута");
  assert.deepEqual(Object.keys(data["rec-article-old"].details).sort(), ["after", "before"], "article.* — провенанс цел");

  const audit = await rawPool.query(`SELECT audit_data FROM ${AUDIT_TABLE}`);
  const entries = audit.rows.map((r) => typeof r.audit_data === "string" ? JSON.parse(r.audit_data) : r.audit_data);
  assert.deepEqual(entries.map((e) => e.entityId), ["gone-2"], "старше 90 дней — выбыла");
  const state = await stateRow(rawPool);
  assert.deepEqual(state.hardDeleteAudit, [], "в блобе аудит пуст");
});

test("dry-run hardDeleteExpired ничего не меняет в таблицах", async () => {
  const {store, rawPool} = buildStore(seed());
  await store.hardDeleteExpired({
    now: new Date("2026-09-01T00:00:00.000Z"),
    auditRetentionDays: 90,
    logRetention: {treeChangeDetailDays: 30},
    dryRun: true,
  });
  const audit = await rawPool.query(`SELECT count(*)::int AS n FROM ${AUDIT_TABLE}`);
  assert.equal(audit.rows[0].n, 2);
  const rows = await rawPool.query(`SELECT record_data FROM ${RECORDS_TABLE} WHERE id = $1`, ["rec-old-heavy"]);
  const data = typeof rows.rows[0].record_data === "string" ? JSON.parse(rows.rows[0].record_data) : rows.rows[0].record_data;
  assert.ok(data.details.before, "dry-run не срезает");
});
