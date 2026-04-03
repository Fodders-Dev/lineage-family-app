import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/chat_service_interface.dart';
import '../backend/interfaces/storage_service_interface.dart';
import '../models/chat_message.dart';
import '../models/chat_preview.dart';
import 'custom_api_auth_service.dart';
import 'custom_api_realtime_service.dart';

class CustomApiChatService implements ChatServiceInterface {
  CustomApiChatService({
    required CustomApiAuthService authService,
    required BackendRuntimeConfig runtimeConfig,
    http.Client? httpClient,
    CustomApiRealtimeService? realtimeService,
    StorageServiceInterface? storageService,
    Duration? pollInterval,
  })  : _authService = authService,
        _runtimeConfig = runtimeConfig,
        _httpClient = httpClient ?? http.Client(),
        _realtimeService = realtimeService,
        _storageService = storageService,
        _pollInterval = pollInterval ?? const Duration(seconds: 3);

  final CustomApiAuthService _authService;
  final BackendRuntimeConfig _runtimeConfig;
  final http.Client _httpClient;
  final CustomApiRealtimeService? _realtimeService;
  final StorageServiceInterface? _storageService;
  final Duration _pollInterval;

  @override
  String? get currentUserId => _authService.currentUserId;

  @override
  String buildChatId(String otherUserId) {
    final userId = currentUserId;
    if (userId == null || userId.isEmpty) {
      throw const CustomApiException('Пользователь не авторизован');
    }

    final ids = <String>[userId, otherUserId]..sort();
    return ids.join('_');
  }

  @override
  Stream<List<ChatPreview>> getUserChatsStream(String userId) {
    return Stream<List<ChatPreview>>.multi((controller) {
      Timer? timer;
      StreamSubscription<CustomApiRealtimeEvent>? realtimeSubscription;
      var pollingEnabled = true;

      Future<void> emitChats() async {
        if (!pollingEnabled) {
          return;
        }
        if (!_hasActiveSession) {
          pollingEnabled = false;
          timer?.cancel();
          await realtimeSubscription?.cancel();
          controller.add(const <ChatPreview>[]);
          return;
        }
        try {
          controller.add(await _fetchChatPreviews());
        } on CustomApiException catch (error, stackTrace) {
          if (await _handleSessionError(error)) {
            pollingEnabled = false;
            timer?.cancel();
            await realtimeSubscription?.cancel();
            controller.add(const <ChatPreview>[]);
            return;
          }
          controller.addError(error, stackTrace);
        } catch (error, stackTrace) {
          if (await _handleSessionError(error)) {
            pollingEnabled = false;
            timer?.cancel();
            await realtimeSubscription?.cancel();
            controller.add(const <ChatPreview>[]);
            return;
          }
          controller.addError(error, stackTrace);
        }
      }

      unawaited(emitChats());
      timer = Timer.periodic(_pollInterval, (_) {
        unawaited(emitChats());
      });

      if (_realtimeService != null) {
        unawaited(_realtimeService!.connect());
        realtimeSubscription = _realtimeService!.events
            .where((event) => event.isChatEvent || event.isNotificationEvent)
            .listen((_) {
          unawaited(emitChats());
        });
      }

      controller.onCancel = () async {
        timer?.cancel();
        await realtimeSubscription?.cancel();
      };
    });
  }

  @override
  Stream<int> getTotalUnreadCountStream(String userId) {
    return Stream<int>.multi((controller) {
      Timer? timer;
      StreamSubscription<CustomApiRealtimeEvent>? realtimeSubscription;
      var pollingEnabled = true;

      Future<void> emitUnread() async {
        if (!pollingEnabled) {
          return;
        }
        if (!_hasActiveSession) {
          pollingEnabled = false;
          timer?.cancel();
          await realtimeSubscription?.cancel();
          controller.add(0);
          return;
        }
        try {
          controller.add(await _fetchTotalUnreadCount());
        } on CustomApiException catch (error, stackTrace) {
          if (await _handleSessionError(error)) {
            pollingEnabled = false;
            timer?.cancel();
            await realtimeSubscription?.cancel();
            controller.add(0);
            return;
          }
          controller.addError(error, stackTrace);
        } catch (error, stackTrace) {
          if (await _handleSessionError(error)) {
            pollingEnabled = false;
            timer?.cancel();
            await realtimeSubscription?.cancel();
            controller.add(0);
            return;
          }
          controller.addError(error, stackTrace);
        }
      }

      unawaited(emitUnread());
      timer = Timer.periodic(_pollInterval, (_) {
        unawaited(emitUnread());
      });

      if (_realtimeService != null) {
        unawaited(_realtimeService!.connect());
        realtimeSubscription = _realtimeService!.events
            .where((event) => event.isChatEvent || event.isNotificationEvent)
            .listen((_) {
          unawaited(emitUnread());
        });
      }

      controller.onCancel = () async {
        timer?.cancel();
        await realtimeSubscription?.cancel();
      };
    });
  }

