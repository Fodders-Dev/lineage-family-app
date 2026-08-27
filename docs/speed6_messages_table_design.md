# SPEED-6: сообщения чатов — из JSONB-блоба в таблицы

> 2026-08-26. Ветка `speed6-messages-table`. **Merge = deploy только по явному
> «го»** (правило из speed_measurement.md): бут-миграция прод-БД, локально
> полностью не доказуема (pg-mem — подмножество Postgres).

## Зачем (свежий замер, 2026-08-26)

Блоб похудел с 4.8 МБ до **~1 МБ** (ежедневный sweep дочистил
`treeChangeRecords` старше 30 дней), но гейт всё равно сработан с запасом:

| метрика (20 сообщений подряд, прод) | значение |
|---|---|
| client send-to-ack p50 / p95 | **1533 / 2031 мс** (цель <300) |
| server `access` | ~150–430 мс |
| server `persist` | ~670–1720 мс |
| server `fanout` | 1.3 с → **7.4 с** (растёт под бёрстом) |

Вывод: цена не в размере блоба как таковом, а в архитектуре — каждый send
это whole-blob RMW в глобальной `_mutateQueue`, и persist сообщения N+1
ждёт в очереди позади фан-аут-записей сообщения N (clearChatDraft,
markChatMessageDelivered, createNotification — всё это blob-RMW).

## Архитектура

**Чаты остаются в блобе** (41 запись; звонки/deleteUser/merge персон читают
их внутри `_mutate`-applyFn — трогать нельзя), но зеркалятся в
projection-таблицу `<t>_chats_projection` + `<t>_chat_participants`
(паттерн auth_users/auth_sessions, синк по хэшу в `_write`). Access-check
(`findChat`) стал индексным SELECT.

**Сообщения, реакции, черновики, пины — только в таблицах**:

- `<t>_chat_messages(id PK, chat_id, sender_id, ts, client_message_id,
  expires_at, haystack, dedup_key UNIQUE, message_data JSONB)`;
  индексы `(chat_id, ts, id)`, `(sender_id)`, `(expires_at)`.
  `dedup_key = chat|sender|clientMessageId` (или id, если client-id нет) —
  полный уникальный индекс вместо партиального (партиальные ломают pg-mem).
  NULL-колонок нет — пустая строка как «нет значения» (тот же pg-mem-баг
  с параметризованным NULL + IS NULL).
- `<t>_chat_reactions(message_id, user_id, emoji, created_at, PK все три)`.
- `<t>_chat_drafts(user_id, chat_id, draft_data, PK пара)`.
- `<t>_chat_pins(chat_id PK, message_id, pin_data)`.
- `<t>_chat_backups` — снапшот исходных массивов перед миграцией.

**Send = один INSERT вне `_mutateQueue`.** Ack-путь целиком:
`findChat` (SELECT по projection) → `isUserBlockedBetween` (LATERAL по
blob'ному `blocks`, с фолбэком) → `addChatMessage` (pre-SELECT dedup +
INSERT). Ожидание: ack ≈ RTT + ~10–20 мс серверных.

## Миграция (бут, идемпотентная)

`_migrateChatCollectionsToTables()` в `_bootstrap`:
маркер `migrationStatus.chatCollectionsToTables='complete-v1'` в блобе;
до переноса исходные массивы сохраняются в `<t>_chat_backups`;
`chatId` сообщений/черновиков/пинов **канонизируется** (`a_b`
сортированный) — рантайм работает по одному id вместо alias-набора.
После переноса блоб-коллекции очищаются.

Отказоустойчивость: если недоступно само чтение состояния (БД лежит) —
warn и старт в деградированном режиме (retry на следующем буте); если
миграция упала ПОСЛЕ успешного чтения — **бут падает** (защита от
split-brain «сообщения в блобе, чтение из пустых таблиц»).

## Откат

`backend/scripts/restore-chat-collections-to-blob.js` (при остановленном
бэкенде): собирает АКТУАЛЬНЫЕ таблицы (включая новые сообщения) → кладёт в
блоб → снимает маркер → чистит таблицы. После этого работает бэкенд любой
версии.

## Намеренные отличия от FileStore-семантики

1. `chat.updatedAt` в блобе на send НЕ бампится (это был бы blob-RMW на
   каждое сообщение); `findChat` доводит `updatedAt` до `MAX(ts)` из
   таблицы, превью сортируются по timestamp последнего сообщения.
2. `deleteUser` не уничтожает сообщения «виртуальных» direct-чатов ТРЕТЬИХ
   лиц (в FileStore это латентный баг: фильтр `activeChatIds` выкидывал все
   сообщения несохранённых чатов); табличная версия удаляет только то, где
   пользователь отправитель/участник, плюс сообщения удалённых чатов.
3. `removeTreeForUser` каскадит черновики/пины/реакции чатов дерева
   (FileStore оставлял сироты — отмечено в аудите как долг).
4. Сниппеты поиска строятся `buildChatSearchSnippet` (как в FileStore),
   а не `ts_headline` — сниппеты на прод теперь идентичны dev.
5. Гонка одинаковых `clientMessageId` упирается в уникальный `dedup_key`
   (unique violation → возврат существующего), а не в сериализацию очереди.

## Тесты

- `backend/test/postgres-chat-tables.test.js` — 11 сквозных сценариев на
  pg-mem с НАСТОЯЩИМ SQL: миграция, send/dedup, виртуальный direct,
  пагинация (before/after/неизвестный курсор), receipts/unread, реакции,
  edit/delete (+каскад пина), черновики, пины, поиск (+доступ), TTL+sweep,
  deleteUser-каскады.
- `postgres-store.test.js` «communication hot paths» переписан на pg-mem
  (раньше — substring-фейк, который не проверял сам SQL).
- Полный бэкенд-набор: **633/633**.

## Деплой-план (когда будет «го»)

1. Снять свежий дамп БД (обычный ночной + ручной перед выкаткой).
2. Merge ветки → deploy (бут сам мигрирует; в journalctl строка
   `chat collections migrated to tables {...}` с количествами).
3. Смоук: send-to-ack по `[send-timing]` (ожидание: ack < 100 мс серверных),
   история/превью/поиск/реакции через приложение.
4. Наблюдение ~неделя; откат — скриптом выше.
5. Следующий кандидат после обкатки: `notifications` и `pushDeliveries`
   из блоба (фоновые blob-RMW на каждый пуш остались).
