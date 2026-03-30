import 'package:flutter_test/flutter_test.dart';
import 'package:lineage/backend/backend_provider_config.dart';
import 'package:lineage/backend/backend_runtime_config.dart';
import 'package:lineage/backend/legacy_backend_runtime_policy.dart';

void main() {
  test(
      'policy skips Firebase core when all providers are custom and legacy links are off',
      () {
    const providerConfig = BackendProviderConfig(
      authProvider: BackendProviderKind.customApi,
      profileProvider: BackendProviderKind.customApi,
      treeProvider: BackendProviderKind.customApi,
      chatProvider: BackendProviderKind.customApi,
      storageProvider: BackendProviderKind.customApi,
      notificationProvider: BackendProviderKind.customApi,
    );
    const runtimeConfig = BackendRuntimeConfig(
      enableLegacyDynamicLinks: false,
    );

    expect(
      LegacyBackendRuntimePolicy.requiresFirebaseCore(
        providerConfig: providerConfig,
        runtimeConfig: runtimeConfig,
      ),
      isFalse,
    );
    expect(
      LegacyBackendRuntimePolicy.requiresSupabaseStorage(providerConfig),
      isFalse,
    );
  });

  test('policy keeps legacy bootstrap for firebase-linked domains', () {
    const providerConfig = BackendProviderConfig(
      authProvider: BackendProviderKind.customApi,
      profileProvider: BackendProviderKind.customApi,
      treeProvider: BackendProviderKind.customApi,
      chatProvider: BackendProviderKind.customApi,
      storageProvider: BackendProviderKind.supabase,
      notificationProvider: BackendProviderKind.hybridLegacy,
    );
    const runtimeConfig = BackendRuntimeConfig(
      enableLegacyDynamicLinks: false,
    );

    expect(
      LegacyBackendRuntimePolicy.requiresFirebaseCore(
        providerConfig: providerConfig,
        runtimeConfig: runtimeConfig,
      ),
      isTrue,
    );
    expect(
      LegacyBackendRuntimePolicy.requiresSupabaseStorage(providerConfig),
      isTrue,
    );
  });

  test('policy preserves firebase bootstrap for legacy dynamic links only', () {
    const providerConfig = BackendProviderConfig(
      authProvider: BackendProviderKind.customApi,
      profileProvider: BackendProviderKind.customApi,
      treeProvider: BackendProviderKind.customApi,
      chatProvider: BackendProviderKind.customApi,
      storageProvider: BackendProviderKind.customApi,
      notificationProvider: BackendProviderKind.customApi,
    );
    const runtimeConfig = BackendRuntimeConfig(
      enableLegacyDynamicLinks: true,
    );

    expect(
      LegacyBackendRuntimePolicy.requiresFirebaseCore(
        providerConfig: providerConfig,
        runtimeConfig: runtimeConfig,
      ),
      isTrue,
    );
  });

  test(
    'prod_custom_api preset keeps startup free from Firebase bootstrap dependencies',
    () {
      const providerConfig = BackendProviderConfig(
        authProvider: BackendProviderKind.customApi,
        profileProvider: BackendProviderKind.customApi,
        treeProvider: BackendProviderKind.customApi,
        chatProvider: BackendProviderKind.customApi,
        storageProvider: BackendProviderKind.customApi,
        notificationProvider: BackendProviderKind.customApi,
      );
      final runtimeConfig = BackendRuntimeConfig.resolve(
        runtimePresetRaw: 'prod_custom_api',
        providerConfig: providerConfig,
      );

      expect(runtimeConfig.enableLegacyDynamicLinks, isFalse);
      expect(
        LegacyBackendRuntimePolicy.requiresFirebaseCore(
          providerConfig: providerConfig,
          runtimeConfig: runtimeConfig,
        ),
        isFalse,
      );
      expect(
        LegacyBackendRuntimePolicy.requiresSupabaseStorage(providerConfig),
        isFalse,
      );
    },
  );
}
