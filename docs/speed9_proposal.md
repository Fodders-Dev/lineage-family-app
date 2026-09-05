# SPEED-9 (анализ) — стоимость `_read()` в горячих путях и что с этим делать

Статус: **анализ + предложения, без изменений прод-путей** (кроме одного
поведенчески-нейтрального прогрева кэша при старте — см. §6.3). Решение по
реализации остальных пунктов — за владельцем продукта. Метод — как в
SPEED-8c/8d: `node`-скрипты напрямую через `FileStore`/`PostgresStore`,
без HTTP, на копии прод-блоба (`~155 persons / 144 relations / 25 деревьев /
88 users / 189 sessions`, compact JSON ≈ 1.6 МБ — прод-блоб больше).

Контекст: SPEED-8d (05.09) обнаружил, что 74% CPU в `identity-suggestions`
уходит в `_read()`/`_syncGraphFromLegacy`, но намеренно не трогал ни сам
`_syncGraphFromLegacy` («чужой, App-wide, риск непропорционален тикету»),
ни `requireTreeAccess` («общий helper для десятков маршрутов»). Этот документ
разбирает оба, плюс находит третью, ранее не задокументированную проблему
(N+1 `_read()` в ленте постов) и холодный старт.

---

## 1. Стоимость частей `_read()` — измерено (FileStore, реальный прод-блоб)

`node bench_read_parts.js local_db.json`, 15–30 итераций, тёплый JIT, среднее:

| часть | avg, мс | что делает |
|---|---|---|
| `JSON.parse(raw)` | 3.16 | парсинг ~2.1 МБ pretty-printed JSON (на Postgres — jsonb-колонка, драйвер `pg` парсит compact-JSON сам; порядок величины тот же) |
| `normalizeDbState(parsed)` | 0.04 | ~50 `Array.isArray(...) ? ... : []` — не clone, не итерация; пренебрежимо |
| `_syncGraphFromLegacy` (steady, идемпотентный проход) | 2.06 | полный скан persons+relations+trees; **см. §3 — не O(N), а O(N²)** |
| `_syncGraphFromLegacy` (cold, зеркало с нуля) | 2.84 | верхняя граница — не сегодняшний прод-кейс (зеркало уже синхронизировано) |
| `structuredClone(state)` | 5.57 | полный глубокий клон объекта (~1.6 МБ, вложенные массивы) |
| **FileStore._read() целиком** (parse+normalize+sync) | 5.64 | это то, что платит каждый вызов `_read()` на FileStore/при промахе Postgres-кэша (без клона — FileStore возвращает объект напрямую) |

## 2. Что именно выполняется в `PostgresStore._read()` — по коду (postgres-store.js:4949-4993)

### Кэш-хит (`_cachedVersion === текущая version строки`)
```
_selectStateVersion()        SQL: SELECT version FROM rodnya_state WHERE id=$1  (1 round-trip)
structuredClone(_cachedState)                                                   (~5.5мс на прод-размере)
_selectProjectedSessionsArray()  SQL: SELECT session_data FROM ..._auth_sessions
                                       ORDER BY created_at, token  (ВСЯ таблица, без WHERE)
computeProjectionHash(sessions)                                    (JSON.stringify)
```
**НЕ выполняется**: SELECT блоба, `JSON.parse`, `_syncGraphFromLegacy`,
`_persistSnapshotCache` (запись sidecar-файла). Итого CPU-часть кэш-хита ≈
`structuredClone` (5.5мс на этом объёме) + недорогой хэш; плюс **2 обязательных
SQL round-trip'а** (version + sessions) НЕЗАВИСИМО от того, что реально
изменилось — сессии перечитываются целиком на каждый `_read()`, потому что
живут вне версионированного блоба.

### Кэш-промах (version не совпала / кэш пуст)
```
_selectStateVersion()
_readSnapshotFromDatabase()      SQL: SELECT data, version FROM rodnya_state WHERE id=$1
normalizeDbState(...)
_syncGraphFromLegacy(...)                                          (§3 — O(N²))
_selectProjectedSessionsArray()
computeProjectionHash × 2
structuredClone(normalizedState)                                    (кэш на будущее)
_persistSnapshotCache(...)       fs.writeFile (JSON.stringify ВСЕГО состояния)
```
Измерено CPU-эквивалентом (`bench_read_parts.js`, без сетевого RTT к Postgres):
**≈14.8 мс** (parse+normalize+sync+clone+stringify). На реальной сети SPEED-8a
уже замерил полный промах на проде (до появления самого кэша) — **≈350 мс**
на блобе меньшего размера; разница с 14.8 мс — сетевой round-trip до
Postgres + фактическая запись sidecar-файла на диск (`fs.writeFile`, не
включена в CPU-бенч).

