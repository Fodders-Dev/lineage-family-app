# Message-send speed — how to measure (and the SPEED-6 gate)

SPEED-1..5 are shipped (backend live; client in 1.0.26+34 via OTA). SPEED-6 (move
messages out of the whole-document JSONB into an append-only `chat_messages` table,
send = INSERT) is the only remaining structural item — a **prod-DB data migration,
not fully testable locally**. Decision rule: **do it only if real numbers still fall
short after 1–5.** Instrumentation is already in the code; here's how to read it.

---

## MEASURED 2026-07-13 on a real device (Galaxy S20 FE, 1.0.26+34) — the gate is TRIPPED, but not where we assumed

Numbers (single message, no backlog; smoke-test chat):
- **client `tap-to-bubble` ~26 ms** — optimistic UI works; the bubble is instant regardless of the server.
- **client `send-to-ack` ~2.5 s** — the ✓ takes ~2.5 s even for one message; worse (4–5 s, climbing) under rapid fire.
- **server split:** `access ~830 ms` + `persist ~1580 ms` = `ack ~2360 ms`. Almost the entire wait is server-side.

**Root cause — not network, not client, not "chat too big":** the ENTIRE app is stored as
ONE Postgres row / ONE JSONB blob (`public.rodnya_state`, `id='default'`), measured at
**8.0 MB**. Every write reads+parses the whole 8 MB (the access-check reads it once,
then `_mutate` reads it again), appends, and rewrites all 8 MB — and the global
`_mutateQueue` serializes every write app-wide. So `persist` is `O(total app size)`,
not `O(this message)`.

