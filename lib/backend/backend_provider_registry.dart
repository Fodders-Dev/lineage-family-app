import 'package:get_it/get_it.dart';

import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/family_service.dart';
import '../services/notification_service.dart';
import '../services/profile_service.dart';
import '../services/storage_service.dart';
import 'backend_provider_config.dart';
import 'interfaces/auth_service_interface.dart';
import 'interfaces/chat_service_interface.dart';
import 'interfaces/family_tree_service_interface.dart';
import 'interfaces/notification_service_interface.dart';
import 'interfaces/profile_service_interface.dart';
import 'interfaces/storage_service_interface.dart';
import 'pending_backend_adapters.dart';

class BackendProviderRegistry {
  static void register(GetIt getIt, {BackendProviderConfig? config}) {
    final resolvedConfig = config ?? BackendProviderConfig.current;

    if (!getIt.isRegistered<BackendProviderConfig>()) {
      getIt.registerSingleton<BackendProviderConfig>(resolvedConfig);
    }

    if (resolvedConfig.authProvider == BackendProviderKind.firebase &&
        !getIt.isRegistered<AuthServiceInterface>()) {
      final authService = getIt.isRegistered<AuthService>()
          ? getIt<AuthService>()
          : AuthService();
      getIt.registerSingleton<AuthServiceInterface>(authService);
    } else if (!getIt.isRegistered<AuthServiceInterface>()) {
      getIt.registerSingleton<AuthServiceInterface>(
        const PendingBackendAuthService(),
      );
    }

    if (resolvedConfig.profileProvider == BackendProviderKind.firebase &&
        !getIt.isRegistered<ProfileServiceInterface>()) {
      getIt.registerLazySingleton<ProfileServiceInterface>(() {
        if (getIt.isRegistered<ProfileService>()) {
          return getIt<ProfileService>();
        }
        return ProfileService();
      });
    } else if (!getIt.isRegistered<ProfileServiceInterface>()) {
      getIt.registerSingleton<ProfileServiceInterface>(
        const PendingBackendProfileService(),
      );
    }

    if (resolvedConfig.treeProvider == BackendProviderKind.firebase &&
        !getIt.isRegistered<FamilyTreeServiceInterface>()) {
      if (getIt.isRegistered<FamilyService>()) {
        getIt.registerSingleton<FamilyTreeServiceInterface>(
          getIt<FamilyService>(),
        );
      } else {
        getIt.registerSingleton<FamilyTreeServiceInterface>(
          const PendingBackendFamilyTreeService(),
        );
      }
    } else if (!getIt.isRegistered<FamilyTreeServiceInterface>()) {
      getIt.registerSingleton<FamilyTreeServiceInterface>(
        const PendingBackendFamilyTreeService(),
      );
    }

    if (resolvedConfig.chatProvider == BackendProviderKind.firebase &&
        !getIt.isRegistered<ChatServiceInterface>()) {
      getIt.registerLazySingleton<ChatServiceInterface>(() {
        if (getIt.isRegistered<ChatService>()) {
          return getIt<ChatService>();
        }
        return ChatService();
      });
    } else if (!getIt.isRegistered<ChatServiceInterface>()) {
      getIt.registerSingleton<ChatServiceInterface>(
        const PendingBackendChatService(),
      );
    }

    if ((resolvedConfig.storageProvider == BackendProviderKind.hybridLegacy ||
            resolvedConfig.storageProvider == BackendProviderKind.supabase) &&
        !getIt.isRegistered<StorageServiceInterface>()) {
      if (getIt.isRegistered<StorageService>()) {
        getIt.registerSingleton<StorageServiceInterface>(
          getIt<StorageService>(),
        );
      } else {
        getIt.registerSingleton<StorageServiceInterface>(NoopStorageService());
      }
    } else if (!getIt.isRegistered<StorageServiceInterface>()) {
      getIt.registerSingleton<StorageServiceInterface>(NoopStorageService());
    }

    if ((resolvedConfig.notificationProvider == BackendProviderKind.firebase ||
            resolvedConfig.notificationProvider ==
                BackendProviderKind.hybridLegacy) &&
        !getIt.isRegistered<NotificationServiceInterface>()) {
      if (getIt.isRegistered<NotificationService>()) {
        getIt.registerSingleton<NotificationServiceInterface>(
          getIt<NotificationService>(),
        );
      } else {
        getIt.registerSingleton<NotificationServiceInterface>(
          NoopNotificationService(),
        );
      }
    } else if (!getIt.isRegistered<NotificationServiceInterface>()) {
      getIt.registerSingleton<NotificationServiceInterface>(
        NoopNotificationService(),
      );
    }
  }
}
