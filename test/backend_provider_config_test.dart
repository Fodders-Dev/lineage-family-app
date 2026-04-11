import 'package:flutter_test/flutter_test.dart';
import 'package:lineage/backend/backend_provider_config.dart';

void main() {
  test('BackendProviderConfig uses customApi by default', () {
    const config = BackendProviderConfig();

    expect(config.authProvider, BackendProviderKind.customApi);
    expect(config.profileProvider, BackendProviderKind.customApi);
    expect(config.treeProvider, BackendProviderKind.customApi);
    expect(config.chatProvider, BackendProviderKind.customApi);
    expect(config.storageProvider, BackendProviderKind.customApi);
    expect(config.notificationProvider, BackendProviderKind.customApi);
  });

  test('BackendProviderConfig.resolve always returns customApi config', () {
    final config = BackendProviderConfig.resolve(
      authProviderRaw: 'firebase',
      hostRaw: 'somewhere.else',
    );

    expect(config.authProvider, BackendProviderKind.customApi);
    expect(config.profileProvider, BackendProviderKind.customApi);
    expect(config.treeProvider, BackendProviderKind.customApi);
    expect(config.chatProvider, BackendProviderKind.customApi);
    expect(config.storageProvider, BackendProviderKind.customApi);
    expect(config.notificationProvider, BackendProviderKind.customApi);
  });
}
