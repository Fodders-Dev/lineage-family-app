import 'package:get_it/get_it.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../backend/backend_provider_config.dart';
import '../backend/backend_provider_registry.dart';
import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/app_startup_service_interface.dart';
import '../backend/interfaces/chat_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/invitation_link_service_interface.dart';
import '../backend/interfaces/notification_service_interface.dart';
import '../backend/interfaces/post_service_interface.dart';
import '../backend/interfaces/profile_service_interface.dart';
import '../backend/interfaces/storage_service_interface.dart';
import '../models/chat_message.dart';
import '../models/family_person.dart' as lineage_models;
import '../models/family_relation.dart';
import '../models/family_tree.dart';
import '../models/user_profile.dart';
import '../providers/tree_provider.dart';
import 'custom_api_auth_service.dart';
import 'custom_api_chat_service.dart';
import 'custom_api_family_tree_service.dart';
import 'custom_api_notification_service.dart';
import 'custom_api_post_service.dart';
import 'custom_api_profile_service.dart';
import 'custom_api_realtime_service.dart';
import 'custom_api_storage_service.dart';
import 'invitation_service.dart';
import 'invitation_link_service.dart';
import 'local_storage_service.dart';
import 'rustore_service.dart';

class AppStartupService implements AppStartupServiceInterface {
  AppStartupService({GetIt? getIt}) : _getIt = getIt ?? GetIt.I;

  final GetIt _getIt;

  @override
  Future<void> initializeForeground() async {
    final providerConfig = BackendProviderConfig.current;
    final runtimeConfig = BackendRuntimeConfig.current;

    await Hive.initFlutter();
    await initializeDateFormatting('ru', null);

    await _registerHiveAdapters();

    final localStorageService = await LocalStorageService.createInstance();
    _registerOrReplaceSingleton<LocalStorageService>(localStorageService);

    final invitationService = InvitationService();
    _registerOrReplaceSingleton<InvitationService>(invitationService);
    _registerOrReplaceSingleton<InvitationLinkServiceInterface>(
      HttpInvitationLinkService(runtimeConfig: runtimeConfig),
    );
    final rustoreService = RustoreService();
    _registerOrReplaceSingleton<RustoreService>(rustoreService);

    final customApiAuthService = await CustomApiAuthService.create(
      runtimeConfig: runtimeConfig,
      invitationService: invitationService,
    );
    _registerOrReplaceSingleton<CustomApiAuthService>(customApiAuthService);
    _registerOrReplaceSingleton<AuthServiceInterface>(customApiAuthService);

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

    final customApiTreeService = CustomApiFamilyTreeService(
      authService: customApiAuthService,
      runtimeConfig: runtimeConfig,
      localStorageService: localStorageService,
      profileService: customApiProfileService,
    );
    _registerOrReplaceSingleton<CustomApiFamilyTreeService>(
      customApiTreeService,
    );
    _registerOrReplaceSingleton<FamilyTreeServiceInterface>(
      customApiTreeService,
    );

    final customApiChatService = CustomApiChatService(
      authService: customApiAuthService,
      runtimeConfig: runtimeConfig,
      realtimeService: customApiRealtimeService,
      storageService: customApiStorageService,
    );
    _registerOrReplaceSingleton<CustomApiChatService>(customApiChatService);
    _registerOrReplaceSingleton<ChatServiceInterface>(customApiChatService);

    final customApiNotificationService =
        await CustomApiNotificationService.create(
      authService: customApiAuthService,
      runtimeConfig: runtimeConfig,
      realtimeService: customApiRealtimeService,
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

    final customApiPostService = CustomApiPostService(
      authService: customApiAuthService,
      runtimeConfig: runtimeConfig,
      storageService: customApiStorageService,
    );
    _registerOrReplaceSingleton<CustomApiPostService>(customApiPostService);
    _registerOrReplaceSingleton<PostServiceInterface>(customApiPostService);

    _registerOrReplaceSingleton<BackendRuntimeConfig>(runtimeConfig);

    BackendProviderRegistry.register(_getIt, config: providerConfig);

    final treeProvider = TreeProvider();
    await treeProvider.loadInitialTree();
    _registerOrReplaceSingleton<TreeProvider>(treeProvider);
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
}
