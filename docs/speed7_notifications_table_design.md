# SPEED-7: notifications + pushDeliveries — из JSONB-блоба в таблицы

> 2026-08-29. Ветка `speed7-notifications-tables`. **Merge = deploy только по
> явному «го»** (правило миграционных веток): бут-миграция прод-БД, локально
> полностью не доказуема (pg-mem — подмножество Postgres).

## Зачем (замер 2026-08-29)

Блоб после гигиены — 978 КБ; notifications 312/160 КБ, pushDeliveries 24/10 КБ.
Размер — не боль. Боль — **write-амплификация фан-аута**: каждый
`createAndDispatchNotification` = `_mutate`-RMW всего блоба, плюс по
1 `createPushDelivery` + 1-2 `updatePushDelivery` НА КАЖДОЕ устройство —
все голыми `_read/_write` парами, каждая — сериализация и запись всего
блоба. Документированный остаток после SPEED-6: «всплески access/persist
до ~300мс под бёрстом = CPU-контеншн фоновых блоб-записей фан-аута».
Базлайн «до» (2 дня): send p50/p95 access 1/2мс, persist 14/18мс, ack
16/19мс — под бёрстом деградирует.

## Архитектура (только PostgresStore; FileStore/dev остаётся на блобе)

**Обе коллекции уезжают из блоба целиком** (в отличие от чатов, никакой
projection не нужен: их никто не читает внутри `_mutate`-applyFn чужих
операций — только пишет).

- `<t>_notifications(id TEXT PK, user_id, type, created_at, read_at TEXT
  NOT NULL DEFAULT '', silent INT NOT NULL DEFAULT 0, coalesce_key TEXT
  NOT NULL DEFAULT '', notification_data JSONB)`;
  индексы `(user_id, created_at, id)`, `(user_id, read_at)`,
  `(user_id, coalesce_key)`.
  NULL-колонок нет: `read_at=''` = непрочитано (pg-mem-грабли с
  параметризованным NULL); silent как INT 0/1.
- `<t>_push_deliveries(id TEXT PK, notification_id TEXT NOT NULL DEFAULT '',
  user_id, device_id, provider, status, created_at, updated_at,
  delivery_data JSONB)`; индексы `(user_id, created_at)`, `(device_id)`.
- `<t>_notification_backups` — снапшот исходных массивов перед миграцией.

**`coalesce_key`** — вычислимый ключ коалесинга, `computeNotificationCoalesceKey`:
- `story_reaction` → `type|storyId|actorUserId`
- `post_reaction` → `type|postId|actorUserId`
- `comment_reaction` → `type|commentId|actorUserId`
- `comment_reply` → `type|parentCommentId|actorUserId`
- типы `_notifyReviewers` (merge/identity ревью) → `type|proposalId|claimId`
- прочие → `''` (без коалесинга).
Не уникальный индекс (несколько ПРОЧИТАННЫХ с тем же ключом легальны);
dedupe = SELECT unread по ключу → UPDATE (bump body/emoji/createdAt,
readAt сброс) или INSERT — та же гонко-семантика, что у нынешних голых
`_read/_write` пар (не хуже).

### Пути записи

1. **Явные оверрайды PostgresStore** (горячие/коалесинг):
   `createNotification` (INSERT вне очередей), `listNotifications`,
   `countUnreadNotifications`, `markNotificationRead`,
   `markNotificationsReadByDataKey`, `addStoryReactionNotification`,
   `addPostReactionNotification`, `addCommentReactionNotification`,
   `addCommentReplyNotification`; `createPushDelivery`,
   `updatePushDelivery`, `listPushDeliveries`.
2. **Drain-страховка в `_write`** для унаследованных inline-путей
   (`_notifyReviewers` внутри `listPendingMergeProposalsForUser` и
   `createIdentityClaim`, `article_block_conflict` в `updateArticleBlock`,
   всё забытое/будущее): перед записью блоба непустые
   `data.notifications`/`data.pushDeliveries` переливаются в таблицы
   (для notifications — с SQL-дедупом по `coalesce_key` unread: хит → skip,
   что соответствует `continue` в `_notifyReviewers`) и обнуляются.
   Блоб-массивы после миграции — «транзитная очередь», в состоянии покоя
   всегда пустые.

### Каскады (переиспользуют предикаты FileStore, фильтрация в JS)

- `deleteUser`: после `super.deleteUser()` (блоб-часть) — SELECT всей
  notifications-таблицы → те же JS-предикаты (data.userId/senderId/… ===
  userId, мёртвые chatId/treeId/postId/…) → DELETE по id; push_deliveries:
  DELETE user_id + сироты по notification_id. Сотни строк — дёшево,
  deleteUser редкий; зато byte-parity с FileStore-логикой без
  jsonb-SQL-сюрпризов в pg-mem.
