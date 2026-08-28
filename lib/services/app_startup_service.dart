import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backend/backend_provider_config.dart';
import '../backend/backend_provider_registry.dart';
import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/app_startup_service_interface.dart';
import '../backend/interfaces/call_service_interface.dart';
import '../backend/interfaces/chat_service_interface.dart';
import '../backend/interfaces/circle_service_interface.dart';
import '../backend/interfaces/dynamic_link_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/identity_service_interface.dart';
import '../backend/interfaces/invitation_link_service_interface.dart';
import '../backend/interfaces/notification_service_interface.dart';
import '../backend/interfaces/post_service_interface.dart';
import '../backend/interfaces/gathering_service_interface.dart';
import '../backend/interfaces/poll_service_interface.dart';
import '../backend/interfaces/profile_article_service_interface.dart';
import '../backend/interfaces/profile_service_interface.dart';
import '../backend/interfaces/safety_service_interface.dart';
import '../backend/interfaces/story_service_interface.dart';
import '../backend/interfaces/storage_service_interface.dart';
import '../models/chat_message_adapter.dart';
import '../models/family_person.dart' as rodnya_models;
import '../models/family_relation.dart';
import '../models/family_tree.dart';
import '../models/user_profile.dart';
import '../config/storefront_config.dart';
import '../providers/tree_provider.dart';
import '../startup/app_startup_pipeline.dart';
import '../startup/app_warmup_coordinator.dart';
import 'app_status_service.dart';
import 'app_update_service.dart';
import 'app_links_dynamic_link_service.dart';
import 'android_incoming_call_service.dart';
import 'audio_route_service.dart';
import 'chat_message_cache.dart';
import 'chat_details_cache.dart';
import 'chat_preview_cache.dart';
import 'notifications_cache.dart';
import 'post_publish_queue.dart';
import 'posts_cache.dart';
import 'tree_graph_cache.dart';
import 'user_profile_cache.dart';
import 'battery_optimization_advisor.dart';
import 'chat_draft_store.dart';
import 'chat_pin_store.dart';
import 'chat_send_queue.dart';
import 'auth_sessions_service.dart';
import 'custom_api_auth_service.dart';
import 'session_revocation_watcher.dart';
import 'custom_api_call_service.dart';
import 'custom_api_chat_service.dart';
import 'custom_api_circle_service.dart';
import 'custom_api_diagnostics_service.dart';
import 'custom_api_family_tree_service.dart';
import 'custom_api_identity_service.dart';
import 'custom_api_notification_service.dart';
import 'custom_api_post_service.dart';
import 'custom_api_gathering_service.dart';
import 'custom_api_poll_service.dart';
import 'custom_api_profile_article_service.dart';
import 'custom_api_profile_service.dart';
import 'custom_api_realtime_service.dart';
import 'custom_api_safety_service.dart';
import 'custom_api_story_service.dart';
import 'custom_api_storage_service.dart';
import 'fcm_push_service.dart';
import 'invitation_service.dart';
import 'tree_mutation_history.dart';
import 'invitation_link_service.dart';
import 'incoming_call_watcher.dart';
import 'local_storage_service.dart';
import 'phone_contacts_service.dart';
import 'rustore_service.dart';
import 'call_coordinator_service.dart';
import 'call_preferences.dart';

class AppStartupService implements AppStartupServiceInterface {
  AppStartupService({GetIt? getIt}) : _getIt = getIt ?? GetIt.I;

  final GetIt _getIt;

