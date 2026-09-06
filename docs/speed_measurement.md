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

## SPEED-8d — identity-suggestions: двойной _read() + пересборка графа родства на каждого кандидата (05.09.2026)

`GET /v1/trees/:treeId/persons/:personId/identity-suggestions` (💡-индикатор
«этот человек уже есть в другом дереве», клиент батчит по одному вызову на
каждую видимую карточку канваса) держался в топе slow-request лога прода:
41 запрос/сутки, p50 648 мс, max 2,3 с на дереве в 41 человека при базе
~400. CPU-профиль (`node --cpu-prof`, копия прод-блоба на FileStore, 820
вызовов = 20 повторов × 41 personId) показал `_read()` на **~74% busy-
времени** — в основном это уже задокументированная (`docs/connected-trees-
refactor/week-1/BACKEND-AUDIT.md`) идемпотентная full-scan пересборка графа
`_syncGraphFromLegacy` на каждом `_read()`/`_write()`, O(persons+relations+
trees); её убирает только запланированный Phase 3.4 cutover — трогать это
здесь НЕ стали (чужой, App-wide, риск непропорционален тикету).

В границах самого хендлера нашлись три конкретных источника лишней работы:
1. **Два независимых `_read()` за один HTTP-запрос** —
   `findCrossTreeSuggestionsForPerson` и `filterLegacyPersonsByGraphVisibility`
   каждый сам читал блоб. На PostgresStore (SPEED-8a) даже кэш-хит — это
   `structuredClone` всего состояния + round-trip на версию/сессии + тот же
   `_syncGraphFromLegacy`; удвоение этого — чистые потери.
2. **`_userCanSeeGraphPerson`** для дефолтной видимости
   «connected-via-blood-graph» на КАЖДОГО из до `limit` (≤50) кандидатов
   заново резолвил self-graph-node viewer'а (линейный проход по
   `users`+`graphPersons`) и пересобирал blood-adjacency карту из
   `graphRelations` с нуля под BFS — притом что viewer и граф внутри одного
   вызова не меняются.
3. **`identity-matcher.js`**: `scorePersonPair` заново нормализовал ОБЕИХ
   персон (имя/токены/даты) на каждую пару, хотя `sourcePerson` в
   `findCrossTreeIdentitySuggestions` не меняется по циклу; плюс
   `normalizeIsoDate` дублировался внутри одного вызова (дата рождения и
   отдельно `normalizedBirthYear`), а `birthPlace` нормализовался до 4 раз.

| источник | до | после | ускорение | где измерено |
|---|---|---|---|---|
| 2×`_read()` → 1×`_read()` за запрос (непустой список кандидатов) | p50 18,54 мс | p50 8,32 мс | 2,23× | `bench_read_elimination.js`, реальный блоб |
| `_userCanSeeGraphPerson` на 10 кандидатов (self-id+adjacency разово vs на каждого) | p50 0,138 мс | p50 0,047 мс | 2,92× | `bench_visibility_batch_context.js`, реальный граф |
| то же на 50 кандидатов | p50 0,703 мс | p50 0,186 мс | 3,78× | там же |
| `findCrossTreeIdentitySuggestions` на ~400 persons (масштаб «база ~400») | p50 2,01 мс | p50 1,08 мс | 1,86× | `bench_matcher_scaling.js`, реальные записи размножены до 400 |

Все четыре сравнения проверены на идентичность результата (fingerprint
до/после совпадает побайтово) — контракт ответа не менялся.

