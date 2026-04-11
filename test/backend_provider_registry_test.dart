import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:lineage/backend/backend_provider_config.dart';
import 'package:lineage/backend/backend_provider_registry.dart';
import 'package:lineage/backend/interfaces/auth_service_interface.dart';
import 'package:lineage/backend/interfaces/chat_service_interface.dart';
import 'package:lineage/backend/interfaces/family_tree_service_interface.dart';
import 'package:lineage/backend/interfaces/notification_service_interface.dart';
import 'package:lineage/backend/interfaces/profile_service_interface.dart';
import 'package:lineage/backend/interfaces/storage_service_interface.dart';
import 'package:lineage/backend/pending_backend_adapters.dart';

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    await getIt.reset();
  });

  tearDown(() async {
    await getIt.reset();
  });

  test('registry uses placeholder adapters for custom API providers', () {
    const config = BackendProviderConfig(
      authProvider: BackendProviderKind.customApi,
      profileProvider: BackendProviderKind.customApi,
      treeProvider: BackendProviderKind.customApi,
      chatProvider: BackendProviderKind.customApi,
      storageProvider: BackendProviderKind.customApi,
      notificationProvider: BackendProviderKind.customApi,
    );

    BackendProviderRegistry.register(getIt, config: config);

    expect(getIt<AuthServiceInterface>(), isA<PendingBackendAuthService>());
    expect(
      getIt<ProfileServiceInterface>(),
      isA<PendingBackendProfileService>(),
    );
    expect(
      getIt<FamilyTreeServiceInterface>(),
      isA<PendingBackendFamilyTreeService>(),
    );
    expect(getIt<ChatServiceInterface>(), isA<PendingBackendChatService>());
    expect(getIt<StorageServiceInterface>(), isA<NoopStorageService>());
    expect(
      getIt<NotificationServiceInterface>(),
      isA<NoopNotificationService>(),
    );
  });
}
