import 'package:flutter_test/flutter_test.dart';
import 'package:lineage/backend/backend_provider_config.dart';

void main() {
  test(
    'Current backend provider config stays on legacy adapters by default',
    () {
      final config = BackendProviderConfig.current;

      expect(config.authProvider, BackendProviderKind.firebase);
      expect(config.profileProvider, BackendProviderKind.firebase);
      expect(config.treeProvider, BackendProviderKind.firebase);
      expect(config.chatProvider, BackendProviderKind.firebase);
      expect(config.storageProvider, BackendProviderKind.hybridLegacy);
      expect(config.notificationProvider, BackendProviderKind.firebase);
    },
  );
}