Правки: `backend/src/routes/tree-routes.js` (один `_read()` на запрос,
передаётся в оба store-метода), `backend/src/store.js`
(`findCrossTreeSuggestionsForPerson` и `filterLegacyPersonsByGraphVisibility`
принимают опциональный уже прочитанный `db`; `_userCanSeeGraphPerson` и
`_findBloodRelationBetween` принимают опциональный `context`/`adjacency` —
без него поведение байт-в-байт прежнее, что и проверяют существующие
`branch-include-rules.test.js`/`graph-sync.test.js`), `backend/src/identity-
matcher.js` (`normalizePersonForScoring` + `scoreNormalizedPersons`,
`scorePersonPair` — тонкая обёртка над ними; within-tree и cross-tree
матчеры нормализуют каждого person'а один раз вместо одного раза на пару).

Что НЕ тронуто и почему: `requireTreeAccess` (`findTree`+`findMembership`,
до 2 доп. `_read()` на запрос) — общий helper для десятков маршрутов,
менять его в рамках одного эндпоинта неоправданно рискованно; `_syncGraph-
FromLegacy` — см. выше, отдельная запланированная миграция. На проде эти
два фактора, вероятно, объясняют бо́льшую часть оставшегося p50 648 мс,
чем то, что чинит этот тикет — так что итоговая цель <100 мс подтверждается
частично: CPU-часть в границах хендлера снижена в 1,9–3,8× с доказанной
идентичностью ответа, полная картина требует отдельного прод-замера после
деплоя (`/prod-diag`, slow-request лог по этому пути) и, возможно, той же
техники (передача `db`) в `requireTreeAccess`.

## SPEED-9 (D+A) — N+1 в ленте постов + O(N²) в _syncGraphFromLegacy (05.09.2026)

Анализ `docs/speed9_proposal.md` (метод SPEED-8c/8d: `node`-скрипты
напрямую через `FileStore`, без HTTP, на копии прод-блоба ~155 persons/144
relations/25 деревьев) нашёл две независимые находки; владелец продукта
утвердил обе к реализации (варианты B и C из документа — прогрев кэша при
старте — оставлены как есть/не в периметре).

### D — N+1 `_read()` в `GET /v1/posts`

`post-routes.js` считал `commentCount` циклом
`Promise.all(page.map(post => store.listPostComments(post.id)))` — на
странице из K постов это K независимых полных `_read()` блоба ПОВЕРХ 2-3
уже нужных (`requireTreeAccess`→`findTree`, `listUserTrees`, `listPosts`).
На PostgresStore (после SPEED-8a) каждый такой лишний `_read()` — это
`structuredClone` всего закэшированного состояния + 2 SQL round-trip'а
(SELECT version + SELECT всей таблицы sessions), см. §2 анализа.

Фикс: `store.listPostCommentsForPosts(postIds, {db})` — один `_read()` на
всю страницу, группирует `db.comments` по `postId` в памяти. Общий хвост
(сортировка по `createdAt`, hydrate `authorPhotoUrl` из `db.users`,
`attachCommentReactions`) вынесен в `hydrateAndSortPostComments` +
`buildUsersByIdMap` и используется ОБОИМИ `listPostComments` (одиночный,
как раньше — используется в 5 других местах post-routes.js, не тронуты) и
`listPostCommentsForPosts` — форма каждого элемента результата побайтово
совпадает между ними, поскольку это буквально один и тот же код, а не две
параллельные копии.

| метрика (страница из 20 постов, копия прод-блоба на FileStore, 155
persons/144 relations, посты — синтетика 3-5 комментариев с ответами и
реакциями) | до | после |
|---|---|---|
| `_read()` на запрос | 23 (K=20 + 3) | **4** (константа, не растёт с K) |
| median времени страницы (20 итераций) | 270,64 мс | **40,96 мс** (6,6×) |

Идентичность результата доказана на двух уровнях: (1) построчно —
`listPostCommentsForPosts(postIds).get(id)` побайтово равен
`listPostComments(id)` на том же db для каждого поста фикстуры с ответами
и реакциями; (2) на уровне HTTP — `commentCount` в обеих формах ответа
`GET /v1/posts` (легаси-массив без `limit` и `{posts, nextCursor}` с
`limit`) совпадает с прямым вызовом `listPostComments` по каждому посту.
Тесты: `backend/test/posts-n1-comments.test.js` — плюс регресс `_read()`
не растёт при увеличении страницы с 1 до 9 постов и с `limit=3` до
`limit=9` (сравнение внутри одной авторизованной сессии, чтобы разница не
объяснялась прогревом auth-кэша `findSession`/`findUserById`).

### A — `_syncGraphFromLegacy`: O(N²) → O(N)

Комментарий в store.js утверждал «O(persons + relations + trees) per
call, ... sub-millisecond» — это было неверно уже на момент SPEED-8d.
`_syncPersonToGraph` делал три линейных `.find()` на КАЖДОГО person
(`db.graphPersons`, `db.branchPersonViews`, `db.branches`);
`_syncRelationToGraph` + `_resolveGraphPersonIdForLegacy` — `.find()` по
`db.graphRelations` и дважды по `db.persons`/`db.graphPersons` на КАЖДУЮ
relation. Итог — `O(persons×graphPersons + relations×(graphRelations+
persons))` ≈ O(N²) над ГЛОБАЛЬНЫМИ коллекциями (все деревья пользователя
блоба разом, не одно дерево), с каждым `_read()`/`_write()`.

Фикс: `_buildGraphSyncIndex(db)` строит 6 `Map`-индексов ОДИН раз в начале
прохода (`graphPersonsById`, `graphPersonsByLegacyId`,
`branchPersonViewByKey`, `branchById`, `personsById`,
`graphRelationsByLegacyId`+`graphRelationsByDedupKey`) и передаёт их как
обязательный параметр `index` в `_syncPersonToGraph`/
`_syncRelationToGraph`/`_resolveGraphPersonIdForLegacy` (единственный
caller всех трёх — `_syncGraphFromLegacy`, других мест не было). Индексы
МУТИРУЮТСЯ этими же helper'ами по ходу прохода (новый graphPerson/view/
graphRelation, сдвиг dedup-ключа при смене типа отношения) — это
воспроизводит поведение живого `.find()` по массиву, который видел бы
изменения, сделанные РАНЕЕ в этом же вызове (иначе разошлось бы с тестом
"collapses identity-linked legacy persons across two trees onto one
graphPerson").

| N (persons≈relations, синтетика: цепочка parent→child в одном дереве) | до, мс (steady-state median) | после, мс | ускорение |
|---|---|---|---|
| 155 (масштаб копии прод-блоба) | 2,54 | 0,82 | 3,1× |
| 1240 | 140,87 | 6,75 | 20,9× |
| 2480 | 559,97 | 24,76 | 22,6× |

Рост 1240→2480 (×2 по N) теперь даёт ×3,7 времени (было ×4,1 — учебный
квадрат) — линейность подтверждена; абсолютные цифры «до» совпадают с
замером анализа (`bench_sync_scaling.js`: 136,42/559,69 мс) в пределах
шума JIT/итераций.

Идентичность результата доказана сравнением с ЗАМОРОЖЕННОЙ копией
дореформенного алгоритма (`backend/test/graph-sync-speed9-index.test.js`,
`referenceSyncGraphFromLegacy` — построчная копия старого кода) на
фикстуре с: дублями по `identityId` на разных деревьях (схлопывание в
один graphPerson с двумя `branchPersonViews`), create- и update-путём
(person без graphPerson vs person с устаревшими каноническими полями),
view, создаваемым поверх уже существующего graphPerson,
`_resolveGraphPersonIdForLegacy` через fallback (legacy person уже
удалён, резолвится только через `graphPerson.legacyPersonIds`), и
намеренно — двумя relations в одном проходе, где ПЕРВАЯ меняет тип связи
(сдвигая dedup-ключ существующей graphRelation), а ВТОРАЯ, ранее не
привязанная, обязана задедуплицироваться в неё же по НОВОМУ ключу —
единственный сценарий, где наивная «построил индекс один раз и забыл»
оптимизация разошлась бы с оригиналом. Плюс существующие
`graph-sync.test.js` (30 тестов) и `branch-include-rules.test.js` (31
тест) остались зелёными без изменений — включая идемпотентность
(повторный проход не плодит дублей и не меняет id).

Не тронуто и почему: комментарий про Phase 3.4 (helper исчезнет после
неё) оставлен — `docs/connected-trees-refactor/CURRENT-PHASE.md` явно
держит graph-слой навсегда, Phase 3.4 ушла в прод как UI-фича без снятия
легаси-зеркала; сама частота вызовов `_syncGraphFromLegacy` (Вариант B из
анализа — реже вызывать) не менялась, только его внутренняя сложность.

Тесты: `npm --prefix backend test` — **699/699**, ~19-21 с (флейков
`api.test.js` в этих прогонах не было).

## SPEED-9 B — один `_read()` на HTTP-запрос для `requireTreeAccess` + горячих GET-маршрутов бёрста входа (05.09.2026)

Прод-журнал 05.09: при входе клиента (в т.ч. по QR) приложение
выстреливает ~10-12 запросов за 1-2 с (`qr/start`,
`invitations/pending/process`, `merge-proposals/pending`,
`trees/:id/persons`, `polls`, `trees/:id/persons/:pid`,
`onboarding-state`, `trees/:id/graph`, `gatherings`, `stories`,
`notifications`, `chats/unread-count`), все по 530-760 мс — очередь на
одном Node-потоке, где каждый запрос делает 2-4 `_read()` (кэш-хит
PostgresStore = SQL `SELECT version` + `structuredClone` ~482 КБ + SQL
`SELECT` всей таблицы сессий, ~8 мс на вызов; SPEED-8a/§2 анализа
`docs/speed9_proposal.md`).

Из 12 маршрутов бёрста шесть реально резервируют лишние `_read()` в
рамках одного HTTP-запроса (по коду, federated-семьи ON — прод-default):

| маршрут | `_read()` до | `_read()` после (Postgres, прод) | `_read()` после (FileStore, тесты) |
|---|---|---|---|
| `GET /v1/trees/:id/persons` | 2-3 (`requireTreeAccess`→`findMembership` + `listPersons` + `listHiddenPersonIdsForCaller`) | **1** | 2 (`findTree` не SQL-scoped на FileStore — вне периметра) |
| `GET /v1/trees/:id/persons/:pid` | 2 (`findMembership` + `findPerson`) | **1** | 2 |
| `GET /v1/trees/:id/graph` | 2 (`findMembership` + `getTreeGraphSnapshot`) | **1** | 2 |
| `GET /v1/gatherings?treeId=` | 2 (`findMembership` + `listGatherings`) | **1** | 3 (`listUserTrees` тоже не scoped на FileStore) |
| `GET /v1/polls?treeId=` | 2 | **1** | 3 |
| `GET /v1/stories?treeId=` | 2 | **1** | 3 |

Остальные шесть маршрутов бёрста уже были минимальны и не тронуты:
`GET /v1/merge-proposals/pending` и `GET /v1/me/onboarding-state` —
по одному `_read()` без `requireTreeAccess` в цепочке; `GET
/v1/notifications` и `GET /v1/chats/unread-count` — 0 (таблицы SPEED-6/
7, блоб не читается); `POST /v1/auth/qr/start` и `POST
/v1/invitations/pending/process` — 0 явных чтений ДО своей мутации на
уровне обработчика (сама мутация делает 1 `_read()` внутри, что вне
периметра — правки `_mutate`-контракта не входят в задачу); ответ
`invitations/pending/process` строит `findTree` ПОСЛЕ мутации —
scoped SQL на Postgres, всегда свежий, трогать незачем.

### Механизм

`requireTreeAccess` (`backend/src/app.js`) в федеративной ветке
(`useSemyaModel && tree.semyaId`) раньше звал `store.findMembership`,
которая сама делает `_read()` — единственный полный blob-read внутри
хелпера на Postgres (сам `tree` резолвится `findTree`, scoped SQL,
0 blob-read). Теперь `requireTreeAccess` читает блоб явно один раз,
передаёт его в `findMembership(semyaId, userId, db)` и кладёт на
`req.storeSnapshot`:

```js
const db = req.storeSnapshot || (await store._read());
if (!req.storeSnapshot) req.storeSnapshot = db;
const membership = await store.findMembership(tree.semyaId, req.auth.user.id, db);
```

Если `requireTreeAccess` вызывается дважды за один запрос (например,
`link-identity` — source-дерево + target-дерево), второй вызов находит
`req.storeSnapshot` уже выставленным и не читает блоб снова — на весь
HTTP-запрос гарантирован максимум один такой `_read()`, независимо от
числа проверок доступа.

Обработчики шести маршрутов передают `req.storeSnapshot || null`
дальше в `listPersons`, `findPerson`, `listHiddenPersonIdsForCaller`,
`getTreeGraphSnapshot`, `listGatherings`, `listPolls`, `listStories` —
все получили новый опциональный последний параметр `db`/`{db}`
(паттерн SPEED-8d: `const db = prefetchedDb || (await this._read());`).
Без `req.storeSnapshot` (легаси-путь, `tree.semyaId` не задан, флаг
выключен) поведение — как раньше, честный собственный `_read()` на
каждый метод; ни один из ~40 остальных вызывающих `requireTreeAccess`/
этих семи store-методов по кодовой базе не меняет поведение (параметр
опционален, позиционные и объектные вызовы без него проходят как
есть — проверено `grep` по всем вызовам вне `store.js`).

**Свежесть после мутаций.** Снимок `req.storeSnapshot` — только для
чтения в рамках GET-обработчиков; ни один из шести оптимизированных
маршрутов не мутирует блоб. Отдельно проверены два маршрута из бёрста,
которые ПИШУТ: `POST /v1/auth/qr/start` (`createAuthHandoff`, 1 `_read`
внутри своей же bare-`_read+_write` пары — pre-existing, не трогали) и
`POST /v1/invitations/pending/process` (`linkPersonToUser` мутирует,
затем обработчик зовёт `store.findTree` уже ПОСЛЕ мутации — на
Postgres это scoped SQL по свежей строке, не кэш; отдавать данные из
устаревшего снимка здесь физически невозможно, потому что снимок
вообще не используется в этих двух обработчиках). Ни один из них не
трогает `req.storeSnapshot`.

### Идентичность и покрытие тестами

`backend/test/speed9-b-single-read.test.js` (9 тестов, FileStore,
федеративное дерево — `RODNYA_FEDERATED_SEMYI_ENABLED=true` в тесте):

1. Для каждого из 7 store-методов — результат с `prefetchedDb`
   побайтово (`deepEqual`, за вычетом `updatedAt`/`createdAt` — см.
   ниже) совпадает с результатом без него (собственный свежий
   `_read()`; на FileStore каждый `_read()` — независимый
   `JSON.parse`, так что это реальное сравнение двух независимых
   чтений одного неизменного состояния).
2. Для каждого из 6 маршрутов — точное число `_read()` за реальный
   HTTP-запрос (инструментированная обёртка над `store._read`)
   совпадает с ожидаемым (2 для persons/person-detail/graph, 3 для
   gatherings/polls/stories — на FileStore, где `findTree`/
   `listUserTrees` не scoped SQL) и меньше «наивной» до-фикса
   последовательности вызовов (`findTree` → `findMembership` без db →
   `listX` без db), посчитанной в том же тесте напрямую по стору:
   persons 4→2, person-detail 3→2, graph 3→2, gatherings/polls/stories
   4→3.
3. Отдельный тест перехватывает `db`-аргумент, реально дошедший до
   `findMembership`/`listPersons`/`listHiddenPersonIdsForCaller` за
   один запрос, и проверяет `===` (строгое совпадение ссылки) — прямое
   доказательство, что это ОДИН и тот же объект, а не совпадение по
   числу.
4. Обратная совместимость: при `RODNYA_FEDERATED_SEMYI_ENABLED`
   выключенном (`tree.semyaId` не участвует) legacy creator+memberIds
   gate работает как раньше, `req.storeSnapshot` не выставляется.

Побочная находка при написании теста (не связана с SPEED-9 B и не
чинилась — вне периметра задачи): `getTreeGraphSnapshot` отдаёт
нестабильный `people[].updatedAt` на двух подряд идущих вызовах БЕЗ
единой мутации между ними, если в дереве 2+ человека без связей друг с
другом (воспроизводится и без единой строки этой задачи — только
`buildTreeGraphSnapshot`/`buildFamilyUnits` над «одиночными»
family-unit'ами). Источник не найден (в самих builder-функциях нет
`nowIso()`/`Date.now()`), тест сравнивает результат без `updatedAt`/
`createdAt`, находка вынесена отдельной задачей в очередь.

### Замер: бёрст 12 запросов, копия прод-блоба (FileStore)

Метод — как в SPEED-8c/8d/9: копия прод-блоба (`local_db.json`, 155
persons/144 relations/25 деревьев/88 users/189 sessions), локальный
HTTP-сервер на `:8123` (не `:8095`), `RODNYA_FEDERATED_SEMYI_ENABLED=
true`. Дерево для бёрста — крупнейшее в копии (41 person, `semyaId`
задан); тестовый пользователь добавлен в его `semyaMembers` (роль
`viewer`) в РАБОЧЕЙ копии блоба (не в исходнике). 12 запросов бёрста
(порядок клиента) выстреливаются параллельно (`Promise.all`), прогон
повторён 12 раз подряд (144 запроса на конфигурацию), «до» — код на
`git stash` (родитель ветки), «после» — эта ветка; сравнение — на ТОЙ
ЖЕ машине, тех же двух прогонах каждый.

| маршрут | p50 до, мс (2 прогона) | p50 после, мс (2 прогона) |
|---|---|---|
| persons | 623, 539 | 454, 396 |
| polls | 623, 539 | 498, 457 |
| person-detail | 578, 452 | 454, 401 |
| graph | 577, 479 | 454, 409 |
| gatherings | 622, 543 | 518, 456 |
| stories | 628, 542 | 518, 467 |
| **весь бёрст (144 запроса)** | **p50 447/417, max 907/797** | **p50 376/363, max 677/659** |

Среднее по двум прогонам: p50 персон 581→425 мс (-27%), graph 528→432
(-18%), gatherings 583→487 (-16%), polls 581→478 (-18%), stories
585→493 (-16%), person-detail 515→428 (-17%); весь бёрст p50 432→370
(-14%), max 852→668 (-22%).

**Важная оговорка**: это FileStore, не PostgresStore — абсолютные
цифры НЕ прод-цифры и системно ЗАНИЖАЮТ реальный эффект. На FileStore
`findSession`/`findUserById` (SPEED-8a scoped-SQL только на Postgres)
тоже делают полный `_read()` — общий «пол» задержки на КАЖДЫЙ из 12
запросов бёрста (200-350 мс здесь) на проде отсутствует вообще
(scoped SQL, 0 blob-read), поэтому доля, которую съедают устраняемые
этой задачей `_read()`, на проде будет заметно больше относительно
общего времени запроса, чем показывают проценты выше. Наблюдаемая
здесь абсолютная экономия (~70-170 мс p50 на маршрут) — это в основном
цена ДВУХ FileStore-специфичных «бесплатных на Postgres» чтений
(`findTree`+`listUserTrees`), которые остаются и после фикса (см.
таблицу `_read()` выше, колонка FileStore) — то есть даже эта
экономия консервативна: на Postgres, где `findTree`/`listUserTrees`
уже 0, единственный устраняемый `_read()` (`findMembership`) и есть
ВСЯ разница между «до» и «после», и по SPEED-8d ($10-20$ мс на
устранённый `_read()` с учётом сети + `structuredClone`) реалистичная
прод-оценка — **10-20 мс на запрос** для этих шести маршрутов
персонально, что на бёрсте из нескольких таких запросов подряд
складывается в те же десятки-сотни мс наблюдаемой на проде очереди.

Тесты: `npm --prefix backend test` — **710/710**, ~20-27 с (9 новых в
`speed9-b-single-read.test.js`, флейков `api.test.js` не было).

## SPEED-9 C-boot — один снимок строки на весь бут вместо пяти (05.09.2026)

`docs/speed9_proposal.md` §5 нашёл, что `PostgresStore._bootstrap()` на
**каждом** рестарте процесса (деплой, production-watch раз в 6 часов)
последовательно звал пять шагов, и **каждый** делал СВОЙ `SELECT data
FROM rodnya_state` + `JSON.parse` + `normalizeDbState` целиком ради
одного и того же: увидеть маркер `migrationStatus.*ToTables =
"complete-v1"` (на проде миграции 6/7/8b давно задеплоены — все три
проверки закономерно no-op) или прогнать backfill идентичностей (тоже
обычно no-op на уже консистентных данных, но с ДВОЙНЫМ хэшированием
persons+personIdentities — до и после — даже когда ничего не меняется).
Итого ≥5 полных SELECT+parse блоба ДО первого HTTP-запроса, плюс после
этого `_cachedVersion` оставался `null` (SPEED-8a кэш ни разу не
подтверждался версией строки за весь бут), поэтому и первый настоящий
`_read()` для первого реального запроса **гарантированно** промахивался
мимо кэша — конкурентные запросы сразу после старта видели тот же
промах каждый, что и объясняет наблюдаемые на проде «500-1000 мс на
первые запросы после рестарта» (множественное число).

| шаг буста | чтений блоба было | чтений блоба стало |
|---|---|---|
| `_backfillPersonIdentitiesInStateRow` | 1 (свой SELECT) | 0 (использует прокинутый снимок) |
| `_hydrateAuthProjectionTablesFromStateRow` | 0 на реальном Postgres (чистый LATERAL SQL); **1** на pg-mem (см. ниже) | 0 всегда — fallback-ветка тоже переиспользует прокинутый снимок |
| `_migrateChatCollectionsToTables` | 1 | 0 |
| `_migrateNotificationCollectionsToTables` | 1 | 0 |
| `_migrateTreeChangeCollectionsToTables` | 1 | 0 |
| `_hydrateChatProjectionFromState` | 1 | 0 |
| **новый общий `_readBootStateRow`** | — | **1** |
| **итого на уже мигрированном проде** | **≥5** (+1 на pg-mem-тестах) | **1** |

Побочная находка: `_hydrateAuthProjectionTablesFromStateRow` на РЕАЛЬНОМ
Postgres блоб в JS вообще не тянет (LATERAL `jsonb_array_elements` прямо
в SQL) — в изначальный список «5 чтений» из `speed9_proposal.md` не
входит. Но на pg-mem этот конкретный LATERAL cross-join падает с
`column "data" does not exist` (ограничение pg-mem, не Postgres —
воспроизведено изолированно, см. `isProjectionHydrationFallbackError`
и её git-историю: заведена именно под эту тестовую особенность в апреле
2026) — что переводит функцию в fallback-ветку, которая ДО этого чанка
делала ещё один независимый `SELECT data FROM`. Эта ветка тоже теперь
принимает прокинутый снимок и не читает блоб сама — на проде это не
меняет поведение (ветка и так не срабатывает), на pg-mem-тестах убирает
шестое чтение.

### Механизм

`_bootstrap()` после DDL/`_createChatTables`/`_createNotificationTables`/
`_createTreeChangeTables` один раз читает строку (`_readBootStateRow`:
`SELECT data FROM ...` — тот же литерал, что раньше использовал каждый
шаг, плюс отдельный дешёвый `SELECT version FROM ...` через уже
существующий `_selectStateVersion()`) и получает `{state, version}` или
`null`, если чтение не удалось. Дальше — два пути:

- **Снимок получен** — `{state, version}` прокидывается через backfill →
  auth-hydrate (только его state, ему не нужна version) → чат-миграцию →
  notification-миграцию → tree-change-миграцию → hydrate chat-projection.
  Каждый метод, который РЕАЛЬНО пишет строку (backfill что-то изменил;
  миграция реально мигрировала, а не увидела маркер), делает свой
  `UPDATE ... RETURNING version` и возвращает {state, version} УЖЕ ПОСЛЕ
  своей записи — следующий шаг в цепочке видит актуальные данные вместо
  устаревших. Метод, который ничего не поменял (маркер уже стоит),
  возвращает вход без изменений — тот же {state, version} едет дальше.
  По итогу всей цепочки, если version подтверждена (число, не `null`/
  `undefined`), ею прогреваются `_cachedState`/`_cachedVersion` — первый
  настоящий `_read()` после буста сразу попадает в кэш (SPEED-8a
  инвариант «кэш валиден ⟺ version кэша = version строки» соблюдён:
  version бралась либо из самого чтения строки, если никто не писал,
  либо из `RETURNING` последней записи).
- **Снимок не получен** (БД моргнула ровно в этот момент) — деградация
  1:1 к поведению до этого чанка: все шесть шагов вызываются БЕЗ
  аргумента, каждый сам читает блоб и сам решает, что делать при
  неудаче (независимые catch-блоки, включая асимметрию chat/notification
  — «роняем бут» — vs tree-change/backfill — «молча деградируем»,
  которая не менялась). Кэш в этом случае не прогревается — первый
  `_read()` честно перечитывает БД, как и раньше.

Каждый из пяти методов принимает опциональный параметр и без него ведёт
себя байт-в-байт как до этого чанка (свой `SELECT`, свой `catch`) — это
защищает любых других вызывающих (по коду их сегодня нет, кроме самого
`_bootstrap()`) и является тем же самым fallback-путём для «БД моргнула».

Семантика DDL, маркеров миграций, порядка записей и безусловной
пересборки чат-проекции (`_hydrateChatProjectionFromState` →
`_replaceChatProjection`, вызывается на КАЖДОМ буте независимо от того,
менялось ли что-то) — не менялась.

### Тесты и намеренные правки существующих

Новый `backend/test/postgres-boot-reads.test.js` (pg-mem, харнесс как в
`postgres-read-cache.test.js`, счётчик `SELECT data(, version)? FROM`
поверх `pool.query`): уже мигрированное состояние → 1 чтение за
`initialize()` + `_cachedVersion` = версии строки + первый `_read()` —
0 чтений; легаси-состояние без маркеров → миграции реально выполняются,
итоговые таблицы/маркеры/projection корректны, но общий счёт всё равно 1;
backfill меняет `persons` → изменение доказано ПРЯМЫМ чтением строки
(не только `_cachedState`), `_cachedVersion` соответствует version ПОСЛЕ
записи; общий снимок недоступен → деградация к независимым чтениям
каждого шага (≥5), кэш не прогрет.

Два существующих теста кодировали именно ту архитектуру («N независимых
чтений на бут»), которую убирает этот чанк, — оставить их без изменений
было бы равносильно не делать чанк вовсе:

- `postgres-notification-tables.test.js` «скип миграции (BD моргнула)» —
  фолт-инъекция считала порядковый номер `SELECT data FROM` среди пяти
  независимых чтений и валила ровно четвёртое (notification-миграция).
  С единым снимком в начале буста на здоровом пути таких независимых
  чтений просто нет — targeting «четвёртое из пяти» стал недостижим.
  Тест теперь СНАЧАЛА валит общий снимок (принудительно переводя бут в
  прежний fallback-режим независимых чтений), ЗАТЕМ таргетирует
  notification-миграцию внутри этого режима — тот же итоговый сценарий
  и те же assertions (гейт закрыт, лента читается из блоба, drain
  выключен, маркер не выставлен), другой (валидный для новой
  архитектуры) способ его вызвать.
- `postgres-read-cache.test.js`, два теста на реальном pg-mem с
  немигрированным seed (миграции реально выполняются во время буста):
  `assert.equal(snapshotSelects, 1)` на ПЕРВОМ `_read()` после буста
  кодировал именно тот баг, который чинит этот чанк (первый `_read()`
  гарантированно проходил мимо кэша) — после фикса он тоже кэш-хит,
  значение поменялось на `0`; второй тест («сторонняя запись
  инвалидирует кэш») аналогично сдвинут на единицу вниз, потому что его
  первый `_read()` тоже стал бесплатным.

`npm --prefix backend test` — **714/714** зелёных (было 710, +4 новых);
`api.test.js` отдельно (Windows-ENOTEMPTY флейк из CLAUDE.md) —
**126/126**, флейка не было.

### Риски

Это горячий путь старта процесса: если бут упадёт — прод не поднимется
после деплоя. Изменение расширяет пять существующих методов
опциональным параметром (без него — прежнее поведение, отдельно
проверено тестом деградации) и добавляет `RETURNING version` к четырём
`UPDATE`-запросам, которые и так безусловно ссылаются на колонку
`version` (если бы её не было, эти `UPDATE` падали бы и до этого чанка —
`RETURNING` не создаёт новый отказ). Прогрев кэша в конце `_bootstrap()`
строго охраняется условием «version не `null`/`undefined`» — при любой
неопределённости (в т.ч. на голом fake-pool в тестах без поддержки
`RETURNING`) кэш просто не прогревается и первый `_read()` ведёт себя
как до этого чанка, без деградации корректности. Изменение не трогает
`_mutate`/`_write`, `store.js` (FileStore), маршруты, `store-factory.js`
и семантику самих миграций — периметр ограничен только тем, ОТКУДА шесть
бут-методов берут state.

### Ревью перед слиянием (05.09, `863bbb00`)

- **Порядок чтения в `_readBootStateRow`: сначала `version`, потом `data`.**
  Два отдельных запроса оставляют окно для чужой записи между ними. При
  порядке version→data кэш в худшем случае получает новые данные под
  старой версией — первый `_read()` видит несовпадение и честно
  перечитывает (одно лишнее чтение). Обратный порядок (data→version)
  давал бы старые данные под новой версией — устаревший кэш до следующей
  записи, молча ломая инвариант SPEED-8a. Одним запросом `SELECT data,
  version` (как в `_loadSnapshot`) было бы ещё чище, но fake-pool'ы
  тестов SPEED-8a считают литералы отдельно — не стоило перепахивать
  пять тестов ради того же результата.
- **Прогрев кэша — с синхронизированным зеркалом графа.** На промахе
  `_read()` перед кэшированием зовёт `_syncGraphFromLegacy` (Phase 3.1c);
  прогретое на буте состояние проходило мимо — первые попадания отдавали
  бы несинхронизированный граф до ближайшей записи. Теперь sync делается
  на клоне перед записью в `_cachedState` (O(N) после SPEED-9 A, ~25 мс).

## SPEED-10 — куда уходят 200–480 мс бёрста, когда чтение блоба уже в кэше (06.09.2026)

После SPEED-9 B прод-журнал бёрста входа (10 параллельных GET на одном
Node-потоке) всё ещё показывал медианы persons 226 / graph 252 / stories
295 / gatherings 368 / polls 378 / merge-proposals/pending 483 /
onboarding-state 187 мс — при том, что SPEED-8a-кэш чтения блоба уже
попадает (SELECT версии + `structuredClone`, не полный SELECT). Гипотеза:
CPU-компьют самого маршрута на каждый запрос, помноженный на конкуренцию
за один event-loop в бёрсте.

### Профиль (метод SPEED-8c/8d/9): `node --cpu-prof`, копия прод-блоба

Харнесс — `backend/tool/speed10_bench.js` (без данных, коммитится) поверх
`FileStore` напрямую: дерево `22dd65fb-…` (41 person, 66 relations, 2
`semyaMembers` — owner+viewer, тот же снаряд, что и в SPEED-9 B), owner —
стюард сразу трёх деревьев (нужно для merge-proposals). Прод-копия на
момент работы содержала 0 историй/встреч — `--augment` добавляет по 24
синтетических истории/встречи/опроса через сами `store.createStory/
createGathering/createPoll` (валидная форма гарантирована самим стором,
не руками), автор — owner, зритель — viewer (разные люди, чтобы не
сработал ранний выход `authorId === viewerUserId`). Профиль — 60 одиночных
+ 30×7 бёрст-вызовов (`backend/tool/speed10_cpuprofile_report.js`,
self-time по `hitCount` из `.cpuprofile`).

Топ-15 self-time ДО (25191 мс запись, 16263 сэмплов):

| self % | self, мс | функция — файл:строка |
|---|---|---|
| 11.4 | 2876 | `ensureAutoCirclesForTree` — store.js:1202 |
| 11.3 | 2852 | `_read` — store.js:6313 |
| 6.1 | 1547 | `write` — node:string_decoder (часть JSON.parse) |
| 5.2 | 1306 | `(anonymous)` — store.js:1710 (`normalizeParticipantIds` callback) |
| 4.8 | 1214 | `normalizeIsoDate` — identity-matcher.js:26 |
| 4.8 | 1208 | `normalizeName` — identity-matcher.js:6 |
| 4.1 | 1081 | `identityIdsForPersonIds` — store.js:1042 |
| 4.1 | 1030 | `normalizeCircleMemberIdentityIds` — store.js:978 |
| 3.8 | 965 | `normalizeNameTokens` — identity-matcher.js:16 |
| 3.8 | 962 | `(anonymous)` — store.js:6334 (внутри `_write`) |
| 3.5 | 897 | `normalizeParticipantIds` — store.js:1703 |
| 2.9 | 722 | `_canUserViewCircleContent` — store.js:16732 |
| 2.8 | 702 | `(idle)` |
| 2.8 | 702 | `buildAutoCircleSpecsForTree` — store.js:1098 |
| 2.5 | 640 | `(garbage collector)` |

Две отдельные находки, обе — «пересчёт на каждый элемент вместо одного
раза на вызов»:

1. **`ensureAutoCirclesForTree`/`buildAutoCircleSpecsForTree`/
   `_canUserViewCircleContent`** (вместе с их внутренними
   `identityIdsForPersonIds`/`normalizeCircleMemberIdentityIds`/
   `normalizeParticipantIds`) — суммарно **≈27% self-time**. Причина:
   `_canUserViewCircleContent(db, {treeId, ...})` вызывает
   `ensureCirclesForTree(db, treeId)` БЕЗУСЛОВНО на каждый вызов, даже
   когда элемент помечен `all_tree` (проверка на `all_tree` идёт уже
   ПОСЛЕ пересборки кругов). `ensureAutoCirclesForTree` — это полный BFS
   двух направлений (потомки/предки) по `persons×relations` дерева НА
   КАЖДОГО person, плюс вложенный проход по всем relations на каждую
   пару-спецификацию — итого пересобирает ВСЕ авто-круги дерева заново.
   `listStories/listGatherings/listPolls` (и `listPosts`/`getBranchDigest`/
   `searchPosts`) зовут это на КАЖДЫЙ элемент ленты одного и того же
   дерева — M элементов = M полных пересборок одного и того же результата.
2. **`normalizeIsoDate`/`normalizeName`/`normalizeNameTokens`**
   (identity-matcher.js) — **≈16% self-time**. `_ensureCrossTreeMergeProposals`
   (внутри `listPendingMergeProposalsForUser`) гоняет двойной цикл
   `stewardPersons × allPersons` и на КАЖДУЮ пару зовёт `scorePersonPair`,
   которая заново нормализует ОБЕ стороны — хотя `allPersons` один и тот
   же набор на всём двойном цикле, и `_markStaleMergeProposals` /
   финальный `.filter()` того же вызова снова гоняют `scorePersonPair` по
   тем же persons третий и четвёртый раз.

`_read` (11.3%) + `write`/JSON-парсинг (6.1%) + `(anonymous)` внутри
`_write` (3.8%) — это ожидаемый «пол» (диск + `JSON.parse`/`stringify` +
`_syncGraphFromLegacy`, SPEED-9 A) — НЕ трогали, см. «Что не тронуто».

### Что исправлено

1. **`buildCanonicalPersonView({usersById})`** (store.js) — `listPersons`
   строит `Map` id→user (`buildUsersByIdMap`, уже существовала с SPEED-9 D)
   ОДИН раз вместо `db.users.find()` на каждого person дерева.
2. **`_buildPersonGraphIndex` + `_buildPersonViewFromGraph({index,
   legacyPerson})`** — `getTreeGraphSnapshot` строил снимок дерева, на
   КАЖДОГО person заново делая четыре `.find()` по ГЛОБАЛЬНЫМ
   `db.persons/db.graphPersons/db.branchPersonViews/db.users`. Теперь три
   карты строятся один раз на весь снимок, person передаётся напрямую
   (уже под рукой из фильтра). Тот же приём, что `_buildGraphSyncIndex`
   в SPEED-9 A.
3. **`_createCircleVisibilityCache` + опциональный `cache` в
   `_canUserViewCircleContent`/`_canUserViewCirclePost`** — мемоизирует
   `ensureCirclesForTree(db, treeId)` и `_userIdentityIdsInTree(db, treeId,
   userId)` по ключу `treeId`/`(treeId, userId)` в пределах ОДНОГО вызова
   `listPosts/listStories/listGatherings/listPolls/getBranchDigest/
   searchPosts`. `ensureCirclesForTree` идемпотентна на неизменном `db`
   (первый вызов создаёт недостающие круги, дальше находит их же) —
   кэшировать её результат в пределах одного db-снимка безопасно.
4. **`_scorePersonPairCached(left, right, normCache)`** (store.js,
   поверх экспортированных из identity-matcher.js
   `normalizePersonForScoring`/`scoreNormalizedPersons`, тех же самых
   функций, что SPEED-8d уже ввёл для identity-suggestions) —
   `_ensureCrossTreeMergeProposals`/`_markStaleMergeProposals`/
   `_mergeProposalStillActionable` делят один `normCache` (Map
   personId→нормализованная форма) на весь вызов
   `listPendingMergeProposalsForUser` — было S×P нормализаций каждой
   стороны, стало ≤S+P.
5. **Не пишем блоб, когда пересчёт дал те же значения** —
   `_ensureCrossTreeMergeProposals`'s `else`-ветка (предложение уже
   `pending`) раньше безусловно ставила `changed=true`, из-за чего на
   дереве с хотя бы одним pending-предложением (обычное дело после
   первого прохода) КАЖДЫЙ `GET merge-proposals/pending` безусловно
   писал блоб целиком — на PostgreSQL это `UPDATE` всей строки + сброс
   SPEED-8a-кэша для ВСЕХ последующих чтений до следующего попадания.
   Теперь `changed=true` только если `matchScore`/`matchSignals`/
   `reasons`/`reviewerUserIds` реально отличаются от уже сохранённых —
   итоговые значения `existing` те же самые в обоих случаях, меняется
   только необходимость `_write()`.

