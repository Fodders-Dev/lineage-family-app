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
- Скрипт активации бэкенда — `deploy/backend/activate_backend_release.sh`
  В РЕПО; оба workflow (`backend-deploy`, `production-watch`) заливают его
  на сервер при каждом запуске. Серверная копия
  `/usr/local/bin/rodnya-activate-backend-release` нужна только ручному
  `deploy/backend/deploy_backend.ps1` и обязана совпадать с репо (04.09.2026
  она отстала на 5 месяцев без `--no-audit`, и деплой повис на лежащем
  audit-эндпоинте registry; старая копия — рядом, `.bak-20260904`). `npm ci`
  в деплое — всегда `--no-audit`: активация не должна зависеть от
  доступности audit-сервиса npm.

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
- Откат SPEED-6: `restore-chat-collections-to-blob.js`, SPEED-7:
  `restore-notifications-to-blob.js`, SPEED-8b:
  `restore-tree-change-records-to-blob.js` (все — guard по маркеру, бэкенд
  остановлен; откат SPEED-8b сам инкрементит version строки, чтобы кэш
  чтения SPEED-8a увидел новый блоб).

## Топология

- Фронт — Caddy (nginx неактивен, fallback). Источник истины Caddyfile —
  `/etc/caddy/Caddyfile` НА СЕРВЕРЕ (репо-копия частична): после ручных правок
  копировать обратно в репо. Caddy раздаёт assetlinks.json (App Links:
  fingerprint обязан совпадать с подписью раздаваемого APK), /invite, /oauth,
  /dl/* (APK — на новом сервере только 3 последние сборки, остальные 23
  остались на старом, переносить не планировалось). Каталог
  `/opt/rodnya/static/dl` обязан принадлежать `rodnya-deploy` — OTA-workflow
  кладёт туда APK по scp от этого пользователя; после переезда он вернулся
  как `rodnya:rodnya 755`, и первый OTA упал на `Permission denied`.
- Сервер (с 31.08.2026): 77.91.113.109 (HOSTKEY, РФ) — переезд со старого
  77.67.89.164 (Нидерланды) из-за 152-ФЗ и общего IP с VPN. UFW включён:
  открыты 22, 80, 443, 7881/tcp (ICE), 50000-60000/udp (медиа), 5349/tcp
  (TURN/TLS), 30000-40000/udp (релей TURN) — новый порт наружу требует
  `ufw allow`. env бэкенда — `/etc/rodnya-backend.env` (флаги читаются на
  старте — смена требует restart).
- Старый сервер (77.67.89.164, `ssh rodnya-vps`) от Родни выведен полностью
  (02–03.09.2026): Caddy-блоки rodnya-tree.ru/api./livekit./turn. сняты
  (бэкап `/etc/caddy/Caddyfile.bak-2026-09-02-pre-rodnya-cleanup`), юниты
  rodnya-backend/rodnya-web-static/rodnya-livekit/rodnya-backup.timer,
  postgresql@14-main и minio — `disable --now`. Перед этим полнота переноса
  доказана пообъектно (все id блоба, сообщения по id, чат-таблицы по хэшу
  строк, 211 медиа-файлов по пути и размеру — старое ⊆ новое), а финальный
  архив старого сервера лежит на новом:
  `/var/backups/rodnya/old-server-final-20260903/` (свежий pg_dump,
  `/var/lib/minio/data`, env, последний ночной дамп). Файлы на старом не
  удалялись — сервер сотрётся с концом аренды. Там остаётся VPN-стек
  (awg0/awg1/remnawave/xray/sing-box) и прокси RadioAtlas — не трогать.
  В DNS-зоне не трогать почтовые записи Unisender (`_dmarc`, NS/SPF/DKIM);
  `wl.rodnya-tree.ru` — мёртвая запись.
