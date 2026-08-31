---
description: Read-only диагностика прод-сервера Родни — журнал бэкенда, send-timing, статусы сервисов, статистика блоба и чат-таблиц, пуш-реестр
---

# Диагностика прода (только чтение)

Доступ: `ssh fodders` (root, ключ настроен). ПРАВИЛО: этот skill — только
чтение; любые изменения на сервере — через CI или по явной просьбе пользователя.

## Здоровье

```bash
curl -s https://api.rodnya-tree.ru/ready
ssh fodders "systemctl is-active rodnya-backend caddy rodnya-livekit; uptime"
ssh fodders "journalctl -u rodnya-backend --since '1 hour ago' --no-pager | grep -iE 'error|failed' | tail -20"
```

## Скорость чатов ([send-timing] пишется на каждый send)

```bash
ssh fodders "journalctl -u rodnya-backend --since '1 day ago' --no-pager | grep -oE 'access=[0-9]+ms persist=[0-9]+ms ack=[0-9]+ms' | tail -30"
```

Норма после SPEED-6/7: access 1–3мс, persist 7–15мс, ack < 30мс серверных.
SPEED-7 (30.08) вынес фан-аут уведомлений из блоба — стабильные всплески
persist теперь повод смотреть pg-индексы/нагрузку общего VPS, не блоб.

## Данные (env: LINEAGE_POSTGRES_URL в /etc/rodnya-backend.env)

```bash
ssh fodders "url=\$(grep -oP 'LINEAGE_POSTGRES_URL=\K.*' /etc/rodnya-backend.env); psql \"\$url\" -tAc \"SELECT pg_size_pretty(pg_column_size(data)::bigint), jsonb_array_length(data->'users'), jsonb_array_length(data->'trees'), jsonb_array_length(data->'semyi') FROM public.rodnya_state WHERE id='default'\""
ssh fodders "url=\$(grep -oP 'LINEAGE_POSTGRES_URL=\K.*' /etc/rodnya-backend.env); psql \"\$url\" -tAc 'SELECT COUNT(*) FROM public.rodnya_state_chat_messages'"
ssh fodders "url=\$(grep -oP 'LINEAGE_POSTGRES_URL=\K.*' /etc/rodnya-backend.env); psql \"\$url\" -tAc 'SELECT (SELECT COUNT(*) FROM public.rodnya_state_notifications), (SELECT COUNT(*) FROM public.rodnya_state_push_deliveries)'"
```

Счётчики новых таблиц (SPEED-7, 30.08): notifications/pushDeliveries внутри
блоба после этого в состоянии покоя пусты (транзитная очередь, drain на
каждой записи) — не путать пустой блоб-массив с отсутствием данных.

## Пуш-реестр по провайдерам

```bash
ssh fodders "url=\$(grep -oP 'LINEAGE_POSTGRES_URL=\K.*' /etc/rodnya-backend.env); psql \"\$url\" -tAc \"SELECT d->>'provider', COUNT(*) FROM public.rodnya_state, LATERAL jsonb_array_elements(data->'pushDevices') d WHERE id='default' GROUP BY 1\""
```

## Деплой-история и бэкапы

```bash
gh run list --limit 10
ssh fodders "ls -lah /opt/rodnya/backups/manual/ | tail -8"
```

Маркеры миграций в блобе: `data->'migrationStatus'` (chatCollectionsToTables,
treesToSemyi, treesToGraph).

## Переезд 31.08.2026

Сервер сменился: 77.67.89.164 (Нидерланды) → 77.91.113.109 (HOSTKEY, РФ,
причина — 152-ФЗ и общий IP с VPN); ssh-алиас старого сервера заменён на
`ssh fodders`. Ключевые изменения:

- Postgres 14 → 16; после `pg_restore --no-owner` владелец таблиц/
  последовательностей явно назначен роли `rodnya_backend` (иначе бэкенд падал
  с `must be owner of table`).
- Появился UFW (на старом не было): открыты 22, 80, 443, 7881/tcp (ICE),
  50000-60000/udp (медиа), 5349/tcp (TURN/TLS), 30000-40000/udp (релей TURN).
  Новый порт наружу — не забыть добавить в UFW.
- LiveKit слушает на новом IP (интерфейс `ens1`), TURN на `turn.rodnya-tree.ru`
  с сертификатом из каталога Caddy. MinIO и бакет `rodnya-media` — без изменений.
- Временно (пока не разойдётся DNS): старый сервер проксирует `rodnya-tree.ru`,
  `api.`, `livekit.`, `turn.` на новый — прокси-блоки в Caddyfile старого
  сервера снять через день-два после отписки DNS.
- `/opt/rodnya/static/dl`: на новом только 3 последние сборки APK, остальные
  23 остались на старом (переносить не планировалось).
- Таймер `rodnya-prune-deploy-backups` (новый): ежедневно оставляет последние
  10 копий из `/opt/rodnya/backups` и всё моложе 30 дней — на старом сервере
  бэкапы деплой-активаторов не чистились и набежало 17 ГБ.
- Не проверен живьём только видеозвонок между двумя реальными людьми;
  `/ready`, LiveKit, TURN и сверка БД (84 пользователя/42 чата/445 сообщений)
  подтверждены.