Контракт всех затронутых маршрутов не менялся: везде — новый
ОПЦИОНАЛЬНЫЙ параметр с default = прежнее поведение (честный `.find()`/
пересчёт без памяти). Ни один из ~10 остальных вызывающих
`_buildPersonViewFromGraph`/`buildCanonicalPersonView`/
`_canUserViewCircleContent`/`_mergeProposalStillActionable` вне
изменённых маршрутов не передаёт новые параметры — поведение байт-в-байт
прежнее (проверено `grep` по всем вызовам).

### Идентичность и тесты

`backend/test/speed10-identity.test.js` (7 тестов, FileStore) — по
разделу на каждую из четырёх оптимизаций: (A) `listPersons` резолвит
каждого linked person'а через СВОЕГО user'а по карте (не путает при
нескольких пользователях в одном дереве); (B) индексированный путь
`getTreeGraphSnapshot` совпадает person-в-person с одиночным `findPerson`
на дереве деда/отца/сына + person вне ветки; (C) `listStories/
listGatherings/listPolls` с кэшем видимости дают ту же видимость по
авто-кругу «Ветка», что и раньше, включая кросс-дерево лента без
`treeId` (кэш не путает деревья); (D) `listPendingMergeProposalsForUser`
с `normCache` побайтово совпадает с ручным прогоном тех же трёх методов
БЕЗ кэша, не-стюард по-прежнему ничего не видит, а повторный вызов без
изменений НЕ пишет блоб (спай на `_write`, 0 записей — было: всегда ≥1),
при этом легитимное изменение (совпавший `birthPlace` → выросший
`matchScore`) пишет ровно один раз и отражается в ответе.

