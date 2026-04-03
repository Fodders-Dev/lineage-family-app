@TestOn('browser')
library custom_api_notification_service_web_test;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lineage/backend/backend_runtime_config.dart';
import 'package:lineage/services/browser_notification_bridge.dart';
import 'package:lineage/services/custom_api_auth_service.dart';
import 'package:lineage/services/custom_api_notification_service.dart';
import 'package:lineage/services/invitation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'CustomApiNotificationService shows unread backend notifications in browser',
    () async {
      var webConfigCalls = 0;
      var pushDeviceRegistrations = 0;

      final client = MockClient((request) async {
        if (request.url.path == '/v1/push/web/config' &&
            request.method == 'GET') {
          webConfigCalls += 1;
          return http.Response(
            jsonEncode({
              'enabled': true,
              'publicKey': 'BElfakeVapidKey1234567890',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        if (request.url.path == '/v1/push/devices' &&
            request.method == 'POST') {
          pushDeviceRegistrations += 1;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['provider'], 'webpush');
          expect(body['platform'], 'web');
          expect(body['token'],
              '{"endpoint":"https://push.example.test/subscription"}');
          return http.Response(
            jsonEncode({
              'device': {
                'id': 'web-device-1',
                'provider': 'webpush',
                'platform': 'web',
              },
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }

        if (request.url.path == '/v1/notifications/unread-count' &&
            request.method == 'GET') {
          return http.Response(
            jsonEncode({'totalUnread': 1}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        if (request.url.path == '/v1/notifications' &&
            request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'notifications': [
                {
                  'id': 'notification-1',
                  'type': 'tree_invitation',
                  'title': 'Приглашение в дерево',
                  'body': 'Вас пригласили в дерево семьи',
                  'createdAt': '2026-03-27T12:01:00.000Z',
                  'data': {
                    'treeId': 'tree-1',
                    'treeName': 'Семья',
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        return http.Response('{"message":"not found"}', 404);
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'custom_api_session_v1',
        jsonEncode({
          'accessToken': 'access-token',
          'refreshToken': 'refresh-token',
          'userId': 'user-1',
          'email': 'dev@lineage.app',
          'displayName': 'Dev User',
          'providerIds': ['password'],
          'isProfileComplete': true,
          'missingFields': const [],
        }),
      );

      final authService = await CustomApiAuthService.create(
        httpClient: client,
        preferences: prefs,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        invitationService: InvitationService(),
      );

      final bridge = _FakeBrowserNotificationBridge(
        permissionStatusValue: BrowserNotificationPermissionStatus.defaultState,
      );

      final service = await CustomApiNotificationService.create(
        preferences: prefs,
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        httpClient: client,
        browserNotificationBridge: bridge,
      );

      expect(
        await service.setNotificationsEnabled(
          true,
          promptForBrowserPermission: true,
        ),
        isTrue,
      );
      expect(bridge.requestedPermissions, 1);

      await service.startForegroundSync();

      expect(webConfigCalls, 1);
      expect(pushDeviceRegistrations, 1);
      expect(bridge.pushSubscriptionsRequested, 1);
      expect(bridge.shownNotifications, hasLength(1));
      expect(bridge.shownNotifications.single.title, 'Приглашение в дерево');
      expect(
        bridge.shownNotifications.single.body,
        'Вас пригласили в дерево семьи',
      );

      await service.dispose();
    },
  );

  test(
    'CustomApiNotificationService keeps browser notifications disabled when permission is denied',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'custom_api_session_v1',
        jsonEncode({
          'accessToken': 'access-token',
          'refreshToken': 'refresh-token',
          'userId': 'user-1',
          'email': 'dev@lineage.app',
          'displayName': 'Dev User',
          'providerIds': ['password'],
          'isProfileComplete': true,
          'missingFields': const [],
        }),
      );

      final authService = await CustomApiAuthService.create(
        httpClient: MockClient((request) async {
          return http.Response('{"notifications":[]}', 200);
        }),
        preferences: prefs,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        invitationService: InvitationService(),
      );

      final bridge = _FakeBrowserNotificationBridge(
        permissionStatusValue: BrowserNotificationPermissionStatus.denied,
      );

      final service = await CustomApiNotificationService.create(
        preferences: prefs,
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        browserNotificationBridge: bridge,
      );

      expect(
        await service.setNotificationsEnabled(
          true,
          promptForBrowserPermission: true,
        ),
        isFalse,
      );
      expect(service.notificationsEnabled, isFalse);
      expect(bridge.requestedPermissions, 1);

      await service.dispose();
    },
  );

  test(
    'CustomApiNotificationService unregisters browser push device when notifications are disabled',
    () async {
      var deletedDeviceId = '';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'custom_api_session_v1',
        jsonEncode({
          'accessToken': 'access-token',
          'refreshToken': 'refresh-token',
          'userId': 'user-1',
          'email': 'dev@lineage.app',
          'displayName': 'Dev User',
          'providerIds': ['password'],
          'isProfileComplete': true,
          'missingFields': const [],
        }),
      );
      await prefs.setString(
        'custom_api_registered_browser_push_device_id_v1',
        'web-device-1',
      );

      final authService = await CustomApiAuthService.create(
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/push/devices/web-device-1' &&
              request.method == 'DELETE') {
            deletedDeviceId = 'web-device-1';
            return http.Response('', 204);
          }
          return http.Response('{"message":"not found"}', 404);
        }),
        preferences: prefs,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        invitationService: InvitationService(),
      );

      final bridge = _FakeBrowserNotificationBridge(
        permissionStatusValue: BrowserNotificationPermissionStatus.granted,
      );

      final service = await CustomApiNotificationService.create(
        preferences: prefs,
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        browserNotificationBridge: bridge,
      );

      expect(await service.setNotificationsEnabled(false), isFalse);
      expect(deletedDeviceId, 'web-device-1');
      expect(bridge.pushUnsubscribeCalls, 1);
      expect(
        prefs.containsKey('custom_api_registered_browser_push_device_id_v1'),
        isFalse,
      );

      await service.dispose();
    },
  );
}

class _FakeBrowserNotificationBridge implements BrowserNotificationBridge {
  _FakeBrowserNotificationBridge({
    required BrowserNotificationPermissionStatus permissionStatusValue,
  }) : _permissionStatus = permissionStatusValue;

  BrowserNotificationPermissionStatus _permissionStatus;
  int requestedPermissions = 0;
  int pushSubscriptionsRequested = 0;
  int pushUnsubscribeCalls = 0;
  final List<_ShownBrowserNotification> shownNotifications =
      <_ShownBrowserNotification>[];

  @override
  bool get isSupported => true;

  @override
  bool get isPushSupported => true;

  @override
  BrowserNotificationPermissionStatus get permissionStatus => _permissionStatus;

  @override
  Future<BrowserNotificationPermissionStatus> requestPermission({
    bool prompt = true,
  }) async {
    requestedPermissions += 1;
    if (_permissionStatus == BrowserNotificationPermissionStatus.defaultState) {
      _permissionStatus = BrowserNotificationPermissionStatus.granted;
    }
    return _permissionStatus;
  }

  @override
  Future<void> showNotification({
    required String title,
    required String body,
    String? tag,
    void Function()? onClick,
  }) async {
    shownNotifications.add(
      _ShownBrowserNotification(title: title, body: body, tag: tag),
    );
  }

  @override
  Future<BrowserPushSubscription?> subscribeToPush({
    required String publicKey,
  }) async {
    pushSubscriptionsRequested += 1;
    return const BrowserPushSubscription(
      token: '{"endpoint":"https://push.example.test/subscription"}',
    );
  }

  @override
  Future<void> unsubscribeFromPush() async {
    pushUnsubscribeCalls += 1;
  }
}

class _ShownBrowserNotification {
  const _ShownBrowserNotification({
    required this.title,
    required this.body,
    this.tag,
  });

  final String title;
  final String body;
  final String? tag;
}
