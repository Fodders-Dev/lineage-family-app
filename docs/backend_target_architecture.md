# Backend Target Architecture

Дата фиксации: 2026-03-26

## Цель

Довести Lineage до Android/web MVP без прямой зависимости клиента от Firebase cloud и hosted Supabase, сохранив быстрый путь к релизу и возможность поэтапной миграции без big-bang rewrite.

## Рекомендованное целевое состояние

Flutter-клиент должен общаться только с собственным backend API и websocket-шлюзом.

Обязательные архитектурные правила:

- никаких прямых SDK-вызовов `FirebaseFirestore`, `FirebaseAuth`, `supabase_flutter` из UI и feature-слоя;
- клиент работает через repositories/adapters/use-cases;
- backend является единственным source of truth для auth, tree data, relations, chat, media metadata и push routing;
- vendor integrations остаются только за backend adapters.

## Recommended Target Stack

### Backend application

- `NestJS` как основной backend-монолит
- `TypeScript`
- `Prisma` для schema management и migrations

Почему `NestJS`:

- это fastest realistic delivery для MVP;
- в репозитории уже есть server-side след на JS через `functions/index.js`;
- удобно собрать в одном приложении REST API, WebSocket gateway, jobs и push adapters.

### Data and infrastructure

- `PostgreSQL` как основной store
- `Redis` для ephemeral state:
  - refresh tokens;
  - rate limiting;
  - online presence;
  - background job coordination;
  - websocket fan-out metadata
- `MinIO` или другой `S3-compatible` storage для аватаров и media

### Auth and session

- own `JWT access + refresh tokens`
- email/password как основной auth flow для MVP
- Google sign-in не делать обязательным для MVP

Принцип:

- идентичности и сессии живут в собственном backend;
- Flutter получает access/refresh token и больше не зависит от Firebase Auth runtime.

### Chat and realtime

- `WebSocket gateway` для 1:1 чатов и in-app notifications
- `PostgreSQL` хранит chat/message state
- unread counters и previews считаются сервером, а не поддерживаются клиентом вручную

### Push delivery

- backend push gateway с provider adapters
- primary: `RuStore Push`
- temporary fallback: `FCM` для GMS-устройств, пока transition не завершен

Принцип:

- клиент только регистрирует device token на собственном backend;
- backend сам решает, в какой push-provider отправлять уведомление.

### Deep links

- `HTTPS App Links / Universal Links` на своем домене
- без Firebase Dynamic Links

## Boundary Between Flutter and Backend

Flutter должен работать через следующие abstraction slices:

- `session`
- `users`
- `trees`
- `relations`
- `chat`
- `media`
- `notifications`

Каждый slice должен иметь:

- domain-facing repository interface;
- current Firebase adapter на переходный период;
- будущий API adapter для собственного backend.

Это обязательный промежуточный слой. Без него миграция останется дорогой и хрупкой.

## Mapping Current Firestore Entities to Target Model

| Текущее Firestore shape | Целевая модель |
| --- | --- |
| `users` | `users`, `user_identities`, `device_push_tokens` |
| `family_trees` + `tree_members` | `trees`, `tree_memberships` |
| `family_persons` | `persons` |
| `family_relations` | `person_relations` |
| `relation_requests` | `relationship_requests` / `invitations` |
| `chats` + `messages` + `chat_previews` | `chats`, `chat_participants`, `messages` |
| `posts` + `comments` | `posts`, `post_media`, `comments` |
| `profile_notes` | `profile_notes` |

Дополнительно:

- derived `chat_previews` не должны быть отдельным клиентским source of truth;
- `device_push_tokens` должны хранить platform/provider metadata;
- membership/permissions деревьев должны считаться сервером, а не UI.

## Recommended Backend Modules

### Auth module

- registration
- login
- refresh
- logout
- password reset
- device/session tracking

### User/Profile module

- profile read/update
- avatar metadata
- device token registration

### Trees module

- tree CRUD
- memberships and roles
- access checks

### Persons and Relations module