`npm --prefix backend test` — **721/721** (было 714, +7 новых), ~26 с;
`api.test.js` в общем прогоне флейка не дал.

### Замер: одиночный вызов и бёрст (FileStore, копия прод-блоба + синтетика)

| метод | одиночный до, мс (median×20) | одиночный после | Δ |
|---|---|---|---|
| `listPersons` | 11.30 | 8.54 | −24% |
| `getTreeGraphSnapshot` | 14.80 | 12.26 | −17% |
| `listStories` | 54.03 | 10.25 | **−81%** |
| `listGatherings` | 44.53 | 10.20 | **−77%** |
| `listPolls` | 43.88 | 10.52 | **−76%** |
| `listPendingMergeProposalsForUser` | 84.84 | 19.89 | **−77%** |
| `getOnboardingState` | 9.01 | 8.63 | −4% (пол `_read()`, не в периметре) |

| бёрст (7 маршрутов × 12 повторов, `Promise.all`) | до | после | Δ |
|---|---|---|---|
| wall median | 258.17 мс | 77.57 мс | **−70%** |
| wall max | 326.59 мс | 91.83 мс | **−72%** |

Топ-15 self-time ПОСЛЕ (7605 мс запись — **3.3× короче** при той же
нагрузке 60+30×7 вызовов): `_read` — 35.5% (теперь безусловный лидер,
как и ожидалось), `write`/JSON-парсинг — 16.6%, `(idle)`/`(gc)` — 9.4%,
остаток — `_syncGraphFromLegacy`/`_syncPersonToGraph`/`_buildGraphSyncIndex`
(SPEED-9 A, ~6% суммарно — не в периметре) и `stableSerialize`/hash
(backfillPersonIdentities, ~7% — см. ниже) — `ensureAutoCirclesForTree`
упал с 11.4% до 2.1% (в АБСОЛЮТНЫХ мс — с 2876 до 163, то есть в 17.6
раза, а не только по доле), `normalizeName`/`normalizeIsoDate`/
`normalizeNameTokens` из identity-matcher.js исчезли из топ-20 совсем.