  @override
  Stream<List<ChatMessage>> getMessagesStream(String chatId) {
    return Stream<List<ChatMessage>>.multi((controller) {
      Timer? timer;
      StreamSubscription<CustomApiRealtimeEvent>? realtimeSubscription;
      var pollingEnabled = true;

      Future<void> emitMessages() async {
        if (!pollingEnabled) {
          return;
        }
        if (!_hasActiveSession) {
          pollingEnabled = false;
          timer?.cancel();
          await realtimeSubscription?.cancel();
          controller.add(const <ChatMessage>[]);
          return;
        }
        try {
          controller.add(await _fetchMessages(chatId));
        } on CustomApiException catch (error, stackTrace) {
          if (await _handleSessionError(error)) {
            pollingEnabled = false;
            timer?.cancel();
            await realtimeSubscription?.cancel();
            controller.add(const <ChatMessage>[]);
            return;
          }
          controller.addError(error, stackTrace);
        } catch (error, stackTrace) {
          if (await _handleSessionError(error)) {
            pollingEnabled = false;
            timer?.cancel();
            await realtimeSubscription?.cancel();
            controller.add(const <ChatMessage>[]);
            return;
          }
          controller.addError(error, stackTrace);
        }
      }

      unawaited(emitMessages());
      timer = Timer.periodic(_pollInterval, (_) {
        unawaited(emitMessages());
      });

      if (_realtimeService != null) {
        unawaited(_realtimeService!.connect());
        realtimeSubscription = _realtimeService!.events.where((event) {
          if (event.type == 'chat.read.updated') {
            return event.chatId == chatId;
          }
          if (event.type == 'chat.message.created') {
            return event.chatId == chatId;
          }
          return false;
        }).listen((_) {
          unawaited(emitMessages());
        });
      }

      controller.onCancel = () async {
        timer?.cancel();
        await realtimeSubscription?.cancel();
      };
    });
  }

  @override
  Future<void> sendTextMessage({
    required String otherUserId,
    required String text,
  }) async {
    await sendMessage(otherUserId: otherUserId, text: text);
  }

  @override
  Future<void> sendMessage({
    required String otherUserId,
    String text = '',
    List<XFile> attachments = const <XFile>[],
  }) async {
    final chatId = await getOrCreateChat(otherUserId);
    if (chatId == null || chatId.isEmpty) {
      throw const CustomApiException('Не удалось определить чат');
    }

    await sendMessageToChat(
      chatId: chatId,
      text: text,
      attachments: attachments,
    );
  }

  @override
  Future<void> sendMessageToChat({
    required String chatId,
    String text = '',
    List<XFile> attachments = const <XFile>[],
  }) async {
    final trimmedText = text.trim();
    if (trimmedText.isEmpty && attachments.isEmpty) {
      throw const CustomApiException('Сообщение не должно быть пустым');
    }

    final mediaUrls = await _uploadAttachments(attachments);

    await _requestJson(
      method: 'POST',
      path: '/v1/chats/$chatId/messages',
      body: {
        'text': trimmedText,
        if (mediaUrls.isNotEmpty) 'mediaUrls': mediaUrls,
        if (mediaUrls.isNotEmpty) 'imageUrl': mediaUrls.first,
      },
    );
  }

  @override
  Future<void> markChatAsRead(String chatId, String userId) async {
    await _requestJson(
      method: 'POST',
      path: '/v1/chats/$chatId/read',
      body: const <String, dynamic>{},
    );
  }