  @override
  Future<void> initializeForeground() async {
    final providerConfig = BackendProviderConfig.current;
    final runtimeConfig = BackendRuntimeConfig.current;
    final storefrontConfig = StorefrontConfig.current;

    await Hive.initFlutter();
    await initializeDateFormatting('ru', null);

    await _registerHiveAdapters();

    final localStorageService = await LocalStorageService.createInstance();
    _registerOrReplaceSingleton<LocalStorageService>(localStorageService);

    final appStatusService = AppStatusService();
    await appStatusService.initialize();
    _registerOrReplaceSingleton<AppStatusService>(appStatusService);

    final invitationService = InvitationService();
    _registerOrReplaceSingleton<InvitationService>(invitationService);
    _registerOrReplaceSingleton<TreeMutationHistory>(TreeMutationHistory());
    _registerOrReplaceSingleton<InvitationLinkServiceInterface>(
      HttpInvitationLinkService(runtimeConfig: runtimeConfig),
    );
    _registerOrReplaceSingleton<DynamicLinkServiceInterface>(
      AppLinksDynamicLinkService(),
    );
    final rustoreService = RustoreService();
    _registerOrReplaceSingleton<RustoreService>(rustoreService);
    final fcmPushService = FcmPushService();
    _registerOrReplaceSingleton<FcmPushService>(fcmPushService);
    _registerOrReplaceLazySingleton<PhoneContactsService>(
      () => PhoneContactsService(),
    );

    final customApiAuthService = await CustomApiAuthService.create(
      runtimeConfig: runtimeConfig,
      invitationService: invitationService,
      appStatusService: appStatusService,
    );
    _registerOrReplaceSingleton<CustomApiAuthService>(customApiAuthService);
    _registerOrReplaceSingleton<AuthServiceInterface>(customApiAuthService);
    _registerOrReplaceSingleton<AuthSessionsService>(
      AuthSessionsService(
        authService: customApiAuthService,
        runtimeConfig: runtimeConfig,
      ),
    );
    _registerOrReplaceSingleton<CustomApiDiagnosticsService>(
      CustomApiDiagnosticsService(
        authService: customApiAuthService,
        runtimeConfig: runtimeConfig,
      ),
    );

    // Startup should remain resilient even with a stale persisted session.
    // Live session validation and profile completeness redirects happen later
    // in the router flow, where errors don't block the whole app bootstrap.

    final customApiRealtimeService = CustomApiRealtimeService(
      authService: customApiAuthService,
      runtimeConfig: runtimeConfig,
    );
    _registerOrReplaceSingleton<CustomApiRealtimeService>(
      customApiRealtimeService,
    );

    final sessionRevocationWatcher = SessionRevocationWatcher(
      authService: customApiAuthService,
      realtimeService: customApiRealtimeService,
    )..start();
    _registerOrReplaceSingleton<SessionRevocationWatcher>(
      sessionRevocationWatcher,
    );

    final customApiStorageService = CustomApiStorageService(
      authService: customApiAuthService,
      runtimeConfig: runtimeConfig,
    );
    _registerOrReplaceSingleton<CustomApiStorageService>(
      customApiStorageService,
    );
    _registerOrReplaceSingleton<StorageServiceInterface>(
      customApiStorageService,
    );

    // Profile Phase 2 (2026-05-29): article editor backend client.
    final customApiProfileArticleService = CustomApiProfileArticleService(
      authService: customApiAuthService,
      runtimeConfig: runtimeConfig,
    );
    _registerOrReplaceSingleton<CustomApiProfileArticleService>(
      customApiProfileArticleService,
    );
    _registerOrReplaceSingleton<ProfileArticleServiceInterface>(
      customApiProfileArticleService,
    );

    final customApiProfileService = await CustomApiProfileService.create(
      authService: customApiAuthService,
      runtimeConfig: runtimeConfig,
      storageService: customApiStorageService,
    );
    _registerOrReplaceSingleton<CustomApiProfileService>(
      customApiProfileService,
    );
    _registerOrReplaceSingleton<ProfileServiceInterface>(
      customApiProfileService,
    );

    final treeGraphCache = HiveTreeGraphCache();
    _registerOrReplaceSingleton<TreeGraphCache>(treeGraphCache);

    final customApiTreeService = CustomApiFamilyTreeService(
      authService: customApiAuthService,
      runtimeConfig: runtimeConfig,
      localStorageService: localStorageService,
      profileService: customApiProfileService,
      treeGraphCache: treeGraphCache,
    );
    _registerOrReplaceSingleton<CustomApiFamilyTreeService>(
      customApiTreeService,
    );
    _registerOrReplaceSingleton<FamilyTreeServiceInterface>(
      customApiTreeService,
    );

    final chatMessageCache = HiveChatMessageCache();
    _registerOrReplaceSingleton<ChatMessageCache>(chatMessageCache);
    final chatPreviewCache = HiveChatPreviewCache();
    _registerOrReplaceSingleton<ChatPreviewCache>(chatPreviewCache);
    final chatDetailsCache = HiveChatDetailsCache();
    _registerOrReplaceSingleton<ChatDetailsCache>(chatDetailsCache);
    final notificationsCache = HiveNotificationsCache();
    _registerOrReplaceSingleton<NotificationsCache>(notificationsCache);
    final postsCache = HivePostsCache();
    _registerOrReplaceSingleton<PostsCache>(postsCache);
    final userProfileCache = HiveUserProfileCache();
    _registerOrReplaceSingleton<UserProfileCache>(userProfileCache);

    final customApiChatService = CustomApiChatService(
      authService: customApiAuthService,
      runtimeConfig: runtimeConfig,
      realtimeService: customApiRealtimeService,
      storageService: customApiStorageService,
      messageCache: chatMessageCache,
      previewCache: chatPreviewCache,
      appStatusService: appStatusService,
    );
    _registerOrReplaceSingleton<CustomApiChatService>(customApiChatService);
    _registerOrReplaceSingleton<ChatServiceInterface>(customApiChatService);
    _registerOrReplaceSingleton<ChatSendQueue>(
      ChatSendQueue(
        chatService: customApiChatService,
        // Listen to AppStatusService so the queue auto-retries
        // failed messages the moment connectivity is restored,
        // instead of leaving the user to tap "Повторить" on each
        // failed bubble.
        appStatusService: appStatusService,
      ),
    );
    _registerOrReplaceSingleton<ChatDraftStore>(
      HybridChatDraftStore(
        localStore: const SharedPreferencesChatDraftStore(),
        remoteClient: customApiChatService,
      ),
    );
    _registerOrReplaceSingleton<ChatPinStore>(
      HybridChatPinStore(
        localStore: const SharedPreferencesChatPinStore(),
        remoteClient: customApiChatService,
      ),
    );

    _registerOrReplaceLazySingleton<CustomApiCallService>(
      () => CustomApiCallService(
        authService: customApiAuthService,
        runtimeConfig: runtimeConfig,
        realtimeService: customApiRealtimeService,
      ),
    );
    _registerOrReplaceLazySingleton<CallServiceInterface>(
      () => _getIt<CustomApiCallService>(),
    );
    _registerOrReplaceLazySingleton<AudioRouteService>(
      AudioRouteService.new,
    );
    _registerOrReplaceLazySingleton<CallPreferences>(
      HiveCallPreferences.new,
    );
    _registerOrReplaceLazySingleton<AndroidIncomingCallService>(
      AndroidIncomingCallService.new,
    );
    final callCoordinatorService = CallCoordinatorService(
      callService: _getIt<CallServiceInterface>(),
      realtimeService: customApiRealtimeService,
      pushMessages: rustoreService.pushMessages,
      audioRouteService: _getIt<AudioRouteService>(),
      callPreferences: _getIt<CallPreferences>(),
      androidIncomingCallService: _getIt<AndroidIncomingCallService>(),
    );
    _registerOrReplaceSingleton<CallCoordinatorService>(callCoordinatorService);
    final incomingCallWatcher = IncomingCallWatcher(
      coordinator: callCoordinatorService,
      realtimeService: customApiRealtimeService,
      // BUG 2: терминальный звонок по realtime → снять входящую уведомку
      // (lazy: notification-сервис регистрируется ниже, а колбэк зовётся
      // только при событии — к тому моменту он уже есть).
      onTerminalCallState: (callId) async {
        if (_getIt.isRegistered<CustomApiNotificationService>()) {
          await _getIt<CustomApiNotificationService>()
              .dismissCallNotification(callId);
        }
      },
    )..start();
    _registerOrReplaceSingleton<IncomingCallWatcher>(
      incomingCallWatcher,
    );

    final customApiNotificationService =
        await CustomApiNotificationService.create(
      authService: customApiAuthService,
      runtimeConfig: runtimeConfig,
      realtimeService: customApiRealtimeService,
      rustoreService: rustoreService,
      remotePushProvider: 'fcm',
      remotePushTokenProvider: fcmPushService.getFcmPushToken,
      remotePushTokenUpdates: fcmPushService.pushTokens,
      androidIncomingCallService: _getIt<AndroidIncomingCallService>(),
    );
    _registerOrReplaceSingleton<CustomApiNotificationService>(
      customApiNotificationService,
    );
    _registerOrReplaceSingleton<NotificationServiceInterface>(
      customApiNotificationService,
    );

    // Drop the device from the backend's push registry the moment
    // the user signs out — must happen WHILE we still hold a valid
    // access token, otherwise the DELETE call returns 401 and the
    // backend keeps stacking devices forever.
    customApiAuthService.registerPreSignOutHook(
      customApiNotificationService.unregisterAllPushDevicesForSignOut,
    );

    // Battery-optimization advisor: detects Xiaomi/Huawei/Oppo etc.
    // so the UI can prompt the user to whitelist us in autostart.
    // We register the prepared instance synchronously after
    // resolving SharedPreferences once, since the advisor itself
    // doesn't take an async constructor.
    final batteryAdvisorPreferences = await SharedPreferences.getInstance();
    _registerOrReplaceSingleton<BatteryOptimizationAdvisor>(
      BatteryOptimizationAdvisor(
        preferences: batteryAdvisorPreferences,
      ),
    );

    final customApiPostService = CustomApiPostService(
      authService: customApiAuthService,
      runtimeConfig: runtimeConfig,
      storageService: customApiStorageService,
    );
    _registerOrReplaceSingleton<CustomApiPostService>(customApiPostService);
    _registerOrReplaceSingleton<PostServiceInterface>(customApiPostService);
    // Шаг 5 bulk-upload: фоновая очередь публикации. Как и у чата,
    // appStatusService даёт автоповтор при возврате сети; restore досылает
    // посты, пережившие kill приложения, не дожидаясь открытия ленты.
    final postPublishQueue = PostPublishQueue(
      postService: customApiPostService,
      appStatusService: appStatusService,
    );
    _registerOrReplaceSingleton<PostPublishQueue>(postPublishQueue);
    unawaited(postPublishQueue.restore());

    final customApiGatheringService = CustomApiGatheringService(
      authService: customApiAuthService,
      storageService: customApiStorageService,
      runtimeConfig: runtimeConfig,
    );
    _registerOrReplaceSingleton<CustomApiGatheringService>(
      customApiGatheringService,
    );
    _registerOrReplaceSingleton<GatheringServiceInterface>(
      customApiGatheringService,
    );

    final customApiPollService = CustomApiPollService(
      authService: customApiAuthService,
      storageService: customApiStorageService,
      runtimeConfig: runtimeConfig,
    );
    _registerOrReplaceSingleton<CustomApiPollService>(customApiPollService);
    _registerOrReplaceSingleton<PollServiceInterface>(customApiPollService);

    final customApiCircleService = CustomApiCircleService(
      authService: customApiAuthService,
      runtimeConfig: runtimeConfig,
    );
    _registerOrReplaceSingleton<CustomApiCircleService>(customApiCircleService);
    _registerOrReplaceSingleton<CircleServiceInterface>(
      customApiCircleService,
    );

    final customApiIdentityService = CustomApiIdentityService(
      authService: customApiAuthService,
      runtimeConfig: runtimeConfig,
    );
    _registerOrReplaceSingleton<CustomApiIdentityService>(
      customApiIdentityService,
    );
    _registerOrReplaceSingleton<IdentityServiceInterface>(
      customApiIdentityService,
    );

    final customApiStoryService = CustomApiStoryService(
      authService: customApiAuthService,
      storageService: customApiStorageService,
      runtimeConfig: runtimeConfig,
    );
    _registerOrReplaceSingleton<CustomApiStoryService>(customApiStoryService);
    _registerOrReplaceSingleton<StoryServiceInterface>(customApiStoryService);

    final customApiSafetyService = CustomApiSafetyService(
      authService: customApiAuthService,
      runtimeConfig: runtimeConfig,
    );
    _registerOrReplaceSingleton<CustomApiSafetyService>(customApiSafetyService);
    _registerOrReplaceSingleton<SafetyServiceInterface>(customApiSafetyService);

    _registerOrReplaceSingleton<BackendRuntimeConfig>(runtimeConfig);

    BackendProviderRegistry.register(_getIt, config: providerConfig);

    final treeProvider = TreeProvider();
    await treeProvider.loadInitialTree();
    _registerOrReplaceSingleton<TreeProvider>(treeProvider);

    // U2: OTA-апдейтер sideload-сборок. Сервис сам гейтит контекст
    // (только Android + sideload, не магазин/.dev) и молчит, если фича
    // на бэке выключена; проверка дёргается в featureLazy ниже.
    final appUpdateService = AppUpdateService(
      apiBaseUrl: runtimeConfig.apiBaseUrl,
    );
    _registerOrReplaceSingleton<AppUpdateService>(appUpdateService);

    final startupPipeline = AppStartupPipeline(
      tasks: <StartupPhaseTask>[
        StartupPhaseTask(
          phase: StartupPhase.featureLazy,
          label: 'fcm-foreground',
          run: (_) async {
            try {
              await fcmPushService.startForegroundWarmup();
            } catch (error, stackTrace) {
              debugPrint('FCM warmup failed: $error\n$stackTrace');
            }
          },
        ),
        StartupPhaseTask(
          phase: StartupPhase.featureLazy,
          label: 'rustore-foreground',
          run: (context) => _warmupPlatformServices(
            context: context,
            rustoreService: rustoreService,
            storefrontConfig: storefrontConfig,
          ),
        ),
        // Initialize the notification plugin EARLY (before auth) so the
        // POST_NOTIFICATIONS runtime prompt + channel registration
        // happen on first launch even for users that never sign in.
        // Without this, Android 13+ never gets the prompt, the
        // permission stays denied by default, and pushes silently
        // never display in the system tray.
        StartupPhaseTask(
          phase: StartupPhase.featureLazy,
          label: 'notifications-initialize',
          run: (_) => customApiNotificationService.initialize(),
        ),
        // U2: проверка OTA-обновления sideload-сборки. checkForUpdate
        // не бросает (внутренний try/catch + graceful), но оборачиваем
        // тоже — M4-паттерн: фоновая фича не должна валить warmup.
        StartupPhaseTask(
          phase: StartupPhase.featureLazy,
          label: 'app-update-check',
          run: (_) async {
            try {
              await appUpdateService.checkForUpdate();
            } catch (_) {
              // Апдейтер — best-effort; молчим при любой ошибке.
            }
          },
        ),
        StartupPhaseTask(
          phase: StartupPhase.authenticatedDeferred,
          label: 'notifications-foreground-sync',
          run: (_) => customApiNotificationService.startForegroundSync(),
        ),
      ],
    );
    _registerOrReplaceSingleton<AppStartupPipeline>(startupPipeline);
    _registerOrReplaceSingleton<AppWarmupCoordinator>(
      AppWarmupCoordinator(
        authService: customApiAuthService,
        pipeline: startupPipeline,
        notificationService: customApiNotificationService,
        realtimeService: customApiRealtimeService,
      ),
    );

    // Wire user-scoped cache cleanup to auth state. The moment the
    // user signs out (or the session is force-revoked) the auth
    // stream emits null — at that point we wipe every per-user
    // Hive box so a different account signing in next doesn't see
    // any leftover messages, profile chrome, posts or tree graph.
    // Best-effort: failures are logged and do not block sign-out.
    String? lastUserId;
    customApiAuthService.authStateChanges.listen((nextUserId) async {
      try {
        if (lastUserId != null && nextUserId != lastUserId) {
          await Future.wait<void>([
            chatMessageCache.clearAll(),
            chatPreviewCache.clear(),
            chatDetailsCache.clearAll(),
            notificationsCache.clear(),
            postsCache.clearAll(),
            userProfileCache.clearAll(),
            treeGraphCache.clearAll(),
          ]);
        }
      } catch (error, stackTrace) {
        debugPrint(
          'AppStartup: cache cleanup on auth change failed: $error\n$stackTrace',
        );
      } finally {
        lastUserId = nextUserId;
      }
    });
  }