**Оговорка (как в SPEED-9 B)**: это FileStore, не PostgresStore —
`_read()` здесь честный диск+`JSON.parse` (~35% профиля), тогда как на
проде кэш-хит SPEED-8a — это `structuredClone` + 2 SQL round-trip'а
(версия + сессии), заметно дешевле. Значит устраняемый этой задачей
route-level CPU (`ensureAutoCirclesForTree`/нормализация merge-пар) на
проде — БОЛЬШАЯ доля общего времени запроса, чем показывают проценты
выше; абсолютные мс переносить на прод нельзя, но направление и
относительное ускорение (17.6× на `ensureAutoCirclesForTree`, 70% на
бёрст целиком) — да.

### Что не тронуто и почему

- **`structuredClone(_cachedState)` в `PostgresStore._read()` на
  попадании кэша (SPEED-8a).** В профиле FileStore это `_read`+JSON-
  парсинг — 41.6% суммарно (35.5+6.1 в новом профиле). На Postgres то
  же место — `structuredClone` ВСЕГО состояния (сейчас ~480 КБ блоб) на
  КАЖДЫЙ `_read()`, даже когда вызывающему нужны 2-3 поля. Инвариант
  (приватная копия на чтение) — сознательный выбор SPEED-8a, менять
  семантику здесь не стали по прямому ограничению задачи. Предложение
  на будущее: ленивый клон только тех top-level коллекций, которые
  реально читает вызывающий метод (`db.persons`/`db.circles`/... по
  требованию, не всё состояние разом) — оценка эффекта требует
  отдельного профиля на реальном Postgres, не входит в этот тикет.
