---
description: Read-only диагностика прод-сервера Родни — журнал бэкенда, send-timing, статусы сервисов, статистика блоба и чат-таблиц, пуш-реестр
---

# Диагностика прода (только чтение)

Доступ: `ssh rodnya-vps` (root, ключ настроен). ПРАВИЛО: этот skill — только
чтение; любые изменения на сервере — через CI или по явной просьбе пользователя.

## Здоровье

```bash
curl -s https://api.rodnya-tree.ru/ready
ssh rodnya-vps "systemctl is-active rodnya-backend caddy rodnya-livekit; uptime"
ssh rodnya-vps "journalctl -u rodnya-backend --since '1 hour ago' --no-pager | grep -iE 'error|failed' | tail -20"
```

## Скорость чатов ([send-timing] пишется на каждый send)

```bash
ssh rodnya-vps "journalctl -u rodnya-backend --since '1 day ago' --no-pager | grep -oE 'access=[0-9]+ms persist=[0-9]+ms ack=[0-9]+ms' | tail -30"
```

Норма после SPEED-6/7: access 1–3мс, persist 7–15мс, ack < 30мс серверных.
SPEED-7 (30.08) вынес фан-аут уведомлений из блоба — стабильные всплески
persist теперь повод смотреть pg-индексы/нагрузку общего VPS, не блоб.

## Данные (env: LINEAGE_POSTGRES_URL в /etc/rodnya-backend.env)

```bash
ssh rodnya-vps "url=\$(grep -oP 'LINEAGE_POSTGRES_URL=\K.*' /etc/rodnya-backend.env); psql \"\$url\" -tAc \"SELECT pg_size_pretty(pg_column_size(data)::bigint), jsonb_array_length(data->'users'), jsonb_array_length(data->'trees'), jsonb_array_length(data->'semyi') FROM public.rodnya_state WHERE id='default'\""
ssh rodnya-vps "url=\$(grep -oP 'LINEAGE_POSTGRES_URL=\K.*' /etc/rodnya-backend.env); psql \"\$url\" -tAc 'SELECT COUNT(*) FROM public.rodnya_state_chat_messages'"
ssh rodnya-vps "url=\$(grep -oP 'LINEAGE_POSTGRES_URL=\K.*' /etc/rodnya-backend.env); psql \"\$url\" -tAc 'SELECT (SELECT COUNT(*) FROM public.rodnya_state_notifications), (SELECT COUNT(*) FROM public.rodnya_state_push_deliveries)'"
```

Счётчики новых таблиц (SPEED-7, 30.08): notifications/pushDeliveries внутри
блоба после этого в состоянии покоя пусты (транзитная очередь, drain на
каждой записи) — не путать пустой блоб-массив с отсутствием данных.

## Пуш-реестр по провайдерам

```bash
ssh rodnya-vps "url=\$(grep -oP 'LINEAGE_POSTGRES_URL=\K.*' /etc/rodnya-backend.env); psql \"\$url\" -tAc \"SELECT d->>'provider', COUNT(*) FROM public.rodnya_state, LATERAL jsonb_array_elements(data->'pushDevices') d WHERE id='default' GROUP BY 1\""
```

## Деплой-история и бэкапы

```bash
gh run list --limit 10
ssh rodnya-vps "ls -lah /opt/rodnya/backups/manual/ | tail -8"
```

Маркеры миграций в блобе: `data->'migrationStatus'` (chatCollectionsToTables,
treesToSemyi, treesToGraph).
