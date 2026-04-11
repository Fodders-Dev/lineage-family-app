import 'package:get_it/get_it.dart';

import 'backend_provider_config.dart';
import 'interfaces/auth_service_interface.dart';
import 'interfaces/chat_service_interface.dart';
import 'interfaces/family_tree_service_interface.dart';
import 'interfaces/notification_service_interface.dart';
import 'interfaces/post_service_interface.dart';
import 'interfaces/profile_service_interface.dart';
import 'interfaces/storage_service_interface.dart';
import 'pending_backend_adapters.dart';

class BackendProviderRegistry {
  static void register(GetIt getIt, {BackendProviderConfig? config}) {
    final resolvedConfig = config ?? BackendProviderConfig.current;

    if (!getIt.isRegistered<BackendProviderConfig>()) {
      getIt.registerSingleton<BackendProviderConfig>(resolvedConfig);
    }

    if (!getIt.isRegistered<AuthServiceInterface>()) {
      getIt.registerSingleton<AuthServiceInterface>(
        const PendingBackendAuthService(),
      );
    }

    if (!getIt.isRegistered<ProfileServiceInterface>()) {
      getIt.registerSingleton<ProfileServiceInterface>(
        const PendingBackendProfileService(),
      );
    }

    if (!getIt.isRegistered<FamilyTreeServiceInterface>()) {
      getIt.registerSingleton<FamilyTreeServiceInterface>(
        const PendingBackendFamilyTreeService(),
      );
    }

    if (!getIt.isRegistered<ChatServiceInterface>()) {
      getIt.registerSingleton<ChatServiceInterface>(
        const PendingBackendChatService(),
      );
    }

    if (!getIt.isRegistered<StorageServiceInterface>()) {
      getIt.registerSingleton<StorageServiceInterface>(
          const NoopStorageService());
    }

    if (!getIt.isRegistered<NotificationServiceInterface>()) {
      getIt.registerSingleton<NotificationServiceInterface>(
        const NoopNotificationService(),
      );
    }

    if (!getIt.isRegistered<PostServiceInterface>()) {
      getIt.registerSingleton<PostServiceInterface>(
        const PendingBackendPostService(),
      );
    }
  }
}
