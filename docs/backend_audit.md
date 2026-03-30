# Backend Audit: Firebase / Supabase Migration Baseline

Дата аудита: 2026-03-26

## Итог аудита

В репозитории нет собственного backend API; Flutter-клиент ходит напрямую в Firebase/Supabase; единственный server-side код внутри репо это Cloud Functions.

Для MVP это означает, что backend не отделен от клиента: бизнес-логика, авторизация, чтение/запись данных, push и deep links завязаны на vendor SDK прямо в `lib/`, а не на внутренние интерфейсы или HTTP/WebSocket API.

## Exact Dependency Map

### Firebase init/config

- `pubspec.yaml`
- `lib/main.dart`
- `lib/firebase_options.dart`
- `firebase.json`
- `.firebaserc`
- `android/build.gradle`
- `android/settings.gradle`
- `android/app/build.gradle`
- `android/app/google-services.json`
- `web/index.html`

### Firebase Auth

- `lib/services/auth_service.dart`
- `lib/navigation/app_router.dart`
- `lib/main.dart`
- `lib/screens/auth_screen.dart`
- `lib/screens/add_relative_screen.dart`
- `lib/screens/chat_screen.dart`
- `lib/screens/complete_profile_screen.dart`
- `lib/screens/find_relative_screen.dart`
- `lib/screens/offline_profiles_screen.dart`
- `lib/screens/profile_screen.dart`
- `lib/screens/profile_edit_screen.dart`
- `lib/screens/relation_request_screen.dart`
- `lib/screens/relation_requests_screen.dart`
- `lib/screens/relatives_screen.dart`
- `lib/screens/send_relation_request_screen.dart`
- `lib/screens/tree_selector_screen.dart`
- `lib/screens/tree_view_screen.dart`
- `lib/screens/trees_screen.dart`
- `lib/widgets/post_card.dart`

### Firestore runtime/services

- `lib/services/auth_service.dart`
- `lib/services/family_service.dart`
- `lib/services/chat_service.dart`
- `lib/services/post_service.dart`
- `lib/services/profile_service.dart`
- `lib/services/sync_service.dart`
- `lib/main.dart`

### Firestore direct UI coupling

- `lib/screens/add_relative_screen.dart`
- `lib/screens/chat_screen.dart`
- `lib/screens/complete_profile_screen.dart`
- `lib/screens/find_relative_screen.dart`
- `lib/screens/family_tree/create_tree_screen.dart`
- `lib/screens/profile_edit_screen.dart`
- `lib/screens/profile_screen.dart`
- `lib/screens/relation_request_screen.dart`
- `lib/screens/relation_requests_screen.dart`
- `lib/screens/relatives_screen.dart`
- `lib/screens/send_relation_request_screen.dart`
- `lib/screens/tree_selector_screen.dart`
- `lib/screens/trees_screen.dart`

### Firestore-coupled models

- `lib/models/user_profile.dart`
- `lib/models/family_person.dart`
- `lib/models/family_relation.dart`
- `lib/models/family_tree.dart`
- `lib/models/family_tree_member.dart`
- `lib/models/relation_request.dart`
- `lib/models/post.dart`
- `lib/models/comment.dart`
- `lib/models/chat_message.dart`
- `lib/models/chat_preview.dart`
- `lib/models/event.dart`
- `lib/models/story.dart`
- `lib/models/profile_note.dart`

### FCM / notifications

- `lib/services/notification_service.dart`
- `lib/services/auth_service.dart`
- `lib/models/user_profile.dart`
- `functions/index.js`
- `functions/package.json`
- `android/app/src/main/AndroidManifest.xml`

### Firebase Dynamic Links

- `lib/main.dart`
- `lib/navigation/deep_link_handler.dart`
- `lib/services/family_service.dart`
- `lib/screens/relative_details_screen.dart`

### Firebase Crashlytics / Analytics

- `lib/main.dart`
- `lib/services/crashlytics_service.dart`
- `lib/services/analytics_service.dart`
- `lib/services/family_service.dart`
- `lib/screens/relatives_screen.dart`
- `lib/screens/tree_view_screen.dart`
- `lib/screens/trees_screen.dart`

### Firebase Storage legacy

- `lib/services/storage_service.dart`
- `lib/services/post_service.dart`
- `lib/services/profile_service.dart`

### Supabase

- `lib/main.dart`
- `lib/services/storage_service.dart`
- `lib/services/post_service.dart`
- `lib/services/profile_service.dart`

## Repo-Specific Findings

### 1. Firebase является source of truth почти для всего MVP

