#!/usr/bin/env node
// SPEED-8b rollback: вернуть treeChangeRecords/hardDeleteAudit из таблиц в блоб.
//
// Нужен ТОЛЬКО для отката бэкенда на код до SPEED-8b: старый код читает
// журнал изменений дерева и аудит hard-delete из блоба, а после миграции они
// живут в таблицах. Скрипт собирает АКТУАЛЬНОЕ содержимое таблиц (включая
// записи, созданные уже после миграции), кладёт его в блоб и снимает маркер.
// Таблицы очищаются, чтобы повторный запуск нового кода начал миграцию заново.
//
// Запуск (на сервере, при ОСТАНОВЛЕННОМ бэкенде):
//   RODNYA_POSTGRES_URL=postgres://... node scripts/restore-tree-change-records-to-blob.js
//   ...или с LINEAGE_POSTGRES_URL / DATABASE_URL — как у самого бэкенда.
// Опции: --dry-run (только показать объёмы), --force (без маркера).

const {Client} = require("pg");

const url =
  process.env.RODNYA_POSTGRES_URL ||
  process.env.LINEAGE_POSTGRES_URL ||
  process.env.DATABASE_URL;
const schema = process.env.RODNYA_POSTGRES_SCHEMA || "public";
const table = process.env.RODNYA_POSTGRES_STATE_TABLE || "rodnya_state";
const rowId = process.env.RODNYA_POSTGRES_STATE_ROW_ID || "default";
const dryRun = process.argv.includes("--dry-run");

if (!url) {
  console.error("Не задан RODNYA_POSTGRES_URL / LINEAGE_POSTGRES_URL / DATABASE_URL");
  process.exit(1);
}

const q = (name) => `"${schema}"."${table}_${name}"`;
const stateTable = `"${schema}"."${table}"`;

const parseJson = (value) => (typeof value === "string" ? JSON.parse(value) : value);

(async () => {
  const client = new Client({connectionString: url});
  await client.connect();
  try {
    const stateResult = await client.query(
      `SELECT data FROM ${stateTable} WHERE id = $1`,
      [rowId],
    );
    if (stateResult.rows.length === 0) {
      throw new Error(`строка состояния id='${rowId}' не найдена`);
    }
    const state = parseJson(stateResult.rows[0].data);

    // Guard: без маркера миграция НЕ выполнялась — журнал ещё в блобе, а
    // таблицы пусты. Перезапись блоба «пустотой из таблиц» уничтожила бы
    // реальные данные. Обойти можно только осознанно через --force.
    const marker = state?.migrationStatus?.treeChangeRecordsToTables;
    if (marker !== "complete-v1" && !process.argv.includes("--force")) {
      throw new Error(
        `миграция не выполнялась (маркер='${marker || "нет"}') — откатывать нечего; ` +
          "если уверены, повторите с --force",
      );
    }

    const treeChangeRecords = (
      await client.query(
        `SELECT record_data FROM ${q("tree_change_records")} ORDER BY created_at, id`,
      )
    ).rows.map((row) => parseJson(row.record_data));
    const hardDeleteAudit = (
      await client.query(
        `SELECT audit_data FROM ${q("hard_delete_audit")} ORDER BY hard_deleted_at, id`,
      )
    ).rows.map((row) => {
      const entry = parseJson(row.audit_data);
      // auditRowId — служебный ключ таблицы, в блобе его не было.
      delete entry.auditRowId;
      return entry;
    });

    console.log(
      `Таблицы: treeChangeRecords=${treeChangeRecords.length} ` +
        `hardDeleteAudit=${hardDeleteAudit.length}; ` +
        `блоб сейчас: treeChangeRecords=${(state.treeChangeRecords || []).length}, ` +
        `маркер=${marker || "нет"}`,
    );
    if (dryRun) {
      console.log("--dry-run: ничего не изменено");
      return;
    }

    const nextState = {
      ...state,
      treeChangeRecords,
      hardDeleteAudit,
      migrationStatus: {...(state.migrationStatus || {})},
    };
    delete nextState.migrationStatus.treeChangeRecordsToTables;

    await client.query("BEGIN");
    // version + 1: кэш чтения (SPEED-8a) обязан увидеть новую строку.
    await client.query(
      `UPDATE ${stateTable}
          SET data = $2::jsonb, updated_at = NOW(), version = version + 1
        WHERE id = $1`,
      [rowId, JSON.stringify(nextState)],
    );
    await client.query(`DELETE FROM ${q("tree_change_records")}`);
    await client.query(`DELETE FROM ${q("hard_delete_audit")}`);
    // Архивируем старый бэкап: у повторной миграции должен появиться СВЕЖИЙ
    // снапшот (write-once id иначе оставил бы устаревший).
    await client.query(
      `UPDATE ${q("tree_change_backups")}
          SET id = id || '-restored-' || $1
        WHERE id = 'pre-migration-complete-v1'`,
      [Date.now().toString(36)],
    );
    await client.query("COMMIT");
    console.log(
      "Готово: treeChangeRecords/hardDeleteAudit возвращены в блоб, маркер снят, таблицы очищены.",
    );
    console.log("Теперь можно запускать бэкенд ЛЮБОЙ версии (старый — читает блоб,");
    console.log("новый — смигрирует в таблицы заново при старте).");
  } catch (error) {
    try {
      await client.query("ROLLBACK");
    } catch (_) {
      // соединение могло уже закрыться — исходная ошибка важнее
    }
    console.error("ОШИБКА:", error.message);
    process.exitCode = 1;
  } finally {
    await client.end();
  }
})();