  Future<void> _registerHiveAdapters() async {
    if (!Hive.isAdapterRegistered(UserProfileAdapter().typeId)) {
      Hive.registerAdapter(UserProfileAdapter());
    }
    if (!Hive.isAdapterRegistered(FamilyTreeAdapter().typeId)) {
      Hive.registerAdapter(FamilyTreeAdapter());
    }
    if (!Hive.isAdapterRegistered(TreeKindAdapter().typeId)) {
      Hive.registerAdapter(TreeKindAdapter());
    }
    if (!Hive.isAdapterRegistered(
      rodnya_models.FamilyPersonAdapter().typeId,
    )) {
      Hive.registerAdapter(rodnya_models.FamilyPersonAdapter());
    }
    if (!Hive.isAdapterRegistered(FamilyRelationAdapter().typeId)) {
      Hive.registerAdapter(FamilyRelationAdapter());
    }
    if (!Hive.isAdapterRegistered(ChatMessageAdapter().typeId)) {
      Hive.registerAdapter(ChatMessageAdapter());
    }
    if (!Hive.isAdapterRegistered(rodnya_models.GenderAdapter().typeId)) {
      Hive.registerAdapter(rodnya_models.GenderAdapter());
    }
    // Hotfix-1: адаптеры расширенной анкеты (details/career/events).
    // Без них FamilyPersonAdapter.write падал на non-null details и
    // валил кэш-запись у всех зрителей дерева.
    if (!Hive.isAdapterRegistered(
      rodnya_models.FamilyPersonDetailsAdapter().typeId,
    )) {
      Hive.registerAdapter(rodnya_models.FamilyPersonDetailsAdapter());
    }
    if (!Hive.isAdapterRegistered(rodnya_models.CareerAdapter().typeId)) {
      Hive.registerAdapter(rodnya_models.CareerAdapter());
    }
    if (!Hive.isAdapterRegistered(rodnya_models.EventAdapter().typeId)) {
      Hive.registerAdapter(rodnya_models.EventAdapter());
    }
    if (!Hive.isAdapterRegistered(RelationTypeAdapter().typeId)) {
      Hive.registerAdapter(RelationTypeAdapter());
    }
  }

