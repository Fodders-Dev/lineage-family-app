import 'package:flutter_test/flutter_test.dart';
import 'package:lineage/services/crashlytics_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CrashlyticsService', () {
    test('работает как no-op без инициализированного Firebase', () async {
      final service = CrashlyticsService();

      await expectLater(service.initialize(), completes);
      await expectLater(service.setUserIdentifier('user-1'), completes);
      await expectLater(service.setCustomKey('screen', 'trees'), completes);
      await expectLater(
        service.logError(
          StateError('boom'),
          StackTrace.current,
          reason: 'test',
        ),
        completes,
      );
      await expectLater(service.log('hello'), completes);
    });
  });
}
