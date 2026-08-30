---
paths:
  - backend/src/store.js
  - backend/src/postgres-store.js
  - backend/test/**
---

# Инварианты стора (блоб + SPEED-6 таблицы)

## Контракт `_mutate` (store.js ~6072)

- Любая мутация блоба — ТОЛЬКО через `_mutate(applyFn)`: он сериализует весь
  read→mutate→write через `_mutateQueue` (закрывает whole-document lost-update).
- `applyFn` чистый и in-memory: НИКОГДА не вызывать внутри него
  `_read/_write/_mutate`. No-op/read-only пути — `return skip(x)`, чтобы не
  писать блоб зря (на Postgres это ещё и лишняя точка отказа записи).
- Голые пары `_read()+_write()` вне `_mutate` = lost-update баг (так уже
  ловили гонку в hard-delete job).

## SPEED-6: чаты в таблицах — намеренная архитектура

- Сообщения/реакции/черновики/пины живут ТОЛЬКО в таблицах
  `<t>_chat_messages/_chat_reactions/_chat_drafts/_chat_pins`; send = один
  INSERT **намеренно ВНЕ `_mutateQueue`** (иначе ack ждал бы блоб-записи
  фан-аута). Не «возвращать» их в очередь.
- Записи чатов остаются в блобе (их читают звонки/deleteUser/merge внутри
  applyFn) и зеркалятся в `<t>_chats_projection` + `_chat_participants`
  (hash-синк в `_write`).
- Намеренные отступления от FileStore-семантики задокументированы в
  `docs/speed6_messages_table_design.md` (chat.updatedAt не бампится на send;
  dedup через UNIQUE `dedup_key`, а не сериализацию; каскады deleteUser) —
  НЕ «чинить обратно».
- Receipt/edit-пути сериализованы `_enqueueChatRowMutation` — не убирать,
  иначе конкурентные delivered-ack'и теряют друг друга.
- Канонический id директ-чата = отсортированные userId через `_`; НО id вида
  `chat_<uuid>` (группы/ветки) канонизировать НЕЛЬЗЯ — parse делит их на две
  части и сортировка переставляет (~81% uuid).

## SPEED-7: notifications/pushDeliveries в таблицах (ветка; после мерджа — прод)

- Обе коллекции — ТОЛЬКО в таблицах `<t>_notifications` / `<t>_push_deliveries`
  (PostgresStore); блоб-массивы — «транзитная очередь» для унаследованных
  inline-путей, `_write` их дренирует. НЕ писать в таблицы из applyFn.
- Гейт `_notificationTablesReady`: false → все оверрайды делегируют в
  FileStore-путь по блобу, drain выключен. Не убирать: без него транзиентный
  сбой миграции на буте травит write-once бэкап пустотой.
- Каскад deleteUser берёт removed-множества ИЗ result FileStore.deleteUser —
  НЕ реконструировать дифом блоба до/после (гонка с чужими удалениями, P0).
- Коалесинг реакций — планы `build*NotificationPlan` + единый
  `computeNotificationCoalesceKey`; тексты уведомлений живут ТОЛЬКО в планах.
- PK новых таблиц — явные имена `<t>_pk` (дефолтный `_pkey` конфликтует с
  осиротевшими именами после DROP легаси-таблиц; на проде была таблица
  старой схемы с апреля 2026 — эвакуируется в backups автоматически).
- Откат: `restore-notifications-to-blob.js` (бэкенд остановлен, guard по
  маркеру `migrationStatus.notificationsToTables`).

## pg-mem (тесты с реальным SQL)

`backend/test/postgres-chat-tables.test.js` гоняет настоящий SQL на pg-mem —
это подмножество Postgres:
- партиальные индексы ЛОМАЮТ pg-mem (строки «исчезают» из фильтров) — только
  полные индексы (отсюда вычисляемый `dedup_key`);
- параметризованный NULL + `IS NULL` не работает — индексные колонки без NULL,
  «нет значения» = пустая строка;
- `ESCAPE` в LIKE не парсится; `\n` в строках ломает LIKE (haystack пишем
  однострочным); повторный `CREATE TABLE IF NOT EXISTS` существующей таблицы
  падает.
- Бут-миграции доказываются полностью только на реальном Postgres — ветки с
  прод-БД-миграциями мержатся ТОЛЬКО по явному «го» пользователя.

## Тесты

- `postgres-store.test.js` — substring-фейки пулов: новый SQL требует новых
  веток в фейках; запрет full-state-чтений включается ПОСЛЕ initialize
  (бут-миграции легитимно читают блоб один раз).
- `api.test.js` — только FileStore; редкие Windows-ENOTEMPTY флейки в
  параллельном прогоне: перегнать файл изолированно, прежде чем чинить.
