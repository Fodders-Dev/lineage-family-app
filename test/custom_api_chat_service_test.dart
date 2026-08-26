import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:rodnya/backend/backend_runtime_config.dart';
import 'package:rodnya/models/chat_attachment.dart';
import 'package:rodnya/models/chat_details.dart';
import 'package:rodnya/models/chat_message.dart';
import 'package:rodnya/models/chat_preview.dart';
import 'package:rodnya/models/chat_send_progress.dart';
import 'package:rodnya/backend/interfaces/storage_service_interface.dart';
import 'package:rodnya/services/chat_message_cache.dart';
import 'package:rodnya/services/custom_api_auth_service.dart';
import 'package:rodnya/services/custom_api_chat_service.dart';
import 'package:rodnya/services/custom_api_realtime_service.dart';
import 'package:rodnya/services/invitation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('CustomApiChatService loads previews, unread count and sends messages',
      () async {
    final messages = <Map<String, dynamic>>[
      {
        'id': 'message-1',
        'chatId': 'other-user_user-1',
        'senderId': 'other-user',
        'text': 'Привет',
        'timestamp': '2026-03-27T12:00:00.000Z',
        'isRead': false,
        'participants': ['other-user', 'user-1'],
        'senderName': 'Собеседник',
      },
    ];

    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats' && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'chats': [
              {
                'id': 'other-user_user-1_user-1',
                'chatId': 'other-user_user-1',
                'userId': 'user-1',
                'otherUserId': 'other-user',
                'otherUserName': 'Собеседник',
                'otherUserPhotoUrl': null,
                'lastMessage': messages.first['text'],
                'lastMessageTime': messages.first['timestamp'],
                'unreadCount':
                    messages.any((item) => item['isRead'] == false) ? 1 : 0,
                'lastMessageSenderId': messages.first['senderId'],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/chats/unread-count' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'totalUnread': messages
                .where(
                  (item) =>
                      item['isRead'] == false && item['senderId'] != 'user-1',
                )
                .length,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/chats/other-user_user-1/messages' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({'messages': messages}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/chats/direct' && request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['otherUserId'], 'other-user');
        return http.Response(
          jsonEncode({'chatId': 'other-user_user-1'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/chats/other-user_user-1/messages' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final message = <String, dynamic>{
          'id': 'message-2',
          'chatId': 'other-user_user-1',
          'senderId': 'user-1',
          'text': body['text'],
          'timestamp': '2026-03-27T12:05:00.000Z',
          'isRead': false,
          'participants': ['other-user', 'user-1'],
          'senderName': 'Dev User',
        };
        messages.insert(0, message);
        return http.Response(
          jsonEncode({'message': message}),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/chats/other-user_user-1/read' &&
          request.method == 'POST') {
        for (final message in messages) {
          if (message['senderId'] != 'user-1') {
            message['isRead'] = true;
          }
        }
        return http.Response(
          jsonEncode({'ok': true}),
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
        'email': 'dev@rodnya.app',
        'displayName': 'Dev User',
        'providerIds': ['password'],
        'isProfileComplete': true,
        'missingFields': const [],
      }),
    );

    final authService = await CustomApiAuthService.create(
      httpClient: client,
      preferences: await SharedPreferences.getInstance(),
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      invitationService: InvitationService(),
    );

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
      pollInterval: const Duration(milliseconds: 10),
    );

    expect(chatService.buildChatId('other-user'), 'other-user_user-1');
    expect(
        await chatService.getOrCreateChat('other-user'), 'other-user_user-1');

    final previews = await chatService.getUserChatsStream('user-1').first;
    expect(previews, hasLength(1));
    expect(previews.first.otherUserName, 'Собеседник');

    final unreadCount =
        await chatService.getTotalUnreadCountStream('user-1').first;
    expect(unreadCount, 1);

    final history =
        await chatService.getMessagesStream('other-user_user-1').first;
    expect(history, hasLength(1));
    expect(history.first.text, 'Привет');

    await chatService.sendTextMessage(
      otherUserId: 'other-user',
      text: 'Ответ',
    );

    final updatedHistory =
        await chatService.getMessagesStream('other-user_user-1').first;
    expect(updatedHistory.first.text, 'Ответ');

    await chatService.markChatAsRead('other-user_user-1', 'user-1');
    final unreadAfterRead =
        await chatService.getTotalUnreadCountStream('user-1').first;
    expect(unreadAfterRead, 0);
  });

  test('CustomApiChatService keeps sent message when stale refresh returns',
      () async {
    final releaseMessagesFetch = Completer<void>();
    var messagesFetchStarted = false;

    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats/chat-1/messages' &&
          request.method == 'GET') {
        messagesFetchStarted = true;
        await releaseMessagesFetch.future;
        return http.Response(
          jsonEncode({
            'messages': [
              {
                'id': 'message-old',
                'chatId': 'chat-1',
                'senderId': 'other-user',
                'text': 'Старое сообщение',
                'timestamp': '2026-03-27T12:00:00.000Z',
                'isRead': false,
                'participants': ['other-user', 'user-1'],
                'senderName': 'Собеседник',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/chats/chat-1/messages' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'message': {
              'id': 'message-new',
              'chatId': 'chat-1',
              'senderId': 'user-1',
              'text': body['text'],
              'timestamp': '2026-03-27T12:05:00.000Z',
              'isRead': false,
              'participants': ['other-user', 'user-1'],
              'senderName': 'Dev User',
              'clientMessageId': body['clientMessageId'],
            },
          }),
          201,
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
        'email': 'dev@rodnya.app',
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

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final snapshots = <List<ChatMessage>>[];
    final subscription =
        chatService.getMessagesStream('chat-1').listen(snapshots.add);
    addTearDown(subscription.cancel);

    for (var i = 0; i < 20 && !messagesFetchStarted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(messagesFetchStarted, isTrue);

    await chatService.sendMessageToChat(
      chatId: 'chat-1',
      text: 'Быстрый ответ',
      clientMessageId: 'local-1',
    );
    for (var i = 0; i < 20 && snapshots.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(snapshots.last.map((message) => message.text), ['Быстрый ответ']);

    releaseMessagesFetch.complete();
    for (var i = 0;
        i < 20 &&
            !snapshots.any(
              (snapshot) => snapshot.any(
                (message) => message.text == 'Старое сообщение',
              ),
            );
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(
      snapshots.last.map((message) => message.text),
      ['Быстрый ответ', 'Старое сообщение'],
    );
  });

  test('CustomApiChatService replays fresh previews to new subscribers',
      () async {
    var chatRequestCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats' && request.method == 'GET') {
        chatRequestCount++;
        return http.Response(
          jsonEncode({
            'chats': [
              {
                'id': 'other-user_user-1_user-1',
                'chatId': 'other-user_user-1',
                'userId': 'user-1',
                'otherUserId': 'other-user',
                'otherUserName': 'Собеседник',
                'otherUserPhotoUrl': null,
                'lastMessage': 'Привет',
                'lastMessageTime': '2026-03-27T12:00:00.000Z',
                'unreadCount': 0,
                'lastMessageSenderId': 'other-user',
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
        'email': 'dev@rodnya.app',
        'displayName': 'Dev User',
        'providerIds': ['password'],
        'isProfileComplete': true,
        'missingFields': const [],
      }),
    );

    final authService = await CustomApiAuthService.create(
      httpClient: client,
      preferences: await SharedPreferences.getInstance(),
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      invitationService: InvitationService(),
    );

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
      realtimeFallbackPollInterval: const Duration(minutes: 5),
    );

    final firstEvent = Completer<List<ChatPreview>>();
    final firstSubscription =
        chatService.getUserChatsStream('user-1').listen((previews) {
      if (!firstEvent.isCompleted) {
        firstEvent.complete(previews);
      }
    });
    addTearDown(firstSubscription.cancel);

    expect(await firstEvent.future, hasLength(1));

    final secondPreviews = await chatService
        .getUserChatsStream('user-1')
        .first
        .timeout(const Duration(seconds: 1));

    expect(secondPreviews, hasLength(1));
    expect(secondPreviews.first.otherUserName, 'Собеседник');
    expect(chatRequestCount, greaterThanOrEqualTo(2));
  });

  test('CustomApiChatService sends reply metadata with message body', () async {
    Map<String, dynamic>? sentBody;

    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats/chat-1/messages' &&
          request.method == 'POST') {
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'ok': true}),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response(
        jsonEncode({'messages': const [], 'chats': const [], 'totalUnread': 0}),
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
        'email': 'dev@rodnya.app',
        'displayName': 'Dev User',
        'providerIds': ['password'],
        'isProfileComplete': true,
        'missingFields': const [],
      }),
    );

    final authService = await CustomApiAuthService.create(
      httpClient: client,
      preferences: await SharedPreferences.getInstance(),
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      invitationService: InvitationService(),
    );

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    await chatService.sendMessageToChat(
      chatId: 'chat-1',
      text: 'Подтверждаю',
      replyTo: const ChatReplyReference(
        messageId: 'm-1',
        senderId: 'other-user',
        senderName: 'Собеседник',
        text: 'Сбор у дома в 19:00',
      ),
      clientMessageId: 'local-42',
      expiresInSeconds: 3600,
    );

    expect(sentBody?['text'], 'Подтверждаю');
    expect(sentBody?['replyTo']['messageId'], 'm-1');
    expect(sentBody?['replyTo']['senderName'], 'Собеседник');
    expect(sentBody?['clientMessageId'], 'local-42');
    expect(sentBody?['expiresInSeconds'], 3600);
  });

  test('CustomApiChatService fetches paged message history', () async {
    Uri? requestedUri;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats/chat-1/messages' &&
          request.method == 'GET') {
        requestedUri = request.url;
        return http.Response(
          jsonEncode({
            'messages': [
              {
                'id': 'm-2',
                'chatId': 'chat-1',
                'senderId': 'user-2',
                'text': 'Вторая страница',
                'timestamp': '2026-04-30T12:00:00.000Z',
                'isRead': false,
                'participants': ['user-1', 'user-2'],
                'senderName': 'Собеседник',
              },
            ],
            'hasMore': true,
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
        'email': 'dev@rodnya.app',
        'displayName': 'Dev User',
        'providerIds': ['password'],
        'isProfileComplete': true,
        'missingFields': const [],
      }),
    );

    final authService = await CustomApiAuthService.create(
      httpClient: client,
      preferences: await SharedPreferences.getInstance(),
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      invitationService: InvitationService(),
    );

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final page = await chatService.fetchMessagesPage(
      'chat-1',
      limit: 25,
      beforeId: 'm-3',
    );

    expect(requestedUri?.queryParameters['limit'], '25');
    expect(requestedUri?.queryParameters['before'], 'm-3');
    expect(requestedUri?.queryParameters.containsKey('after'), isFalse);
    expect(page.messages, hasLength(1));
    expect(page.messages.first.id, 'm-2');
    expect(page.hasMore, true);
  });

  test('CustomApiChatService searches messages through backend', () async {
    Uri? searchUri;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats/search' && request.method == 'GET') {
        searchUri = request.url;
        return http.Response(
          jsonEncode({
            'results': [
              {
                'messageId': 'message-1',
                'chatId': 'chat-1',
                'senderId': 'user-2',
                'senderName': 'Андрей',
                'text': 'Нашли семейное фото',
                'snippet': 'семейное фото',
                'matchedAt': '2026-04-30T12:00:00.000Z',
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
        'email': 'dev@rodnya.app',
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

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final results = await chatService.searchMessages(
      query: ' фото ',
      chatId: 'chat-1',
      limit: 20,
    );

    expect(searchUri?.queryParameters['q'], 'фото');
    expect(searchUri?.queryParameters['chatId'], 'chat-1');
    expect(searchUri?.queryParameters['limit'], '20');
    expect(results, hasLength(1));
    expect(results.single.messageId, 'message-1');
    expect(results.single.snippet, 'семейное фото');
  });

  test('CustomApiChatService syncs chat drafts through backend', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/v1/chats/drafts' && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'drafts': [
              {
                'chatId': 'chat-1',
                'text': 'Черновик со второго устройства',
                'updatedAt': '2026-04-30T12:00:00.000Z',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/v1/chats/chat-1/draft' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'draft': {
              'chatId': 'chat-1',
              'text': 'Черновик чата',
              'updatedAt': '2026-04-30T12:05:00.000Z',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/v1/chats/chat-1/draft' &&
          request.method == 'PUT') {
        return http.Response(
          jsonEncode({
            'draft': {
              'chatId': 'chat-1',
              'text': jsonDecode(request.body)['text'],
              'updatedAt': '2026-04-30T12:06:00.000Z',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/v1/chats/chat-1/draft' &&
          request.method == 'DELETE') {
        return http.Response(
          jsonEncode({'draft': null}),
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
        'email': 'dev@rodnya.app',
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

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final draft = await chatService.getChatDraft('chat-1');
    expect(draft?.text, 'Черновик чата');

    final drafts = await chatService.getChatDrafts();
    expect(drafts['chat:chat-1']?.text, 'Черновик со второго устройства');

    await chatService.saveChatDraft(chatId: 'chat-1', text: 'Новый черновик');
    await chatService.clearChatDraft('chat-1');

    final putRequest = requests.firstWhere((item) => item.method == 'PUT');
    expect(jsonDecode(putRequest.body)['text'], 'Новый черновик');
    expect(requests.any((item) => item.method == 'DELETE'), isTrue);
  });

  test('CustomApiChatService syncs pinned message through backend', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/v1/chats/chat-1/pin' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'pin': {
              'chatId': 'chat-1',
              'messageId': 'm-1',
              'senderId': 'user-2',
              'senderName': 'Анна',
              'text': 'Проверить документы',
              'attachmentCount': 0,
              'pinnedAt': '2026-04-30T12:00:00.000Z',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/v1/chats/chat-1/messages/m-2/pin' &&
          request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'pin': {
              'chatId': 'chat-1',
              'messageId': 'm-2',
              'senderId': 'user-1',
              'senderName': 'Dev User',
              'text': 'Новый закреп',
              'attachmentCount': 1,
              'pinnedAt': '2026-04-30T12:05:00.000Z',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/v1/chats/chat-1/pin' &&
          request.method == 'DELETE') {
        return http.Response(
          jsonEncode({'pin': null}),
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
        'email': 'dev@rodnya.app',
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

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final pin = await chatService.getChatPinnedMessage('chat-1');
    expect(pin?.messageId, 'm-1');
    expect(pin?.text, 'Проверить документы');

    final updated = await chatService.pinChatMessage(
      chatId: 'chat-1',
      messageId: 'm-2',
    );
    expect(updated?.messageId, 'm-2');
    expect(updated?.attachmentCount, 1);

    await chatService.clearChatPinnedMessage('chat-1');

    expect(
      requests.any((item) =>
          item.url.path == '/v1/chats/chat-1/messages/m-2/pin' &&
          item.method == 'POST'),
      isTrue,
    );
    expect(
      requests.any((item) =>
          item.url.path == '/v1/chats/chat-1/pin' && item.method == 'DELETE'),
      isTrue,
    );
  });

  test(
    'CustomApiChatService emits cached messages before a full reconcile fetch',
    () async {
      Uri? requestedUri;
      final cachedMessage = ChatMessage(
        id: 'm-cached',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Вчерашнее сообщение',
        timestamp: DateTime.utc(2026, 4, 29, 18),
        isRead: true,
        participants: const ['user-1', 'other-user'],
        senderName: 'Собеседник',
      );
      final messageCache = _MemoryChatMessageCache({
        'chat-1': [cachedMessage],
      });

      final client = MockClient((request) async {
        if (request.url.path == '/v1/chats/chat-1/messages' &&
            request.method == 'GET') {
          requestedUri = request.url;
          return http.Response(
            jsonEncode({
              'messages': [
                {
                  'id': 'm-new',
                  'chatId': 'chat-1',
                  'senderId': 'user-1',
                  'text': 'Новое сообщение',
                  'timestamp': '2026-04-30T10:00:00.000Z',
                  'isRead': false,
                  'participants': ['user-1', 'other-user'],
                  'senderName': 'Dev User',
                },
              ],
              'hasMore': false,
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
          'email': 'dev@rodnya.app',
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

      final chatService = CustomApiChatService(
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        httpClient: client,
        messageCache: messageCache,
      );

      final firstEmission = Completer<List<ChatMessage>>();
      final secondEmission = Completer<List<ChatMessage>>();
      var emissionCount = 0;
      final subscription = chatService.getMessagesStream('chat-1').listen(
        (messages) {
          emissionCount += 1;
          if (emissionCount == 1 && !firstEmission.isCompleted) {
            firstEmission.complete(messages);
          } else if (emissionCount == 2 && !secondEmission.isCompleted) {
            secondEmission.complete(messages);
          }
        },
      );
      addTearDown(subscription.cancel);

      final cached = await firstEmission.future.timeout(
        const Duration(seconds: 2),
      );
      expect(cached.map((message) => message.id).toList(), ['m-cached']);

      final refreshed = await secondEmission.future.timeout(
        const Duration(seconds: 2),
      );
      expect(
        refreshed.map((message) => message.id).toList(),
        ['m-new', 'm-cached'],
      );
      expect(requestedUri?.queryParameters['limit'], '200');
      // The refresh is a full newest-window fetch (no after-cursor delta) so it
      // can reconcile deletions that happened while this device was away — a
      // delta fetch only ever adds.
      expect(requestedUri?.queryParameters.containsKey('after'), isFalse);
      expect(requestedUri?.queryParameters.containsKey('before'), isFalse);

      await Future<void>.delayed(Duration.zero);
      expect(
        messageCache.snapshot('chat-1').map((message) => message.id).toList(),
        ['m-new', 'm-cached'],
      );
    },
  );

  test(
    'CustomApiChatService refresh never drops messages on an empty or '
    'shorter server page (P0 data-loss guard)',
    () async {
      // Regression: a no-afterId refresh (fired on every websocket reconnect /
      // app resume) used to REPLACE the local list with the latest server
      // page — an empty page wiped everything, a 100-row page truncated longer
      // chats. The fix merges (union by id). Drive the no-afterId path via
      // refreshMessages with an empty page then a latest-only page; assert no
      // message is ever dropped.
      var getCalls = 0;
      Map<String, dynamic> msg(
        String id,
        String text,
        String ts,
        String sender,
      ) =>
          {
            'id': id,
            'chatId': 'chat-1',
            'senderId': sender,
            'text': text,
            'timestamp': ts,
            'isRead': true,
            'participants': ['user-1', 'other-user'],
            'senderName': sender == 'user-1' ? 'Dev User' : 'Собеседник',
          };
      final client = MockClient((request) async {
        if (request.url.path == '/v1/chats/chat-1/messages' &&
            request.method == 'GET') {
          getCalls += 1;
          final List<Map<String, dynamic>> messages;
          if (getCalls == 1) {
            messages = [
              msg('m-1', 'Раз', '2026-04-01T10:00:00.000Z', 'other-user'),
              msg('m-2', 'Два', '2026-04-01T10:01:00.000Z', 'user-1'),
              msg('m-3', 'Три', '2026-04-01T10:02:00.000Z', 'other-user'),
            ];
          } else if (getCalls == 2) {
            messages = const <Map<String, dynamic>>[]; // transient empty page
          } else {
            messages = [
              msg('m-3', 'Три', '2026-04-01T10:02:00.000Z', 'other-user'),
            ]; // latest-only short page
          }
          return http.Response(
            jsonEncode({'messages': messages, 'hasMore': false}),
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
          'email': 'dev@rodnya.app',
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

      final chatService = CustomApiChatService(
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        httpClient: client,
      );

      final snapshots = <List<ChatMessage>>[];
      final subscription =
          chatService.getMessagesStream('chat-1').listen(snapshots.add);
      addTearDown(subscription.cancel);

      // First full (no-afterId) fetch lands 3 messages, newest first.
      for (var i = 0;
          i < 50 && !(snapshots.isNotEmpty && snapshots.last.length == 3);
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(snapshots.last.map((m) => m.id).toList(), ['m-3', 'm-2', 'm-1']);

      // Reconnect-style no-afterId refresh returns an EMPTY page → must NOT wipe.
      await chatService.refreshMessages('chat-1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(getCalls >= 2, isTrue);
      expect(
        snapshots.last.map((m) => m.id).toList(),
        ['m-3', 'm-2', 'm-1'],
        reason: 'empty server page must not drop existing messages',
      );

      // Another no-afterId refresh returns only the latest → older preserved.
      await chatService.refreshMessages('chat-1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(getCalls >= 3, isTrue);
      expect(
        snapshots.last.map((m) => m.id).toList(),
        ['m-3', 'm-2', 'm-1'],
        reason: 'a latest-only short page must not truncate older messages',
      );
    },
  );

  test(
    'CustomApiChatService reconciles a server-side deletion within the '
    'fetched window on refetch',
    () async {
      // A message deleted from another device (or a «delete for everyone» this
      // client missed) used to stay cached forever: the sync only ADDED server
      // messages. Now a full refetch prunes a locally-cached message that is
      // absent from the server page yet sits strictly INSIDE the fetched
      // window — flanked by a still-present message both newer and older.
      var getCalls = 0;
      Map<String, dynamic> msg(String id, String ts) => {
            'id': id,
            'chatId': 'chat-1',
            'senderId': 'other-user',
            'text': id,
            'timestamp': ts,
            'isRead': true,
            'participants': ['user-1', 'other-user'],
            'senderName': 'Собеседник',
          };
      final client = MockClient((request) async {
        if (request.url.path == '/v1/chats/chat-1/messages' &&
            request.method == 'GET') {
          getCalls += 1;
          final List<Map<String, dynamic>> messages;
          if (getCalls == 1) {
            // Newest-first, as the backend returns.
            messages = [
              msg('m-5', '2026-04-01T10:04:00.000Z'),
              msg('m-4', '2026-04-01T10:03:00.000Z'),
              msg('m-3', '2026-04-01T10:02:00.000Z'),
              msg('m-2', '2026-04-01T10:01:00.000Z'),
              msg('m-1', '2026-04-01T10:00:00.000Z'),
            ];
          } else {
            // m-3 has been deleted server-side; m-2/m-4 still flank the hole.
            messages = [
              msg('m-5', '2026-04-01T10:04:00.000Z'),
              msg('m-4', '2026-04-01T10:03:00.000Z'),
              msg('m-2', '2026-04-01T10:01:00.000Z'),
              msg('m-1', '2026-04-01T10:00:00.000Z'),
            ];
          }
          return http.Response(
            jsonEncode({'messages': messages, 'hasMore': false}),
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
          'email': 'dev@rodnya.app',
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

      final messageCache = _MemoryChatMessageCache();
      final chatService = CustomApiChatService(
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        httpClient: client,
        messageCache: messageCache,
      );

      final snapshots = <List<ChatMessage>>[];
      final subscription =
          chatService.getMessagesStream('chat-1').listen(snapshots.add);
      addTearDown(subscription.cancel);

      for (var i = 0;
          i < 50 && !(snapshots.isNotEmpty && snapshots.last.length == 5);
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        snapshots.last.map((m) => m.id).toList(),
        ['m-5', 'm-4', 'm-3', 'm-2', 'm-1'],
      );

      await chatService.refreshMessages('chat-1');
      for (var i = 0;
          i < 50 && !(snapshots.isNotEmpty && snapshots.last.length == 4);
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        snapshots.last.map((m) => m.id).toList(),
        ['m-5', 'm-4', 'm-2', 'm-1'],
        reason: 'an interior server-side deletion must be pruned locally',
      );

      // The prune is persisted too — the next cold read must not resurrect it.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        messageCache.snapshot('chat-1').map((m) => m.id).toList(),
        ['m-5', 'm-4', 'm-2', 'm-1'],
      );
    },
  );

  test('CustomApiChatService sends forwarded attachments without reupload',
      () async {
    Map<String, dynamic>? sentBody;

    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats/chat-1/messages' &&
          request.method == 'POST') {
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'message': {
              'id': 'msg-forwarded',
              'chatId': 'chat-1',
              'senderId': 'user-1',
              'text': 'Пересланное сообщение',
              'timestamp': '2026-04-11T12:00:00.000Z',
              'isRead': false,
              'participants': ['user-1', 'other-user'],
              'attachments': sentBody?['attachments'] ?? const [],
            },
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response('{}', 404);
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'custom_api_session_v1',
      jsonEncode({
        'accessToken': 'access-token',
        'refreshToken': 'refresh-token',
        'userId': 'user-1',
        'email': 'dev@rodnya.app',
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

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    await chatService.sendMessageToChat(
      chatId: 'chat-1',
      text: 'Пересланное сообщение',
      forwardedAttachments: const [
        ChatAttachment(
          type: ChatAttachmentType.image,
          url: 'https://cdn.example.ru/chat/photo.jpg',
          fileName: 'photo.jpg',
        ),
      ],
    );

    expect(sentBody?['attachments'], hasLength(1));
    expect(sentBody?['attachments'][0]['url'],
        'https://cdn.example.ru/chat/photo.jpg');
    expect(sentBody?['mediaUrls'], ['https://cdn.example.ru/chat/photo.jpg']);
  });

  test('CustomApiChatService edits message with PATCH request', () async {
    String? editedPath;
    String? editedMethod;
    Map<String, dynamic>? sentBody;

    final client = MockClient((request) async {
      editedPath = request.url.path;
      editedMethod = request.method;
      sentBody = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'message': {'id': 'm-1'}
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
        'email': 'dev@rodnya.app',
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

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    await chatService.editChatMessage(
      chatId: 'chat-1',
      messageId: 'm-1',
      text: '  Исправленный текст  ',
    );

    expect(editedMethod, 'PATCH');
    expect(editedPath, '/v1/chats/chat-1/messages/m-1');
    expect(sentBody, {'text': 'Исправленный текст'});
  });

  test('CustomApiChatService deletes message with DELETE request', () async {
    String? deletedPath;
    String? deletedMethod;

    final client = MockClient((request) async {
      deletedPath = request.url.path;
      deletedMethod = request.method;
      return http.Response(
        jsonEncode({'ok': true}),
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
        'email': 'dev@rodnya.app',
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

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    await chatService.deleteChatMessage(
      chatId: 'chat-1',
      messageId: 'm-2',
    );

    expect(deletedMethod, 'DELETE');
    expect(deletedPath, '/v1/chats/chat-1/messages/m-2');
  });

  test(
    'CustomApiChatService treats a 404 delete as success and prunes locally',
    () async {
      ChatMessage message(String id, String ts) => ChatMessage(
            id: id,
            chatId: 'chat-1',
            senderId: 'user-1',
            text: id,
            timestamp: DateTime.parse(ts),
            isRead: true,
            participants: const ['user-1', 'other-user'],
            senderName: 'Dev User',
          );
      final messageCache = _MemoryChatMessageCache({
        'chat-1': [
          message('m-1', '2026-04-01T10:00:00.000Z'),
          message('m-2', '2026-04-01T10:01:00.000Z'),
        ],
      });

      var deleteCalls = 0;
      final client = MockClient((request) async {
        if (request.method == 'DELETE' &&
            request.url.path == '/v1/chats/chat-1/messages/m-2') {
          deleteCalls += 1;
          return http.Response(
            jsonEncode({'message': 'Сообщение не найдено'}),
            404,
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
          'email': 'dev@rodnya.app',
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

      final chatService = CustomApiChatService(
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        httpClient: client,
        messageCache: messageCache,
      );

      // «Already gone» must NOT throw.
      await chatService.deleteChatMessage(chatId: 'chat-1', messageId: 'm-2');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(deleteCalls, 1);
      expect(
        messageCache.snapshot('chat-1').map((m) => m.id).toList(),
        ['m-1'],
        reason: 'a 404 delete must prune the stale local copy',
      );
    },
  );

  test('CustomApiChatService rethrows a non-404 delete error', () async {
    final client = MockClient((request) async {
      if (request.method == 'DELETE') {
        return http.Response(
          jsonEncode({'message': 'Можно удалять только свои сообщения'}),
          403,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200, headers: {'content-type': 'application/json'});
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'custom_api_session_v1',
      jsonEncode({
        'accessToken': 'access-token',
        'refreshToken': 'refresh-token',
        'userId': 'user-1',
        'email': 'dev@rodnya.app',
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

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    await expectLater(
      chatService.deleteChatMessage(chatId: 'chat-1', messageId: 'm-2'),
      throwsA(isA<CustomApiException>()),
    );
  });

  test('CustomApiChatService refreshes message stream on websocket events',
      () async {
    final messages = <Map<String, dynamic>>[
      {
        'id': 'message-1',
        'chatId': 'other-user_user-1',
        'senderId': 'other-user',
        'text': 'Первое сообщение',
        'timestamp': '2026-03-27T12:00:00.000Z',
        'isRead': false,
        'participants': ['other-user', 'user-1'],
        'senderName': 'Собеседник',
      },
    ];

    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats/other-user_user-1/messages' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({'messages': messages}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/chats/direct' && request.method == 'POST') {
        return http.Response(
          jsonEncode({'chatId': 'other-user_user-1'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response(
        jsonEncode({'chats': const [], 'totalUnread': 0}),
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
        'email': 'dev@rodnya.app',
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
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      invitationService: InvitationService(),
    );

    final realtimeController = StreamController<dynamic>.broadcast();
    final realtimeService = CustomApiRealtimeService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      channelFactory: (_) => _FakeWebSocketChannel(realtimeController.stream),
      reconnectDelay: const Duration(milliseconds: 10),
    );

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      httpClient: client,
      realtimeService: realtimeService,
      pollInterval: const Duration(hours: 1),
    );

    final messagesStream =
        chatService.getMessagesStream('other-user_user-1').asBroadcastStream();
    final refreshedMessagesFuture = messagesStream.skip(1).first.timeout(
          const Duration(seconds: 1),
        );

    final initialMessages = await messagesStream.first;
    expect(initialMessages, hasLength(1));
    expect(initialMessages.first.text, 'Первое сообщение');

    messages.insert(0, {
      'id': 'message-2',
      'chatId': 'other-user_user-1',
      'senderId': 'other-user',
      'text': 'Второе сообщение',
      'timestamp': '2026-03-27T12:05:00.000Z',
      'isRead': false,
      'participants': ['other-user', 'user-1'],
      'senderName': 'Собеседник',
    });

    realtimeController.add(
      jsonEncode({
        'type': 'chat.message.created',
        'chatId': 'other-user_user-1',
        'message': messages.first,
      }),
    );

    final refreshedMessages = await refreshedMessagesFuture;
    expect(refreshedMessages.first.text, 'Второе сообщение');

    await realtimeController.close();
    await realtimeService.dispose();
  });

  test('CustomApiChatService merges sent message response without refetch',
      () async {
    var messageHistoryRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats/chat-1/messages' &&
          request.method == 'GET') {
        messageHistoryRequests++;
        return http.Response(
          jsonEncode({
            'messages': [
              {
                'id': 'message-1',
                'chatId': 'chat-1',
                'senderId': 'user-2',
                'text': 'Первое сообщение',
                'timestamp': '2026-03-27T12:00:00.000Z',
                'isRead': false,
                'participants': ['user-1', 'user-2'],
                'senderName': 'Собеседник',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/chats/chat-1/messages' &&
          request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'message': {
              'id': 'message-2',
              'chatId': 'chat-1',
              'senderId': 'user-1',
              'text': 'Ответ без refetch',
              'timestamp': '2026-03-27T12:05:00.000Z',
              'isRead': false,
              'participants': ['user-1', 'user-2'],
              'senderName': 'Dev User',
            },
          }),
          201,
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
        'email': 'dev@rodnya.app',
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

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final messagesStream =
        chatService.getMessagesStream('chat-1').asBroadcastStream();
    final updatedMessagesFuture = messagesStream.skip(1).first;
    expect(await messagesStream.first, hasLength(1));

    await chatService.sendMessageToChat(
      chatId: 'chat-1',
      text: 'Ответ без refetch',
    );

    final updatedMessages = await updatedMessagesFuture;
    expect(updatedMessages.first.text, 'Ответ без refetch');
    expect(messageHistoryRequests, 1);
  });

  test('CustomApiChatService applies realtime total unread count', () async {
    var unreadRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats/unread-count' &&
          request.method == 'GET') {
        unreadRequests++;
        return http.Response(
          jsonEncode({'totalUnread': 0}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response(
        jsonEncode({'messages': const [], 'chats': const []}),
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
        'email': 'dev@rodnya.app',
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
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      invitationService: InvitationService(),
    );

    final realtimeController = StreamController<dynamic>.broadcast();
    final realtimeService = CustomApiRealtimeService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      channelFactory: (_) => _FakeWebSocketChannel(realtimeController.stream),
      reconnectDelay: const Duration(milliseconds: 10),
    );

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      httpClient: client,
      realtimeService: realtimeService,
      overviewPollInterval: const Duration(hours: 1),
    );

    final unreadStream =
        chatService.getTotalUnreadCountStream('user-1').asBroadcastStream();
    final updatedUnreadFuture = unreadStream.skip(1).first;
    expect(await unreadStream.first, 0);

    realtimeController.add(
      jsonEncode({
        'type': 'chat.unread.changed',
        'chatId': 'chat-1',
        'totalUnread': 4,
      }),
    );

    expect(await updatedUnreadFuture, 4);
    expect(unreadRequests, 1);

    await realtimeController.close();
    await realtimeService.dispose();
  });

  test('CustomApiChatService refreshes previews from realtime without polling',
      () async {
    var chatsRequestCount = 0;
    var latestPreviewText = 'Привет';
    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats' && request.method == 'GET') {
        chatsRequestCount++;
        return http.Response(
          jsonEncode({
            'chats': [
              {
                'id': 'chat-1_user-1',
                'chatId': 'chat-1',
                'userId': 'user-1',
                'otherUserId': 'user-2',
                'otherUserName': 'Собеседник',
                'otherUserPhotoUrl': null,
                'lastMessage': latestPreviewText,
                'lastMessageTime': '2026-04-30T12:00:00.000Z',
                'unreadCount': 0,
                'lastMessageSenderId': 'user-2',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response(
        jsonEncode({'messages': const [], 'totalUnread': 0}),
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
        'email': 'dev@rodnya.app',
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
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      invitationService: InvitationService(),
    );

    final realtimeController = StreamController<dynamic>.broadcast();
    final realtimeService = CustomApiRealtimeService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      channelFactory: (_) => _FakeWebSocketChannel(realtimeController.stream),
      reconnectDelay: const Duration(milliseconds: 10),
    );

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      httpClient: client,
      realtimeService: realtimeService,
      realtimeFallbackPollInterval: const Duration(milliseconds: 10),
    );

    final previewsStream =
        chatService.getUserChatsStream('user-1').asBroadcastStream();
    final updatedPreviewsFuture = previewsStream.skip(1).first;
    final initialPreviews = await previewsStream.first;
    expect(initialPreviews.first.lastMessage, 'Привет');

    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(chatsRequestCount, 1);

    latestPreviewText = 'Новое сообщение';
    realtimeController.add(
      jsonEncode({
        'type': 'chat.updated',
        'chatId': 'chat-1',
      }),
    );

    final updatedPreviews = await updatedPreviewsFuture;
    expect(updatedPreviews.first.lastMessage, 'Новое сообщение');
    expect(chatsRequestCount, 2);

    await realtimeController.close();
    await realtimeService.dispose();
  });

  test(
      'CustomApiChatService patches group preview photo from realtime '
      'chat.updated even when /v1/chats stays stale-null', () async {
    const groupPhotoUrl = 'https://cdn.example.ru/group-1.jpg';
    // GET /v1/chats keeps returning photoUrl:null for the group (the stale
    // backend bug); the realtime chat.updated event carries the real photo.
    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats' && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'chats': [
              {
                'id': 'group-1_unit',
                'chatId': 'group-1',
                'userId': 'user-1',
                'type': 'group',
                'title': 'Семья Кузнецовых',
                'photoUrl': null,
                'participantIds': ['user-1', 'user-2', 'user-3'],
                'otherUserId': '',
                'otherUserName': '',
                'lastMessage': 'Привет',
                'lastMessageTime': '2026-04-30T12:00:00.000Z',
                'unreadCount': 0,
                'lastMessageSenderId': 'user-2',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response(
        jsonEncode({'messages': const [], 'totalUnread': 0}),
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
        'email': 'dev@rodnya.app',
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
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      invitationService: InvitationService(),
    );

    final realtimeController = StreamController<dynamic>.broadcast();
    final realtimeService = CustomApiRealtimeService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      channelFactory: (_) => _FakeWebSocketChannel(realtimeController.stream),
      reconnectDelay: const Duration(milliseconds: 10),
    );

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      httpClient: client,
      realtimeService: realtimeService,
      realtimeFallbackPollInterval: const Duration(milliseconds: 10),
    );

    final previewsStream =
        chatService.getUserChatsStream('user-1').asBroadcastStream();
    final initialPreviews = await previewsStream.first;
    // Baseline: the fetch is stale — group shows no photo.
    expect(initialPreviews.first.isGroup, isTrue);
    expect(initialPreviews.first.displayPhotoUrl, isNull);

    // Wait for a preview where the group photo has been patched in.
    final patchedFuture = previewsStream
        .firstWhere(
          (previews) =>
              previews.isNotEmpty &&
              previews.first.displayPhotoUrl == groupPhotoUrl,
        )
        .timeout(const Duration(seconds: 2));

    realtimeController.add(
      jsonEncode({
        'type': 'chat.updated',
        'chatId': 'group-1',
        'chat': {
          'id': 'group-1_unit',
          'chatId': 'group-1',
          'userId': 'user-1',
          'type': 'group',
          'title': 'Семья Кузнецовых',
          'photoUrl': groupPhotoUrl,
          'participantIds': ['user-1', 'user-2', 'user-3'],
        },
      }),
    );

    final patched = await patchedFuture;
    // Realtime photoUrl wins over the stale-null fetch — and survives the
    // subsequent debounced refetch (which also returns photoUrl:null).
    expect(patched.first.displayPhotoUrl, groupPhotoUrl);
    expect(patched.first.displayName, 'Семья Кузнецовых');

    // Let the debounced stale refetch run; the override must persist.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final afterRefetch = await chatService.getUserChatsStream('user-1').first;
    expect(
      afterRefetch.first.displayPhotoUrl,
      groupPhotoUrl,
      reason: 'stale /v1/chats refetch must not blank the realtime photo',
    );

    await realtimeController.close();
    await realtimeService.dispose();
  });

  test(
      'CustomApiChatService restores group preview photo from a persisted '
      'override on cold start (first emit, fresh service + filled Hive)',
      () async {
    const groupPhotoUrl = 'https://cdn.example.ru/group-1.jpg';
    // The fetch still returns photoUrl:null (stale backend) on this cold boot.
    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats' && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'chats': [
              {
                'id': 'group-1_unit',
                'chatId': 'group-1',
                'userId': 'user-1',
                'type': 'group',
                'title': 'Семья Кузнецовых',
                'photoUrl': null,
                'participantIds': ['user-1', 'user-2', 'user-3'],
                'otherUserId': '',
                'otherUserName': '',
                'lastMessage': 'Привет',
                'lastMessageTime': '2026-04-30T12:00:00.000Z',
                'unreadCount': 0,
                'lastMessageSenderId': 'user-2',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response(
        jsonEncode({'messages': const [], 'totalUnread': 0}),
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
        'email': 'dev@rodnya.app',
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
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      invitationService: InvitationService(),
    );

    // Simulate a Hive box already populated by a previous session.
    final overrideCache = InMemoryChatPreviewOverrideCache(
      <String, ChatPreviewOverride>{
        'group-1': const ChatPreviewOverride(
          photoUrl: groupPhotoUrl,
          title: 'Семья Кузнецовых',
          type: 'group',
        ),
      },
    );

    // Fresh service (no realtime yet) — the cold-start case.
    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      httpClient: client,
      overrideCache: overrideCache,
      pollInterval: const Duration(hours: 1),
      realtimeFallbackPollInterval: const Duration(hours: 1),
    );

    final firstPreviews = await chatService.getUserChatsStream('user-1').first;
    expect(firstPreviews, hasLength(1));
    expect(firstPreviews.first.isGroup, isTrue);
    expect(
      firstPreviews.first.displayPhotoUrl,
      groupPhotoUrl,
      reason: 'the very first emit on cold start must carry the restored group '
          'avatar from the persisted override, before the stale fetch wins',
    );
    expect(firstPreviews.first.displayName, 'Семья Кузнецовых');
  });

  test(
      'CustomApiChatService starts low-rate fallback after realtime disconnect',
      () async {
    var unreadRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats/unread-count' &&
          request.method == 'GET') {
        unreadRequests++;
        return http.Response(
          jsonEncode({'totalUnread': unreadRequests == 1 ? 0 : 2}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response(
        jsonEncode({'messages': const [], 'chats': const []}),
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
        'email': 'dev@rodnya.app',
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
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      invitationService: InvitationService(),
    );

    final realtimeController = StreamController<dynamic>.broadcast();
    final realtimeService = CustomApiRealtimeService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      channelFactory: (_) => _FakeWebSocketChannel(realtimeController.stream),
      reconnectDelay: const Duration(hours: 1),
    );

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      httpClient: client,
      realtimeService: realtimeService,
      realtimeFallbackPollInterval: const Duration(milliseconds: 10),
    );

    final unreadStream =
        chatService.getTotalUnreadCountStream('user-1').asBroadcastStream();
    final fallbackUnreadFuture = unreadStream.skip(1).first;
    expect(await unreadStream.first, 0);

    await realtimeController.close();

    expect(await fallbackUnreadFuture.timeout(const Duration(seconds: 1)), 2);
    expect(unreadRequests, greaterThanOrEqualTo(2));

    await realtimeService.dispose();
  });

  test(
      'CustomApiChatService shares previews and unread streams across listeners',
      () async {
    var chatsRequestCount = 0;
    var unreadRequestCount = 0;

    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats' && request.method == 'GET') {
        chatsRequestCount++;
        return http.Response(
          jsonEncode({
            'chats': [
              {
                'id': 'other-user_user-1_user-1',
                'chatId': 'other-user_user-1',
                'userId': 'user-1',
                'otherUserId': 'other-user',
                'otherUserName': 'Собеседник',
                'otherUserPhotoUrl': null,
                'lastMessage': 'Привет',
                'lastMessageTime': '2026-03-27T12:00:00.000Z',
                'unreadCount': 1,
                'lastMessageSenderId': 'other-user',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/chats/unread-count' &&
          request.method == 'GET') {
        unreadRequestCount++;
        return http.Response(
          jsonEncode({'totalUnread': 1}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response(
        jsonEncode({'messages': const []}),
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
        'email': 'dev@rodnya.app',
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

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
      pollInterval: const Duration(hours: 1),
    );

    final previewsStream = chatService.getUserChatsStream('user-1');
    final unreadStream = chatService.getTotalUnreadCountStream('user-1');

    final previewResults = await Future.wait([
      previewsStream.first,
      previewsStream.first,
    ]);
    final unreadResults = await Future.wait([
      unreadStream.first,
      unreadStream.first,
    ]);

    expect(previewResults.first, hasLength(1));
    expect(previewResults.last, hasLength(1));
    expect(unreadResults, [1, 1]);
    expect(chatsRequestCount, 1);
    expect(unreadRequestCount, 1);
  });

  test(
    'CustomApiChatService does not synthesize local chat id when backend response is incomplete',
    () async {
      final client = MockClient((request) async {
        if (request.url.path == '/v1/chats/direct' &&
            request.method == 'POST') {
          return http.Response(
            jsonEncode({'chatId': ''}),
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
          'email': 'dev@rodnya.app',
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

      final chatService = CustomApiChatService(
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        httpClient: client,
      );

      await expectLater(
        chatService.getOrCreateChat('other-user'),
        throwsA(
          isA<CustomApiException>().having(
            (error) => error.message,
            'message',
            contains('идентификатор чата'),
          ),
        ),
      );
    },
  );

  test('CustomApiChatService creates group chat and parses group previews',
      () async {
    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats/groups' && request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['participantIds'], ['user-2', 'user-3']);
        expect(body['title'], 'Семья Кузнецовых');
        expect(body['treeId'], 'tree-1');
        return http.Response(
          jsonEncode({
            'chatId': 'chat-group-1',
            'chat': {
              'id': 'chat-group-1',
              'type': 'group',
              'title': 'Семья Кузнецовых',
              'participantIds': ['user-1', 'user-2', 'user-3'],
            },
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/chats' && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'chats': [
              {
                'id': 'chat-group-1_user-1',
                'chatId': 'chat-group-1',
                'userId': 'user-1',
                'type': 'group',
                'title': 'Семья Кузнецовых',
                'participantIds': ['user-1', 'user-2', 'user-3'],
                'otherUserId': '',
                'otherUserName': 'Семья Кузнецовых',
                'otherUserPhotoUrl': null,
                'lastMessage': '',
                'lastMessageTime': '2026-03-27T12:00:00.000Z',
                'unreadCount': 0,
                'lastMessageSenderId': '',
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
        'email': 'dev@rodnya.app',
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

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final chatId = await chatService.createGroupChat(
      participantIds: const ['user-2', 'user-3'],
      title: 'Семья Кузнецовых',
      treeId: 'tree-1',
    );
    expect(chatId, 'chat-group-1');

    final previews = await chatService.getUserChatsStream('user-1').first;
    expect(previews, hasLength(1));
    expect(previews.first.isGroup, isTrue);
    expect(previews.first.displayName, 'Семья Кузнецовых');
    expect(previews.first.participantIds, ['user-1', 'user-2', 'user-3']);
  });

  test('CustomApiChatService creates branch chat', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats/branches' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['treeId'], 'tree-1');
        expect(body['branchRootPersonIds'], ['person-1']);
        expect(body['title'], 'Ветка Иван Петров');
        return http.Response(
          jsonEncode({
            'chatId': 'chat-branch-1',
            'chat': {
              'id': 'chat-branch-1',
              'type': 'branch',
              'title': 'Ветка Иван Петров',
              'participantIds': ['user-1', 'user-2'],
              'branchRootPersonIds': ['person-1'],
            },
          }),
          201,
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
        'email': 'dev@rodnya.app',
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

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final chatId = await chatService.createBranchChat(
      treeId: 'tree-1',
      branchRootPersonIds: const ['person-1'],
      title: 'Ветка Иван Петров',
    );
    expect(chatId, 'chat-branch-1');
  });

  test('CustomApiChatService loads and updates ordinary group details',
      () async {
    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats/chat-group-1' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'chat': {
              'id': 'chat-group-1',
              'type': 'group',
              'title': 'Семья Кузнецовых',
              'participantIds': ['user-1', 'user-2'],
              'treeId': 'tree-1',
            },
            'participants': [
              {
                'userId': 'user-1',
                'displayName': 'Артем',
              },
              {
                'userId': 'user-2',
                'displayName': 'Андрей',
              },
            ],
            'branchRoots': const [],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/chats/chat-group-1' &&
          request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['title'], 'Совет семьи');
        return http.Response(
          jsonEncode({
            'chat': {
              'id': 'chat-group-1',
              'type': 'group',
              'title': 'Совет семьи',
              'participantIds': ['user-1', 'user-2'],
              'treeId': 'tree-1',
            },
            'participants': [
              {
                'userId': 'user-1',
                'displayName': 'Артем',
              },
              {
                'userId': 'user-2',
                'displayName': 'Андрей',
              },
            ],
            'branchRoots': const [],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/chats/chat-group-1/participants' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['participantIds'], ['user-3']);
        return http.Response(
          jsonEncode({
            'chat': {
              'id': 'chat-group-1',
              'type': 'group',
              'title': 'Совет семьи',
              'participantIds': ['user-1', 'user-2', 'user-3'],
              'treeId': 'tree-1',
            },
            'participants': [
              {
                'userId': 'user-1',
                'displayName': 'Артем',
              },
              {
                'userId': 'user-2',
                'displayName': 'Андрей',
              },
              {
                'userId': 'user-3',
                'displayName': 'Дарья',
              },
            ],
            'branchRoots': const [],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/chats/chat-group-1/participants/user-2' &&
          request.method == 'DELETE') {
        return http.Response(
          jsonEncode({
            'chat': {
              'id': 'chat-group-1',
              'type': 'group',
              'title': 'Совет семьи',
              'participantIds': ['user-1', 'user-3'],
              'treeId': 'tree-1',
            },
            'participants': [
              {
                'userId': 'user-1',
                'displayName': 'Артем',
              },
              {
                'userId': 'user-3',
                'displayName': 'Дарья',
              },
            ],
            'branchRoots': const [],
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
        'email': 'dev@rodnya.app',
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

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final details = await chatService.getChatDetails('chat-group-1');
    expect(details, isA<ChatDetails>());
    expect(details.memberCount, 2);
    expect(details.displayTitle, 'Семья Кузнецовых');

    final renamed = await chatService.renameGroupChat(
      chatId: 'chat-group-1',
      title: 'Совет семьи',
    );
    expect(renamed.displayTitle, 'Совет семьи');

    final expanded = await chatService.addGroupParticipants(
      chatId: 'chat-group-1',
      participantIds: const ['user-3'],
    );
    expect(expanded.memberCount, 3);

    final reduced = await chatService.removeGroupParticipant(
      chatId: 'chat-group-1',
      participantId: 'user-2',
    );
    expect(reduced.participantIds, ['user-1', 'user-3']);
  });

  test('CustomApiChatService reports attachment upload progress', () async {
    final uploadedUrls = <String>[];
    final uploadedAttachments = <Map<String, dynamic>>[];
    final uploadFolders = <String>[];
    final storageService = _FakeStorageService(
      onUpload: (index) => 'https://cdn.example.test/photo-$index.jpg',
      onUploadFolder: uploadFolders.add,
    );
    final progressEvents = <ChatSendProgress>[];

    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats/chat-1/messages' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        uploadedUrls.addAll(
          (body['mediaUrls'] as List<dynamic>).map((item) => item.toString()),
        );
        uploadedAttachments.addAll(
          (body['attachments'] as List<dynamic>)
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item)),
        );
        return http.Response(
          jsonEncode({'ok': true}),
          201,
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
        'email': 'dev@rodnya.app',
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

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
      storageService: storageService,
    );

    await chatService.sendMessageToChat(
      chatId: 'chat-1',
      attachments: [
        XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'one.jpg'),
        XFile.fromData(Uint8List.fromList([4, 5, 6]), name: 'two.jpg'),
      ],
      onProgress: progressEvents.add,
    );

    expect(uploadedUrls, [
      'https://cdn.example.test/photo-1.jpg',
      'https://cdn.example.test/photo-2.jpg',
    ]);
    expect(uploadFolders, [
      'chat-media/user-1',
      'chat-media/user-1',
    ]);
    expect(
      uploadedAttachments
          .map((attachment) => attachment['type']?.toString())
          .toList(),
      ['image', 'image'],
    );
    expect(
      uploadedAttachments
          .map((attachment) => attachment['fileName']?.toString())
          .toList(),
      ['photo-1.jpg', 'photo-2.jpg'],
    );
    expect(
      progressEvents.map((event) => event.stage).toList(),
      [
        ChatSendProgressStage.preparing,
        ChatSendProgressStage.uploading,
        ChatSendProgressStage.uploading,
        ChatSendProgressStage.uploading,
        ChatSendProgressStage.sending,
      ],
    );
    expect(progressEvents[1].completed, 0);
    expect(progressEvents[1].total, 2);
    expect(progressEvents[3].completed, 2);
    expect(progressEvents[3].total, 2);
  });

  test('CustomApiChatService uploads voice notes with waveform metadata',
      () async {
    final uploadedAttachments = <Map<String, dynamic>>[];
    final uploadFolders = <String>[];
    final storageService = _FakeStorageService(
      onUpload: (_) => 'https://cdn.example.test/voice-note.m4a',
      onUploadFolder: uploadFolders.add,
    );

    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats/chat-1/messages' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        uploadedAttachments.addAll(
          (body['attachments'] as List<dynamic>)
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item)),
        );
        return http.Response(
          jsonEncode({'ok': true}),
          201,
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
        'email': 'dev@rodnya.app',
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

    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
      storageService: storageService,
    );

    final voiceDirectory = await Directory.systemTemp.createTemp(
      'rodnya_voice_test_',
    );
    addTearDown(() async {
      if (await voiceDirectory.exists()) {
        await voiceDirectory.delete(recursive: true);
      }
    });
    final voiceFile = File('${voiceDirectory.path}/voice_note_3s_123.m4a');
    await voiceFile.writeAsBytes(
      Uint8List.fromList(List<int>.generate(256, (index) => index % 256)),
    );

    await chatService.sendMessageToChat(
      chatId: 'chat-1',
      attachments: [
        XFile(
          voiceFile.path,
          mimeType: 'audio/m4a',
        ),
      ],
    );

    expect(uploadFolders, ['chat-voice/user-1']);
    expect(uploadedAttachments, hasLength(1));
    final attachment = uploadedAttachments.single;
    expect(attachment['type'], 'audio');
    expect(attachment['presentation'], 'voice_note');
    expect(attachment['durationMs'], 3000);
    expect(attachment['waveform'], isA<List<dynamic>>());
    final waveform = attachment['waveform'] as List<dynamic>;
    expect(waveform, isNotEmpty);
    expect(waveform.length, lessThanOrEqualTo(100));
    expect(
      waveform.every((value) => value is num && value >= 0 && value <= 1),
      isTrue,
    );
  });

  test(
      'CustomApiChatService classifies a web voice note (audio/webm) as audio, '
      'not video', () async {
    // Regression: a web voice note is `voice_note_*.webm` with mime
    // `audio/webm`. `.webm` is also in the video extension list, so the
    // old extension-OR-mime check shipped it as an unplayable «video».
    final uploadedAttachments = <Map<String, dynamic>>[];
    final storageService = _FakeStorageService(
      onUpload: (_) => 'https://cdn.example.test/voice-note.webm',
    );
    final client = MockClient((request) async {
      if (request.url.path == '/v1/chats/chat-1/messages' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        uploadedAttachments.addAll(
          (body['attachments'] as List<dynamic>)
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item)),
        );
        return http.Response(
          jsonEncode({'ok': true}),
          201,
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
        'email': 'dev@rodnya.app',
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
    final chatService = CustomApiChatService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
      storageService: storageService,
    );

    final voiceDirectory = await Directory.systemTemp.createTemp(
      'rodnya_voice_webm_test_',
    );
    addTearDown(() async {
      if (await voiceDirectory.exists()) {
        await voiceDirectory.delete(recursive: true);
      }
    });
    final voiceFile = File('${voiceDirectory.path}/voice_note_2s_777.webm');
    await voiceFile.writeAsBytes(
      Uint8List.fromList(List<int>.generate(128, (index) => index % 256)),
    );

    await chatService.sendMessageToChat(
      chatId: 'chat-1',
      attachments: [
        XFile(voiceFile.path, mimeType: 'audio/webm'),
      ],
    );

    expect(uploadedAttachments, hasLength(1));
    expect(uploadedAttachments.single['type'], 'audio');
  });

  test(
    'CustomApiChatService clears stale session and returns safe defaults on 401 polling',
    () async {
      var logoutCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/v1/chats' && request.method == 'GET') {
          return http.Response(
            jsonEncode({'message': 'session expired'}),
            401,
            headers: {'content-type': 'application/json'},
          );
        }

        if (request.url.path == '/v1/chats/unread-count' &&
            request.method == 'GET') {
          return http.Response(
            jsonEncode({'message': 'session expired'}),
            401,
            headers: {'content-type': 'application/json'},
          );
        }

        if (request.url.path == '/v1/auth/logout' && request.method == 'POST') {
          logoutCalls += 1;
          return http.Response(
            jsonEncode({'ok': true}),
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
          'email': 'dev@rodnya.app',
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

      final chatService = CustomApiChatService(
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        httpClient: client,
        pollInterval: const Duration(milliseconds: 10),
      );

      final chats = await chatService.getUserChatsStream('user-1').first;
      expect(chats, isEmpty);

      final unreadCount =
          await chatService.getTotalUnreadCountStream('user-1').first;
      expect(unreadCount, 0);
      expect(authService.currentUserId, isNull);
      expect(logoutCalls, 0);
    },
  );

  test(
    'CustomApiChatService returns safe defaults immediately without active session',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final authService = await CustomApiAuthService.create(
        httpClient: MockClient((request) async {
          return http.Response('{"message":"not found"}', 404);
        }),
        preferences: prefs,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        invitationService: InvitationService(),
      );

      final chatService = CustomApiChatService(
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        httpClient: MockClient((request) async {
          return http.Response('{"message":"not found"}', 404);
        }),
      );

      expect(await chatService.getUserChatsStream('user-1').first, isEmpty);
      expect(await chatService.getTotalUnreadCountStream('user-1').first, 0);
      expect(
        await chatService.getMessagesStream('chat-1').first,
        const <ChatMessage>[],
      );
    },
  );

  test(
    'CustomApiChatService toggles message reactions and patches active stream',
    () async {
      final messages = <Map<String, dynamic>>[
        {
          'id': 'message-1',
          'chatId': 'chat-1',
          'senderId': 'user-2',
          'text': 'Можно лайкнуть',
          'timestamp': '2026-03-27T12:00:00.000Z',
          'isRead': false,
          'participants': ['user-1', 'user-2'],
          'senderName': 'Собеседник',
          'reactions': const [],
        },
      ];
      Map<String, dynamic>? sentReactionBody;

      final client = MockClient((request) async {
        if (request.url.path == '/v1/chats/chat-1/messages' &&
            request.method == 'GET') {
          return http.Response(
            jsonEncode({'messages': messages}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        if (request.url.path ==
                '/v1/chats/chat-1/messages/message-1/reactions' &&
            request.method == 'POST') {
          sentReactionBody = jsonDecode(request.body) as Map<String, dynamic>;
          final reactions = [
            {
              'emoji': '👍',
              'userIds': ['user-1'],
              'count': 1,
            },
          ];
          messages.first['reactions'] = reactions;
          return http.Response(
            jsonEncode({
              'messageId': 'message-1',
              'reactions': reactions,
              'added': true,
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
          'email': 'dev@rodnya.app',
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
      final chatService = CustomApiChatService(
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        httpClient: client,
      );

      final emissions = <List<ChatMessage>>[];
      final subscription =
          chatService.getMessagesStream('chat-1').listen(emissions.add);
      addTearDown(subscription.cancel);

      await _waitFor(() => emissions.isNotEmpty);
      expect(emissions.last.single.reactions, isEmpty);

      await chatService.toggleMessageReaction(
        chatId: 'chat-1',
        messageId: 'message-1',
        emoji: '👍',
      );

      await _waitFor(() => emissions.last.single.reactions.isNotEmpty);
      expect(sentReactionBody?['emoji'], '👍');
      expect(emissions.last.single.reactions.single.emoji, '👍');
      expect(emissions.last.single.reactions.single.userIds, ['user-1']);
    },
  );

  test(
    'CustomApiChatService applies realtime reaction updates to cached messages',
    () async {
      final realtimeController = StreamController<dynamic>.broadcast();
      final client = MockClient((request) async {
        if (request.url.path == '/v1/chats/chat-1/messages' &&
            request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'messages': [
                {
                  'id': 'message-1',
                  'chatId': 'chat-1',
                  'senderId': 'user-2',
                  'text': 'Realtime reaction',
                  'timestamp': '2026-03-27T12:00:00.000Z',
                  'isRead': false,
                  'participants': ['user-1', 'user-2'],
                  'senderName': 'Собеседник',
                  'reactions': const [],
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
          'email': 'dev@rodnya.app',
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
      final realtimeService = CustomApiRealtimeService(
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
          webSocketBaseUrl: 'wss://api.example.ru',
        ),
        channelFactory: (_) => _FakeWebSocketChannel(realtimeController.stream),
        reconnectDelay: const Duration(milliseconds: 10),
      );
      addTearDown(realtimeService.dispose);

      final chatService = CustomApiChatService(
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
          webSocketBaseUrl: 'wss://api.example.ru',
        ),
        httpClient: client,
        realtimeService: realtimeService,
      );

      final emissions = <List<ChatMessage>>[];
      final subscription =
          chatService.getMessagesStream('chat-1').listen(emissions.add);
      addTearDown(subscription.cancel);

      await _waitFor(() => emissions.isNotEmpty);
      realtimeController.add(
        jsonEncode({
          'type': 'message.reaction.changed',
          'chatId': 'chat-1',
          'messageId': 'message-1',
          'reactions': [
            {
              'emoji': '❤️',
              'userIds': ['user-2'],
              'count': 1,
            },
          ],
        }),
      );

      await _waitFor(() => emissions.last.single.reactions.isNotEmpty);
      expect(emissions.last.single.reactions.single.emoji, '❤️');
      expect(emissions.last.single.reactions.single.userIds, ['user-2']);
      await realtimeController.close();
    },
  );

  test(
    'CustomApiChatService applies realtime delivered and read receipts',
    () async {
      final realtimeController = StreamController<dynamic>.broadcast();
      final client = MockClient((request) async {
        if (request.url.path == '/v1/chats/chat-1/messages' &&
            request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'messages': [
                {
                  'id': 'message-1',
                  'chatId': 'chat-1',
                  'senderId': 'user-1',
                  'text': 'Receipt test',
                  'timestamp': '2026-03-27T12:00:00.000Z',
                  'isRead': false,
                  'participants': ['user-1', 'user-2'],
                  'senderName': 'Dev User',
                  'deliveredTo': ['user-1'],
                  'readBy': ['user-1'],
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
          'email': 'dev@rodnya.app',
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
      final realtimeService = CustomApiRealtimeService(
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
          webSocketBaseUrl: 'wss://api.example.ru',
        ),
        channelFactory: (_) => _FakeWebSocketChannel(realtimeController.stream),
        reconnectDelay: const Duration(milliseconds: 10),
      );
      addTearDown(realtimeService.dispose);

      final chatService = CustomApiChatService(
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
          webSocketBaseUrl: 'wss://api.example.ru',
        ),
        httpClient: client,
        realtimeService: realtimeService,
      );

      final emissions = <List<ChatMessage>>[];
      final subscription =
          chatService.getMessagesStream('chat-1').listen(emissions.add);
      addTearDown(subscription.cancel);

      await _waitFor(() => emissions.isNotEmpty);
      expect(emissions.last.single.deliveredTo, ['user-1']);
      expect(emissions.last.single.readBy, ['user-1']);

      realtimeController.add(
        jsonEncode({
          'type': 'message.delivered',
          'chatId': 'chat-1',
          'messageId': 'message-1',
          'userIds': ['user-2'],
          'deliveredTo': ['user-1', 'user-2'],
        }),
      );
      await _waitFor(
          () => emissions.last.single.deliveredTo.contains('user-2'));

      realtimeController.add(
        jsonEncode({
          'type': 'message.read',
          'chatId': 'chat-1',
          'userId': 'user-2',
          'messageIds': ['message-1'],
        }),
      );
      await _waitFor(() => emissions.last.single.readBy.contains('user-2'));
      expect(emissions.last.single.isRead, isTrue);
      await realtimeController.close();
    },
  );
}

Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 1),
}) async {
  final startedAt = DateTime.now();
  while (DateTime.now().difference(startedAt) < timeout) {
    if (predicate()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition was not met before timeout.');
}

class _FakeWebSocketChannel implements WebSocketChannel {
  _FakeWebSocketChannel(this._stream);

  final Stream<dynamic> _stream;
  final _FakeWebSocketSink _sink = _FakeWebSocketSink();

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _stream;

  @override
  _FakeWebSocketSink get sink => _sink;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWebSocketSink implements WebSocketSink {
  @override
  void add(event) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream stream) async {}

  @override
  Future close([int? closeCode, String? closeReason]) async {}

  @override
  Future get done async {}
}

class _MemoryChatMessageCache implements ChatMessageCache {
  _MemoryChatMessageCache([Map<String, List<ChatMessage>>? seed]) {
    for (final entry in (seed ?? const <String, List<ChatMessage>>{}).entries) {
      _messages[entry.key] = _trimmed(entry.value);
    }
  }

  final Map<String, List<ChatMessage>> _messages =
      <String, List<ChatMessage>>{};

  List<ChatMessage> snapshot(String chatId) {
    return List<ChatMessage>.unmodifiable(
      _messages[chatId] ?? const <ChatMessage>[],
    );
  }

  @override
  Future<List<ChatMessage>> read(String chatId) async {
    return snapshot(chatId);
  }

  @override
  Future<void> write(
    String chatId,
    List<ChatMessage> messages, {
    int keepCount = 200,
  }) async {
    _messages[chatId] = _trimmed(messages, keepCount: keepCount);
  }

  @override
  Future<void> mergePage(
    String chatId,
    List<ChatMessage> messages, {
    int keepCount = 200,
  }) async {
    await write(
      chatId,
      <ChatMessage>[
        ...snapshot(chatId),
        ...messages,
      ],
      keepCount: keepCount,
    );
  }

  @override
  Future<void> appendOne(
    String chatId,
    ChatMessage message, {
    int keepCount = 200,
  }) {
    return mergePage(chatId, <ChatMessage>[message], keepCount: keepCount);
  }

  @override
  Future<void> removeOne(String chatId, String messageId) async {
    await write(
      chatId,
      snapshot(chatId)
          .where((message) => message.id != messageId)
          .toList(growable: false),
    );
  }

  @override
  Future<void> evictOlder(String chatId, {int keepCount = 200}) {
    return write(chatId, snapshot(chatId), keepCount: keepCount);
  }

  @override
  Future<void> clearAll() async {
    _messages.clear();
  }

  List<ChatMessage> _trimmed(
    List<ChatMessage> messages, {
    int keepCount = 200,
  }) {
    final byId = <String, ChatMessage>{};
    for (final message in messages) {
      if (message.id.trim().isNotEmpty) {
        byId[message.id] = message;
      }
    }
    final sortedMessages = byId.values.toList();
    sortedMessages.sort(_sortMessagesDescending);
    if (keepCount <= 0 || sortedMessages.length <= keepCount) {
      return sortedMessages;
    }
    return sortedMessages.take(keepCount).toList(growable: false);
  }

  int _sortMessagesDescending(ChatMessage left, ChatMessage right) {
    final timestampCompare = right.timestamp.compareTo(left.timestamp);
    if (timestampCompare != 0) {
      return timestampCompare;
    }
    return right.id.compareTo(left.id);
  }
}

class _FakeStorageService implements StorageServiceInterface {
  _FakeStorageService({
    required this.onUpload,
    this.onUploadFolder,
  });

  final String Function(int index) onUpload;
  final void Function(String folder)? onUploadFolder;
  int _uploadCounter = 0;

  @override
  Future<String?> uploadImage(XFile imageFile, String folder) async {
    _uploadCounter += 1;
    onUploadFolder?.call(folder);
    return onUpload(_uploadCounter);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
