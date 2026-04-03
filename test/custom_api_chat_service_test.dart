import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lineage/backend/backend_runtime_config.dart';
import 'package:lineage/models/chat_details.dart';
import 'package:lineage/models/chat_message.dart';
import 'package:lineage/models/chat_send_progress.dart';
import 'package:lineage/backend/interfaces/storage_service_interface.dart';
import 'package:lineage/services/custom_api_auth_service.dart';
import 'package:lineage/services/custom_api_chat_service.dart';
import 'package:lineage/services/custom_api_realtime_service.dart';
import 'package:lineage/services/invitation_service.dart';
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

  test(
    'CustomApiChatService clears stale session and returns safe defaults on 401 polling',
    () async {
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
