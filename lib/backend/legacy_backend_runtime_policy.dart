import 'backend_provider_config.dart';
import 'backend_runtime_config.dart';

class LegacyBackendRuntimePolicy {
  static bool requiresFirebaseCore({
    required BackendProviderConfig providerConfig,
    required BackendRuntimeConfig runtimeConfig,
  }) {
    return providerConfig.authProvider == BackendProviderKind.firebase ||
        providerConfig.profileProvider == BackendProviderKind.firebase ||
        providerConfig.treeProvider == BackendProviderKind.firebase ||
        providerConfig.chatProvider == BackendProviderKind.firebase ||
        providerConfig.notificationProvider == BackendProviderKind.firebase ||
        providerConfig.notificationProvider ==
            BackendProviderKind.hybridLegacy ||
        runtimeConfig.enableLegacyDynamicLinks;
  }

  static bool requiresSupabaseStorage(BackendProviderConfig providerConfig) {
    return providerConfig.storageProvider == BackendProviderKind.hybridLegacy ||
        providerConfig.storageProvider == BackendProviderKind.supabase;
  }
}
