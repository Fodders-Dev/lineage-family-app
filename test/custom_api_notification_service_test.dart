import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:lineage/backend/backend_runtime_config.dart';
import 'package:lineage/services/custom_api_auth_service.dart';
import 'package:lineage/services/custom_api_notification_service.dart';
import 'package:lineage/services/invitation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterLocalNotificationsPlatform.instance =
        _FakeFlutterLocalNotificationsPlatform();
  });

  test(
    'CustomApiNotificationService polls unread notifications and deduplicates delivered ids',
    () async {
      final unreadNotifications = [
        {
          'id': 'notification-1',
          'type': 'chat_message',
          'title': 'Собеседник',
          'body': 'Привет из чата',
          'createdAt': '2026-03-27T12:00:00.000Z',
          'data': {
            'chatId': 'chat-1',
            'senderId': 'user-2',
            'senderName': 'Собеседник',
          },
        },
        {
          'id': 'notification-2',
          'type': 'tree_invitation',
          'title': 'Приглашение в дерево',
          'body': 'Вас пригласили в дерево семьи',
          'createdAt': '2026-03-27T12:01:00.000Z',
          'data': {
            'treeId': 'tree-1',
            'treeName': 'Семья',
          },
        },
      ];

      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/notifications');
        expect(request.url.queryParameters['status'], 'unread');
        expect(request.url.queryParameters['limit'], '20');
        expect(request.headers['authorization'], 'Bearer access-token');

        return http.Response(
          jsonEncode({
            'notifications': unreadNotifications,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
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

      final shownChatNotifications = <Map<String, dynamic>>[];
      final shownGenericNotifications = <Map<String, dynamic>>[];

      final service = await CustomApiNotificationService.create(
        preferences: prefs,
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        httpClient: client,
        onChatNotification: ({
          required String chatId,
          required String senderId,
          required String senderName,
          required String messageText,
          required int notificationId,
        }) async {
          shownChatNotifications.add({
            'chatId': chatId,
            'senderId': senderId,
            'senderName': senderName,
            'messageText': messageText,
            'notificationId': notificationId,
          });
        },
        onGenericNotification: ({
          required String title,
          required String body,
          required int notificationId,
          String? payload,
        }) async {
          shownGenericNotifications.add({
            'title': title,
            'body': body,
            'notificationId': notificationId,
            'payload': payload,
          });
        },
      );

      await service.initialize();
      await service.syncPendingNotifications();

      expect(shownChatNotifications, hasLength(1));
      expect(shownChatNotifications.first['chatId'], 'chat-1');
      expect(shownChatNotifications.first['messageText'], 'Привет из чата');

      expect(shownGenericNotifications, hasLength(1));
      expect(shownGenericNotifications.first['title'], 'Приглашение в дерево');
      expect(
        shownGenericNotifications.first['body'],
        'Вас пригласили в дерево семьи',
      );

      final deliveredIds = prefs.getStringList(
        'custom_api_delivered_notification_ids_v1',
      );
      expect(
        deliveredIds,
        containsAll(<String>['notification-1', 'notification-2']),
      );

      final restartedService = await CustomApiNotificationService.create(
        preferences: prefs,
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        httpClient: client,
        onChatNotification: ({
          required String chatId,
          required String senderId,
          required String senderName,
          required String messageText,
          required int notificationId,
        }) async {
          shownChatNotifications.add({'chatId': chatId});
        },
        onGenericNotification: ({
          required String title,
          required String body,
          required int notificationId,
          String? payload,
        }) async {
          shownGenericNotifications.add({'title': title});
        },
      );

      await restartedService.initialize();
      await restartedService.syncPendingNotifications();

      expect(shownChatNotifications, hasLength(1));
      expect(shownGenericNotifications, hasLength(1));

      await service.dispose();
      await restartedService.dispose();
    },
  );

  test(
    'CustomApiNotificationService registers rustore push token on backend startup',
    () async {
      var registeredDeviceCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/v1/push/devices' &&
            request.method == 'POST') {
          registeredDeviceCalls += 1;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['provider'], 'rustore');
          expect(body['token'], 'rustore-token-1');

          return http.Response(
            jsonEncode({
              'device': {
                'id': 'device-1',
                'provider': 'rustore',
                'platform': 'android',
              },
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }

        if (request.url.path == '/v1/notifications' &&
            request.method == 'GET') {
          return http.Response(
            jsonEncode({'notifications': const []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        if (request.url.path == '/v1/notifications/unread-count' &&
            request.method == 'GET') {
          return http.Response(
            jsonEncode({'totalUnread': 0}),
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

      final service = await CustomApiNotificationService.create(
        preferences: prefs,
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        httpClient: client,
        pollInterval: const Duration(hours: 1),
        remotePushTokenProvider: () async => 'rustore-token-1',
      );

      await service.startForegroundSync();
      expect(registeredDeviceCalls, 1);

      await service.startForegroundSync();
      expect(registeredDeviceCalls, 1);

      await service.dispose();
    },
  );

  test(
    'CustomApiNotificationService обновляет unread count stream из backend',
    () async {
      final client = MockClient((request) async {
        if (request.url.path == '/v1/notifications/unread-count' &&
            request.method == 'GET') {
          return http.Response(
            jsonEncode({'totalUnread': 3}),
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
                  'body': 'Вас пригласили',
                  'createdAt': '2026-04-03T10:00:00.000Z',
                  'data': {'treeId': 'tree-1'},
                },
                {
                  'id': 'notification-2',
                  'type': 'chat_message',
                  'title': 'Собеседник',
                  'body': 'Привет',
                  'createdAt': '2026-04-03T10:01:00.000Z',
                  'data': {
                    'chatId': 'chat-1',
                    'senderId': 'user-2',
                    'senderName': 'Собеседник',
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

      final service = await CustomApiNotificationService.create(
        preferences: prefs,
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        httpClient: client,
      );

      final seenCounts = <int>[];
      final subscription =
          service.unreadNotificationsCountStream.listen(seenCounts.add);

      expect(await service.refreshUnreadNotificationsCount(), 3);
      expect(service.unreadNotificationsCount, 3);

      final notifications = await service.fetchUnreadNotifications(limit: 10);
      expect(notifications, hasLength(2));
      expect(service.unreadNotificationsCount, 2);

      await Future<void>.delayed(Duration.zero);
      expect(seenCounts, containsAllInOrder(<int>[3, 2]));

      await subscription.cancel();
      await service.dispose();
    },
  );
}

class _FakeFlutterLocalNotificationsPlatform
    extends FlutterLocalNotificationsPlatform {
  @override
  Future<NotificationAppLaunchDetails?>
      getNotificationAppLaunchDetails() async {
    return const NotificationAppLaunchDetails(false);
  }
}
