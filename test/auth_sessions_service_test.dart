// AuthSessionSummary parsing + AuthSessionsService.listSessions() network
// round trip, focused on the osVersion field added alongside
// deviceName/platform/appVersion so the "Active sessions" screen can show
// "Android 14" instead of just "Android".
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:rodnya/backend/backend_runtime_config.dart';
import 'package:rodnya/services/auth_sessions_service.dart';
import 'package:rodnya/services/custom_api_auth_service.dart';
import 'package:rodnya/services/invitation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Rodnya',
      packageName: 'dev.rodnya.test',
      version: '1.0.35',
      buildNumber: '42',
      buildSignature: '',
    );
  });

  group('AuthSessionSummary.fromJson', () {
    test('parses osVersion when the backend sends it', () {
      final summary = AuthSessionSummary.fromJson({
        'sessionPublicId': 'sess-1',
        'deviceName': 'Samsung Galaxy S20 FE',
        'platform': 'android',
        'osVersion': '14',
        'appVersion': '1.0.35',
        'isCurrent': true,
      });

      expect(summary.osVersion, '14');
    });

    test('osVersion is null for a session created before the field shipped',
        () {
      // Old sessions rows (or old client builds that never sent osVersion)
      // simply omit the key — must not throw, must not fabricate a value.
      final summary = AuthSessionSummary.fromJson({
        'sessionPublicId': 'sess-legacy',
        'deviceName': 'iPhone Ивана',
        'platform': 'ios',
        'appVersion': '1.0.20',
        'isCurrent': false,
      });

      expect(summary.osVersion, isNull);
    });
  });

  test('AuthSessionsService.listSessions() surfaces osVersion end to end',
      () async {
    final authClient = MockClient((request) async {
      if (request.url.path == '/v1/auth/login') {
        return http.Response(
          jsonEncode({
            'accessToken': 'access-token',
            'refreshToken': 'refresh-token',
            'user': {
              'id': 'user-1',
              'email': 'dev@rodnya.app',
              'displayName': 'Dev User',
              'providerIds': ['password'],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"message":"offline"}', 500);
    });

    const runtimeConfig =
        BackendRuntimeConfig(apiBaseUrl: 'https://api.example.ru');
    final authService = await CustomApiAuthService.create(
      httpClient: authClient,
      preferences: await SharedPreferences.getInstance(),
      runtimeConfig: runtimeConfig,
      invitationService: InvitationService(),
    );
    await authService.loginWithEmail('dev@rodnya.app', 'secret123');

    final sessionsClient = MockClient((request) async {
      expect(request.url.path, '/v1/auth/sessions');
      return http.Response(
        jsonEncode({
          'sessions': [
            {
              'sessionPublicId': 'sess-1',
              'deviceName': 'Samsung Galaxy S20 FE',
              'platform': 'android',
              'osVersion': '14',
              'appVersion': '1.0.35',
              'createdAt': '2026-09-01T00:00:00.000Z',
              'lastSeenAt': '2026-09-05T00:00:00.000Z',
              'isCurrent': true,
            },
          ],
          'currentSessionPublicId': 'sess-1',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final sessionsService = AuthSessionsService(
      authService: authService,
      runtimeConfig: runtimeConfig,
      httpClient: sessionsClient,
    );

    final result = await sessionsService.listSessions();

    expect(result.sessions, hasLength(1));
    expect(result.sessions.single.osVersion, '14');
    expect(result.sessions.single.deviceName, 'Samsung Galaxy S20 FE');
  });
}