## 3. Находка: `_syncGraphFromLegacy` — не O(N), а O(N²) (комментарий в коде устарел)

Комментарий в store.js:14124 говорит: *«The cost is O(persons + relations +
trees) per call, which on today's scale is sub-millisecond»*. Это **больше не
так** — сам вызов делает три вложенных линейных скана на каждый элемент
внешнего цикла:

- `_syncPersonToGraph` (store.js:12393, 12472, 12506) — на **каждого** person:
  `db.graphPersons.find(...)`, `db.branchPersonViews.find(...)`,
  `db.branches.find(...)` — три линейных скана массивов, растущих
  пропорционально числу persons.
- `_syncRelationToGraph` (store.js:12686) + `_resolveGraphPersonIdForLegacy`
  (store.js:12653, вызывается дважды на relation) — на **каждую** relation:
  `db.graphRelations.find(...)` + 2×`db.persons.find(...)`.

Ни один из скан-хелперов не использует индекс/Map — итог `O(persons ×
graphPersons + relations × (graphRelations + persons))` ≈ `O(N²)`, где
`N ~ persons+relations`. Подтверждено замером на синтетических данных
(`bench_sync_scaling.js`, N persons + N-1 relations в одном дереве,
steady-state проход):

| N (persons≈relations) | steady-state, мс |
|---|---|
| 155 (прод-масштаб копии) | 3.96 |
| 310 | 9.69 |
| 620 | 38.32 |
| 1240 | 136.42 |
| 2480 | 559.69 |

Рост 1240→2480 (×2) даёт ×4.1 времени — учебный O(N²). **`_syncGraphFromLegacy`
работает над ГЛОБАЛЬНЫМИ коллекциями `db.persons`/`db.relations` — то есть по
ВСЕМ деревьям пользователя блоба разом**, не по одному дереву. Сегодня на
масштабе копии (155/144) цена мала (2-4 мс на `_read()`/`_write()`), но при
8-кратном росте (не экзотика — это одна активная семья с полной родословной
в несколько поколений плюс федеративные привязки) цена одного
`_syncGraphFromLegacy` вырастет до **~140 мс на КАЖДЫЙ** `_read()`/`_write()` —
а таких за один HTTP-запрос бывает 2-4 (см. §4). Это тихий scaling cliff,
а не гипотетический риск.

Важно: `docs/connected-trees-refactor/CURRENT-PHASE.md` явно говорит **«НЕ
депрекейтить graph-слой (он остаётся)»** — план «Phase 3.4 уберёт этот
хелпер», на который ссылается сам комментарий в коде, не реализован (Phase
3.4 ушла в прод как UI-фича, легаси-зеркало осталось навсегда). Комментарий в
store.js:14117-14126 стоит поправить отдельным мелким PR независимо от
решения по SPEED-9 (описывает не то, что происходит).

## 4. `_read()` на запрос — 6 маршрутов (по коду, federated-семьи ON в проде)

`requireAuth` (app.js:952) → `findSession`+`findUserById` — оба скоуплены
SQL по auth-проекциям (SPEED-8a), **0** полных `_read()`.

`requireTreeAccess` (app.js:1935) → `findTree` скоуплен SQL
(postgres-store.js:4928, LATERAL по `data->'trees'`) — **0** полных `_read()`;
но при `tree.semyaId` (федеративное дерево — типично для прода после Phase B)
зовёт `findMembership` (store.js:8713), которая **НЕ переопределена** в
PostgresStore → **1** полный `_read()`.

