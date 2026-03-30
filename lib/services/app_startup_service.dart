import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get_it/get_it.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../backend/backend_provider_config.dart';
import '../backend/backend_provider_registry.dart';
import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/app_startup_service_interface.dart';
import '../backend/interfaces/chat_service_interface.dart';
import '../backend/interfaces/dynamic_link_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/invitation_link_service_interface.dart';
import '../backend/interfaces/notification_service_interface.dart';
import '../backend/interfaces/profile_service_interface.dart';
import '../backend/interfaces/storage_service_interface.dart';
import '../backend/legacy_backend_runtime_policy.dart';
import '../firebase_options.dart';
import '../models/chat_message.dart';
import '../models/family_person.dart' as lineage_models;
import '../models/family_relation.dart';
import '../models/family_tree.dart';
import '../models/user_profile.dart';
import '../providers/tree_provider.dart';
import 'analytics_service.dart';
import 'auth_service.dart';
import 'crashlytics_service.dart';
import 'custom_api_auth_service.dart';
import 'custom_api_chat_service.dart';
import 'custom_api_family_tree_service.dart';
import 'custom_api_notification_service.dart';
import 'custom_api_profile_service.dart';
import 'custom_api_realtime_service.dart';
import 'custom_api_storage_service.dart';
import 'dynamic_link_service.dart';
import 'family_service.dart';
import 'invitation_service.dart';
import 'invitation_link_service.dart';
import 'local_storage_service.dart';
import 'notification_service.dart';
import 'rustore_service.dart';
import 'storage_service.dart';
import 'sync_service.dart';

class AppStartupService implements AppStartupServiceInterface {
  AppStartupService({GetIt? getIt}) : _getIt = getIt ?? GetIt.I;

  final GetIt _getIt;

  @override
  Future<void> initializeForeground() async {
    final providerConfig = BackendProviderConfig.current;
    final runtimeConfig = BackendRuntimeConfig.current;
    final usesCustomApiAuth =
        providerConfig.authProvider == BackendProviderKind.customApi;
    final usesCustomApiProfile =
        providerConfig.profileProvider == BackendProviderKind.customApi;
    final usesCustomApiTree =
        providerConfig.treeProvider == BackendProviderKind.customApi;
    final usesCustomApiChat =
        providerConfig.chatProvider == BackendProviderKind.customApi;
    final usesCustomApiStorage =
        providerConfig.storageProvider == BackendProviderKind.customApi;
    final usesCustomApiNotification =
        providerConfig.notificationProvider == BackendProviderKind.customApi;
    final needsFirebaseCore = LegacyBackendRuntimePolicy.requiresFirebaseCore(
      providerConfig: providerConfig,
      runtimeConfig: runtimeConfig,
    );

    await Hive.initFlutter();
    await initializeDateFormatting('ru', null);

    await _registerHiveAdapters();

    if (needsFirebaseCore) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );

      if (kIsWeb) {
        await FirebaseAuth.instance.setPersistence(Persistence.LOCAL);
      }

      final crashlyticsService = CrashlyticsService();
      await crashlyticsService.initialize();