- `FirebaseAuth` определяет session bootstrap, route guard и часть UI-поведения.
- `Firestore` хранит профили, деревья, участников, персон, связи, запросы, чаты, сообщения, посты и комментарии.
- `SyncService` и background tasks стартуют с обязательной инициализацией Firebase.
- Экранный слой регулярно идет в `FirebaseFirestore.instance` напрямую, минуя сервисный слой.

### 2. Supabase в репозитории не является основным backend

- `supabase_flutter` используется только для storage-операций в `StorageService`.
- Активные пути использования:
  - `uploadAvatar()` для фото профиля;
  - `uploadBytes()` для изображений постов.
- При этом `Supabase.initialize(...)` захардкожен в `lib/main.dart`, включая URL и anon key.

### 3. Storage уже находится в гибридном и незавершенном состоянии

- `StorageService` одновременно содержит:
  - legacy Firebase Storage API;
  - активные Supabase Storage API.
- `ProfileService` уже пишет avatar URL в Firestore и Firebase Auth, но upload делает в Supabase.
- `PostService` грузит media в Supabase Storage.
- Legacy-методы Firebase Storage остаются в коде и продолжают удерживать зависимость.

### 4. Push path завязан на Firebase Cloud Messaging

- Клиент получает FCM token в `NotificationService`.
- Токены сохраняются в Firestore в поле `users.fcmTokens`.
- Отправка chat push реализована только через Firebase Cloud Function `functions/index.js`.
- Для Android вне GMS этот путь недостаточен.
- RuStore Push SDK уже подключен, но server-side integration отсутствует: токен лишь логируется, а не регистрируется на backend.

### 5. Deep links уже находятся в broken legacy зоне

- В коде есть `firebase_dynamic_links` и несколько `.page.link` / `lineage.app` invite paths.
- На 2026-03-26 это не просто риск: Firebase Dynamic Links официально прекращены 2025-08-25.
- Значит invite flow и любая зависимость от `.page.link` должны считаться сломанными legacy-механизмами.

### 6. В repo нет собственного backend foundation

- Нет отдельного API-сервиса.
- Нет схемы БД.
- Нет migration tooling.
- Нет device token registry вне Firestore.
- Единственный server-side код это Firebase Cloud Functions, заточенные под Firestore/FCM.

## Firestore Data Shape

По коду и query-паттернам проект опирается на следующие коллекции Firestore:

- `users`
- `family_trees`
- `tree_members`
- `family_persons`
- `family_relations`
- `relation_requests`
- `messages`
- `chat_previews`
- `chats`
- `posts`
- `comments`
- `profile_notes`
- `relatives`

Дополнительные замечания по shape:

- `users` используется как профиль, auth-linked record и token registry.
- `chat_previews` и `users/{id}/chats` частично дублируют derived state чата.
- `family_trees/{id}/relatives` и top-level `family_persons` сосуществуют одновременно, что повышает риск schema drift.
- Во многих моделях доменный serialization/deserialization использует `Timestamp`, `DocumentSnapshot`, `FieldValue`, а не backend-neutral DTO.

## Risk Assessment

| Уровень | Риск | Почему это важно |
| --- | --- | --- |
| Critical | Firebase Dynamic Links уже отключены; invite flow и `.page.link` нужно удалять сразу | В проекте осталась runtime-зависимость от сервиса, который больше не должен использоваться |
| Critical | Firestore/Auth являются source of truth почти для всех MVP-фич | Без замены этих зависимостей приложение не сможет стабильно работать на Russia-friendly backend |
| High | FCM + Cloud Functions завязаны на `fcmTokens` в Firestore и не покрывают Android-распространение вне GMS | Push path не соответствует платформенной реальности продукта |
| High | UI и модели напрямую знают про `FirebaseAuth`, `FirebaseFirestore`, `Timestamp`, `DocumentSnapshot`, `FieldValue` | Миграция усложняется не только заменой сервиса, но и чисткой архитектурной связности |
| Medium | hosted Supabase используется только для storage, но URL и anon key зашиты в `lib/main.dart` | Даже точечная интеграция пока не вынесена в конфиг и не готова к безопасной замене |
| Medium | `firebase_storage` остался в коде как legacy API в `StorageService`, хотя активный путь уже гибридный | Наличие двух storage paths затрудняет понимание реального источника истины |
| Low / Temporary | Crashlytics и Analytics не должны блокировать миграцию core backend | Эти зависимости можно оставить до поздней стадии, если они не мешают выпуску MVP |

## Что legacy и что оставить временно