| маршрут | вызовы `_read()` | откуда |
|---|---|---|
| `GET /v1/trees/:id/persons` | **2-3** | requireTreeAccess→findMembership (1) + `listPersons` (1) + `listHiddenPersonIdsForCaller` (1, если tree.semyaId) — tree-routes.js:362 |
| `GET /v1/trees/:id/persons/:pid` | **2** | requireTreeAccess (1) + `findPerson` (1) — tree-routes.js:846 |
| `GET /v1/posts` (с `treeId`, лимитом `limit=K`) | **2 + K** | requireTreeAccess (1) + `listPosts` (1) + `listPostComments(post.id)` **на каждый пост страницы** (K) — post-routes.js:65,96-101/133-138. Без `limit` (легаси-клиенты) — `2 + все видимые посты`. **Это N+1, а не константа** — см. ниже. |
| `GET /v1/chats` | **0** | `listChatPreviews` полностью на SPEED-6 чат-таблицах + projection (postgres-store.js:4146) — блоб не читается вообще |
| `GET /v1/trees/:id/graph` (канвас дерева/«Родные») | **2** | requireTreeAccess (1) + `getTreeGraphSnapshot` (1) — tree-routes.js:1181, store.js:15090 |
| `GET /v1/me/onboarding-state` | **1** | `getOnboardingState` (store.js:20863), requireAuth не читает блоб |

**Находка вне изначальной постановки задачи**: `GET /v1/posts` — не «2-4
`_read()` на запрос», как в среднем по остальным маршрутам, а **N+1**: цикл
`Promise.all(page.map(post => store.listPostComments(post.id)))`
(post-routes.js:96-101 и 133-138) делает ОТДЕЛЬНЫЙ полный `_read()` на КАЖДЫЙ
пост страницы, чтобы посчитать/подтянуть комментарии. На кэш-хите Postgres
каждый такой `_read()` — это `structuredClone` (~5.5 мс на прод-объёме) + 2
SQL round-trip'а (version + **весь** таблица sessions, см. §2). Для страницы
из 20 постов это **~22 `_read()`** вместо 2-3: ~120 мс лишнего CPU на клоны
плюс 40+ лишних SQL-запросов к таблице сессий — причём каждый такой запрос
возвращает и парсит ВСЮ таблицу sessions заново, не только относящееся к
текущему пользователю.

(SPEED-8c уже чинил `/v1/posts` — но другую причину: `ensureCirclesForAllTrees`
сверку кругов на каждый пост. N+1 в `listPostComments` — независимая,
ортогональная проблема, не устранённая тем фиксом.)

## 5. Холодный старт — что и сколько (по коду, `_bootstrap()` + первый `_read()`)

`PostgresStore._bootstrap()` (postgres-store.js:310-410) при КАЖДОМ рестарте
процесса, последовательно:

1. ~15 DDL-запросов (`CREATE SCHEMA/TABLE/INDEX IF NOT EXISTS` × ~13, плюс
   `ALTER TABLE ADD COLUMN IF NOT EXISTS version`) — на прод-масштабе каждый
   no-op, но всё равно платит сетевой round-trip к Postgres.
2. `_backfillPersonIdentitiesInStateRow()` (:1141) — **отдельный** `SELECT
   data FROM rodnya_state` (весь блоб) + `normalizeDbState` +
   `backfillPersonIdentities`, которая **дважды** хэширует ВСЕ persons+
   personIdentities (`hashSnapshot` = `stableSerialize`+sha256, до и после,
   даже если ничего не изменилось — migration-utils.js:132,258). Измерено:
   **10.44 мс** на прод-объёме, даже в no-op случае (когда backfill ничего
   не делает — обычный случай на уже мигрированных данных).
3. `_migrateChatCollectionsToTables()` (:873), `_migrateNotificationCollections-
   ToTables()` (:743), `_migrateTreeChangeCollectionsToTables()` (:2589) —
   **каждая** делает СВОЙ отдельный `SELECT data FROM rodnya_state` (весь
   блоб) + `normalizeDbState`, единственно чтобы прочитать одно поле
   `migrationStatus.<x>ToTables` и увидеть маркер `"complete-v1"` (уже
   стоит на проде — миграции 6/7/8b задеплоены). Итого — **ещё 3 полных
   SELECT+parse блоба**, которые на проде НИЧЕГО не мигрируют, только
   проверяют маркер.
4. `_hydrateChatProjectionFromState()` (:1118) — **ещё один** `SELECT data`
   (5-й за бут) + безусловный `_replaceChatProjection` (DELETE+INSERT всей
   таблицы `<t>_chats_projection`) — тоже на каждый рестарт, не только когда
   что-то изменилось.

Итого **минимум 5 отдельных полных SELECT+parse блоба** на каждый бут ДО
первого реального HTTP-запроса, плюс backfill-хэш (~10мс), плюс ~15 DDL
round-trip'ов — всё последовательно внутри `initialize()`, которую ждут
все хендлеры (`await store.initialize()` в начале почти каждого метода).