- **`_reconcilePersonIdentities`/`backfillPersonIdentities` двойной
  `hashSnapshot` (sha256 всех persons+personIdentities, ДО и ПОСЛЕ)
  внутри `_ensureCrossTreeMergeProposals`.** В ПОСЛЕ-профиле —
  `stableSerialize`+`(anonymous)` migration-utils.js:88/92+`update`
  hash:134 ≈ **7% self-time**, второй по величине источник после
  `_read()`. `_reconcilePersonIdentities` вызывается тут БЕЗУСЛОВНО на
  каждый `listPendingMergeProposalsForUser`, даже когда у всех persons
  уже есть согласованный `identityId` (steady state — обычный случай).
  SPEED-8c уже чинил ровно этот паттерн для `ensureAutoCirclesForTree`
  (гейт `treeHasPersonsWithoutIdentity(db, treeId)`) — но
  `_reconcilePersonIdentities` вызывается из **19 разных мест** по
  store.js (create/link/merge-пути), и её текущая логика не только
  «добавляет отсутствующий identityId», но и синхронизирует
  `identity.personIds` со всеми `person.identityId` — дешёвый гейт
  «есть ли person без identityId» рискует не отловить рассинхрон
  `personIds`-массива и молча пропустить нужную починку в одном из
  других 18 вызывающих. Не в периметре этой задачи — риск
  (широко разделяемый helper, 19 caller'ов, не аудировал все) не
  оправдан выигрышем одного маршрута; кандидат для отдельного тикета.
- **`_isPersonSteward`/`personStewardUserIds`** (`db.trees.find()` на
  каждый person в фильтре `stewardPersons`) — не входит в топ-20
  ни до, ни после (O(persons×trees), но trees мало, ~25) — не трогали:
  не даёт заметного вклада, оптимизация не прошла бы порог 15%.
- **`_syncGraphFromLegacy`** (SPEED-9 A, внутри каждого `_read()`/
  `_write()`) — уже O(N) после SPEED-9 A, в новом профиле — фиксированный
  «налог» на каждый вызов (~6% суммарно), вне периметра (задача про
  route-level compute поверх УЖЕ оптимизированного `_read()`).

### Риски

Все четыре правки — чисто аддитивные (новый опциональный параметр,
default воспроизводит старое поведение один-в-один) и не трогают
`_mutate`/`_write`/`_read`, SQL `PostgresStore`, контракты маршрутов
или форму ответа. Наибольший радиус поражения — у пункта 5 (когда именно
пишется блоб для merge-proposals): написан консервативно (сравнение по
значению всех четырёх полей, а не эвристика) и покрыт отдельным тестом
на то, что легитимное изменение оценки по-прежнему пишет. Кэш видимости
кругов (пункт 3) живёт СТРОГО в пределах одного вызова (новый `Map` на
каждый вызов `listX`, не переживает между запросами) — протухания между
запросами быть не может по конструкции.

## SPEED-11 — попадание в кэш чтения без клона и без SQL сессий (06.09.2026)

SPEED-10 (см. «Что не тронуто» выше) назвал `structuredClone(_cachedState)`
внутри `PostgresStore._read()` на попадании кэша (SPEED-8a) главным
оставшимся «полом» бёрста на Postgres — 480 КБ-2 МБ блоб копируется
целиком на КАЖДЫЙ из ~10-12 запросов бёрста входа, хотя шесть GET-
маршрутов (persons/person/graph/gatherings/polls/stories,
`req.storeSnapshot` из SPEED-9 B) используют этот `db` только чтобы
передать его store-методам ниже — ни один не мутирует блоб и не читает
`db.sessions`. Раз потребление read-only и на весь HTTP-запрос нужен один
и тот же снимок — клон вообще не нужен: можно отдавать ОДИН И ТОТ ЖЕ
объект всем читателям, если сделать его неизменяемым.

### Механизм

`readSharedSnapshot()` — новый метод, параллельный `_read()`, а не замена
ему (`_read()` не тронут: как отдавал приватный мутируемый клон + свежие
сессии, так и отдаёт — им продолжают пользоваться все мутирующие пути и
всё, что реально читает `db.sessions`).

- **FileStore** (`store.js`): `readSharedSnapshot()` = `_read()` + разовая
  `deepFreezeState()` + обёртка `_buildSharedSnapshotView` (убирает
  `sessions`). У FileStore нет version-keyed кэша — каждый `_read()` и так
  честный `JSON.parse` — здесь это только контракт (заморожено, без
  sessions), а не оптимизация; реальная экономия — только на Postgres.
- **PostgresStore** (`postgres-store.js`): на попадании (`_cachedVersion`
  строки совпал с `_selectStateVersion()`) отдаёт `this._cachedState`
  напрямую — 0 `structuredClone`, 0 `SELECT session_data`. Единственный
  SQL — `SELECT version`, схлопнутый single-flight'ом
  (`_sharedVersionCheck`) на конкурентный бёрст. На промахе — честная
  перезагрузка (`_refreshSharedSnapshotOnMiss`), тоже single-flight'ом на
  конкурентный бёрст промахов (иначе N параллельных промахов — например,
  сразу после чужой записи — делали бы N SELECT+`normalizeDbState`+
  граф-синк+sidecar-запись вместо одной).
- `requireTreeAccess` (`app.js`) кладёт результат `readSharedSnapshot()`
  (не `_read()`) на `req.storeSnapshot` — единственная точка входа в
  прод-код, дальше всё, что было в SPEED-9 B, не изменилось (шесть
  маршрутов передают снимок как `prefetchedDb`/`db`).

### Инварианты снимка

1. **Заморожен один раз, в момент заполнения, не на каждый hit.**
   `deepFreezeState()` (store.js) — рекурсивный `Object.freeze` с ранним
   возвратом на уже замороженном значении (O(1) вместо O(размера) на
   повторный вызов с тем же объектом — иначе «защитный» вызов на каждом
   hit'е стоил бы столько же, сколько убираемый клон). Единственная точка
   присвоения `_cachedState` на путях, которые МОГУТ дать подтверждённую
   версию (а значит — стать источником hit'а), — `_commitCachedState`
   (прайм при буте, `_read()`-промах, `_write()`); она замораживает перед
   присвоением. Бут-миграции (`_migrate*ToTables`/
   `_backfillPersonIdentitiesInStateRow`) присваивают `_cachedState`
   напрямую, в обход — они никогда не подтверждают версию (см. комментарий
   у `_cachedVersion`), так что их состояние в любом случае замещается
   первым честным чтением; замораживать его там означало бы трогать код
   миграций без пользы (вне периметра задачи).
2. **`db.sessions` бросает, а не отдаёт устаревшее значение.**
   `_buildSharedSnapshotView` удаляет поле и заменяет геттером, который
   всегда throw'ит с понятным текстом («используйте findSession/...»).
   Сознательный выбор вместо «просто не копировать»: сессии — то немногое,
   что реально меняется между двумя запросами с одинаковой версией блоба
   (проекционная таблица сессий живёт отдельно от версии строки блоба), и
   тихая отдача точечного снимка на момент заполнения кэша была бы
   opt-in багом, который никто не заметит вручную.
3. **`req.storeSnapshot` — один и тот же объект в пределах HTTP-запроса.**
   `_buildSharedSnapshotView` строит новую обёртку `{...state}` на каждый
   вызов (дёшево — shallow spread верхнего уровня), но `readSharedSnapshot()`
   кэширует эту обёртку по ССЫЛКЕ на исходное состояние
   (`_sharedSnapshotViewFor`) — иначе два подряд идущих hit'а отдавали бы
   РАЗНЫЕ объекты-обёртки над одним и тем же `_cachedState`, что ломает
   контракт «один снимок на весь запрос», на котором держится SPEED-9 B
   (`req.storeSnapshot`, тест на строгое `===`). Инвалидация — сама
   ссылка: `_cachedState` меняется ТОЛЬКО через полное переприсвоение
   (`_commitCachedState`), никогда не мутируется на месте, поэтому
   сравнение по `===` само по себе корректно инвалидирует кэш обёртки.
4. **Методы с `prefetchedDb`/`db` не мутируют снимок.** Полный аудит семи
   методов, которые реально получают этот снимок через
   `req.storeSnapshot` (`findMembership`, `listPersons`, `findPerson`,
   `listHiddenPersonIdsForCaller`, `getTreeGraphSnapshot`, `listGatherings`,
   `listPolls`) плюс `listStories` (восьмой — прокидывается отдельно от
   `req.storeSnapshot`, но через тот же `db`-параметр из
   `story-routes.js`):
   - Шесть из восьми — чистое чтение (`.find`/`.filter`/`.map`,
     `structuredClone` для КЛОНОВ отдельных записей на возврат, не для
     мутации `db`) — без изменений.
   - `_canUserViewCircleContent`/`_canUserViewCirclePost` (используются
     `listStories`/`listGatherings`/`listPolls`) вызывают
     `ensureCirclesForTree`, которая при неизменном `db` реконструирует
     авто-круги in-place (`db.circles.push`, `circle[key] = value`,
     `db.circleMembers = ...filter().push(...)`, и — если у дерева есть
     person без `identityId` — `backfillPersonIdentities(db)`, которая
     мутирует `person.identityId` на КАЖДОМ person'е БД, не только этого
     дерева). На фростженном `db` `push`/присвоение поля частично либо
     бросали бы (мутатор массива), либо тихо no-op'ались (sloppy-mode
     присвоение поля объекта в store.js — файл без `"use strict"`) —
     второе опаснее: не крашится, а молча вычисляет видимость по
     наполовину реконструированным кругам. Фикс —
     `_writableCirclesViewForTree(db, treeId, cache)`: copy-on-write
     оверлей (`{...db}` + карту `circles`/`persons` через `.map()`,
     `Array.isArray(db.circles) ? ... : []` — новые изменяемые массивы),
     мемоизированный в `cache` (`_createCircleVisibilityCache`, тот же
     объект, что уже несёт кэш SPEED-10) по `treeId`; no-op, когда `db`
     не заморожен (нулевая цена для всех остальных вызывающих —
     `createPost`/`createStory`/… всегда передают приватный клон).
     `persons` клонируются ЦЕЛИКОМ (не только персон этого дерева) —
     `backfillPersonIdentities` сканирует+мутирует `db.persons` глобально
     (возвращает согласованный `personIdentities`, привязывая КАЖДОГО
     затронутого person'а, не только текущего дерева); клонировать только
     текущее дерево оставило бы часть persons всё ещё заморожена под
     мутацией, которая либо всё равно no-op'ается для конкретно текущего
     дерева (потому что оно уже клонировано — видимого бага сегодня нет),
     либо оставляет `personIdentities` рассинхронизированным с
     персонами других деревьев в пределах ЭТОГО overlay'я (то, что
     сегодня никто не читает, но это фактическая рассинхронизация, не
     доказанная безопасность) — клонировать все persons целиком дешевле,
     чем доказывать это безопасным по построению; на прод-объёме (155
     persons в копии блоба) — сотни микросекунд.
   - `listStories` (store.js) чистит просроченные истории синхронно на
     чтении (существовало до SPEED-11): раньше `db.stories =
     activeStories; await this._write(db);` — на фростженном `db` это
     присвоение либо no-op (sloppy-mode), либо (если бы кто-то однажды
     переключил файл на strict) бросало бы, а `_write(db)` в любом случае
     персистировал бы НАБЛЮДЁННЫЙ (возможно уже устаревший к моменту
     записи) снимок — фактический lost-update риск, СУЩЕСТВОВАВШИЙ и до
     SPEED-11 на приватном клоне тоже (просто маскировался тем, что
     `_write` побеждал редко-конкурирующую запись). Уборка переведена в
     `_mutate` — атомарный read-modify-write, который перечитывает
     СВЕЖЕЕ состояние вместо персистирования наблюдения (`skip()`, если
     переписывать нечего). Ответ клиенту строится из `activeStories`
     (фильтр на КОПИИ массива, не самого `db.stories`) — не зависит от
     того, успела ли уборка приземлиться до возврата ответа.
5. **Single-flight — только про конкурентность, не про свежесть.**
   И `_sharedVersionCheck`, и `_refreshSharedSnapshotOnMiss` вычищают свой
   промис сразу после разрешения (успех или ошибка) — следующий вызов
   (даже в следующем тике) идёт в БД заново. Не даёт временного окна, где
   «протухший» ответ раздаётся дольше одного всплеска конкурентных
   вызовов.

### Замер до/после

Метод — как в SPEED-8c/8d/9/10: копия прод-блоба (`backend/.scratch/
local_db.json`, вне репозитория, не коммитится; 155 persons/144
relations/25 деревьев/89 users/190 sessions, 2.08 МБ JSON-текста — крупнее
цифры «~480 КБ», которую называли SPEED-8a/9 B, потому что эта конкретная
копия снята до полной эвакуации части легаси-коллекций из блоба на этом
инстансе; направление и относительный эффект от этого не меняются).
Харнесс — `backend/.scratch/speed11_bench.js` (не коммитится): 20
прогонов `structuredClone(state)` (медиана — маргинальная цена ОДНОГО
попадания ДО SPEED-11), один прогон `deepFreezeState(state)` (цена
ОДНОКРАТНОЙ заморозки при заполнении кэша) и бёрст 10 параллельных
попаданий на pg-mem (`PostgresStore` с фейковым `pool`, копия блоба
как seed-строка — тот же приём, что `backend/test/postgres-read-cache.
test.js`), «до» — `store._read()`, «после» — `store.readSharedSnapshot()`.
3 прогона, значения стабильны:

| замер | значение |
|---|---|
| `structuredClone(state)` — median из 20 (маргинальная цена ДО, на попадание) | 5.2-5.9 мс |
| `deepFreezeState(state)` — один прогон (цена ОДНОКРАТНОЙ заморозки) | 1.9-2.3 мс |
| `deepFreezeState(state)` повторно на уже замороженном (идемпотентность) | 0.001 мс |
| бёрст 10 параллельных `store._read()` (до) | 84-92 мс |
| бёрст 10 параллельных `store.readSharedSnapshot()` (после) | 1.5-3.1 мс |

**≈30-55× на бёрсте попаданий** (10 параллельных запросов, копия
прод-блоба) — устранены и 10× `structuredClone` (~480 КБ-2 МБ), и 10×
`SELECT session_data`, а 10× `SELECT version` схлопнуты в 1 через
single-flight. Заморозка платится РОВНО ОДИН раз за всё время жизни
кэшированной версии (до следующей записи), а не на каждый запрос —
2 мс за один раз против 5-6 мс за КАЖДЫЙ из потенциально десятков
попаданий между записями делает её однозначно выгодной уже при 1
повторном попадании; для бёрста из 10+ запросов, который и мотивировал
задачу, выигрыш — почти вся цена клона на 9 из 10 запросов.

**Оговорка, как в SPEED-9 B/10**: pg-mem — не настоящий Postgres; цифры
показывают ОТНОСИТЕЛЬНЫЙ эффект механизма (клон/SQL сессий убраны,
single-flight работает), не абсолютные прод-миллисекунды (на реальном
Postgres к каждому SQL добавляется сетевой RTT, которого у pg-mem нет —
абсолютная разница на проде будет БОЛЬШЕ, не меньше, потому что все
устраняемые операции здесь SQL, а не только CPU).

### Идентичность и тесты

`backend/test/speed11-shared-snapshot.test.js` (9 тестов, `PostgresStore`
+ pg-mem):

1. Попадание в кэш: 0 `SELECT данных`, 0 `SELECT session_data`, два
   подряд идущих `readSharedSnapshot()` отдают строго один и тот же
   объект (`===`).
2. Снимок и его коллекции глубоко заморожены (`Object.isFrozen`).
3. `db.sessions` бросает (`assert.throws`, текст ошибки).
4. Иммутабельность способом, не зависящим от strict-mode вызывающего
   кода: `Reflect.set(snapshot, "trees", [])` возвращает `false` (не
   бросает и не мутирует — так и должно быть при sloppy-mode
   присвоении), `snapshot.persons.push(...)` бросает `TypeError`
   безусловно (встроенные мутаторы массива всегда throw, независимо от
   режима).
5. Single-flight на попадании: 10 параллельных `readSharedSnapshot()` →
   1 `SELECT version`, все 10 получили один объект.
6. Single-flight на промахе (после сторонней записи, меняющей версию):
   8 параллельных `readSharedSnapshot()` → 1 `SELECT данных+version`, все
   8 видят свежие данные стороннего изменения.
7. Идентичность: каждый из 8 store-методов с замороженным снимком даёт
   результат, побайтово (`deepEqual`, без `updatedAt`/`createdAt` — тот же
   pre-existing источник дрожания `getTreeGraphSnapshot`, что и в
   SPEED-9 B) совпадающий с вызовом на честном `_read()`-клоне.
8. `listStories` с замороженным `db` отфильтровывает просроченную
   историю и не бросает.
9. Уборка просроченных историй через `_mutate` реально видна следующему
   чтению (не только исключена из ОДНОГО ответа) — второй
   `readSharedSnapshot()` после уборки не содержит просроченную запись.

Не покрыто этим файлом (см. комментарий в его начале): HTTP end-to-end
через `createApp`+`PostgresStore`+pg-mem — `findTree` (вызывается
`requireTreeAccess` на КАЖДОМ tree-scoped запросе, до входа в SPEED-11
код) использует `LATERAL jsonb_array_elements`, который pg-mem не умеет
исполнять в этой форме (`column "data" does not exist` — движок, а не
SPEED-11); реальную wiring-цепочку `requireTreeAccess → readSharedSnapshot()
→ шесть маршрутов` (тот же код, что на проде) покрывает
`speed9-b-single-read.test.js` на `FileStore` — там `readSharedSnapshot()`
вызывается по-настоящему production-путём, просто её FileStore-контракт
(«просто `_read()`+freeze») не проверяет single-flight/переиспользование
объекта — их проверяют тесты 1, 5, 6 выше на `PostgresStore`.

`npm --prefix backend test` — **730/730** (было 721, +9 новых), ~23-27 с;
`api.test.js` перегнан отдельно (126/126) — флейка не было ни в общем
прогоне, ни изолированно.

### Риски

- **Единственная точка правды для заморозки — `_commitCachedState`.**
  Любой БУДУЩИЙ код, который присвоит `this._cachedState = X` в обход
  этого метода на пути, способном дать подтверждённую версию, тихо
  вернёт МУТИРУЕМЫЙ объект как «общий снимок» — источник трудноуловимой
  порчи состояния между независимыми HTTP-запросами (не крэш, а
  постепенное расхождение данных). Защитный `deepFreezeState()` на каждом
  hit'е (O(1) на уже замороженном значении) самокорректирует ЭТОТ
  конкретный симптом (снимок останется заморожен), но не отловит НОВОЕ
  место записи, которое обходит `_commitCachedState` целиком — ревью
  новых `_cachedState =` в `postgres-store.js` остаётся ответственностью
  код-ревью, не теста.
- **`_writableCirclesViewForTree`/`backfillPersonIdentities` — граница
  доказанной безопасности сегодняшним использованием, не архитектурным
  инвариантом.** Аудит (см. «Инварианты», пункт 4) показал, что
  клонирование ВСЕХ persons (не только текущего дерева) устраняет
  единственный найденный путь к рассинхронизации `personIdentities`
  внутри overlay'я, но сам факт, что `ensureCirclesForTree`/
  `backfillPersonIdentities` при неизменном `db` вообще пытаются
  мутировать переданный объект — remains a general foot-gun: если
  завтра кто-то передаст `readSharedSnapshot()`-снимок в МЕТОД, который
  ЕЩЁ не в списке из восьми аудированных (например, по ошибке — сняли
  `prefetchedDb` с одного из ~19 других мест, вызывающих
  `_reconcilePersonIdentities`/родственные helper'ы), фикс-по-аналогии
  не сработает автоматически — нужен новый `_writableCirclesViewForTree`-
  подобный overlay ИЛИ явный отказ мутировать. Не устранено архитектурно,
  потому что переписывать `ensureCirclesForTree`/`backfillPersonIdentities`
  на чистое (без мутации входа) вычисление — вне периметра задачи
  (затронуло бы ~19+ вызывающих мест по всему store.js).
- **Не проверено на реальном Postgres.** Как и все pg-mem-тесты в этом
  документе — доказывает МЕХАНИЗМ (freeze/single-flight/аудит мутаций),
  не абсолютные прод-цифры и не полную SQL-совместимость (пример —
  `findTree`'s LATERAL, который pg-mem не тянет вообще, см. «Идентичность
  и тесты» выше). Ветка не мержится в main до явного «го» — см.
  `.claude/rules/backend-store.md`.

