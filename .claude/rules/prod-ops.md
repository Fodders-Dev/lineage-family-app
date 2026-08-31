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
- Аутентификация CI→сервер — ТОЛЬКО ключ (`SERVER_SSH_KEY`), пользователь
  root (у `rodnya-deploy` NOPASSWD-sudo есть только на
  rodnya-activate-web-release/rodnya-set-android-update, не на
  rodnya-activate-backend-release). Секрет `BACKEND_SERVER_PASSWORD` удалён;
  парольный вход по ssh на сервере отключён — решения на нём не работают.
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
  /dl/* (APK — на новом сервере только 3 последние сборки, остальные 23
  остались на старом, переносить не планировалось).
- Сервер (с 31.08.2026): 77.91.113.109 (HOSTKEY, РФ) — переезд со старого
  77.67.89.164 (Нидерланды) из-за 152-ФЗ и общего IP с VPN. UFW включён:
  открыты 22, 80, 443, 7881/tcp (ICE), 50000-60000/udp (медиа), 5349/tcp
  (TURN/TLS), 30000-40000/udp (релей TURN) — новый порт наружу требует
  `ufw allow`. env бэкенда — `/etc/rodnya-backend.env` (флаги читаются на
  старте — смена требует restart).
- Старый сервер временно (до расхождения DNS) проксирует rodnya-tree.ru/
  api./livekit./turn. на новый — прокси-блоки и проброс
  `/.well-known/acme-challenge/*` в его Caddyfile снять через день-два. На
  старом сервере остаётся VPN-стек (awg0/awg1/remnawave/xray/sing-box) — к
  Родне отношения не имеет, не трогать. В DNS-зоне не трогать почтовые записи
  Unisender (`_dmarc`, NS/SPF/DKIM); `wl.rodnya-tree.ru` — мёртвая запись.
