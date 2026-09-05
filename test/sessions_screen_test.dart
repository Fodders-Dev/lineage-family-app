// SessionsScreen ("Активные сеансы") rendering: device name / platform +
// OS version / app version, the "это устройство" current-session badge,
// and the honest "Неизвестное устройство" fallback for sessions that
// predate device-metadata collection (old client build or old row).
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/backend/backend_runtime_config.dart';
import 'package:rodnya/screens/sessions_screen.dart';
import 'package:rodnya/services/auth_sessions_service.dart';
import 'package:rodnya/services/custom_api_auth_service.dart';
import 'package:rodnya/services/invitation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Real `flutter_secure_storage` has no platform implementation to talk to
/// under `flutter test`, but — unlike a plain `test()` body — a
/// `testWidgets()` body DOES have a live `ServicesBinding`, so the plugin's
/// default `MethodChannelFlutterSecureStorage` proceeds to actually invoke
/// the channel instead of failing fast on "binding not initialized". With
/// no engine on the other end, that call never returns, and
/// `CustomApiAuthService.create()` → `restoreSession()` hangs for the full
/// test timeout. Swap in an in-memory fake platform (the same override
/// point real platform implementations register through) so the
/// session-restore read resolves immediately.
class _FakeSecureStoragePlatform extends FlutterSecureStoragePlatform {
  final Map<String, String> _values = {};

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    _values[key] = value;
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async =>
      _values[key];

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async =>
      _values.containsKey(key);

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    _values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async =>
      Map.of(_values);

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    _values.clear();
  }
}

/// Stubs the network round trip entirely. `AuthSessionsService` still needs
/// a real `CustomApiAuthService` to satisfy its constructor, but we never
/// log in through it (login would resolve `DeviceDescriptorBuilder`, which
/// dispatches to `device_info_plus`'s real Windows channel under
/// `testWidgets` and hangs the same way flutter_secure_storage did above —
/// out of scope to fake as well, so we just never call it).
class _FakeAuthSessionsService extends AuthSessionsService {
  _FakeAuthSessionsService({
    required super.authService,
    required this.result,
  }) : super(
          runtimeConfig:
              const BackendRuntimeConfig(apiBaseUrl: 'https://api.example.ru'),
        );

  final AuthSessionsListResult result;

  @override
  Future<AuthSessionsListResult> listSessions() async => result;
}

void main() {
  final getIt = GetIt.instance;

  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  setUp(() async {
    FlutterSecureStoragePlatform.instance = _FakeSecureStoragePlatform();
    SharedPreferences.setMockInitialValues({});
    await getIt.reset();
  });

  tearDown(() async {
    await getIt.reset();
  });

  Future<void> pumpSessionsScreen(
    WidgetTester tester,
    List<AuthSessionSummary> sessions,
    String currentSessionPublicId,
  ) async {
    final authService = await CustomApiAuthService.create(
      httpClient: http.Client(),
      preferences: await SharedPreferences.getInstance(),
      invitationService: InvitationService(),
    );
    getIt.registerSingleton<AuthSessionsService>(
      _FakeAuthSessionsService(
        authService: authService,
        result: AuthSessionsListResult(
          sessions: sessions,
          currentSessionPublicId: currentSessionPublicId,
        ),
      ),
    );

    await tester.pumpWidget(const MaterialApp(home: SessionsScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'shows device name, "platform + OS version", "Родня <appVersion>" and '
    'the current-device badge',
    (tester) async {
      await pumpSessionsScreen(
        tester,
        [
          AuthSessionSummary.fromJson({
            'sessionPublicId': 'sess-1',
            'deviceName': 'Samsung Galaxy S20 FE',
            'platform': 'android',
            'osVersion': '14',
            'appVersion': '1.0.35',
            'createdAt': '2026-09-01T00:00:00.000Z',
            'lastSeenAt': '2026-09-05T00:00:00.000Z',
            'isCurrent': true,
          }),
        ],
        'sess-1',
      );

      expect(find.text('Samsung Galaxy S20 FE'), findsOneWidget);
      expect(find.textContaining('Android 14'), findsOneWidget);
      expect(find.textContaining('Родня 1.0.35'), findsOneWidget);
      expect(find.text('это устройство'), findsOneWidget);
    },
  );

  testWidgets(
    'falls back to "Неизвестное устройство" for a session with no device '
    'metadata (pre-existing row / old client build)',
    (tester) async {
      await pumpSessionsScreen(
        tester,
        [
          AuthSessionSummary.fromJson({
            'sessionPublicId': 'sess-legacy',
            'isCurrent': true,
          }),
        ],
        'sess-legacy',
      );

      expect(find.text('Неизвестное устройство'), findsOneWidget);
    },
  );
}
