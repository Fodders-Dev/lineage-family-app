---
paths:
  - .github/workflows/**
  - deploy/**
  - backend/scripts/**
---

# Прод-операции

## Деплой-каналы

- `backend-deploy.yml` / `flutter-web-deploy.yml` — деплоят В ПРОД на push в
  main (path-фильтры). `production-watch.yml` — кроном каждые 6ч редеплоит
  бэкенд с main + смоуки + backup-drill: всё смерженное в main доедет до
  прода максимум за 6 часов, а ручные правки на сервере будут ЗАТЁРТЫ.
- Аутентификация CI→сервер — ТОЛЬКО ключ (`SERVER_SSH_KEY`); парольные пути
  умерли вместе со старым сервером (август 2026).
- Flutter в CI запинен (`flutter-version:` в каждом workflow) — версия должна
  совпадать с локальной; незапиненный stable уже ломал сборку (livekit_client).
- `android-ota-release.yml` — единственная кнопка «отдать пользователям»;
  требует предварительного бампа `version:` в pubspec (workflow сверяет
  versionCode эндпоинта). `regen-tree-goldens.yml` пушит бот-коммит в main
  (только goldens-пути — деплой не триггерит).

## Миграции прод-БД

- Скрипты в `backend/scripts/` — **file-store-only** (`RODNYA_DB_PATH`,
  JSON-файл). На Postgres-проде паттерн: остановить бэкенд → экспорт блоба
  `psql -Atc "SELECT data FROM public.rodnya_state WHERE id='default'"` в файл
  → прогнать скрипт по файлу (`--commit`) → импорт обратно параметризованным
  node/pg-запросом → старт. Перед этим — свежий `pg_dump` в
  `/opt/rodnya/backups/manual/`.
- Сначала ВСЕГДА репетиция на scratch-БД, восстановленной из свежего дампа;
  встроенные проверки скриптов местами тавтологичны — ключевые инварианты
  сверять своим SQL.
- Откат SPEED-6: `restore-chat-collections-to-blob.js` (guard по маркеру,
  бэкенд остановлен).

## Топология

- Фронт — Caddy (nginx неактивен, fallback). Источник истины Caddyfile —
  `/etc/caddy/Caddyfile` НА СЕРВЕРЕ (репо-копия частична): после ручных правок
  копировать обратно в репо. Caddy раздаёт assetlinks.json (App Links:
  fingerprint обязан совпадать с подписью раздаваемого APK), /invite, /oauth,
  /dl/* (APK).
- Сервер общий (VPN-стек, другие проекты) — фоновые всплески CPU не всегда
  «наши»; env бэкенда — `/etc/rodnya-backend.env` (флаги читаются на старте —
  смена требует restart).
