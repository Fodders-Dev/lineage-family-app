# Текущая фаза рефакторинга

> ⚠️ Важно: PLAN.md этой папки SUPERSEDED. Источник правды —
> [`docs/tree_model_overhaul_rfc.md`](../tree_model_overhaul_rfc.md).
> См. [DECISIONS.md](DECISIONS.md) от 2026-05-09.

## Status update: 2026-09-04

* **31.08 — переезд прода в РФ** (152-ФЗ): 77.91.113.109 (HOSTKEY), PG16,
  ssh только по ключу; **02–03.09 старый сервер (NL) выведен полностью** —
  перенос доказан пообъектно, архив `/var/backups/rodnya/old-server-final-20260903/`
  на новом сервере. Подробности — `.claude/rules/prod-ops.md`.
* **01–02.09 — навигация «дерево как ядро»**: дерево — снова вкладка и
  центр нижнего бара, `/trees` — только селектор; тур больше не врёт про
  дерево; дубли маршрутов `/trees` и `/user/:userId` убраны (тест-гард
  на дубли в таблице роутов).
* **02.09 — плотность, чанки 1–5** (главная боль Артёма — пустота и крупный
  текст): строки «Родных» 96→76dp, шапка профиля 430→290dp, плоский нижний
  бар 56, топбар 62→56, заголовки вкладок 22→20, лента −120dp на первом
  экране, баннеры/метр профиля/создание ветки ужаты. Ещё не трогали: чаты,
  экран человека, настройки.
* **OTA 1.0.31 (02.09) и 1.0.32 (03.09)** — второй чинит запрос
  full-screen-intent на каждом старте (теперь один раз на установку).
  Base64-загрузка медиа — sunset (410), только бинарный PUT.
  RuStore SDK — зеркало в репо (`android/rustore-maven`), Artifactory умер 01.09.
* **03.09 — SPEED-8a** (`a638d9a`): кэш чтения PostgresStore по колонке
  `version` — persons 1,5с → ~0,16с. **SPEED-8b** (`ae016aa`):
  treeChangeRecords + hardDeleteAudit из блоба в таблицы, блоб 975 → 482 КБ,
  миграция 3053+2550, 0 пропущенных. **04.09 — SPEED-8c** (`513210f`):
  `GET /v1/posts` p50 657 → 84 мс — лента больше не сверяет авто-круги всех
  деревьев на каждом чтении (77% CPU был бэкфилл идентичностей с двойным
  sha256 всей базы). После 8c в журнале ноль медленных запросов. Разборы —
  `docs/speed_measurement.md`.
* **04.09 — плотность, чанк 6 (чаты) + OTA 1.0.33+41**: список чатов без
  обзорной строки и отдельной строки поиска (поиск — иконкой в топбаре,
  фильтры — табами), первый чат на ~100dp вместо 210; композер в одну
  рамку. OTA-workflow run 33906348876, `/v1/app/latest` → versionCode 41.
* **04.09 — плотность, чанки 7–8** (веб задеплоен, в Android уедет со
  следующим OTA): карточка человека — ряд плиток действий вместо столбика
  кнопок, аватар 120→96, одно пустое состояние фотографий (`a0b3891`);
  «Родные» — поиск в шапке, список сразу под ней, первая строка на ~136dp
  вместо 228 (`d66eaae`). **OTA 1.0.34+42 (05.09)** — run 33920587662,
  `/v1/app/latest` → versionCode 42.
* **05.09 — конвейер sonnet-агентов** (worktree + ветка + гардрейлы, ревью и
  живая проверка — Fable): чанки 9 (профиль+настройки) и 10 (оверлеи дерева)
  → OTA 1.0.35+43; чанк 11 (вложенные настройки: сеансы 100→64dp/строка,
  доступы, уведомления, корзина, скрытые, архив историй), чанк 12 (формы и
  композер без рамок в рамках), чанк 13 (форма «Добавить родственника»:
  заголовки 18sp, без дубля вопроса; лист «Кем приходится?» — сетка 2×3
  вместо шести пилюль) и **SPEED-8d** (`identity-suggestions`: один `_read()`
  на запрос, батч adjacency, матчер без повторной нормализации; бэкенд
  693/693). Плюс `feat/session-device-info` (версия ОС в сеансах). **OTA
  1.0.36+44 (05.09 14:10 МСК)** — run 33959493531, `/v1/app/latest` →
  versionCode 44; загрузка APK шла ~70 мин (медленный канал GitHub→HOSTKEY,
  сервер здоров).
