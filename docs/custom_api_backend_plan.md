# Minimal Custom API Backend Plan

Дата: 2026-03-27

## Цель

Поднять минимальный self-hostable backend contract под уже существующие `customApi`-адаптеры Flutter, чтобы приложение можно было запускать в dev-режиме без обязательного Firebase Auth/Profile bootstrap.

## P0

- Поднять отдельный `backend/` сервис рядом с Flutter-репозиторием.
- Реализовать `POST /v1/auth/register`.
- Реализовать `POST /v1/auth/login`.
- Реализовать `GET /v1/auth/session`.
- Реализовать `POST /v1/auth/logout`.
- Реализовать `POST /v1/auth/password-reset` как безопасный no-op/accepted flow для dev.
- Реализовать `DELETE /v1/auth/account`.
- Реализовать `GET /v1/profile/me/bootstrap`.
- Реализовать `PUT /v1/profile/me/bootstrap`.
- Реализовать `PATCH /v1/profile/me`.
- Реализовать `POST /v1/profile/me/verify-phone`.
- Реализовать `GET /v1/users/search`.
- Реализовать `GET /v1/users/search/by-field`.
- Реализовать `GET /v1/users/:id/profile`.
- Реализовать `PATCH /v1/users/:id/profile` для собственного профиля.
- Реализовать `POST /v1/invitations/pending/process` как безопасный no-op/stub.
- Добавить file-backed dev storage и автотесты.

## P1

- Добавить `POST /v1/auth/google` как backend-managed Google sign-in flow.
- Добавить `media` contract для аватаров и файлов: upload init, finalize, delete.
- Добавить `profile notes` endpoints.
- Перевести `CustomApiProfileService.uploadProfilePhoto` с `UnsupportedError` на реальный backend path.

## P2

- Перенести `tree` домен.
- Перенести `chat/realtime`.
- Перенести `notifications` и device token registry.
- Перенести `storage` на S3-compatible media path.
- Отдельно снизить исторический шум `flutter analyze`.

## Порядок внедрения

1. Запускать backend локально.
2. Переключать Flutter dev-сборку на:
   - `LINEAGE_AUTH_PROVIDER=customApi`
   - `LINEAGE_PROFILE_PROVIDER=customApi`
   - `LINEAGE_API_BASE_URL=http://127.0.0.1:8080`
   - `LINEAGE_ENABLE_LEGACY_DYNAMIC_LINKS=false`
3. Проверять auth + profile bootstrap end-to-end.
4. Только потом подключать следующие домены.

## Ограничения P0

- P0 backend контракт предназначен для локальной разработки и adapter integration.
- В P0 допустимы file-backed storage и no-op/stub endpoints.
- В P0 не решаются production-grade migration вопросы по Postgres, object storage, WebSocket и push gateway.
