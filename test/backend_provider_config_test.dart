import 'package:flutter_test/flutter_test.dart';
import 'package:lineage/backend/backend_provider_config.dart';

void main() {
  test('BackendProviderConfig uses legacy-safe defaults', () {
    const config = BackendProviderConfig();

    expect(config.authProvider, BackendProviderKind.firebase);
    expect(config.profileProvider, BackendProviderKind.firebase);
    expect(config.treeProvider, BackendProviderKind.firebase);
    expect(config.chatProvider, BackendProviderKind.firebase);
    expect(config.storageProvider, BackendProviderKind.hybridLegacy);
    expect(config.notificationProvider, BackendProviderKind.firebase);
  });

  test('BackendProviderConfig allows provider overrides per domain', () {
    const config = BackendProviderConfig(
      authProvider: BackendProviderKind.customApi,
      profileProvider: BackendProviderKind.customApi,
      treeProvider: BackendProviderKind.customApi,
      chatProvider: BackendProviderKind.customApi,
      storageProvider: BackendProviderKind.supabase,
      notificationProvider: BackendProviderKind.hybridLegacy,
    );

    expect(config.authProvider, BackendProviderKind.customApi);
    expect(config.profileProvider, BackendProviderKind.customApi);
    expect(config.treeProvider, BackendProviderKind.customApi);
    expect(config.chatProvider, BackendProviderKind.customApi);
    expect(config.storageProvider, BackendProviderKind.supabase);
    expect(config.notificationProvider, BackendProviderKind.hybridLegacy);
  });

  test('BackendProviderConfig cascades customApi auth to other domains', () {
    final config = BackendProviderConfig.resolve(authProviderRaw: 'customApi');

    expect(config.authProvider, BackendProviderKind.customApi);
    expect(config.profileProvider, BackendProviderKind.customApi);
    expect(config.treeProvider, BackendProviderKind.customApi);
    expect(config.chatProvider, BackendProviderKind.customApi);
    expect(config.storageProvider, BackendProviderKind.customApi);
    expect(config.notificationProvider, BackendProviderKind.customApi);
  });

  test('BackendProviderConfig still allows explicit domain overrides', () {
    final config = BackendProviderConfig.resolve(
      authProviderRaw: 'customApi',
      treeProviderRaw: 'firebase',
      storageProviderRaw: 'supabase',
    );

    expect(config.authProvider, BackendProviderKind.customApi);
    expect(config.profileProvider, BackendProviderKind.customApi);
    expect(config.treeProvider, BackendProviderKind.firebase);
    expect(config.chatProvider, BackendProviderKind.customApi);
    expect(config.storageProvider, BackendProviderKind.supabase);
    expect(config.notificationProvider, BackendProviderKind.customApi);
  });
}