- person CRUD
- relation CRUD
- request/invitation workflow
- invited user linking

### Chat module

- create/get 1:1 chat
- message history
- send/read events
- unread counters

### Feed module

- posts
- post media
- comments

### Media module

- presigned upload flow
- media validation
- public/private access policy

### Notifications module

- push dispatch orchestration
- provider adapters
- notification event templates

## Migration Principle

Миграция должна идти только так:

1. сначала adapters/interfaces в Flutter;
2. потом backend vertical slices;
3. потом dual-write/read-switch;
4. потом удаление Firebase/Supabase SDK.

Что это означает practically:

- сначала вводятся repository interfaces и Firebase adapters;
- затем новый backend реализует slice за slice;
- затем клиент переключается с прямого SDK на API adapter;
- только после стабилизации удаляются старые vendor SDK и legacy code.

## Self-Hosted Supabase: допустимый, но не целевой компромисс

Self-hosted Supabase допустим только как временная инфраструктурная ступень:

- можно использовать `Postgres + Auth + Storage` self-hosted, если это ускорит старт;
- нельзя снова строить прямой доступ Flutter-клиента к vendor SDK как основную архитектуру.

То есть:

- self-hosted Supabase может временно закрыть infra gap;
- но публичный контракт системы все равно должен идти через собственный backend слой.

Для Russia-friendly managed-варианта допустим и более раздельный стек на собственной или локально-контролируемой инфраструктуре, например:

- `Yandex Cloud Managed PostgreSQL` для primary DB;
- `Yandex Object Storage` для media;
- `Serverless Containers` или обычные VM/Kubernetes для `NestJS`;
- WebSocket/API gateway слой на своей инфраструктуре или в локально-контролируемом облаке.

## Rollout Order

### P0

- убрать Firebase Dynamic Links из invite flow;
- ввести первые backend abstraction seams для auth, profiles, family tree, chat, file storage и notifications;
- завести backend foundation: `NestJS`, `PostgreSQL`, `Prisma`, `Redis`, `MinIO`;
- реализовать регистрацию device tokens и push adapters;
- зафиксировать, что новые feature changes не добавляют прямой Firebase coupling в UI.

### P1

- auth/profile/session bootstrap -> собственный backend;
- media upload -> presigned S3-compatible uploads;
- tree/person/relation/request flows -> API + Postgres;
- 1:1 chat -> WebSocket + Postgres + push gateway.

### P2

- убрать Firebase Crashlytics/Analytics или заменить;
- удалить Firebase Cloud Functions;
- удалить Firebase SDK из Flutter и platform config;
- удалить `supabase_flutter`, когда storage/auth transition завершен.

## First Migration Phase

Цель первой фазы: создать backend abstraction seams, чтобы Flutter-приложение больше не зависело напрямую от Firebase или Supabase внутри UI-кода, сохранив текущее поведение на существующем backend.

### Scope

- ввести repository/service interfaces для:
  - auth;
  - profiles;
  - family tree;
  - chat;
  - file storage;
  - notifications;
- вынести прямые SDK-вызовы из `screens/` и другого UI-heavy кода;
- сохранить текущий runtime behavior через существующие Firebase/Supabase adapters;
- добавить configuration points для выбора backend provider;
- не делать full migration backend на этой фазе.

### Implementation Strategy

Первая фаза должна быть минимальной и обратимой:

1. добавить интерфейсы репозиториев в backend-neutral слое;
2. обернуть текущие Firebase/Supabase сервисы в adapters, а не переписывать их заново;
3. переключить `screens/` и route/bootstrap код на работу через interfaces;
4. оставить существующие vendor SDK как внутреннюю реализацию adapters;
5. подготовить provider selection config, чтобы следующий backend можно было подключить без повторного рефакторинга UI.

### Recommended Seams for This Repo

На основе текущего кода первый migration slice должен пройти через эти точки:

- `session/auth`
  - закрыть прямые обращения к `FirebaseAuth` в `lib/main.dart`, `lib/navigation/app_router.dart`, `lib/services/auth_service.dart`;