- `removeTreeForUser`: то же по `data.treeId` (обе ветки: hard-delete и leave).
- `deletePushDevice` / `unbindPushDevicesForSession`: DELETE по device_id.

### Retention

`hardDeleteExpired` в PostgresStore: `super.hardDeleteExpired()` (блоб-часть;
там notifications/pushDeliveries уже пустые) + SQL-DELETE по таблицам:
notifications — три окна (silent=1 && created_at < now-48h; read_at!='' &&
< now-30d; unread < now-365d; ISO-строки сравниваются лексикографически),
записи с пустым/непарсибельным created_at не трогаются (как в FileStore);
push_deliveries — TTL 7д + cap newest-2000 (SELECT id ORDER BY created_at
ASC LIMIT overflow → DELETE). Счётчики — в тот же summary.logRetention.

## Миграция (бут, идемпотентная — по образцу SPEED-6)

`_migrateNotificationCollectionsToTables()` в `_bootstrap` (после
`_migrateChatCollectionsToTables`): маркер
`migrationStatus.notificationsToTables='complete-v1'`; бэкап обоих массивов
в `<t>_notification_backups`; построчный INSERT … ON CONFLICT DO NOTHING
(coalesce_key вычисляется при переносе); один UPDATE блоба — массивы
пустые + маркер. Ошибка после успешного чтения = throw (анти-split-brain,
как SPEED-6).

## Откат

`backend/scripts/restore-notifications-to-blob.js` (при остановленном
бэкенде): собирает АКТУАЛЬНЫЕ таблицы → кладёт в блоб → снимает маркер →
чистит таблицы. После этого работает бэкенд любой версии.

## Намеренные отличия от FileStore-семантики

1. Гонка коалесинга реакций может дать дубль вместо бампа (SELECT-then-
   UPSERT без уникального индекса) — сегодня та же гонка есть у голых
   `_read/_write`; не хуже.
2. `listNotifications` сортирует по `(created_at, id) DESC`; FileStore —
   обратный порядок вставки. Для реальных данных (createdAt=nowIso при
   вставке) порядок совпадает; синтетические равные createdAt
   упорядочиваются по id.
3. Каскад `deleteUser` для мёртвых ссылок сверяется с состоянием блоба НА
   МОМЕНТ каскада (как и раньше), но notifications других юзеров, ссылающиеся
   на удаляемого, теперь удаляются из таблицы, а не из массива — семантика
   та же.
4. `_notifyReviewers`-дедуп идёт через drain (SQL-проверка unread по
   coalesce_key) вместо скана массива — семантика та же, механизм другой.

## Тесты

`backend/test/postgres-notification-tables.test.js` на pg-mem с настоящим
SQL (по образцу postgres-chat-tables.test.js): миграция+бэкап+идемпотент,
create/list/count/markRead/markReadByDataKey, коалесинг реакций (бамп и
дубль-скип), drain из унаследованных путей, каскады deleteUser/
removeTreeForUser/deletePushDevice, retention-окна, push_deliveries CRUD.
Помнить pg-mem-грабли: без партиальных индексов, без параметризованного
NULL, без ESCAPE/\n в LIKE, CREATE TABLE IF NOT EXISTS не повторять.

## Репетиция (2026-08-30, scratch из прод-дампа)

Бут ветки против scratch-БД из свежего дампа
(`pre-speed7-rehearsal-20260829-1648.dump`):
- **находка**: на проде с апреля 2026 существовала `rodnya_state_notifications`
  СТАРОЙ схемы (notification_id PK, 6 мёртвых строк раннего эксперимента) —
  первый бут падал на CREATE INDEX; добавлена эвакуация несовместимой
  таблицы в backups + явные имена PK (`<t>_pk`). pg-mem это не ловил —
  ровно зачем нужна репетиция на реальном дампе;
- после фикса: **312 notifications + 24 pushDeliveries, 0 пропусков, ~3с**;
  блоб-массивы пусты, маркер стоит, в backups 2 снапшота (легаси-таблица
  + pre-migration), unread в таблице 300/312;
- второй бут идемпотентен (миграция не повторяется, данные нетронуты).

## Деплой-план (когда будет «го»)

1. Свежий ручной дамп БД → /opt/rodnya/backups/manual/.
2. Merge → deploy (бут мигрирует; в journalctl —
   `notification collections migrated to tables {...}`).
3. Смоук: лента уведомлений/unread-счётчик/пометка прочитанным через
   приложение; `[send-timing]` под бёрстом (ожидание: без всплесков до
   300мс); `GET /v1/push/deliveries` после тестового пуша.
4. Наблюдение ~неделя; откат — скриптом выше.
5. После обкатки блоб остаётся с users/trees/persons/chats/… — следующий
   кандидат решается по новым замерам.