      final analyticsService = AnalyticsService();
      _registerOrReplaceSingleton<AnalyticsService>(analyticsService);
    }

    if (_usesLegacyNotificationProvider(providerConfig)) {
      final notificationService = NotificationService();
      await notificationService.initialize();
      _registerOrReplaceSingleton<NotificationService>(notificationService);
    }

    final localStorageService = await LocalStorageService.createInstance();
    _registerOrReplaceSingleton<LocalStorageService>(localStorageService);

    SyncService? syncService;
    if (needsFirebaseCore) {
      syncService = await SyncService.createInstance(
        localStorage: localStorageService,
        firestore: FirebaseFirestore.instance,
        auth: FirebaseAuth.instance,
      );
      _registerOrReplaceSingleton<SyncService>(syncService);

      final familyService = FamilyService(
        localStorageService: localStorageService,
        syncService: syncService,
      );
      _registerOrReplaceSingleton<FamilyService>(familyService);
    }

    if (_usesLegacyStorageProvider(providerConfig)) {
      await Supabase.initialize(
        url: runtimeConfig.supabaseUrl,
        anonKey: runtimeConfig.supabaseAnonKey,
      );

      _registerOrReplaceSingleton<StorageService>(StorageService());
    }

    final invitationService = InvitationService();
    _registerOrReplaceSingleton<InvitationService>(invitationService);
    _registerOrReplaceSingleton<InvitationLinkServiceInterface>(
      HttpInvitationLinkService(runtimeConfig: runtimeConfig),
    );
    final rustoreService = RustoreService();
    _registerOrReplaceSingleton<RustoreService>(rustoreService);

    if (usesCustomApiAuth) {
      final customApiAuthService = await CustomApiAuthService.create(
        runtimeConfig: runtimeConfig,
        invitationService: invitationService,
      );
      _registerOrReplaceSingleton<CustomApiAuthService>(customApiAuthService);

      _registerOrReplaceSingleton<AuthServiceInterface>(customApiAuthService);

      final customApiRealtimeService = CustomApiRealtimeService(
        authService: customApiAuthService,
        runtimeConfig: runtimeConfig,
      );
      _registerOrReplaceSingleton<CustomApiRealtimeService>(
        customApiRealtimeService,
      );

      CustomApiStorageService? customApiStorageService;
      if (usesCustomApiStorage) {
        customApiStorageService = CustomApiStorageService(
          authService: customApiAuthService,
          runtimeConfig: runtimeConfig,
        );
        _registerOrReplaceSingleton<CustomApiStorageService>(
          customApiStorageService,
        );
        _registerOrReplaceSingleton<StorageServiceInterface>(
          customApiStorageService,
        );
      }

      if (usesCustomApiProfile) {
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
      }

      if (usesCustomApiTree) {
        final customApiTreeService = CustomApiFamilyTreeService(
          authService: customApiAuthService,
          runtimeConfig: runtimeConfig,
          localStorageService: localStorageService,
          profileService: _getIt.isRegistered<ProfileServiceInterface>()
              ? _getIt<ProfileServiceInterface>()
              : null,
        );
        _registerOrReplaceSingleton<CustomApiFamilyTreeService>(
          customApiTreeService,
        );
        _registerOrReplaceSingleton<FamilyTreeServiceInterface>(
          customApiTreeService,
        );
      }

      if (usesCustomApiChat) {
        final customApiChatService = CustomApiChatService(
          authService: customApiAuthService,
          runtimeConfig: runtimeConfig,
          realtimeService: customApiRealtimeService,
        );
        _registerOrReplaceSingleton<CustomApiChatService>(customApiChatService);
        _registerOrReplaceSingleton<ChatServiceInterface>(customApiChatService);
      }
    }

    if (needsFirebaseCore) {
      final authService = AuthService();
      _registerOrReplaceSingleton<AuthService>(authService);
    }

    if (usesCustomApiNotification) {
      final customApiNotificationService =
          await CustomApiNotificationService.create(
        authService: _getIt.isRegistered<CustomApiAuthService>()
            ? _getIt<CustomApiAuthService>()
            : null,
        runtimeConfig: runtimeConfig,
        realtimeService: _getIt.isRegistered<CustomApiRealtimeService>()
            ? _getIt<CustomApiRealtimeService>()
            : null,
        rustoreService: rustoreService,
      );
      await customApiNotificationService.initialize();
      _registerOrReplaceSingleton<CustomApiNotificationService>(
        customApiNotificationService,
      );
      _registerOrReplaceSingleton<NotificationServiceInterface>(
        customApiNotificationService,
      );
      await customApiNotificationService.startForegroundSync();
    }

    final dynamicLinkService = runtimeConfig.enableLegacyDynamicLinks
        ? FirebaseDynamicLinkService()
        : NoopDynamicLinkService();
    _registerOrReplaceSingleton<DynamicLinkServiceInterface>(
      dynamicLinkService,
    );
    _registerOrReplaceSingleton<BackendRuntimeConfig>(runtimeConfig);

    BackendProviderRegistry.register(_getIt, config: providerConfig);

    final treeProvider = TreeProvider();
    await treeProvider.loadInitialTree();
    _registerOrReplaceSingleton<TreeProvider>(treeProvider);

    if (syncService != null) {
      await syncService.syncData();
    }
  }

  Future<void> _registerHiveAdapters() async {
    if (!Hive.isAdapterRegistered(UserProfileAdapter().typeId)) {
      Hive.registerAdapter(UserProfileAdapter());
    }
    if (!Hive.isAdapterRegistered(FamilyTreeAdapter().typeId)) {
      Hive.registerAdapter(FamilyTreeAdapter());
    }
    if (!Hive.isAdapterRegistered(
      lineage_models.FamilyPersonAdapter().typeId,
    )) {
      Hive.registerAdapter(lineage_models.FamilyPersonAdapter());
    }
    if (!Hive.isAdapterRegistered(FamilyRelationAdapter().typeId)) {
      Hive.registerAdapter(FamilyRelationAdapter());
    }
    if (!Hive.isAdapterRegistered(ChatMessageAdapter().typeId)) {
      Hive.registerAdapter(ChatMessageAdapter());
    }
    if (!Hive.isAdapterRegistered(lineage_models.GenderAdapter().typeId)) {
      Hive.registerAdapter(lineage_models.GenderAdapter());
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

  bool _usesLegacyNotificationProvider(BackendProviderConfig config) {
    return config.notificationProvider == BackendProviderKind.firebase ||
        config.notificationProvider == BackendProviderKind.hybridLegacy;
  }

  bool _usesLegacyStorageProvider(BackendProviderConfig config) {
    return LegacyBackendRuntimePolicy.requiresSupabaseStorage(config);
  }
}
