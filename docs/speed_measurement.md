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