После этого — **первый настоящий `_read()`** для первого реального запроса
ГАРАНТИРОВАННО промахивается: `_cachedVersion` инициализируется `null` в
конструкторе и не выставляется ни одной из миграций выше (они пишут
`_cachedState` напрямую, минуя версию) — так что version-чек в `_read()`
(`this._cachedVersion === currentVersion`) не совпадёт, даже если данные не
менялись с последнего бута. SPEED-8a на реальной сети уже замерил цену
такого промаха — **≈350 мс** (до появления самого кэша). Наблюдаемые на
проде «500-1000 мс на первые запросы после рестарта» (множественное число!)
хорошо объясняются: если несколько первых HTTP-запросов приходят
конкурентно сразу после старта (до того как первый `_read()` успел
записать `_cachedState`/`_cachedVersion`), КАЖДЫЙ из них тоже видит
несовпадение версии и тоже делает полный промах — «стадный» эффект на
несколько первых запросов, не один.

## 6. Предложения

### 6.1 Вариант A — убрать O(N²) внутри `_syncGraphFromLegacy` (§3)

Построить 4-5 `Map` (по `identityId`→graphPerson, `(branchId,personId)`→view,
`treeId`→branch, dedup-key→graphRelation, `legacyPersonId`→identityId) ОДИН
раз в начале `_syncGraphFromLegacy`, передать их как опциональные параметры в
`_syncPersonToGraph`/`_syncTreeToBranch`/`_syncRelationToGraph`/
`_resolveGraphPersonIdForLegacy` вместо `.find()` — тот же паттерн
опционального контекста, что SPEED-8d уже применил для
`_userCanSeeGraphPerson`/`_findBloodRelationBetween` (store.js, см. SPEED-8d
запись в `docs/speed_measurement.md`). Превращает O(N²) в O(N).
- **Выигрыш**: на сегодняшнем масштабе (155/144) — доли мс, незаметно. При
  8-кратном росте данных — разница между ~140 мс и ~4 мс на каждый
  `_read()`/`_write()`. Профилактическая инвестиция, не «горящий» фикс.
- **Риск**: средний — трогает `backend/src/store.js` (под правилом
  `.claude/rules/backend-store.md`), но изменение изолировано в приватных
  helper-методах без изменения внешнего контракта; `graph-sync.test.js` и
  `branch-include-rules.test.js` уже проверяют побайтовую идентичность
  поведения (тот же регрессионный щит, которым пользовался SPEED-8d).
- **Тесты**: существующие graph-sync/branch-include-rules тесты как
  регрессия «то же поведение»; добавить тест-бенчмарк со сравнением времени
  на N и 2N (аналог `bench_sync_scaling.js`) с бюджетом, чтобы будущий
  регресс в O(N²) падал в CI, а не тихо деградировал в проде.
- **Объём**: ~полдня.

### 6.2 Вариант B — один `_read()` на запрос в горячих маршрутах (паттерн SPEED-8d)

Расширить `requireTreeAccess`, чтобы он (опционально) возвращал уже
прочитанный `db` вместе с `tree` (как SPEED-8d уже сделал для
`findCrossTreeSuggestionsForPerson`/`filterLegacyPersonsByGraphVisibility` в
tree-routes.js), и передавать этот `db` в `listPersons`/`findPerson`/
`getTreeGraphSnapshot`/`listHiddenPersonIdsForCaller`, которые уже готовы
принять необязательный «уже прочитанный» аргумент по этому же паттерну.
- **Выигрыш**: persons list 3→1, person detail 2→1, tree/graph 2→1 полных
  `_read()`. На кэш-хите каждый устранённый `_read()` — это ~5.5 мс clone
  (прод-объём) + 2 SQL round-trip'а (version + вся таблица sessions);
  реалистично **10-20 мс на устранённый `_read()`** с учётом сети, то есть
  **20-40 мс на запрос** для persons-list/graph.
- **Риск**: низкий-средний — сигнатуры методов расширяются опциональным
  параметром (обратная совместимость для остальных вызывающих), но нужно
  трогать несколько хендлеров в `tree-routes.js` — держать под тем же
  «побайтовая идентичность ответа» тестом, что SPEED-8d.
- **Не трогать** (как и SPEED-8d решил): `_syncGraphFromLegacy` внутри
  самого `_read()` — это Вариант A, отдельно.
- **Объём**: ~1 день (несколько маршрутов, тесты).

