// SPEED-8a: кэш чтения PostgresStore на настоящем SQL (pg-mem): колонка
// version появляется при бутстрапе, UPSERT её инкрементит, повторное
// чтение без записей не перечитывает блоб, после записи кэш актуален.
const test = require("node:test");
const assert = require("node:assert/strict");

const {newDb} = require("pg-mem");
const {PostgresStore} = require("../src/postgres-store");

function buildStore(seededState) {
  const memDb = newDb();
  const {Pool} = memDb.adapters.createPg();
  const rawPool = new Pool();
  const counters = {snapshotSelects: 0};
  const pool = {
    counters,
    query: (sql, params) => {
      let effectiveParams = params;
      if (
        String(sql).includes("ON CONFLICT (id) DO NOTHING") &&
        Array.isArray(params) &&
        params[0] === "default"
      ) {
        effectiveParams = [params[0], JSON.stringify(seededState)];
      }
      if (String(sql).includes("SELECT data, version FROM")) {
        counters.snapshotSelects += 1;
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
  users: [{id: "user-1", email: "ivan@rodnya-tree.ru", profile: {displayName: "Иван"}}],
  trees: [],
};

test("pg-mem: version есть после бутстрапа и растёт на каждой записи", async () => {
  const {store, rawPool} = buildStore(SEED);
  await store.initialize();
  // Бут-миграции (чаты/уведомления → таблицы) сами пишут строку и
  // инкрементят version — считаем относительно состояния после initialize.
  const before = await rawPool.query(
    'SELECT version FROM "public"."rodnya_state" WHERE id = $1',
    ["default"],
  );
  const base = Number(before.rows[0].version);
  assert.ok(Number.isInteger(base) && base >= 0, "колонка version есть после бутстрапа");

  const state = await store._read();
  state.trees.push({id: "tree-1", name: "Наше дерево", memberIds: ["user-1"]});
  await store._write(state);
  await store._write(state);

  const after = await rawPool.query(
    'SELECT version FROM "public"."rodnya_state" WHERE id = $1',
    ["default"],
  );
  assert.equal(Number(after.rows[0].version), base + 2, "каждый UPSERT = +1");
});

test("pg-mem: повторные чтения не трогают блоб, запись обновляет кэш", async () => {
  const {store, pool} = buildStore(SEED);
  const first = await store._read();
  const second = await store._read();
  assert.equal(first.users[0].id, "user-1");
  assert.equal(second.users[0].id, "user-1");
  assert.equal(pool.counters.snapshotSelects, 1, "второе чтение — из кэша");

  second.trees.push({id: "tree-1", name: "Наше дерево", memberIds: ["user-1"]});
  await store._write(second);
  const third = await store._read();
  assert.equal(third.trees.length, 1);
  assert.equal(pool.counters.snapshotSelects, 1, "после записи кэш актуален без перечитывания");
});

test("pg-mem: сторонняя запись в строку (version + 1) инвалидирует кэш", async () => {
  const {store, pool, rawPool} = buildStore(SEED);
  await store._read();
  await rawPool.query(
    `UPDATE "public"."rodnya_state"
        SET data = $2::jsonb, version = version + 1
      WHERE id = $1`,
    ["default", JSON.stringify({...SEED, users: [...SEED.users, {id: "user-2", email: "x@y"}]})],
  );
  const after = await store._read();
  assert.equal(after.users.length, 2);
  assert.equal(pool.counters.snapshotSelects, 2);
});