- `profiles`
  - дать единый interface поверх `ProfileService` и чтения профиля пользователя;
- `family tree`
  - вынести tree/person/relation access из экранов в repository/service layer;
- `chat`
  - закрыть прямые Firestore query из chat-related UI;
- `file storage`
  - скрыть выбор между Firebase Storage legacy и Supabase Storage за interface;
- `notifications`
  - скрыть FCM / RuStore specifics за adapter boundary.

### Configuration Points

Первая фаза должна ввести явные точки конфигурации backend provider selection:

- `authProvider`
- `profileProvider`
- `treeProvider`
- `chatProvider`
- `storageProvider`
- `notificationProvider`

На этой фазе все они могут указывать на текущие Firebase/Supabase реализации по умолчанию, но выбор не должен быть захардкожен внутри UI.

### Expected File Areas

Без big-bang rewrite основная работа должна происходить вокруг:

- `lib/main.dart`
- `lib/navigation/app_router.dart`
- `lib/services/auth_service.dart`
- `lib/services/profile_service.dart`
- `lib/services/family_service.dart`
- `lib/services/chat_service.dart`
- `lib/services/storage_service.dart`
- `lib/services/notification_service.dart`

И вокруг экранов, которые сейчас ходят напрямую в `FirebaseAuth` / `FirebaseFirestore`.

### Testing Requirements

На этой фазе нужно:

- добавить или обновить тесты на новые interfaces/adapters;
- покрыть route/session bootstrap после отвязки UI от прямого `FirebaseAuth`;
- проверить, что существующее поведение не меняется при current provider selection;
- не ограничиваться только compile-level refactor.

### Verification Requirements

После выполнения первой фазы нужно:

- запустить `dart format` на измененных файлах;
- запустить `flutter analyze`;
- запустить `flutter test`;
- в финальном отчете перечислить:
  - измененные файлы;
  - что прошло из verification;
  - какие direct-backend hotspots еще остались.

### Constraints

- минимальные обратимые изменения;
- без full migration на новый backend;
- без big-bang rewrite;
- поведение приложения должно сохраниться;
- работа не должна останавливаться на analysis-only этапе.

## Acceptance Criteria for Target State

- Flutter стартует и проходит route guard без прямой зависимости от Firebase SDK.
- Invite flow работает через собственные HTTPS links.
- Device tokens хранятся на собственном backend, а не в Firestore.
- Media upload не зависит от hosted Supabase.
- Tree/person/relation/chat data читаются и пишутся через backend API/WebSocket.
- Firebase packages не нужны для core product path Android/web MVP.

## Constraints and Assumptions

- Android и web являются first-class платформами; iOS позже.
- Россия является обязательной целевой средой, поэтому backend должен быть self-hostable или Russia-friendly.
- Голос/видео звонки не входят в этот migration scope.
- В текущем repo нет отдельного backend-сервиса, поэтому backend foundation придется поднимать отдельно или в новом каталоге/репозитории.

## Single Best Next Implementation Task

Ввести `BackendSessionRepository` и `UserProfileRepository` с текущими Firebase-адаптерами и перевести на них `lib/main.dart`, `lib/navigation/app_router.dart`, `lib/services/auth_service.dart`, не меняя поведения.

Это лучший следующий шаг, потому что он:

- создает первый обязательный abstraction seam;
- минимально рискован;
- напрямую уменьшает Firebase coupling в app bootstrap;
- открывает путь к следующей фазе миграции без остановки разработки MVP.

## Источники

- Firebase Dynamic Links FAQ: <https://firebase.google.com/support/dynamic-links-faq>
- Firebase Dynamic Links docs: <https://firebase.google.com/docs/dynamic-links>
- Supabase self-hosting: <https://supabase.com/docs/guides/self-hosting>
- Supabase self-hosted S3 storage: <https://supabase.com/docs/guides/self-hosting/self-hosted-s3>
- RuStore Push docs: <https://www.rustore.ru/help/sdk/push-notifications>
