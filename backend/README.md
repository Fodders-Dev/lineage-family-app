# Lineage Minimal Backend

Минимальный self-hostable backend contract для dev-переключения Flutter-приложения на `customApi` без Firebase Auth/Profile bootstrap.

## Что реализовано

- `POST /v1/auth/register`
- `POST /v1/auth/login`
- `POST /v1/auth/logout`
- `GET /v1/auth/session`
- `POST /v1/auth/password-reset`
- `DELETE /v1/auth/account`
- `POST /v1/auth/google` с явным `501 Not Implemented`
- `GET /v1/profile/me/bootstrap`
- `PUT /v1/profile/me/bootstrap`
- `PATCH /v1/profile/me`
- `POST /v1/profile/me/verify-phone`
- `GET /v1/users/:id/profile-notes`
- `POST /v1/users/:id/profile-notes`
- `PATCH /v1/users/:id/profile-notes/:noteId`
- `DELETE /v1/users/:id/profile-notes/:noteId`
- `GET /v1/users/search`
- `GET /v1/users/search/by-field`
- `GET /v1/users/:id/profile`
- `PATCH /v1/users/:id/profile`
- `POST /v1/invitations/pending/process`
- `POST /v1/media/upload`
- `DELETE /v1/media`
- `GET /v1/posts`
- `POST /v1/posts`
- `DELETE /v1/posts/:postId`
- `POST /v1/posts/:postId/like`
- `GET /v1/posts/:postId/comments`
- `POST /v1/posts/:postId/comments`
- `DELETE /v1/posts/:postId/comments/:commentId`
- `POST /v1/trees`
- `GET /v1/trees`
- `DELETE /v1/trees/:treeId`
- `GET /v1/trees/selectable`
- `GET /v1/trees/:treeId/persons`
- `POST /v1/trees/:treeId/persons`
- `GET /v1/trees/:treeId/persons/:personId`
- `PATCH /v1/trees/:treeId/persons/:personId`
- `DELETE /v1/trees/:treeId/persons/:personId`
- `GET /v1/trees/:treeId/relations`
- `POST /v1/trees/:treeId/relations`
- `POST /v1/trees/:treeId/invitations`
- `GET /v1/trees/:treeId/relation-requests`
- `POST /v1/trees/:treeId/relation-requests`
- `GET /v1/tree-invitations/pending`
- `POST /v1/tree-invitations/:invitationId/respond`
- `GET /v1/relation-requests/pending`
- `POST /v1/relation-requests/:requestId/respond`
- `GET /v1/chats`
- `GET /v1/chats/unread-count`
- `POST /v1/chats/direct`
- `GET /v1/chats/:chatId/messages`
- `POST /v1/chats/:chatId/messages`
- `PATCH /v1/chats/:chatId/messages/:messageId`
- `DELETE /v1/chats/:chatId/messages/:messageId`
- `POST /v1/chats/:chatId/read`
- `GET /v1/notifications`
- `GET /v1/notifications/unread-count`
- `POST /v1/notifications/:notificationId/read`
- `GET /v1/push/devices`
- `GET /v1/push/web/config`
- `POST /v1/push/devices`
- `DELETE /v1/push/devices/:deviceId`
- `GET /v1/push/deliveries`
- `GET /media/*`
- `GET /health`
- `WS /v1/realtime?accessToken=...`

## Запуск

```powershell
cd backend
npm install
npm start
```

По умолчанию сервер поднимается на `http://127.0.0.1:8080`.

## Переменные окружения

- `PORT` - порт сервера, по умолчанию `8080`
- `LINEAGE_BACKEND_DATA_PATH` - путь к JSON-файлу dev-хранилища, по умолчанию `backend/data/dev-db.json`
- `LINEAGE_BACKEND_CORS_ORIGIN` - CORS origin, по умолчанию `*`
- `LINEAGE_BACKEND_MEDIA_ROOT` - папка для сохранения media-файлов, по умолчанию `backend/data/uploads`
- `LINEAGE_PUBLIC_API_URL` - публичная база backend API для генерации media URL, например `https://api.rodnya-tree.ru`
- `LINEAGE_PUBLIC_APP_URL` - публичный URL web-приложения, по умолчанию `https://rodnya-tree.ru`
- `LINEAGE_WEB_PUSH_PUBLIC_KEY` - публичный VAPID key для browser push
- `LINEAGE_WEB_PUSH_PRIVATE_KEY` - приватный VAPID key для browser push
- `LINEAGE_WEB_PUSH_SUBJECT` - VAPID subject, по умолчанию `https://rodnya-tree.ru`
- `LINEAGE_RUSTORE_PUSH_PROJECT_ID` - ID проекта RuStore Push из RuStore Console
- `LINEAGE_RUSTORE_PUSH_SERVICE_TOKEN` - сервисный токен RuStore Push из RuStore Console
- `LINEAGE_RUSTORE_PUSH_API_BASE_URL` - базовый URL RuStore Push API, по умолчанию `https://vkpns.rustore.ru`

## Подключение Flutter dev-сборки

```powershell
flutter run `
  --dart-define=LINEAGE_AUTH_PROVIDER=customApi `
  --dart-define=LINEAGE_PROFILE_PROVIDER=customApi `
  --dart-define=LINEAGE_TREE_PROVIDER=customApi `
  --dart-define=LINEAGE_CHAT_PROVIDER=customApi `
  --dart-define=LINEAGE_STORAGE_PROVIDER=customApi `
  --dart-define=LINEAGE_NOTIFICATION_PROVIDER=customApi `
  --dart-define=LINEAGE_API_BASE_URL=http://127.0.0.1:8080 `
  --dart-define=LINEAGE_WS_BASE_URL=ws://127.0.0.1:8080 `
  --dart-define=LINEAGE_ENABLE_LEGACY_DYNAMIC_LINKS=false
```

## Ограничения

- Это dev bootstrap backend, а не финальный production backend.
- Хранилище file-backed и подходит для локальной разработки, smoke-интеграции и первых ручных проверок.
- `Google sign-in`, remote push и realtime/websocket здесь ещё не реализованы полноценно.
- Media upload, profile notes и posts/feed реализованы в минимальном file-backed виде, без production-grade object storage и без realtime синхронизации.
- Tree API сейчас покрывает базовый MVP-срез: создание дерева, список деревьев, людей и прямые родственные связи.
- Tree invitations тоже покрыты в минимальном виде: backend умеет создать pending invite, показать его на вкладке приглашений и принять или отклонить.
- Relation requests и invite-link processing теперь тоже покрыты в минимальном виде для `customApi` dev-path.
- Chat API сейчас покрывает базовый MVP-срез: список чатов, историю сообщений, отправку и отметку как прочитанных через polling-stream на клиенте.
- Notification feed тоже покрыт в минимальном виде: backend создаёт unread-события для сообщений, заявок на родство и приглашений в дерево, а Flutter `customApi` path может забирать их polling-ом и показывать как локальные уведомления.
- Realtime-путь теперь тоже есть: backend поднимает `WS /v1/realtime`, а Flutter `customApi` chat/notification path может получать server-driven события для новых сообщений и уведомлений.
- Remote push теперь умеет реально доставлять browser push через Web Push API и RuStore push через `vkpns.rustore.ru`, если backend запущен с нужными ключами. Без `LINEAGE_RUSTORE_PUSH_*` или `LINEAGE_WEB_PUSH_*` переменных соответствующий канал остаётся в состоянии `*_not_configured`.
- Browser push теперь поддерживается отдельно через Web Push API и VAPID, если backend запущен с `LINEAGE_WEB_PUSH_*` ключами.
