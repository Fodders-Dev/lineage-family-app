import 'package:flutter_test/flutter_test.dart';
import 'package:lineage/backend/backend_provider_config.dart';

void main() {
  test(
    'Current backend provider config uses Custom API by default',
    () {
      final config = BackendProviderConfig.current;

      expect(config.authProvider, BackendProviderKind.customApi);
      expect(config.profileProvider, BackendProviderKind.customApi);
      expect(config.treeProvider, BackendProviderKind.customApi);
      expect(config.chatProvider, BackendProviderKind.customApi);
      expect(config.storageProvider, BackendProviderKind.customApi);
      expect(config.notificationProvider, BackendProviderKind.customApi);
    },
  );
}