  void _registerOrReplaceSingleton<T extends Object>(T instance) {
    if (_getIt.isRegistered<T>()) {
      _getIt.unregister<T>();
    }
    _getIt.registerSingleton<T>(instance);
  }

  void _registerOrReplaceLazySingleton<T extends Object>(
    T Function() factory,
  ) {
    if (_getIt.isRegistered<T>()) {
      _getIt.unregister<T>();
    }
    _getIt.registerLazySingleton<T>(factory);
  }

  Future<void> _warmupPlatformServices({
    required StartupPhaseContext context,
    required RustoreService rustoreService,
    required StorefrontConfig storefrontConfig,
  }) async {
    final isRuStoreRuntime = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        storefrontConfig.isRustore;
    if (!isRuStoreRuntime) {
      return;
    }

    await rustoreService.startForegroundWarmup(enableUpdates: false);

    if (!storefrontConfig.enableRustoreUpdates) {
      return;
    }

    final updateInfo = await rustoreService.checkForUpdate();
    if (updateInfo == null ||
        updateInfo.updateAvailability != updateAvailabilityAvailable) {
      return;
    }

    rustoreService.startUpdateListener((state) {
      if (state.installStatus == installStatusDownloaded) {
        _showWarmupSnackBar(
          context.scaffoldMessengerKey,
          message: 'Обновление скачано.',
          actionLabel: 'УСТАНОВИТЬ',
          onAction: rustoreService.completeUpdateFlexible,
          duration: const Duration(days: 1),
        );
      } else if (state.installStatus == installStatusFailed) {
        _showWarmupSnackBar(
          context.scaffoldMessengerKey,
          message: 'Ошибка загрузки обновления: ${state.installErrorCode}',
          duration: const Duration(seconds: 10),
        );
      }
    });

    _showWarmupSnackBar(
      context.scaffoldMessengerKey,
      message: 'Доступно обновление приложения.',
      actionLabel: 'ОБНОВИТЬ',
      onAction: rustoreService.startUpdateFlow,
      duration: const Duration(days: 1),
    );
  }

  void _showWarmupSnackBar(
    GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey, {
    required String message,
    String? actionLabel,
    Future<void> Function()? onAction,
    Duration duration = const Duration(seconds: 6),
  }) {
    final messengerState = scaffoldMessengerKey?.currentState;
    if (messengerState == null) {
      return;
    }

    messengerState.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration,
        action: actionLabel == null || onAction == null
            ? null
            : SnackBarAction(
                label: actionLabel,
                onPressed: () {
                  unawaited(onAction());
                },
              ),
      ),
    );
  }
}
