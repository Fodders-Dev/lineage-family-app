#!/usr/bin/env node
// SPEED-7 rollback: вернуть notifications/pushDeliveries из таблиц в блоб.
//
// Нужен ТОЛЬКО для отката бэкенда на код до SPEED-7: старый код читает
// уведомления из блоба, а после миграции они живут в таблицах. Скрипт
// собирает АКТУАЛЬНОЕ содержимое таблиц (включая записи, созданные уже
// после миграции), кладёт его в блоб и снимает маркер. Таблицы очищаются,
// чтобы повторный запуск нового кода начал миграцию заново.
//
// Запуск (на сервере, при ОСТАНОВЛЕННОМ бэкенде):
//   RODNYA_POSTGRES_URL=postgres://... node scripts/restore-notifications-to-blob.js
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
    const rawData = stateResult.rows[0].data;
    const state = typeof rawData === "string" ? JSON.parse(rawData) : rawData;

    // Guard: без маркера миграция НЕ выполнялась — уведомления ещё в блобе,
    // а таблицы пусты. Перезапись блоба «пустотой из таблиц» уничтожила бы
    // реальные данные. Обойти можно только осознанно через --force.
    const marker = state?.migrationStatus?.notificationsToTables;
    if (marker !== "complete-v1" && !process.argv.includes("--force")) {
      throw new Error(
        `миграция не выполнялась (маркер='${marker || "нет"}') — откатывать нечего; ` +
          "если уверены, повторите с --force",
      );
    }

    const notifications = (
      await client.query(`SELECT notification_data FROM ${q("notifications")}`)
    ).rows.map((row) =>
      typeof row.notification_data === "string"
        ? JSON.parse(row.notification_data)
        : row.notification_data,
    );
    const pushDeliveries = (
      await client.query(`SELECT delivery_data FROM ${q("push_deliveries")}`)
    ).rows.map((row) =>
      typeof row.delivery_data === "string"
        ? JSON.parse(row.delivery_data)
        : row.delivery_data,
    );

    console.log(
      `Таблицы: notifications=${notifications.length} ` +
        `pushDeliveries=${pushDeliveries.length}; ` +
        `блоб сейчас: notifications=${(state.notifications || []).length}, ` +
        `маркер=${state.migrationStatus?.notificationsToTables || "нет"}`,
    );
    if (dryRun) {
      console.log("--dry-run: ничего не изменено");
      return;
    }

    const nextState = {
      ...state,
      notifications,
      pushDeliveries,
      migrationStatus: {...(state.migrationStatus || {})},
    };
    delete nextState.migrationStatus.notificationsToTables;

    await client.query("BEGIN");
    await client.query(
      `UPDATE ${stateTable} SET data = $2::jsonb, updated_at = NOW() WHERE id = $1`,
      [rowId, JSON.stringify(nextState)],
    );
    await client.query(`DELETE FROM ${q("notifications")}`);
    await client.query(`DELETE FROM ${q("push_deliveries")}`);
    // Архивируем старый бэкап: у повторной миграции должен появиться СВЕЖИЙ
    // снапшот (write-once id иначе оставил бы устаревший).
    await client.query(
      `UPDATE ${q("notification_backups")}
          SET id = id || '-restored-' || $1
        WHERE id = 'pre-migration-complete-v1'`,
      [Date.now().toString(36)],
    );
    await client.query("COMMIT");
    console.log(
      "Готово: notifications/pushDeliveries возвращены в блоб, маркер снят, таблицы очищены.",
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