* **05.09 — волна 3 агентов + OTA 1.0.37+45**: чанк 14 (профиль: единый
  список вместо пяти карточек-на-строку), чанк 15 (экран звонка — только
  вёрстка, `lib/services` не тронут, «Принять/Завершить» 64dp), стабилизация
  флейков бэкенд-тестов (гонка status=sent в push-тестах, `*.tmp` при rm
  tempDir; `FileStore.close()` — аддитивно). Run 33969019334, `/v1/app/latest`
  → versionCode 45. Ещё не трогали: топбар/тулбар дерева, «Спросить историю»
  как сценарий (продуктовое решение).
* **04.09 — деплой-CI**: скрипт активации бэкенда теперь едет из репо
  (серверная копия отстала на 5 месяцев и повисла на лежащем audit-эндпоинте
  npm); `npm ci --no-audit` везде.

## Status update: 2026-08-30

* **27.08 — SPEED-6 задеплоен**: сообщения чатов вынесены из блоба в таблицы
  (send = INSERT); send-to-ack p50 74мс (было 1533).
* **27.08 — Phase B live в проде**: федеративные семьи,
  `RODNYA_FEDERATED_SEMYI_ENABLED=true`.
* **28-29.08 — массовая загрузка фото**: план `docs/plan_bulk_photo_upload.md`
  выполнен целиком (5 шагов); OTA-релиз 1.0.29+37 разослан пользователям.
* **29.08 — бинарная загрузка медиа**: `PUT /v1/media/object` вместо
  base64-JSON; base64 остаётся легаси до sunset.
* **30.08 — SPEED-7 задеплоен** (squash `158bdf9`): notifications +
  pushDeliveries вынесены из блоба в таблицы; миграция на проде — 312+24
  перенесено, 0 пропусков (легаси-таблица notifications с апреля
  эвакуирована в backups); persist p50 13мс; наблюдение ~неделя.

---

**Status update**: 2026-05-26 (post 18-ship session — Phase A calls package landed, Phase B backend complete + frontend 8/10 ships shipped + integration test coverage, 5 design docs Phase B/C/D/E captured).

## Сессия 2026-05-26 — 18 ships, zero regressions

~13800 LOC across 18 commits. Single squash session за один день, разделённый на тематические chunks. Все ship'ы прошли flutter analyze + регрессионный suite. Бэкенд + auth + tree-view-screen untouched после frozen-points (Phase B backend Ship 1-10, Bug B observation week, Q1-Q3a observation).

### Phase A — Calls package (production-ready, RuStore signing key check pending)

