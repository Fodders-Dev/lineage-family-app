# Родня — контекст для Claude Code

Семейное приложение: дерево родни + чаты + звонки + лента. Ориентир UX — Telegram
(чаты/звонки должны ощущаться так же быстро). Продуктовый лейтмотив — сохранить
семейную память («поговори, пока есть возможность»).

## Архитектура (карта, не читая 21k строк)

- **Клиент**: Flutter, Dart SDK ≥2.17 <4.0 — **не использовать** фичи Dart 3
  (patterns, class modifiers, records). provider + go_router. Экраны тонкие
  (`lib/screens/`, крупные разбиты на `*_sections.dart`), логика в
  `lib/services/` (customApi-адаптеры + клиентские кэши). Новые фичи —
  аддитивно через capability-mixin интерфейсы в `lib/backend/interfaces/`.
- **Бэкенд**: Node/Express (`backend/src/app.js` + `routes/`). Хранилище — ОДИН
  JSONB-блоб (`public.rodnya_state`) через `FileStore` (`store.js`, 21k строк —
  не читать целиком, только Grep/Explore) и `PostgresStore extends FileStore`.
  Исключение: чат-коллекции (сообщения/реакции/черновики/пины) живут в
  отдельных таблицах (SPEED-6), чаты зеркалятся в projection-таблицу.
  Realtime — WS (`realtime-hub.js`), пуши — FCM (+legacy RuStore, web),
  звонки — LiveKit.
- **Федеративные семьи** включены в проде (`RODNYA_FEDERATED_SEMYI_ENABLED=true`):
  доступ к привязанному дереву решает членство семьи; легаси-пути вступления
  обязаны dual-write'ить членство (`_ensureSemyaMembershipForLegacyJoin`).

## ⚠️ Прод и деплой

- **`git push` в main = деплой в прод**: пути `backend/**` → backend-deploy,
  `lib/** web/** assets/** pubspec.*` → web-deploy. Плюс production-watch
  каждые 6 часов молча редеплоит бэкенд с main. Пушить только готовое.
- **Android-релиз пользователям** = ручной `gh workflow run android-ota-release.yml`
  — ПЕРЕД этим обязателен бамп `version:` в pubspec.yaml, иначе клиенты не
  увидят обновление. Процедура: skill `/release-ota`. RuStore-стор закрыт;
  каналы распространения — Telegram + in-app OTA.
- Ветки с миграциями прод-БД мержатся в main **только по явному «го»** пользователя.
- Прод-сервер (с 31.08.2026): `ssh fodders` (root, IP 77.91.113.109,
  HOSTKEY/РФ, старый 77.67.89.164 выведен из эксплуатации). Postgres 16;
  парольный вход по ssh отключён — только ключ. По умолчанию — только чтение
  (диагностика: skill `/prod-diag`); изменения на сервере — через CI или по
  явной просьбе. Канонический чекаут — корень `C:/rodnya-tree-app`, не worktree.

## Команды и Definition of Done

- `flutter analyze` — чисто; `flutter test <затронутые>` — зелёные; перед push —
  полный `flutter test` (~1413) и/или `npm --prefix backend test` (639, ~25с),
  если менялся бэкенд.
- **Голден-тесты**: падения на Windows ~2% — среда (эталоны из Linux-CI).
  ЗАПРЕЩЕНО `--update-goldens` локально (заблокировано hook'ом); регенерация —
  только workflow `regen-tree-goldens.yml`.
- `backend/test/api.test.js` в параллельном прогоне даёт редкие
  Windows-ENOTEMPTY-флейки — перегнать файл изолированно, прежде чем чинить.
- Perf-тесты (`test/perf/`) выключены тегом — шум таймингов.
- UI-изменения проверять живьём: web — превью `rodnya-web` (`.claude/launch.json`),
  Android — эмулятор, flavor dev (`flutter build apk --flavor dev --debug`,
  пакет `com.ahjkuio.rodnya_family_app.dev`).
- Смоук прода: `node tool/prod_route_smoke.mjs` (env — см. `tool/prod_route_smoke.env.example`).

## Правила разработки

- Комментарии в коде — инварианты и «почему», не «что делает строка».
- RU-копирайт продуктового качества (тексты видят семьи).
- Git: без `--no-verify`, без force-push, без amend опубликованных коммитов;
  показывать diff stat перед коммитом; большие изменения — под-чанками.
- Правильное решение важнее дешёвого — всегда.

## Навигация по знанию

- Текущий статус проекта: `docs/connected-trees-refactor/CURRENT-PHASE.md`
  (живой). Архитектурные решения — append-only `DECISIONS.md` там же.
- `docs/speed_measurement.md` — скорость чатов и SPEED-6 (живой).
- `deploy/README.md` — топология прода (Caddy; источник истины Caddyfile — на сервере).
- `docs/active_execution_plan.md` и `docs/mvp_web_audit_*.md` — ЗАМОРОЖЕНЫ,
  не следовать.