### 6.3 Вариант C — прогрев кэша при старте (СДЕЛАНО в этой ветке, ≤10 строк)

`backend/src/store-factory.js`: сразу после `await store.initialize()` в
postgres-ветке `createStore()` — `await warmPostgresReadCache(store)`,
которая просто `try { await store._read() } catch { console.warn(...) }`.
- Убирает промах для ВСЕХ реальных первых запросов (не только одного) —
  прогрев случается ДО `app.listen()` в server.js, то есть до начала приёма
  трафика; «стадный эффект» из §5 больше не может случиться, потому что
  `_cachedState`/`_cachedVersion` уже выставлены к моменту первого реального
  запроса.
- Поведенчески нейтрально: тот же `_read()` всё равно случился бы на первом
  запросе — просто раньше. Ошибка прогрева (БД недоступна на старте) не
  роняет старт — `warmPostgresReadCache` глотает исключение и логирует
  warning; следующий `_read()` (первый настоящий запрос) просто честно
  перечитает БД, как и без прогрева.
- Только `postgres`-ветка `createStore()` (`storageMode === "postgres"`);
  file-store ветка не тронута — для неё нет кэша, которым можно было бы
  прогреться, лишнее чтение только удвоило бы боот на dev/тестах.
- Изолировано от `postgres-store.js`/`store.js` — не задевает
  `.claude/rules/backend-store.md` инварианты и «no full-state read after
  initialize» допущения тестов, которые конструируют `PostgresStore`
  напрямую (`new PostgresStore(...)`, минуя `store-factory.js`).
- Тесты: `backend/test/store-factory.test.js` — прогрев реально заполняет
  `_cachedState`/`_cachedVersion` после `createStore()` (pg-mem), плюс
  отдельный тест что `warmPostgresReadCache` не бросает при падении
  `_read()`. Оба зелёные (см. §7).

### 6.4 Вариант D — устранить N+1 в `GET /v1/posts` (§4, новая находка)

Батчить комментарии одним `_read()` вместо одного на пост: например, новый
`listCommentCountsForPosts(postIds)`/`listCommentsForPosts(postIds)`,
делающий один `db.comments.filter(c => postIds.has(c.postId))` и группировку
в памяти, вместо `Promise.all(posts.map(listPostComments))`.
- **Выигрыш**: для страницы из K постов — `K+2` → `~2-3` полных `_read()`.
  При K=20 это ~110 мс CPU (клоны) + ~40 лишних SQL-запросов к сессиям,
  устранённые одним махом — самый большой множитель среди всех находок
  этого документа (единственный, растущий с размером страницы, а не
  константа).
- **Риск**: низкий — чисто внутренняя батчировка, форма ответа не меняется.
- **Тесты**: assert на количество вызовов `_read()` (аналогично тому, как
  SPEED-8d проверял 2×→1× для identity-suggestions) не растёт с размером
  страницы; существующие posts-тесты как регрессия формата ответа.
- **Объём**: несколько часов.
- Формально это вне периметра исходного тикета (посты, не persons/tree/
  identity-suggestions), но найдено тем же методом и достаточно дёшево и
  безопасно, чтобы включить в рекомендацию ниже.

### Рекомендация по приоритету

**D → B → A** (C уже сделано). D — самый дешёвый и самый большой по
множителю (растёт с размером страницы ленты, а не константа), явный «баг»,
а не архитектурный компромисс. B — проверенный паттерн (SPEED-8d), даёт
предсказуемые 20-40 мс на запрос на самых частых маршрутах (persons/graph).
A — не горит сегодня, но закрывает тихий scaling cliff, который иначе
всплывёт неожиданно (и тяжело диагностируемо — профиль покажет только
«`_read()` медленный», без объяснения роста) при естественном росте данных.

---

## 7. Тесты

`npm --prefix backend test` — **695 tests, 695 pass, 0 fail**, ~25 с
(включая 2 новых теста для Варианта C, см. `backend/test/store-factory.test.js`).
Флейков в `api.test.js` в этом прогоне не было.

## Файлы

- `backend/src/store-factory.js` — прогрев кэша (Вариант C, реализовано).
- `backend/test/store-factory.test.js` — тесты на прогрев.
- Скрипты замеров (не в репозитории, временные, в scratchpad-каталоге
  агента): `bench_read_parts.js`, `bench_sync_scaling.js`, `blob_breakdown.js`.