| Ship | Commit | Что |
|---|---|---|
| Bug A foreground service | `766e5e0` | Audio one-way fix, validated через звонок к маме |
| Q1 wizard skip | `9589cbf` | Мама-blocker — skip-onboarding tile + banner |
| Q2 Google dialog | `0367e81` | Cross-provider Google email confirm UX |
| Bug 2/3 UI state sync | `207245a` | Call screen state convergence |
| Bug B cross-provider email | `ff74a2d` | 409 EMAIL_PROVIDER_MISMATCH + modal flow |
| Bug 4 PiP drag | `8ab3b02` | Picture-in-picture window manipulation |
| Q3 safety polish | `f27a228` | Sign-out confirm + reg validation + provider hide |
| Q4 tree action sheet | `50edd73` | Bottom sheet 5 actions на person tap (audit Critical #4) |
| Q3a auth provider gate | `0b53b87` | /health authProviders + per-button gate |
| Post-delete polish | `8d98b5e` | Shared safe-delete confirmation widget |
| Empty tree CTA | `0dda6fe` | EmptyTreeGuidedCta widget для onboarding |

### Phase B backend (100% — Ships 1-10 уже жил с 2026-05-19)

См. отдельный progression в [SHARED-TREE-PROPOSAL.md](SHARED-TREE-PROPOSAL.md). Frontend этой сессии wrap'нул endpoints без backend touch.

### Phase B frontend (80% — 8/10 ships shipped)

| Ship | Commit | Что |
|---|---|---|
| FE1 — Семя model + switcher | `25841cd` | SemyaListController + SemyaSwitcher widget + GET /v1/me/semya |
| FE2 — Семя details screen | `f5e405c` | Details screen + members section + role chip + management tiles |
| FE3 — Invitation flow | `ada0513` | Create/list/revoke + accept deep link + invite screen |
| FE4 — Tree view семя-aware | `5ac5b62` | Parallel семя context fetch + role gating + viewer empty state |
| FE5 — Pull-person foundation | `b34060a` | Service method + PullPersonSheet widget (entry point deferred к FE6) |
| FE6a — Browse viewer + share | `70cc000` | BrowseTreeScreen + ShareBrowseTokenModal + /browse/:token route |
| FE6b — Browse tokens mgmt | `0c8de00` | List section в семя details + revoke per row |
| FE7 — Hide filter | `cccd4e8` | Action sheet «Скрыть от меня» tile + HiddenPersonsSection |
| FE7b — Settings tile polish | `152c067` | Settings entry point + семя picker + scrollToHidden |
| FE10 partial — Integration tests | `1b1dc17` | 29 end-to-end tests FE1-FE7 в test/integration/ |
| FE8 — Membership mutation UI | `7d86bb7` | promote/demote/kick + invite-grant + confirm dialogs |
| FE9 — Onboarding wizard rewrite | `3eaa643` | mama-friendly onboarding flow |
| FE10 full — Integration coverage | `bb0b3ae` | end-to-end FE1-FE9 coverage |
| FE3b — Invitation accept deep link | `9b7a3d3` | rodnya-tree.ru/i/<token> universal-link wiring |
| Phase B polish (mama-friendly) | (этот чанк) | имена участников вместо userId + undo-тосты «Отменить» + «Не бойся сломать» баннер + тёплые empty states + article history §3.2.4 |

### Design docs captured

* **UX-AUDIT-2026-05-25** — 49 screens, top-20 recommendations (NOT в этой папке — отдельный audit pass)
* [SHARED-TREE-PROPOSAL.md](SHARED-TREE-PROPOSAL.md) — Phase B федеративная семя vision
* [CIRCLE-EXTENSION-PROPOSAL.md](CIRCLE-EXTENSION-PROPOSAL.md) — Phase C — Круг extension
* [PHASE-D-MEMORY-HISTORY-PROPOSAL.md](PHASE-D-MEMORY-HISTORY-PROPOSAL.md) — Phase D
* [PHASE-E-SOCIAL-INTERACTIONS-PROPOSAL.md](PHASE-E-SOCIAL-INTERACTIONS-PROPOSAL.md) — Phase E

### Pending для следующей сессии

Phase B фронт ЗАКРЫТ (FE1-FE10 + FE3b + mama-friendly polish chunk). До
запуска федеративной семьи на проде осталось:

* **RuStore signing key check** (CRITICAL — unlocks все ships для real users)
* **Рассылка приглашений email/SMS** — нужен внешний провайдер (SMS-gateway /
  email): приглашения создаются и принимаются по ссылке, но авто-доставки
  SMS/email пока нет (Артём шлёт ссылку вручную). Кросс-стек заход.
* **Черновик-режим персон** (draft mode, §6 Week 7) — ОТЛОЖЕНО, кросс-стек
  (backend visibility «черновик/опубликовано» + frontend). Снижает страх
  «сразу всем покажется кривое».
* **Миграция данных Phase B + флип feature-флага** на прод.
* **Coach-marks тур первого запуска** (§6 Week 7) — НЕ сделан в polish-чанке
  (самый тяжёлый, отложен; нужен overlay/пакет + first-run гейтинг).
* **Kick-участника undo** — нужен FE-метод service.addMembership (POST
  /membership) — его нет во фронт-сервисе (только GET/PATCH/DELETE).
* **UX audit Major remaining** (3 items — auth + tree-adjacent)
* **Q4a soft-delete proper design pass** (deferred 2026-05-26 — backend
  hard-delete reality vs spec)

Сделано в mama-friendly polish-чанке: имена участников вместо userId
(backend enrich + frontend), undo-тосты «Отменить» для правок дерева,
баннер «Не бойся сломать», тёплые пустые состояния, экран «История
изменений» статьи §3.2.4.

## Shipped к production

| Phase | Status | Main commit | Notes |
|---|---|---|---|
| Phase 0 | ✅ closed 2026-05-09 | (audit, no code) | AUDIT.md + IDENTITY-MATCHER.md + SCHEMA.md |
| Phase 1.3 | ✅ closed 2026-05-09 | (already реализован in code) | edit-time conflict surfacing — DoD достигнут |
| Phase 3.1 | ✅ closed 2026-05-10 | `0d5acec` | schema graph + migration v1→v2 |
| Phase 3.2 | ✅ closed 2026-05-10 | `a40a429` | owner-model enforcement gates + grants/visibility endpoints |
| Phase 3 squash | ✅ shipped 2026-05-11 | `cb67b0b` | Phase 3 connected per-user trees squash |
| Phase 4 | ✅ shipped 2026-05-12 | `028d1d2` | extended-family network (BFS view) |
| Phase 4 flag flip | ✅ flag-on 2026-05-13 | `5fb1d3c` | `useExtendedRenderPath` default true — observation week closed 2026-05-18 cleanup `baa75d5` |
| Phase 4 cleanup | ✅ closed 2026-05-18 | `baa75d5` | flag + legacy renderer + override removed; extended-network permanent. См. DECISIONS.md 2026-05-18 |
| Phase 6 | ✅ shipped 2026-05-14 | `414b218` | onboarding wizard + kinship-check «мы родственники?» |
| Phase 6 hotfix | ✅ closed 2026-05-18 | `b4dcb47` + `40202a1` | `/v1/auth/session` requiresOnboarding gap (chunk 4a follow-up) — DECISIONS.md 2026-05-18 hot-path fix |
| Phase 3.6 | ✅ shipped 2026-05-18 + activated 2026-05-19 | `253efaf` | Hard-delete background job. Live в проде с 2026-05-19 03:03 UTC (env flip `RODNYA_HARD_DELETE_ENABLED=true` + `_FIRST_RUN_DRY=false`). First live run 0/0/0 deletions. DECISIONS.md 2026-05-18 ship + 2026-05-19 activation. |
| Phase 3.4 | ✅ shipped 2026-05-11 | `cb67b0b` | UI: visibility toggle + grants + branch wizard + sensitive contacts + conflict badges. Squash of branch `claude/infallible-pike-41360c` (16 commits, ~15400 insertions). Branch cleaned up 2026-05-22 (см. DECISIONS 2026-05-22). |
| Phase A+B auto-refresh | ✅ shipped 2026-05-22 | (этого ship'а) | Push/WebSocket-triggered refetch для feed (Phase A) и tree mutations (Phase B-narrow: 5 endpoints). Silent push для tree, banner-OK для posts. Single coordinator entry point — WebSocket realtime + push сходятся через `_showBackendNotification`. 7 backend + 15 frontend tests. См. DECISIONS 2026-05-22. |

## Parked (готово к merge, ждёт Артёмова call)

(пусто — ничего не parked)

## Observation windows (active)

* **SPEED-8b observation**: 2026-09-03 → ~2026-09-10. Пред-деплойный дамп
  `/opt/rodnya/backups/manual/pre-speed8b-20260903-203120.dump`, откат —
  `backend/scripts/restore-tree-change-records-to-blob.js`. После окна —
  уборка как у SPEED-6/7 (бэкап-таблицы, откат-скрипт). SPEED-6/7 окна
  закрыты без инцидентов.
* **SPEED-8c**: наблюдение по журналу `slow-request` (порог 500 мс) — с
  деплоя 04.09 10:26 пусто.

* **Phase 6 observation**: 2026-05-14 → 2026-05-28 (2 weeks).
  Метрики per MERGE-CHECKLIST-PHASE-6 §5:
  * register → wizard finish >70%
  * wizard finish → tree view >90%
  * discover funnel (FAB → submit) >40%
  * kinship acceptance rate (informational)
  * 5xx rate <0.1%
  Flagless (additive feature) — observation = passive metric monitoring,
  no code flip needed.

  > ⚠️ Day 8 peek (2026-05-22): organic adoption минимальный
  > (1 real user из 5 registrations, hit chunk 4a bug before fix
  > deploy). Server-side state correct (`currentStep: "welcome"` для
  > всех 5), automatic retry slot ready на next login. Review window
  > likely inconclusive — sample too small. См. DECISIONS 2026-05-22
  > "Phase 6 observation early peek".

## Pending — нужен Артёмов design call

* **Phase 6.5** (post-observation, conditional):
  * Identity-suggestions push notification (DECISIONS
    2026-05-14 «identity-suggestions push deferred»).
  * ~~Revocation UX для kinship-checks (PHASE-6-PROPOSAL §2.6).~~
    ✅ Shipped 2026-05-22 — initiator может отозвать pending
    request, target gets `kinship_check_revoked` notification.
    См. DECISIONS 2026-05-22.
  * Native notification action buttons (Подтвердить/Отклонить
    inside notification body).

## Cutover plan (Артёмов 2026-05-10, original)

```
3.1 (done)  → pre-prod (миграция + schema) — 0d5acec
3.2 (done)  → pre-prod (enforcement gates + grants endpoints) — a40a429
3.4 (shipped 2026-05-11 cb67b0b) → squash of branch which was cleaned up 2026-05-22
3.6 (activated 2026-05-19) → prod (hard-delete background job; shipped
              independently от 3.4, activated через env flip 24h после
              ship). 253efaf + manual env flip.
4 (done)    → prod (extended-family network) — 028d1d2 + 5fb1d3c flag-flip
6 (done)    → prod (onboarding wizard + kinship-check) — 414b218
```

Реальная последовательность: Phase 3.1 (05-10) → 3.2 (05-10) →
Phase 3 squash включая 3.4 UI (05-11 `cb67b0b`) → Phase 4
(05-12 `028d1d2`) → Phase 6 (05-14 `414b218`). Phase 3.4 branch
остался dangling как squash-merge artifact до 2026-05-22 cleanup
(см. DECISIONS 2026-05-22).

## Чего НЕ делать

* НЕ депрекейтить graph-слой (он остаётся).
* НЕ принимать архитектурные решения без записи в DECISIONS.md.

---

## 2026-08-27 — Phase B ЗАПУЩЕНА В ПРОДЕ ✅

По «го» Артёма («если работает и полезно — го»):

1. **Пре-флип фикс дрейфа**: все 8 легаси-путей вступления (accept
   tree-инвайта, identity-attach ×3, person-create-with-userId, restore,
   legacy invitation) теперь dual-write'ят членство семьи
   (`_ensureSemyaMembershipForLegacyJoin`, role viewer как в миграции Q1) —
   без этого каждый новый участник ловил бы 403 после флипа.
2. **Миграция**: репетиция на scratch-копии прод-БД (8/8 проверок ✓,
   инвариант покрытия memberIds→memberships: 0 непокрытых из 59) →
   боевой прогон: **24 семьи, 35 членств, 24 привязки, 0 пропусков**.
   Простой ~90 сек. Pre-image: /opt/rodnya/backups/manual/
   rodnya_state.pre-semya-20260827-*.json (+ pg_dump'ы).
3. **Флаг `RODNYA_FEDERATED_SEMYI_ENABLED=true`** в /etc/rodnya-backend.env,
   рестарт. Смоук: создание семьи 201, me/semya, легаси-инвайт на
   привязанное дерево при флаге ON → доступ 200 + членство viewer.
4. Дальше: наблюдение (Production Watch каждые 6ч), owner'ы могут
   повышать viewer'ов вручную; хвосты — SemyaSwitcher не смонтирован
   (dead code), доставка инвайтов email/SMS всё ещё ручная.