**Blob breakdown (why scoped SPEED-6 alone barely helps):**
| key | size | note |
|---|---|---|
| `treeChangeRecords` | 3.5 MB (43%) | tree + profile-article HISTORY (feature-backing; retention-trim, don't drop) |
| `graphPersons` | 617 KB | |
| `pushDeliveries` | 608 KB | delivery telemetry — pure log, prunable |
| `calls` | 570 KB | call log — prunable/cappable |
| `deletedPersons` | 529 KB | tombstones |
| `notifications` | 426 KB | high-churn |
| **`messages`** | **372 KB (4.5%)** | the actual chat messages |

**Messages are only 4.5% of the blob** — moving *just* messages into their own table
would remove almost none of the 3–4 s. The persist cost is dominated by the unbounded
history/log collections, above all `treeChangeRecords`. And even a messages table won't
fix send speed alone, because the **access-check (~830 ms) also reads the whole blob**
to verify chat membership — chat metadata must leave the blob too, or be cached.

**Fix path (proper > cheap):**
1. **Retention hygiene (own-right correctness) — SHIPPED 2026-07-13.** `_sweepUnboundedLogs`
   in the daily `hardDeleteExpired` job caps/TTL-prunes the unbounded collections:
   `pushDeliveries` (>7d), `calls` (terminal >24h; busy never touched), `notifications`
   (silent >48h / read >30d / unread >365d), and strips `before/after/mergedFrom` snapshots
   from non-article `treeChangeRecords` >30d (record kept; client history never reads them).
   The job was also routed through `_mutate` (was raw `_read/_write` → lost-update race).
2. **Structural fix (Telegram-grade `ack`, deferred).** To get `ack` under ~300 ms you must
   take the hot-write collections out of the single blob into their own indexed tables —
   messages (send = INSERT) AND the chat membership/metadata read for the access-check, then
   the big logs. Staged, deploy-gated, not fully testable locally. SPEED-6 generalized.

### PROVEN RESULT — one-time prune on prod (2026-07-13)
A dry-run then live one-shot of the sweep on the prod blob removed 263 terminal calls,
1378 push deliveries, 464 old notifications (0 unread touched), and stripped 1757
tree-change snapshots. Re-measured on the same device:

| metric | before | after | Δ |
|---|---|---|---|
| blob size | 8.0 MB | 4.8 MB | −40% |
| server `access` | ~830 ms | ~470 ms | −43% |
| server `persist` | ~1580 ms | ~940 ms | −40% |
| client send-to-ack | ~2500 ms | ~1500 ms | −40% |
| tap-to-bubble | ~26 ms | ~28 ms | unchanged (optimistic UI) |

The proportional drop confirms persist is `O(blob size)`. The daily job keeps it trimmed
and keeps stripping `treeChangeRecords` as they age past 30d. tap-to-bubble was already
instant (optimistic UI) — the ~1.5 s that remains is the whole-blob rewrite, which only the
structural fix (step 2) removes.

The generic how-to-measure notes below still apply for re-checking after each step.

---

## Client — tap → bubble (target: <16 ms = one frame)
`PerfTrace('chat.tap-to-bubble')` in `lib/screens/chat_screen.dart` fires from the
send tap to the first frame with the optimistic bubble. In a debug/profile build,
`flutter logs` (or `adb logcat | grep '\[perf\]'`) shows:
```
[perf] chat.tap-to-bubble: 8ms
```
- <16 ms → the "Telegram instant" feel is achieved (SPEED-1 did this). This number is
  network-independent, so it should already be tiny. If it isn't, that's a client
  jank bug, NOT a reason for SPEED-6.

## Client — tap → ack (the «часики → галочка», network-bound)
`PerfTrace('chat.send-to-ack')` (already existed) logs the full round-trip:
```
[perf] chat.send-to-ack: 180ms
```
- Target p50 <300 ms, p95 <800 ms on mobile data (Nielsen/RAIL + RU-RTT ~20–80 ms).
  SPEED-2/3/4 attack this. If p95 is comfortably under target → **SPEED-6 not needed.**

## Server — where the ack ms go
Every send logs a grep-able line (`ssh` to prod, `journalctl -u rodnya-backend -f` or
the app log), split into phases:
```
[send-timing] chat=<id> access=<ms> persist=<ms> ack=<ms> dedup=false
[send-timing] chat=<id> fanout=<ms> recipients=<n>
```
- `ack` = time to the sender's 200 (auth + access read + persist). This is what the
  user feels. `fanout` runs AFTER the ack (backgrounded) — it does NOT delay the user.
- **The SPEED-6 signal:** watch `persist`. Today it's a whole-document read-modify-write,
  so it grows with total chat history and serializes under concurrent senders (the
  global `_mutateQueue`). If `persist` is a few ms and flat → the JSONB store is fine at
  this scale, **skip SPEED-6.** If `persist` climbs into tens/hundreds of ms as history
  grows, or `ack` p95 balloons when several people send at once → **that's the trigger**
  to build SPEED-6.

## How to sample honestly
1. On a real RuStore-installed device (not emulator), send ~20 messages fast in a busy
   group chat; collect `chat.send-to-ack` p50/p95 from `[perf]` logs.
2. On the server, grep `[send-timing]` over the same burst; note `persist` and whether
   `ack` inflates under the concurrent senders.
3. Repeat once the chat has a large history (the JSONB store degrades with size).

If both client p95 and server `persist` stay under target across those → **1–5 already
delivered Telegram-grade send speed; SPEED-6 is premature optimization.** If not, build
SPEED-6 on a branch (PostgresStore overrides for addChatMessage + message reads +
markDelivered + unread + reactions + search + a JSONB→table migration; dedup on
(chatId, senderId, clientMessageId)); merge = deploy only on an explicit go, with prod
validation — it can't be fully proven locally (postgres-store tests run on a mock).

---

## RE-MEASURED 2026-08-26 — gate still tripped at a 1 MB blob; SPEED-6 built on a branch

Daily sweep shrank the blob to ~1 MB (441 messages / 41 chats), yet a 20-message
API burst measured **send-to-ack p50 1533 ms / p95 2031 ms** (server: access
150–430 ms, persist 670–1720 ms, fanout climbing to 7.4 s). The cost is
architectural: every send is a whole-blob RMW serialized in the global
_mutateQueue BEHIND the previous message's fanout writes.

The structural fix is implemented on branch **`speed6-messages-table`**
(messages/reactions/drafts/pins → tables, send = INSERT; chats stay in the
blob with a fast projection for the access check). Design, migration,
rollback script and deploy plan: `docs/speed6_messages_table_design.md`.
Merge = deploy only on an explicit go.

### DEPLOYED + PROVEN 2026-08-27 — SPEED-6 live: send-to-ack p50 74 ms (was 1533)

Squash-merged and deployed on Артём's go. Boot migration moved 441 messages /
3 reactions / 2 drafts to tables (0 skipped), blob marker set. A follow-up fix
removed the write-queue barrier from chat-table methods (it made access wait up
to ~300 ms for fanout blob writes).

| metric (20-msg burst, prod, same client) | before SPEED-6 | after |
|---|---|---|
| client send-to-ack p50 | 1533 ms | **74 ms** |
| client send-to-ack p95 | 2031 ms | **250 ms** |
| server access | 150–430 ms | **1–3 ms** |
| server persist | 670–1720 ms | **8–11 ms** |

Functional sanity on prod tables: history/pagination/dedup/previews/unread/
search/reactions/mark-read — all pass. Rollback stays available via
backend/scripts/restore-chat-collections-to-blob.js + the pre-deploy dump
(/opt/rodnya/backups/manual/pre-speed6-20260827-0916.dump).

### SPEED-7 задеплоен 2026-08-30 — notifications+pushDeliveries тоже вынесены

Squash `158bdf9`: notifications и pushDeliveries больше не пишутся в блоб —
фан-аут теперь делает INSERT в собственные таблицы (с SQL-дедупом по
coalesce_key для реакций) вместо RMW всего блоба. Редкие всплески
access/persist до ~300мс под бёрстом, оставленные SPEED-6 как известный
остаток, больше не должны воспроизводиться. Если они всё же появятся снова —
причина уже НЕ блоб-фан-аут (смотреть pg-индексы таблиц / нагрузку VPS, не
возвращать коллекции в блоб). Дизайн и цифры репетиции/деплоя:
`docs/speed7_notifications_table_design.md`. Наблюдение ~неделя с 30.08.

## Замер на новом сервере (31.08.2026, РФ)

После переезда (77.91.113.109, HOSTKEY) первый замер дал p50 70мс при p95
**567мс** — всплески пошли изнутри. Разбор: БД ни при чём (коммит в
Postgres 16 стабильно 2–8мс), в логах видно `fanout=534ms`, за которым
СЛЕДУЮЩАЯ отправка ждёт в `access=467ms`.

Причина — единственный оставшийся блоб-читатель в горячем пути:
`listPushDevices` в фан-ауте пушей. На PostgresStore любой `_read()` это
полный цикл (SELECT ~1МБ JSONB + JSON.parse + `_syncGraphFromLegacy` +
`structuredClone` + запись sidecar-кэша) — сотни мс блокировки event-loop
на каждый пуш. Заменено точечным SQL по блобу (развёртка массива в
подзапросе; LATERAL нельзя — pg-mem не резолвит внешнюю колонку).

Итог после фикса: **client p50 43мс / p95 64мс**, server access 2–3мс,
persist 12–18мс, max fanout 57мс (было 534).

Урок на будущее: цена не в размере блоба, а в КАЖДОМ его чтении из
горячего пути. Прежде чем выносить очередную коллекцию в таблицы — сначала
посмотреть, кто зовёт `_read()` там, где счёт идёт на миллисекунды.

## SPEED-8a — кэш чтения PostgresStore по версии строки (03.09.2026)

Симптом: `GET /v1/trees/:id/persons` (список людей для «Дерева» и «Родных»)
у реальных пользователей **p50 1,5 с / p95 3,1 с / max 4,3 с** (85 запросов
за сутки, дерево на 41 человека). Обработчик тривиален, но findTree +
findMembership + listPersons + listHiddenPersonIdsForCaller = 4–5 полных
`_read()`, а каждый `_read()` = SELECT блоба ~1 МБ + parse + запрос сессий +
два хэша + `_syncGraphFromLegacy` + `structuredClone` + запись 1 МБ
sidecar-файла ≈ 350 мс.

Фикс (commit a638d9a): `rodnya_state.version BIGINT`, каждый писатель строки
инкрементит её (UPSERT в `_write` с `RETURNING version`, бут-миграции,
зеркало сессий, fast-path createPerson; статический тест сторожит), `_read()`
сначала сверяет `version` с кэшем и при совпадении отдаёт клон кэша со
свежими сессиями. Нет колонки → кэш выключен, чтение честное.

| метрика | до (03.09 утро) | после (03.09 16:00) |
|---|---|---|
| GET persons, тестовое дерево (3 чел.), с сервера через Caddy | 520–600 мс | 154–322 мс |
| GET persons, реальные деревья, p50 / p95 | 1,5 с / 3,1 с | наблюдение ~неделя |
| slow-request по persons за сутки | 85 | 0 за первые часы |
| version после create → delete | — | 0 → 1 → 2, ответы согласованы сразу |

Репетиция: копия прод-дампа, второй инстанс на :8090 — ответ persons
идентичен проду, persons 60–115 мс на localhost.

Что кэш НЕ лечит: пути на точечном SQL по блобу (`LATERAL
jsonb_array_elements`) — `/v1/posts` даёт ~750 мс и с кэшем. Следующий
кандидат SPEED-8b: `treeChangeRecords` (1,5 МБ текста, 3046 записей) и
`hardDeleteAudit` (0,65 МБ) — вон из блоба.

## SPEED-8b — treeChangeRecords и hardDeleteAudit из блоба (03.09.2026, 23:32)

Блоб: `treeChangeRecords` 1,5 МБ текста (3053 записи с апреля) и
`hardDeleteAudit` 0,65 МБ — две трети объёма, который парсится при каждой
перезагрузке кэша SPEED-8a и сканируется каждым точечным SQL по блобу.
Обе коллекции append-only и не читаются внутри `_mutate` — вынесены целиком
по схеме SPEED-7 (бэкап → INSERT → маркер `treeChangeRecordsToTables`).
Новые записи по-прежнему рождаются в блобе внутри мутаций и дренируются в
таблицу на `_write`; правки старых (слияние дублей, псевдонимизация,
ретенция) — хуки FileStore, PostgresStore ставит табличную операцию в
очередь, `_write` применяет после UPSERT.

| метрика | до | после |
|---|---|---|
| блоб `rodnya_state` | 975 КБ | **482 КБ** |
| миграция на проде | — | 3053 записи + 2550 аудита, 0 пропущенных, ~1 с при старте |
| `/v1/trees/:id/history` | из блоба | из таблицы; ответ до/после идентичен |
| GET persons (с сервера, HTTPS) | 154–322 мс (после 8a) | 160–220 мс |
| GET history | — | 120–160 мс |
| `/v1/posts` | ~750 мс | ~750 мс — блоб ни при чём, см. SPEED-8c |

Откат: `scripts/restore-tree-change-records-to-blob.js` (проверен на копии
дампа: блоб 481 → 975 КБ, маркер снят; повторная миграция идемпотентна).
Пред-деплойный дамп: `/opt/rodnya/backups/manual/pre-speed8b-20260903-203120.dump`.
Наблюдение ~неделя, затем — как SPEED-6/7.

## SPEED-8c — сверка кругов на чтении ленты (04.09.2026)

`GET /v1/posts` держался на ~750 мс и после кэша чтения (8a), и после
похудения блоба (8b) — значит, не I/O. CPU-профиль (`node --cpu-prof`,
прод-блоб на FileStore, 30 запросов): **77% busy-времени — `ensureCirclesForAllTrees`**
внутри `listPosts`: на каждое чтение ленты для КАЖДОГО из 25 деревьев
пересобирались авто-круги, а `ensureAutoCirclesForTree` перед этим звал
`backfillPersonIdentities(db)` по всей базе — тот дважды хэширует все
persons+identities (`stableSerialize` + sha256). 50 полных сериализаций
базы на один GET при неизменных данных. Плюс результат сверки писался в
блоб из читающего пути в обход `_mutate` (lost-update).

Фикс (store.js, поведение FileStore и PostgresStore одинаковое):
- бэкфилл идентичностей из сверки авто-кругов — только если у людей ЭТОГО
  дерева реально нет `identityId` (легаси-данные обслуживаются, устоявшиеся
  не хэшируются);
- ленты (posts/stories/gatherings/polls) больше не сверяют круги всех
  деревьев и не пишут блоб: круги нужного дерева лениво сверяет
  `_canUserViewCircleContent` в памяти запроса; хранимое состояние чинят
  мутации графа и `listCircles`/`findCircle` (как и раньше).

| метрика (локально, прод-блоб на FileStore) | до | после |
|---|---|---|
| `GET /v1/posts`, среднее по 30 | 237 мс | **34 мс** |
| из них сверка кругов | ~180 мс | ~1 мс (только дерево поста) |
| `GET /v1/posts` на проде, HTTPS с этой машины, 15 замеров (деплой 513210f, 04.09 10:26) | p50 657 / p90 998 мс | **p50 84 / p90 103 мс**, slow-request по /posts — 0 |

Тесты: `test/circles-reconcile.test.js` — лента не пишет блоб и не чинит
чужие деревья; видимость по авто-кругу работает и без сохранённых кругов;
бэкфилл всё ещё срабатывает для людей без `identityId`.