  @override
  Future<String?> getOrCreateChat(String otherUserId) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/chats/direct',
      body: {
        'otherUserId': otherUserId,
      },
    );

    final chatId = response['chatId']?.toString();
    if (chatId == null || chatId.isEmpty) {
      throw const CustomApiException(
        'Backend не вернул идентификатор чата',
      );
    }
    return chatId;
  }

  @override
  Future<String?> createGroupChat({
    required List<String> participantIds,
    String? title,
    String? treeId,
  }) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/chats/groups',
      body: {
        'participantIds': participantIds,
        if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
        if (treeId != null && treeId.trim().isNotEmpty) 'treeId': treeId.trim(),
      },
    );

    final chatId = response['chatId']?.toString();
    if (chatId == null || chatId.isEmpty) {
      throw const CustomApiException(
        'Backend не вернул идентификатор группового чата',
      );
    }
    return chatId;
  }

  Future<List<ChatPreview>> _fetchChatPreviews() async {
    final response = await _requestJson(
      method: 'GET',
      path: '/v1/chats',
    );

    final rawChats = response['chats'];
    if (rawChats is! List<dynamic>) {
      return const <ChatPreview>[];
    }

    return rawChats.whereType<Map<String, dynamic>>().map((chat) {
      final timestamp =
          DateTime.tryParse(chat['lastMessageTime']?.toString() ?? '') ??
              DateTime.now();
      return ChatPreview.fromMap({
        'id': chat['id'],
        'chatId': chat['chatId'],
        'userId': chat['userId'],
        'type': chat['type'],
        'title': chat['title'],
        'photoUrl': chat['photoUrl'],
        'participantIds': chat['participantIds'],
        'otherUserId': chat['otherUserId'],
        'otherUserName': chat['otherUserName'],
        'otherUserPhotoUrl': chat['otherUserPhotoUrl'],
        'lastMessage': chat['lastMessage'],
        'lastMessageTime': Timestamp.fromDate(timestamp),
        'unreadCount': chat['unreadCount'],
        'lastMessageSenderId': chat['lastMessageSenderId'],
      });
    }).toList();
  }

  Future<int> _fetchTotalUnreadCount() async {
    final response = await _requestJson(
      method: 'GET',
      path: '/v1/chats/unread-count',
    );

    return (response['totalUnread'] as num?)?.toInt() ?? 0;
  }

  Future<List<ChatMessage>> _fetchMessages(String chatId) async {
    final response = await _requestJson(
      method: 'GET',
      path: '/v1/chats/$chatId/messages',
    );

    final rawMessages = response['messages'];
    if (rawMessages is! List<dynamic>) {
      return const <ChatMessage>[];
    }

    return rawMessages.whereType<Map<String, dynamic>>().map((message) {
      return ChatMessage.fromMap({
        'id': message['id'],
        'chatId': message['chatId'],
        'senderId': message['senderId'],
        'text': message['text'],
        'timestamp': message['timestamp'],
        'isRead': message['isRead'],
        'imageUrl': message['imageUrl'],
        'mediaUrls': message['mediaUrls'],
        'participants': message['participants'],
        'senderName': message['senderName'],
      });
    }).toList();
  }

  Future<List<String>> _uploadAttachments(List<XFile> attachments) async {
    if (attachments.isEmpty) {
      return const <String>[];
    }

    final storageService = _storageService ??
        (GetIt.I.isRegistered<StorageServiceInterface>()
            ? GetIt.I<StorageServiceInterface>()
            : null);
    final userId = currentUserId;
    if (storageService == null || userId == null || userId.isEmpty) {
      throw const CustomApiException('Не удалось подготовить вложения');
    }

    final mediaUrls = <String>[];
    for (final attachment in attachments) {
      final uploadedUrl = await storageService.uploadImage(
        attachment,
        'chat-images/$userId',
      );
      if (uploadedUrl != null && uploadedUrl.isNotEmpty) {
        mediaUrls.add(uploadedUrl);
      }
    }
    return mediaUrls;
  }

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) async {
    final uri = _buildUri(path);
    late http.Response response;

    switch (method) {
      case 'GET':
        response = await _httpClient.get(uri, headers: _headers());
        break;
      case 'POST':
        response = await _httpClient.post(
          uri,
          headers: _headers(),
          body: jsonEncode(body ?? const <String, dynamic>{}),
        );
        break;
      default:
        throw CustomApiException('Неподдерживаемый HTTP-метод: $method');
    }

    if (response.body.isEmpty) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return const <String, dynamic>{};
      }
      throw CustomApiException(
        'Пустой ответ от backend',
        statusCode: response.statusCode,
      );
    }

    final dynamic decoded = jsonDecode(response.body);
    final payload = decoded is Map<String, dynamic>
        ? decoded
        : <String, dynamic>{'data': decoded};

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return payload;
    }

    throw CustomApiException(
      payload['message']?.toString() ??
          payload['error']?.toString() ??
          'Ошибка backend (${response.statusCode})',
      statusCode: response.statusCode,
    );
  }

  Uri _buildUri(String path) {
    final normalizedBase = _runtimeConfig.apiBaseUrl.replaceAll(
      RegExp(r'/$'),
      '',
    );
    return Uri.parse('$normalizedBase$path');
  }

  Map<String, String> _headers() {
    final token = _authService.accessToken;
    if (token == null || token.isEmpty) {
      throw const CustomApiException('Нет активной customApi session');
    }

    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  bool get _hasActiveSession {
    final token = _authService.accessToken;
    final userId = _authService.currentUserId;
    return token != null &&
        token.isNotEmpty &&
        userId != null &&
        userId.isNotEmpty;
  }

  Future<bool> _handleSessionError(Object error) async {
    final isUnauthorized = error is CustomApiException &&
        (error.statusCode == 401 ||
            error.statusCode == 403 ||
            error.message.contains('Нет активной customApi session'));
    final normalized = error.toString().toLowerCase();
    final looksLikeExpiredSession = normalized.contains('сесс') ||
        normalized.contains('unauthorized') ||
        normalized.contains('expired');
    if (!isUnauthorized && !looksLikeExpiredSession) {
      return false;
    }

    if (_authService.currentUserId == null) {
      return true;
    }

    await _authService.signOut();
    return true;
  }
}
