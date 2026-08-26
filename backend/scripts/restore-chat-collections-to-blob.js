#!/usr/bin/env node
// SPEED-6 rollback: вернуть чат-коллекции из таблиц обратно в JSONB-блоб.
//
// Нужен ТОЛЬКО для отката бэкенда на код до SPEED-6: старый код читает
// сообщения из блоба, а после миграции они живут в таблицах. Скрипт
// собирает АКТУАЛЬНОЕ содержимое таблиц (включая сообщения, отправленные
// уже после миграции), кладёт его в блоб и снимает маркер миграции.
// Таблицы при этом очищаются, чтобы повторный запуск нового кода начал
// миграцию заново с честного состояния.
//
// Запуск (на сервере, при ОСТАНОВЛЕННОМ бэкенде):
//   RODNYA_POSTGRES_URL=postgres://... node scripts/restore-chat-collections-to-blob.js
//   ...или с LINEAGE_POSTGRES_URL / DATABASE_URL — как у самого бэкенда.
// Опции: --dry-run (только показать объёмы), --schema/--table/--row-id как env.

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

    // Guard: без маркера миграция НЕ выполнялась — сообщения ещё в блобе,
    // а таблицы пусты. Перезапись блоба «пустотой из таблиц» уничтожила бы
    // реальные данные. Обойти можно только осознанно через --force.
    const marker = state?.migrationStatus?.chatCollectionsToTables;
    if (marker !== "complete-v1" && !process.argv.includes("--force")) {
      throw new Error(
        `миграция не выполнялась (маркер='${marker || "нет"}') — откатывать нечего; ` +
          "если уверены, повторите с --force",
      );
    }

    const messages = (
      await client.query(`SELECT message_data FROM ${q("chat_messages")}`)
    ).rows.map((row) =>
      typeof row.message_data === "string"
        ? JSON.parse(row.message_data)
        : row.message_data,
    );
    const reactions = (
      await client.query(
        `SELECT message_id, user_id, emoji, created_at FROM ${q("chat_reactions")}`,
      )
    ).rows.map((row) => ({
      messageId: row.message_id,
      userId: row.user_id,
      emoji: row.emoji,
      createdAt: row.created_at,
    }));
    const drafts = (
      await client.query(`SELECT draft_data FROM ${q("chat_drafts")}`)
    ).rows.map((row) =>
      typeof row.draft_data === "string" ? JSON.parse(row.draft_data) : row.draft_data,
    );
    const pins = (
      await client.query(`SELECT pin_data FROM ${q("chat_pins")}`)
    ).rows.map((row) =>
      typeof row.pin_data === "string" ? JSON.parse(row.pin_data) : row.pin_data,
    );

    console.log(
      `Таблицы: messages=${messages.length} reactions=${reactions.length} ` +
        `drafts=${drafts.length} pins=${pins.length}; ` +
        `блоб сейчас: messages=${(state.messages || []).length}, ` +
        `маркер=${state.migrationStatus?.chatCollectionsToTables || "нет"}`,
    );
    if (dryRun) {
      console.log("--dry-run: ничего не изменено");
      return;
    }

    const nextState = {
      ...state,
      messages,
      messageReactions: reactions,
      chatDrafts: drafts,
      chatPins: pins,
      migrationStatus: {...(state.migrationStatus || {})},
    };
    delete nextState.migrationStatus.chatCollectionsToTables;

    await client.query("BEGIN");
    await client.query(
      `UPDATE ${stateTable} SET data = $2::jsonb, updated_at = NOW() WHERE id = $1`,
      [rowId, JSON.stringify(nextState)],
    );
    await client.query(`DELETE FROM ${q("chat_messages")}`);
    await client.query(`DELETE FROM ${q("chat_reactions")}`);
    await client.query(`DELETE FROM ${q("chat_drafts")}`);
    await client.query(`DELETE FROM ${q("chat_pins")}`);
    // Архивируем старый бэкап: у повторной миграции должен появиться СВЕЖИЙ
    // снапшот (write-once id иначе оставил бы устаревший).
    await client.query(
      `UPDATE ${q("chat_backups")}
          SET id = id || '-restored-' || $1
        WHERE id = 'pre-migration-complete-v1'`,
      [Date.now().toString(36)],
    );
    await client.query("COMMIT");
    console.log("Готово: чат-коллекции возвращены в блоб, маркер снят, таблицы очищены.");
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