| Статус | Компонент | Решение |
| --- | --- | --- |
| Оставить временно | Firebase Crashlytics | Не блокирует миграцию core backend, можно вывести позже |
| Оставить временно | Firebase Analytics | Не должен тормозить перенос auth/data/chat |
| Оставить временно | FCM как secondary fallback | Допустим на переходный период для GMS-устройств |
| Оставить временно | hosted Supabase Storage | Можно держать до появления собственного media adapter и S3-compatible storage |
| Legacy к немедленному выводу | Firebase Dynamic Links | Сервис де-факто мертв; invite path нужно перевести на свои HTTPS links |
| Legacy к немедленному выводу | Cloud Functions `sendChatNotification` | Жестко завязана на Firestore и FCM |
| Legacy к немедленному выводу | Прямые импорты `FirebaseFirestore` / `FirebaseAuth` в UI | Нужно переводить на repositories/adapters |
| Legacy к немедленному выводу | hardcoded `Supabase.initialize(...)` в `lib/main.dart` | Конфиг должен уйти в abstraction/config layer |

## Migration Blockers

- нет backend abstraction layer;
- многие экраны ходят в Firestore напрямую;
- модели домена завязаны на Firestore-типы;
- `main.dart` и background tasks не стартуют без Firebase;
- push-token lifecycle хранится только в Firestore;
- invite/deep-link flow зависит от мертвого сервиса;
- в workspace нет отдельного backend-репозитория;
- `flutter analyze` и `flutter test` сейчас не запускаются, потому что `flutter` не найден в shell.

## Рекомендованный Target Stack

- `NestJS`
- `PostgreSQL`
- `Prisma`
- `Redis`
- `MinIO` или другой `S3-compatible` storage
- own `JWT access + refresh tokens`
- `WebSocket` gateway для 1:1 чатов
- push gateway с `RuStore Push` как primary path и `FCM` как temporary fallback
- `HTTPS App Links / Universal Links` на своем домене

## P0 / P1 / P2 Migration Backlog

### P0

- Удалить зависимость invite-flow от Firebase Dynamic Links и перевести приглашения на свои HTTPS links + App Links / Universal Links.
- Ввести backend abstraction layer в Flutter: `session`, `users`, `trees`, `relations`, `chat`, `media`, `notifications`.
- Перестать добавлять новые прямые вызовы `FirebaseAuth` / `FirebaseFirestore` в `screens/` и `widgets/`.
- Поднять backend foundation: `NestJS`, `PostgreSQL`, `Prisma`, `Redis`, `MinIO`, auth/session endpoints.
- Сделать device token registry и push adapters; подключить `RuStore Push` как primary path.
- Реализовать первую migration phase без смены текущего backend behavior:
  - ввести interfaces для auth, profiles, family tree, chat, file storage и notifications;
  - вынести direct SDK calls из UI-heavy кода;
  - добавить configuration points для backend provider selection;
  - обновить или добавить релевантные тесты.

### P1

- Перенести auth/profile/session bootstrap с Firebase Auth на собственный backend.
- Перенести media upload с hosted Supabase на `MinIO` / `S3` через presigned upload.
- Перенести `trees` / `persons` / `relations` / `requests` с Firestore на API + Postgres.
- Перенести chat с `Firestore + Cloud Function + FCM` на `WebSocket + Postgres + push gateway`.

### P2

- Убрать `Firebase Crashlytics` / `Firebase Analytics` или заменить на self-hosted / neutral observability.
- Удалить `functions/`, `firebase_options.dart`, `google-services.json`, Firebase scripts из `web/index.html`, `firebase_*` packages.
- Удалить `supabase_flutter` после завершения storage/auth transition.

## Single Best Next Implementation Task

Ввести `BackendSessionRepository` и `UserProfileRepository` с текущими Firebase-адаптерами и перевести на них `lib/main.dart`, `lib/navigation/app_router.dart`, `lib/services/auth_service.dart`, не меняя поведение приложения.

Почему это лучший следующий шаг:

- это минимальный seam, который убирает прямую зависимость старта приложения и route guard от Firebase SDK;
- он позволяет продолжить миграцию без big-bang rewrite;
- он задает первую backend-neutral contract surface внутри Flutter-клиента.

## Verification Notes

- `docs/` отсутствовала до этого изменения и была создана в рамках задачи.
- Runtime-код приложения не менялся.
- `flutter analyze` не удалось запустить: `flutter` отсутствует в `PATH`.
- `flutter test` не удалось запустить: `flutter` отсутствует в `PATH`.

## Источники

- Firebase Dynamic Links FAQ: <https://firebase.google.com/support/dynamic-links-faq>
- Firebase Dynamic Links docs: <https://firebase.google.com/docs/dynamic-links>
- Supabase self-hosting: <https://supabase.com/docs/guides/self-hosting>
- Supabase self-hosted S3 storage: <https://supabase.com/docs/guides/self-hosting/self-hosted-s3>
- RuStore Push docs: <https://www.rustore.ru/help/sdk/push-notifications>
