import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/chat_service_interface.dart';
import '../backend/interfaces/storage_service_interface.dart';
import '../models/chat_attachment.dart';
import '../models/chat_details.dart';
import '../models/chat_message.dart';
import '../models/chat_message_search_result.dart';
import '../models/chat_messages_page.dart';
import '../models/chat_preview.dart';
import '../models/chat_send_progress.dart';
import '../utils/voice_waveform.dart';
import 'app_status_service.dart';
import 'chat_draft_store.dart';
import 'chat_message_cache.dart';
import 'chat_preview_cache.dart';
import 'chat_pin_store.dart';
import 'hive_box_recovery.dart';
import 'custom_api_auth_service.dart';
import 'custom_api_realtime_service.dart';
import 'warm_http_client.dart';

class _ChatMessageStreamState {
  _ChatMessageStreamState(this.chatId);

  final String chatId;
  late final StreamController<List<ChatMessage>> controller;
  StreamSubscription<CustomApiRealtimeEvent>? realtimeSubscription;
  Timer? refreshDebounce;
  int listenerCount = 0;
  bool started = false;
  bool isFetching = false;
  bool hasQueuedRefresh = false;
  List<ChatMessage> messages = const <ChatMessage>[];
  int messagesVersion = 0;
}

class _UploadedAttachmentMetadata {
  const _UploadedAttachmentMetadata({
    this.durationMs,
    this.waveform = const <double>[],
    this.width,
    this.height,
  });

  final int? durationMs;
  final List<double> waveform;
  final int? width;
  final int? height;
}

class CustomApiChatService
    implements
        ChatServiceInterface,
        RemoteChatDraftClient,
        RemoteChatPinClient {
  CustomApiChatService({
    required CustomApiAuthService authService,
    required BackendRuntimeConfig runtimeConfig,
    http.Client? httpClient,
    CustomApiRealtimeService? realtimeService,
    StorageServiceInterface? storageService,
    ChatMessageCache? messageCache,
    ChatPreviewCache? previewCache,
    ChatPreviewOverrideCache? overrideCache,
    AppStatusService? appStatusService,
    Duration? pollInterval,
    Duration? overviewPollInterval,
    Duration? realtimeFallbackPollInterval,
  })  : _authService = authService,
        _runtimeConfig = runtimeConfig,
        // SPEED-4: горячий путь отправки — держим keep-alive тёплым 5 минут
        // (дефолтные 15с рвали соединение за время набора текста → свежий
        // TCP+TLS handshake на следующем сообщении).
        _httpClient = httpClient ?? createWarmHttpClient(),
        _realtimeService = realtimeService,
        _storageService = storageService,
        _messageCache = messageCache,
        _previewCache = previewCache,
        // Persist overrides whenever the app wired a (Hive) preview cache —
        // that's our reliable "Hive is available" signal. Tests that inject
        // neither stay fully in-memory; the cold-start test injects its own.
        _overrideCache = overrideCache ??
            (previewCache != null ? HiveChatPreviewOverrideCache() : null),
        _appStatusService = appStatusService,
        _pollInterval = pollInterval ?? const Duration(seconds: 3),
        _realtimeFallbackPollInterval = realtimeFallbackPollInterval ??
            overviewPollInterval ??
            const Duration(seconds: 30);

  final CustomApiAuthService _authService;
  final BackendRuntimeConfig _runtimeConfig;
  final http.Client _httpClient;
  final CustomApiRealtimeService? _realtimeService;
  final StorageServiceInterface? _storageService;
  final ChatMessageCache? _messageCache;
  final ChatPreviewCache? _previewCache;
  final AppStatusService? _appStatusService;
  final Duration _pollInterval;
  final Duration _realtimeFallbackPollInterval;

  /// Snapshot of the most recently emitted previews — keeps us from
  /// re-hydrating the cache on every realtime tick when nothing changed.
  List<ChatPreview>? _lastEmittedPreviews;
  StreamController<List<ChatPreview>>? _chatPreviewsController;
  Timer? _chatPreviewsFallbackTimer;
  Timer? _chatPreviewsRealtimeDebounce;
  StreamSubscription<CustomApiRealtimeEvent>? _chatPreviewsRealtimeSubscription;
  int _chatPreviewsListenerCount = 0;
  bool _chatPreviewsUpdatesActive = false;
  // Realtime-sourced overrides for chat-list previews, keyed by chatId. A
  // realtime chat.updated/chat.created carries the FULL mapped chat (with a
  // correct photoUrl/title), whereas GET /v1/chats can return a stale null
  // group photoUrl until the backend is restarted. We overlay these on top of
  // the fetch result so the fresh event value wins and survives a stale
  // refetch (which would otherwise blank the group avatar back out).
  final Map<String, ChatPreviewOverride> _realtimeChatPreviewOverrides =
      <String, ChatPreviewOverride>{};
  // Persistence for the override map (cold-start survival). Defaults to a Hive
  // box when a (Hive) preview cache is wired — i.e. in the real app — and to
  // null in tests that don't opt in. Hydrated once before the first emit.
  final ChatPreviewOverrideCache? _overrideCache;
  bool _overridesHydrated = false;
  static const int _maxPersistedOverrides = 200;

  StreamController<int>? _totalUnreadController;
  Timer? _totalUnreadFallbackTimer;
  Timer? _totalUnreadRealtimeDebounce;
  StreamSubscription<CustomApiRealtimeEvent>? _totalUnreadRealtimeSubscription;
  int _totalUnreadListenerCount = 0;
  bool _totalUnreadUpdatesActive = false;
  final Map<String, _ChatMessageStreamState> _messageStates =
      <String, _ChatMessageStreamState>{};

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
    final wasActive = _chatPreviewsUpdatesActive;
    _ensureChatPreviewsStream();
    if (wasActive) {
      scheduleMicrotask(() => unawaited(_emitChatPreviews()));
    }
    return _chatPreviewsController!.stream;
  }

  @override
  Stream<int> getTotalUnreadCountStream(String userId) {
    _ensureTotalUnreadStream();
    return _totalUnreadController!.stream;
  }

  @override
  Stream<List<ChatMessage>> getMessagesStream(String chatId) {
    return _ensureMessageStream(chatId).controller.stream;
  }

  Future<void> refreshChatOverview() async {
    if (_chatPreviewsUpdatesActive) {
      await _emitChatPreviews();
    }
    if (_totalUnreadUpdatesActive) {
      await _emitTotalUnread();
    }
  }

  Future<ChatMessagesPage> fetchMessagesPage(
    String chatId, {
    int limit = 50,
    String? beforeId,
    String? afterId,
  }) async {
    final normalizedBeforeId = beforeId?.trim();
    final normalizedAfterId = afterId?.trim();
    if ((normalizedBeforeId?.isNotEmpty ?? false) &&
        (normalizedAfterId?.isNotEmpty ?? false)) {
      throw const CustomApiException(
        'Нельзя запрашивать сообщения одновременно до и после курсора',
      );
    }

    final normalizedLimit = limit.clamp(1, 200).toInt();
    final response = await _requestJson(
      method: 'GET',
      path: '/v1/chats/$chatId/messages',
      queryParameters: <String, String>{
        'limit': '$normalizedLimit',
        if (normalizedBeforeId != null && normalizedBeforeId.isNotEmpty)
          'before': normalizedBeforeId,
        if (normalizedAfterId != null && normalizedAfterId.isNotEmpty)
          'after': normalizedAfterId,
      },
    );

    final rawMessages = response['messages'];
    final messages = rawMessages is List<dynamic>
        ? rawMessages
            .whereType<Map<String, dynamic>>()
            .map(_parseChatMessage)
            .toList()
        : const <ChatMessage>[];
    if (messages.isNotEmpty) {
      _cacheMessages(
        (cache) => cache.mergePage(chatId, messages),
      );
    }
    return ChatMessagesPage(
      messages: messages,
      hasMore: response['hasMore'] == true,
    );
  }

  @override
  Future<List<ChatMessageSearchResult>> searchMessages({
    required String query,
    String? chatId,
    int limit = 50,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      return const <ChatMessageSearchResult>[];
    }

    final response = await _requestJson(
      method: 'GET',
      path: '/v1/chats/search',
      queryParameters: <String, String>{
        'q': normalizedQuery,
        if (chatId != null && chatId.trim().isNotEmpty) 'chatId': chatId.trim(),
        'limit': limit.clamp(1, 100).toString(),
      },
    );
    final rawResults = response['results'];
    if (rawResults is! List<dynamic>) {
      return const <ChatMessageSearchResult>[];
    }
    return rawResults
        .whereType<Map>()
        .map((entry) => ChatMessageSearchResult.fromMap(
              Map<String, dynamic>.from(entry),
            ))
        .where(
            (result) => result.messageId.isNotEmpty && result.chatId.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<ChatDraftSnapshot?> getChatDraft(String chatId) async {
    final response = await _requestJson(
      method: 'GET',
      path: '/v1/chats/$chatId/draft',
    );
    final draft = response['draft'];
    if (draft is! Map<String, dynamic>) {
      return null;
    }
    final snapshot = ChatDraftSnapshot.fromJson(draft);
    return snapshot.text.trim().isEmpty ? null : snapshot;
  }

  @override
  Future<Map<String, ChatDraftSnapshot>> getChatDrafts() async {
    final response = await _requestJson(
      method: 'GET',
      path: '/v1/chats/drafts',
    );
    final rawDrafts = response['drafts'];
    if (rawDrafts is! List<dynamic>) {
      return const <String, ChatDraftSnapshot>{};
    }

    final drafts = <String, ChatDraftSnapshot>{};
    for (final entry in rawDrafts.whereType<Map>()) {
      final map = Map<String, dynamic>.from(entry);
      final chatId = (map['chatId']?.toString() ?? '').trim();
      if (chatId.isEmpty) {
        continue;
      }
      final snapshot = ChatDraftSnapshot.fromJson(map);
      if (snapshot.text.trim().isEmpty) {
        continue;
      }
      drafts[SharedPreferencesChatDraftStore.chatKey(chatId)] = snapshot;
    }
    return drafts;
  }

  @override
  Future<void> saveChatDraft({
    required String chatId,
    required String text,
  }) async {
    await _requestJson(
      method: 'PUT',
      path: '/v1/chats/$chatId/draft',
      body: <String, dynamic>{'text': text},
    );
  }

  @override
  Future<void> clearChatDraft(String chatId) async {
    await _requestJson(
      method: 'DELETE',
      path: '/v1/chats/$chatId/draft',
    );
  }

  @override
  Future<ChatPinnedMessageSnapshot?> getChatPinnedMessage(String chatId) async {
    final response = await _requestJson(
      method: 'GET',
      path: '/v1/chats/$chatId/pin',
    );
    return _parsePinnedMessageSnapshot(response['pin']);
  }

  @override
  Future<ChatPinnedMessageSnapshot?> pinChatMessage({
    required String chatId,
    required String messageId,
  }) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/chats/$chatId/messages/$messageId/pin',
    );
    return _parsePinnedMessageSnapshot(response['pin']);
  }

  @override
  Future<void> clearChatPinnedMessage(String chatId) async {
    await _requestJson(
      method: 'DELETE',
      path: '/v1/chats/$chatId/pin',
    );
  }

  @override
  Future<void> refreshMessages(String chatId) async {
    final state = _messageStates[chatId];
    if (state == null) {
      if (!_hasActiveSession) {
        return;
      }
      await _fetchMessages(chatId);
      return;
    }

    await _refreshMessageState(state);
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
    List<ChatAttachment> forwardedAttachments = const <ChatAttachment>[],
    ChatReplyReference? replyTo,
    String? clientMessageId,
    int? expiresInSeconds,
    void Function(ChatSendProgress progress)? onProgress,
  }) async {
    final trimmedText = text.trim();
    if (trimmedText.isEmpty &&
        attachments.isEmpty &&
        forwardedAttachments.isEmpty) {
      throw const CustomApiException('Сообщение не должно быть пустым');
    }

    final uploadedAttachments = await _uploadAttachments(
      attachments,
      onProgress: onProgress,
    );
    final allAttachments = <ChatAttachment>[
      ...forwardedAttachments
          .where((attachment) => attachment.url.trim().isNotEmpty),
      ...uploadedAttachments,
    ];

    onProgress?.call(
      const ChatSendProgress(
        stage: ChatSendProgressStage.sending,
        completed: 1,
        total: 1,
      ),
    );

    final response = await _requestJson(
      method: 'POST',
      path: '/v1/chats/$chatId/messages',
      body: {
        'text': trimmedText,
        if (allAttachments.isNotEmpty)
          'attachments':
              allAttachments.map((attachment) => attachment.toMap()).toList(),
        if (allAttachments.isNotEmpty)
          'mediaUrls':
              allAttachments.map((attachment) => attachment.url).toList(),
        if (allAttachments.isNotEmpty) 'imageUrl': allAttachments.first.url,
        if (replyTo != null && replyTo.messageId.isNotEmpty)
          'replyTo': replyTo.toMap(),
        if (clientMessageId != null && clientMessageId.trim().isNotEmpty)
          'clientMessageId': clientMessageId.trim(),
        if (expiresInSeconds != null && expiresInSeconds > 0)
          'expiresInSeconds': expiresInSeconds,
      },
    );
    final messageState = _messageStates[chatId];
    if (messageState != null) {
      final rawMessage = response['message'];
      if (rawMessage is Map<String, dynamic>) {
        _mergeRealtimeMessage(messageState, rawMessage);
      } else {
        _scheduleMessageRefresh(messageState, immediate: true);
      }
    }
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
  Future<void> editChatMessage({
    required String chatId,
    required String messageId,
    required String text,
  }) async {
    await _requestJson(
      method: 'PATCH',
      path: '/v1/chats/$chatId/messages/$messageId',
      body: {
        'text': text.trim(),
      },
    );
  }

  @override
  Future<void> deleteChatMessage({
    required String chatId,
    required String messageId,
  }) async {
    try {
      await _requestJson(
        method: 'DELETE',
        path: '/v1/chats/$chatId/messages/$messageId',
      );
    } on CustomApiException catch (error) {
      // 404 = the server no longer has this message (already deleted from
      // another device, a «delete for everyone» we missed, or expired). For a
      // delete, «already gone» IS success — swallow it and fall through to the
      // local prune below instead of leaving a stale copy stuck in the cache.
      if (error.statusCode != 404) {
        rethrow;
      }
    }
    // Prune locally right away rather than waiting for the realtime
    // `chat.message.deleted` echo: the echo never arrives on a 404, and can be
    // missed entirely when realtime is down — which is exactly how a deleted
    // message used to get stuck in the local cache forever.
    _pruneLocalMessage(chatId, messageId);
  }

  @override
  Future<void> toggleMessageReaction({
    required String chatId,
    required String messageId,
    required String emoji,
  }) async {
    final normalizedEmoji = emoji.trim();
    if (normalizedEmoji.isEmpty) {
      return;
    }

    final response = await _requestJson(
      method: 'POST',
      path: '/v1/chats/$chatId/messages/$messageId/reactions',
      body: <String, dynamic>{
        'emoji': normalizedEmoji,
      },
    );

    final state = _messageStates[chatId];
    final rawReactions = response['reactions'];
    if (state == null) {
      return;
    }
    if (rawReactions is List<dynamic>) {
      _applyReactionUpdate(state, messageId, rawReactions);
    } else {
      _scheduleMessageRefresh(state, immediate: true);
    }
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

  @override
  Future<String?> createBranchChat({
    required String treeId,
    required List<String> branchRootPersonIds,
    String? title,
  }) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/chats/branches',
      body: {
        'treeId': treeId.trim(),
        'branchRootPersonIds': branchRootPersonIds,
        if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
      },
    );

    final chatId = response['chatId']?.toString();
    if (chatId == null || chatId.isEmpty) {
      throw const CustomApiException(
        'Backend не вернул идентификатор чата ветки',
      );
    }
    return chatId;
  }

  @override
  Future<ChatDetails> getChatDetails(String chatId) async {
    final response = await _requestJson(
      method: 'GET',
      path: '/v1/chats/$chatId',
    );

    final rawChat = response['chat'];
    if (rawChat is! Map<String, dynamic>) {
      throw const CustomApiException('Не удалось загрузить данные чата');
    }

    return ChatDetails.fromMap({
      ...rawChat,
      'participants': response['participants'],
      'branchRoots': response['branchRoots'],
    });
  }

  @override
  Future<ChatDetails> renameGroupChat({
    required String chatId,
    required String title,
  }) async {
    final response = await _requestJson(
      method: 'PATCH',
      path: '/v1/chats/$chatId',
      body: {
        'title': title.trim(),
      },
    );

    final rawChat = response['chat'];
    if (rawChat is! Map<String, dynamic>) {
      throw const CustomApiException('Не удалось обновить название чата');
    }

    final details = ChatDetails.fromMap({
      ...rawChat,
      'participants': response['participants'],
      'branchRoots': response['branchRoots'],
    });
    unawaited(refreshChatOverview());
    return details;
  }

  @override
  Future<ChatDetails> updateGroupChatPhoto({
    required String chatId,
    required XFile photo,
  }) async {
    final storageService = _storageService;
    if (storageService == null) {
      throw const CustomApiException(
        'Загрузка изображения чата сейчас недоступна',
      );
    }

    final photoUrl = await storageService.uploadImage(photo, 'chat');
    if (photoUrl == null || photoUrl.trim().isEmpty) {
      throw const CustomApiException('Не удалось загрузить изображение чата');
    }

    final response = await _requestJson(
      method: 'PATCH',
      path: '/v1/chats/$chatId',
      body: {
        'photoUrl': photoUrl.trim(),
      },
    );

    final rawChat = response['chat'];
    if (rawChat is! Map<String, dynamic>) {
      throw const CustomApiException('Не удалось обновить изображение чата');
    }

    final details = ChatDetails.fromMap({
      ...rawChat,
      'participants': response['participants'],
      'branchRoots': response['branchRoots'],
    });
    unawaited(refreshChatOverview());
    return details;
  }

  @override
  Future<ChatDetails> addGroupParticipants({
    required String chatId,
    required List<String> participantIds,
  }) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/chats/$chatId/participants',
      body: {
        'participantIds': participantIds,
      },
    );

    final rawChat = response['chat'];
    if (rawChat is! Map<String, dynamic>) {
      throw const CustomApiException('Не удалось добавить участников');
    }

    final details = ChatDetails.fromMap({
      ...rawChat,
      'participants': response['participants'],
      'branchRoots': response['branchRoots'],
    });
    unawaited(refreshChatOverview());
    return details;
  }

  @override
  Future<ChatDetails> removeGroupParticipant({
    required String chatId,
    required String participantId,
  }) async {
    final response = await _requestJson(
      method: 'DELETE',
      path: '/v1/chats/$chatId/participants/$participantId',
    );

    final rawChat = response['chat'];
    if (rawChat is! Map<String, dynamic>) {
      throw const CustomApiException('Не удалось обновить состав чата');
    }

    final details = ChatDetails.fromMap({
      ...rawChat,
      'participants': response['participants'],
      'branchRoots': response['branchRoots'],
    });
    unawaited(refreshChatOverview());
    return details;
  }

  @override
  Future<void> leaveGroup(String chatId) async {
    // G2: участник убирает СЕБЯ — сервер берёт его из auth, тела/пути с id
    // не нужно. Ответ (обновлённый состав) игнорируем: вышедший к нему
    // уже не имеет доступа.
    await _requestJson(
      method: 'POST',
      path: '/v1/chats/$chatId/leave',
    );
    unawaited(refreshChatOverview());
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
        'lastMessageTime': timestamp,
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

  void _ensureChatPreviewsStream() {
    if (_chatPreviewsController != null) {
      return;
    }

    _chatPreviewsController = StreamController<List<ChatPreview>>.broadcast(
      onListen: () {
        _chatPreviewsListenerCount++;
        if (_chatPreviewsListenerCount == 1) {
          _startChatPreviewsUpdates();
        }
      },
      onCancel: () async {
        _chatPreviewsListenerCount--;
        if (_chatPreviewsListenerCount <= 0) {
          _chatPreviewsListenerCount = 0;
          await _stopChatPreviewsUpdates();
        }
      },
    );
  }

  void _startChatPreviewsUpdates() {
    if (_chatPreviewsUpdatesActive || _chatPreviewsController == null) {
      return;
    }

    _chatPreviewsUpdatesActive = true;
    // Stale-while-revalidate: hydrate from Hive synchronously so the list
    // appears immediately, then trigger the API refresh in the background.
    unawaited(_hydrateChatPreviewsFromCache());
    // Restore persisted realtime overrides BEFORE the first fetch+emit so the
    // group avatar survives a cold start (the stale /v1/chats would otherwise
    // re-blank it before any chat.updated arrives).
    unawaited(_bootstrapChatPreviewsWithOverrides());

    if (_realtimeService != null) {
      unawaited(_realtimeService!.connect());
      _chatPreviewsRealtimeSubscription =
          _realtimeService!.events.listen((event) {
        if (event.type == 'connection.ready') {
          _stopChatPreviewsFallbackPolling();
          _scheduleChatPreviewsRefresh(immediate: true);
          return;
        }
        if (event.type == 'connection.disconnected') {
          _startChatPreviewsFallbackPolling();
          return;
        }
        if (_shouldRefreshChatPreviewsForRealtimeEvent(event)) {
          // Patch the matching preview straight from the event's full chat
          // payload (photoUrl/title) so the group avatar appears immediately,
          // then schedule the (possibly stale) refetch — the override is
          // re-applied on top of it below so the fetch can't blank it out.
          final overriddenChatId = _captureChatPreviewOverride(event);
          if (overriddenChatId != null) {
            _patchEmittedChatPreviewsWithOverrides();
          }
          _scheduleChatPreviewsRefresh();
        }
      });
    } else {
      _startChatPreviewsFallbackPolling();
    }
  }

  /// Hydrate persisted overrides, THEN do the first fetch+emit — so the very
  /// first emitted list already carries any restored group avatar.
  Future<void> _bootstrapChatPreviewsWithOverrides() async {
    await _hydrateRealtimeOverrides();
    await _emitChatPreviews();
  }

  Future<void> _stopChatPreviewsUpdates() async {
    _chatPreviewsUpdatesActive = false;
    _stopChatPreviewsFallbackPolling();
    _chatPreviewsRealtimeDebounce?.cancel();
    _chatPreviewsRealtimeDebounce = null;
    await _chatPreviewsRealtimeSubscription?.cancel();
    _chatPreviewsRealtimeSubscription = null;
  }

  void _startChatPreviewsFallbackPolling() {
    if (!_chatPreviewsUpdatesActive ||
        _chatPreviewsController == null ||
        _chatPreviewsFallbackTimer != null) {
      return;
    }

    _chatPreviewsFallbackTimer = Timer.periodic(
      _realtimeFallbackPollInterval,
      (_) => unawaited(_emitChatPreviews()),
    );
  }

  void _stopChatPreviewsFallbackPolling() {
    _chatPreviewsFallbackTimer?.cancel();
    _chatPreviewsFallbackTimer = null;
  }

  Future<void> _emitChatPreviews() async {
    final controller = _chatPreviewsController;
    if (!_chatPreviewsUpdatesActive ||
        controller == null ||
        controller.isClosed) {
      return;
    }

    if (!_hasActiveSession) {
      await _stopChatPreviewsUpdates();
      if (!controller.isClosed) {
        controller.add(const <ChatPreview>[]);
      }
      return;
    }

    try {
      final previews = await _fetchChatPreviews();
      // Overlay realtime overrides AFTER the fetch so a fresh chat.updated
      // photoUrl/title beats a stale null from GET /v1/chats.
      final overridden = _applyRealtimeChatPreviewOverrides(previews);
      _lastEmittedPreviews = overridden;
      // Persist to cache so the next cold start can show the list before
      // the network round-trip finishes. Cache the overridden version so the
      // group photo survives a restart (the override map is in-memory).
      // Failures are non-fatal — caching is a UX optimization, not truth.
      unawaited(_writeChatPreviewsCache(overridden));
      controller.add(overridden);
    } on CustomApiException catch (error, stackTrace) {
      if (await _handleSessionError(error)) {
        await _stopChatPreviewsUpdates();
        if (!controller.isClosed) {
          controller.add(const <ChatPreview>[]);
        }
        return;
      }
      _appStatusService?.reportError(
        error,
        fallbackMessage: 'Не удалось обновить список чатов.',
      );
      controller.addError(error, stackTrace);
    } catch (error, stackTrace) {
      if (await _handleSessionError(error)) {
        await _stopChatPreviewsUpdates();
        if (!controller.isClosed) {
          controller.add(const <ChatPreview>[]);
        }
        return;
      }
      _appStatusService?.reportError(
        error,
        fallbackMessage: 'Не удалось обновить список чатов.',
      );
      controller.addError(error, stackTrace);
    }
  }

  Future<void> _hydrateChatPreviewsFromCache() async {
    final cache = _previewCache;
    if (cache == null) return;
    try {
      final cached = await cache.read();
      if (cached.isEmpty) return;
      final controller = _chatPreviewsController;
      if (controller == null || controller.isClosed) return;
      // Only emit cached data if we haven't already produced a fresher
      // result during the cache read — race avoidance.
      if (_lastEmittedPreviews != null) return;
      _lastEmittedPreviews = cached;
      controller.add(cached);
    } catch (_) {
      // Cache corruption is non-fatal; let the API refresh repopulate.
    }
  }

  Future<void> _writeChatPreviewsCache(List<ChatPreview> previews) async {
    final cache = _previewCache;
    if (cache == null) return;
    try {
      await cache.write(previews);
    } catch (_) {
      // Best-effort — never fail the foreground stream because of cache.
    }
  }

  bool _shouldRefreshChatPreviewsForRealtimeEvent(
    CustomApiRealtimeEvent event,
  ) {
    return event.type == 'chat.created' ||
        event.type == 'chat.updated' ||
        event.type == 'chat.message.created' ||
        event.type == 'chat.message.updated' ||
        event.type == 'chat.message.deleted';
  }

  void _scheduleChatPreviewsRefresh({bool immediate = false}) {
    _chatPreviewsRealtimeDebounce?.cancel();
    if (immediate) {
      unawaited(_emitChatPreviews());
      return;
    }

    _chatPreviewsRealtimeDebounce = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_emitChatPreviews()),
    );
  }

  /// Records the photoUrl/title from a realtime chat.updated/chat.created event
  /// (which carries the full mapped chat) so a later stale /v1/chats refetch
  /// can't blank the group photo back out. Returns the affected chatId, or
  /// null when the event carried no usable chat payload. The latest event
  /// always wins; a null/empty field falls through to the fetched value.
  String? _captureChatPreviewOverride(CustomApiRealtimeEvent event) {
    final chat = event.chat;
    if (chat == null) {
      return null;
    }
    final chatId = chat['chatId']?.toString() ?? chat['id']?.toString() ?? '';
    if (chatId.isEmpty) {
      return null;
    }
    final photoUrl = chat['photoUrl']?.toString();
    final title = chat['title']?.toString();
    final type = chat['type']?.toString();
    _realtimeChatPreviewOverrides[chatId] = ChatPreviewOverride(
      photoUrl: (photoUrl != null && photoUrl.isNotEmpty) ? photoUrl : null,
      title: (title != null && title.isNotEmpty) ? title : null,
      type: type,
    );
    // Write-through to Hive so the avatar survives a cold start.
    unawaited(_persistRealtimeOverrides());
    return chatId;
  }

  /// Persists the subset of overrides worth surviving a restart: GROUP chats
  /// with a real photoUrl (exactly the disappearing-group-avatar case). Capped
  /// to [_maxPersistedOverrides] most-recent entries to bound the box size.
  Future<void> _persistRealtimeOverrides() async {
    final cache = _overrideCache;
    if (cache == null) {
      return;
    }
    final persistable = <String, ChatPreviewOverride>{};
    _realtimeChatPreviewOverrides.forEach((chatId, override) {
      if (override.isGroup &&
          override.photoUrl != null &&
          override.photoUrl!.isNotEmpty) {
        persistable[chatId] = override;
      }
    });
    final capped = persistable.length <= _maxPersistedOverrides
        ? persistable
        : Map<String, ChatPreviewOverride>.fromEntries(
            persistable.entries.toList().sublist(
                  persistable.length - _maxPersistedOverrides,
                ),
          );
    await cache.write(capped);
  }

  /// Hydrates the in-memory override map from the persistent cache once, before
  /// the first preview emit, so a stale /v1/chats refetch on cold start can't
  /// blank a restored group avatar. Idempotent; live captures win over cache.
  Future<void> _hydrateRealtimeOverrides() async {
    if (_overridesHydrated) {
      return;
    }
    _overridesHydrated = true;
    final cache = _overrideCache;
    if (cache == null) {
      return;
    }
    try {
      final stored = await cache.read();
      stored.forEach((chatId, override) {
        // A live chat.updated captured during hydration is fresher — keep it.
        _realtimeChatPreviewOverrides.putIfAbsent(chatId, () => override);
      });
    } catch (_) {
      // Best-effort — a missing/corrupt box just means no restore this boot.
    }
  }

  /// Overlays the realtime overrides on top of a preview list. A new list is
  /// returned only if something actually changed (so callers can skip a
  /// spurious emit); each unchanged preview keeps its identity.
  List<ChatPreview> _applyRealtimeChatPreviewOverrides(
    List<ChatPreview> previews,
  ) {
    if (_realtimeChatPreviewOverrides.isEmpty) {
      return previews;
    }
    var changed = false;
    final result = previews.map((preview) {
      final override = _realtimeChatPreviewOverrides[preview.chatId];
      if (override == null) {
        return preview;
      }
      final nextPhotoUrl = override.photoUrl ?? preview.photoUrl;
      final nextTitle = override.title ?? preview.title;
      if (nextPhotoUrl == preview.photoUrl && nextTitle == preview.title) {
        return preview;
      }
      changed = true;
      return ChatPreview(
        id: preview.id,
        chatId: preview.chatId,
        userId: preview.userId,
        type: preview.type,
        title: nextTitle,
        photoUrl: nextPhotoUrl,
        participantIds: preview.participantIds,
        otherUserId: preview.otherUserId,
        otherUserName: preview.otherUserName,
        otherUserPhotoUrl: preview.otherUserPhotoUrl,
        lastMessage: preview.lastMessage,
        lastMessageTime: preview.lastMessageTime,
        unreadCount: preview.unreadCount,
        lastMessageSenderId: preview.lastMessageSenderId,
      );
    }).toList();
    return changed ? result : previews;
  }

  /// Re-applies overrides to the currently-emitted previews and pushes the
  /// patched list immediately, so the group avatar updates the moment the
  /// realtime event arrives — without waiting for the debounced refetch.
  void _patchEmittedChatPreviewsWithOverrides() {
    final controller = _chatPreviewsController;
    final current = _lastEmittedPreviews;
    if (controller == null || controller.isClosed || current == null) {
      return;
    }
    final patched = _applyRealtimeChatPreviewOverrides(current);
    if (identical(patched, current)) {
      return;
    }
    _lastEmittedPreviews = patched;
    controller.add(patched);
    unawaited(_writeChatPreviewsCache(patched));
  }

  void _ensureTotalUnreadStream() {
    if (_totalUnreadController != null) {
      return;
    }

    _totalUnreadController = StreamController<int>.broadcast(
      onListen: () {
        _totalUnreadListenerCount++;
        if (_totalUnreadListenerCount == 1) {
          _startTotalUnreadUpdates();
        }
      },
      onCancel: () async {
        _totalUnreadListenerCount--;
        if (_totalUnreadListenerCount <= 0) {
          _totalUnreadListenerCount = 0;
          await _stopTotalUnreadUpdates();
        }
      },
    );
  }

  void _startTotalUnreadUpdates() {
    if (_totalUnreadUpdatesActive || _totalUnreadController == null) {
      return;
    }

    _totalUnreadUpdatesActive = true;
    unawaited(_emitTotalUnread());

    if (_realtimeService != null) {
      unawaited(_realtimeService!.connect());
      _totalUnreadRealtimeSubscription =
          _realtimeService!.events.listen((event) {
        if (event.type == 'connection.ready') {
          _stopTotalUnreadFallbackPolling();
          _scheduleTotalUnreadRefresh(immediate: true);
          return;
        }
        if (event.type == 'connection.disconnected') {
          _startTotalUnreadFallbackPolling();
          return;
        }
        if (_applyTotalUnreadRealtimeEvent(event)) {
          return;
        }
        if (_shouldRefreshTotalUnreadForRealtimeEvent(event)) {
          _scheduleTotalUnreadRefresh();
        }
      });
    } else {
      _startTotalUnreadFallbackPolling();
    }
  }

  Future<void> _stopTotalUnreadUpdates() async {
    _totalUnreadUpdatesActive = false;
    _stopTotalUnreadFallbackPolling();
    _totalUnreadRealtimeDebounce?.cancel();
    _totalUnreadRealtimeDebounce = null;
    await _totalUnreadRealtimeSubscription?.cancel();
    _totalUnreadRealtimeSubscription = null;
  }

  void _startTotalUnreadFallbackPolling() {
    if (!_totalUnreadUpdatesActive ||
        _totalUnreadController == null ||
        _totalUnreadFallbackTimer != null) {
      return;
    }

    _totalUnreadFallbackTimer = Timer.periodic(
      _realtimeFallbackPollInterval,
      (_) => unawaited(_emitTotalUnread()),
    );
  }

  void _stopTotalUnreadFallbackPolling() {
    _totalUnreadFallbackTimer?.cancel();
    _totalUnreadFallbackTimer = null;
  }

  Future<void> _emitTotalUnread() async {
    final controller = _totalUnreadController;
    if (!_totalUnreadUpdatesActive ||
        controller == null ||
        controller.isClosed) {
      return;
    }

    if (!_hasActiveSession) {
      await _stopTotalUnreadUpdates();
      if (!controller.isClosed) {
        controller.add(0);
      }
      return;
    }

    try {
      controller.add(await _fetchTotalUnreadCount());
    } on CustomApiException catch (error, stackTrace) {
      if (await _handleSessionError(error)) {
        await _stopTotalUnreadUpdates();
        if (!controller.isClosed) {
          controller.add(0);
        }
        return;
      }
      _appStatusService?.reportError(
        error,
        fallbackMessage: 'Не удалось обновить счётчик непрочитанных.',
      );
      controller.addError(error, stackTrace);
    } catch (error, stackTrace) {
      if (await _handleSessionError(error)) {
        await _stopTotalUnreadUpdates();
        if (!controller.isClosed) {
          controller.add(0);
        }
        return;
      }
      _appStatusService?.reportError(
        error,
        fallbackMessage: 'Не удалось обновить счётчик непрочитанных.',
      );
      controller.addError(error, stackTrace);
    }
  }

  void _scheduleTotalUnreadRefresh({bool immediate = false}) {
    _totalUnreadRealtimeDebounce?.cancel();
    if (immediate) {
      unawaited(_emitTotalUnread());
      return;
    }

    _totalUnreadRealtimeDebounce = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_emitTotalUnread()),
    );
  }

  bool _applyTotalUnreadRealtimeEvent(CustomApiRealtimeEvent event) {
    if (event.type != 'chat.unread.changed') {
      return false;
    }

    final totalUnread = int.tryParse(
      event.payload['totalUnread']?.toString() ?? '',
    );
    final controller = _totalUnreadController;
    if (totalUnread == null || controller == null || controller.isClosed) {
      return false;
    }

    _totalUnreadRealtimeDebounce?.cancel();
    controller.add(totalUnread);
    return true;
  }

  bool _shouldRefreshTotalUnreadForRealtimeEvent(
    CustomApiRealtimeEvent event,
  ) {
    return event.type == 'chat.message.created' ||
        event.type == 'chat.message.deleted' ||
        event.type == 'chat.read.updated' ||
        event.type == 'notification.created';
  }

  _ChatMessageStreamState _ensureMessageStream(String chatId) {
    final existingState = _messageStates[chatId];
    if (existingState != null) {
      return existingState;
    }

    final state = _ChatMessageStreamState(chatId);
    state.controller = StreamController<List<ChatMessage>>.broadcast(
      onListen: () {
        state.listenerCount += 1;
        if (state.listenerCount == 1) {
          _startMessageState(state);
        } else if (state.messages.isNotEmpty) {
          state.controller.add(List<ChatMessage>.unmodifiable(state.messages));
        }
      },
      onCancel: () async {
        state.listenerCount -= 1;
        if (state.listenerCount <= 0) {
          state.listenerCount = 0;
          await _disposeMessageState(chatId);
        }
      },
    );
    _messageStates[chatId] = state;
    return state;
  }

  void _startMessageState(_ChatMessageStreamState state) {
    if (state.started) {
      return;
    }

    state.started = true;
    if (!_hasActiveSession) {
      state.messages = const <ChatMessage>[];
      state.controller.add(const <ChatMessage>[]);
      return;
    }

    unawaited(_hydrateMessageState(state));

    if (_realtimeService != null) {
      unawaited(_realtimeService!.connect());
      state.realtimeSubscription = _realtimeService!.events.listen((event) {
        if (event.type == 'connection.ready') {
          _scheduleMessageRefresh(state, immediate: true);
          return;
        }

        if (event.chatId != state.chatId) {
          return;
        }

        switch (event.type) {
          case 'chat.message.created':
          case 'chat.message.updated':
            final payload = event.message;
            if (payload == null) {
              _scheduleMessageRefresh(state);
              return;
            }
            _mergeRealtimeMessage(state, payload);
            return;
          case 'chat.message.deleted':
            final messageId = event.payload['messageId']?.toString();
            if (messageId == null || messageId.isEmpty) {
              _scheduleMessageRefresh(state);
              return;
            }
            _removeRealtimeMessage(state, messageId);
            return;
          case 'message.reaction.changed':
            final messageId = event.payload['messageId']?.toString();
            final rawReactions = event.payload['reactions'];
            if (messageId == null ||
                messageId.isEmpty ||
                rawReactions is! List<dynamic>) {
              _scheduleMessageRefresh(state);
              return;
            }
            _applyReactionUpdate(state, messageId, rawReactions);
            return;
          case 'message.delivered':
            final messageId = event.payload['messageId']?.toString();
            final userIds = _stringListFromDynamic(event.payload['userIds']);
            final deliveredTo =
                _stringListFromDynamic(event.payload['deliveredTo']);
            if (messageId == null || messageId.isEmpty) {
              _scheduleMessageRefresh(state);
              return;
            }
            _applyDeliveryUpdate(
              state,
              messageId: messageId,
              userIds: deliveredTo.isNotEmpty ? deliveredTo : userIds,
            );
            return;
          case 'message.read':
            final readerUserId = event.userId;
            if (readerUserId == null || readerUserId.isEmpty) {
              _scheduleMessageRefresh(state);
              return;
            }
            _applyReadUpdate(
              state,
              readerUserId,
              messageIds: _stringListFromDynamic(event.payload['messageIds']),
            );
            return;
          case 'chat.read.updated':
            final readerUserId = event.userId;
            if (readerUserId == null || readerUserId.isEmpty) {
              _scheduleMessageRefresh(state);
              return;
            }
            _applyReadUpdate(state, readerUserId);
            return;
          default:
            return;
        }
      });
    }
  }

  Future<void> _disposeMessageState(String chatId) async {
    final state = _messageStates.remove(chatId);
    if (state == null) {
      return;
    }

    state.refreshDebounce?.cancel();
    // Flush any pending debounced cache write so the next cold read sees
    // the freshest known state — then cancel the timer.
    final pendingFlush = _dirtyMessageCacheFlushTimers.remove(chatId);
    if (pendingFlush != null) {
      pendingFlush.cancel();
      final snapshot = List<ChatMessage>.unmodifiable(state.messages);
      _cacheMessages((cache) => cache.write(chatId, snapshot));
    }
    await state.realtimeSubscription?.cancel();
    await state.controller.close();
  }

  void _scheduleMessageRefresh(
    _ChatMessageStreamState state, {
    bool immediate = false,
  }) {
    state.refreshDebounce?.cancel();
    if (immediate) {
      unawaited(_refreshMessageState(state));
      return;
    }

    final debounceMs = _pollInterval.inMilliseconds.clamp(150, 1000);
    state.refreshDebounce = Timer(
      Duration(milliseconds: debounceMs),
      () => unawaited(_refreshMessageState(state)),
    );
  }

  Future<void> _hydrateMessageState(_ChatMessageStreamState state) async {
    if (_messageCache == null) {
      await _refreshMessageState(state);
      return;
    }

    var cachedMessages = const <ChatMessage>[];
    try {
      cachedMessages = await _messageCache!.read(state.chatId);
    } catch (_) {
      cachedMessages = const <ChatMessage>[];
    }

    if (cachedMessages.isNotEmpty) {
      // Show the cached window instantly (no flash-of-empty), then re-sync it
      // against the server. This is a full newest-window fetch — NOT an
      // after-cursor delta — so it can RECONCILE deletions that happened while
      // this device was away. A delta fetch only ever adds, so a message
      // deleted elsewhere would otherwise stay cached forever.
      state.messages = cachedMessages;
      if (!state.controller.isClosed) {
        state.controller.add(List<ChatMessage>.unmodifiable(cachedMessages));
      }
    }

    await _refreshMessageState(state);
  }

  Future<void> _refreshMessageState(_ChatMessageStreamState state) async {
    if (state.isFetching) {
      state.hasQueuedRefresh = true;
      return;
    }

    if (!_hasActiveSession) {
      state.messages = const <ChatMessage>[];
      if (!state.controller.isClosed) {
        state.controller.add(const <ChatMessage>[]);
      }
      return;
    }

    state.isFetching = true;
    final versionAtRequestStart = state.messagesVersion;
    try {
      // Fetch the authoritative newest window (keepCount-wide) so a single
      // round-trip re-syncs the whole cached window — including reconciling
      // deletions we may have missed.
      final page = await fetchMessagesPage(state.chatId, limit: 200);
      final pageMessages = page.messages;
      // NEVER destructively replace the local list with a server page. This
      // refresh fires on every websocket reconnect / app resume / chat reopen.
      // A blind `= pageMessages` caused data loss two ways: (1) truncation — a
      // chat with more messages than the page limit was cut to the newest
      // page (there is no scroll-up pagination); (2) empty-wipe — a transient
      // empty page (backend listChatMessages returns [] mid group/branch
      // mutation) erased everything. So always MERGE (union by id).
      //
      // On the CLEAN path (nothing landed locally while this fetch was in
      // flight) we then reconcile server-side deletions the realtime
      // `chat.message.deleted` event may have missed (offline, another device,
      // cold start): a message absent from the page yet strictly inside the
      // fetched window is a genuine deletion and is pruned. Truncation and
      // empty/short-page glitches never drop a message because only interior
      // holes are pruned. On the DIRTY path (a realtime/send update bumped the
      // version mid-fetch) we skip reconciliation and preserve the local state
      // so a just-arrived message the stale page can't know about survives.
      if (state.messagesVersion == versionAtRequestStart) {
        state.messages = _reconcileWithServerPage(
          _mergeMessageLists(state.messages, pageMessages),
          pageMessages,
        );
      } else {
        state.messages = _mergeMessageListsPreservingExisting(
          state.messages,
          pageMessages,
        );
      }
      state.messagesVersion++;
      _cacheMessages(
        (cache) => cache.write(state.chatId, state.messages),
      );
      if (!state.controller.isClosed) {
        state.controller.add(List<ChatMessage>.unmodifiable(state.messages));
      }
    } on CustomApiException catch (error, stackTrace) {
      if (await _handleSessionError(error)) {
        state.messages = const <ChatMessage>[];
        if (!state.controller.isClosed) {
          state.controller.add(const <ChatMessage>[]);
        }
      } else {
        _appStatusService?.reportError(
          error,
          fallbackMessage: 'Не удалось обновить сообщения.',
        );
        if (!state.controller.isClosed) {
          state.controller.addError(error, stackTrace);
        }
      }
    } catch (error, stackTrace) {
      if (await _handleSessionError(error)) {
        state.messages = const <ChatMessage>[];
        if (!state.controller.isClosed) {
          state.controller.add(const <ChatMessage>[]);
        }
      } else {
        _appStatusService?.reportError(
          error,
          fallbackMessage: 'Не удалось обновить сообщения.',
        );
        if (!state.controller.isClosed) {
          state.controller.addError(error, stackTrace);
        }
      }
    } finally {
      state.isFetching = false;
      if (state.hasQueuedRefresh) {
        state.hasQueuedRefresh = false;
        unawaited(_refreshMessageState(state));
      }
    }
  }

  void _mergeRealtimeMessage(
    _ChatMessageStreamState state,
    Map<String, dynamic> rawMessage,
  ) {
    final incomingMessage = _parseChatMessage(rawMessage);
    final existingIndex = state.messages.indexWhere(
      (message) => message.id == incomingMessage.id,
    );

    final nextMessages = List<ChatMessage>.from(state.messages);
    if (existingIndex == -1) {
      nextMessages.add(incomingMessage);
    } else {
      nextMessages[existingIndex] = incomingMessage;
    }
    nextMessages.sort(_sortMessagesDescending);
    state.messages = nextMessages;
    state.messagesVersion++;
    _cacheMessages(
      (cache) => cache.appendOne(state.chatId, incomingMessage),
    );
    if (!state.controller.isClosed) {
      state.controller.add(List<ChatMessage>.unmodifiable(nextMessages));
    }
  }

  void _removeRealtimeMessage(
    _ChatMessageStreamState state,
    String messageId,
  ) {
    final nextMessages = state.messages
        .where((message) => message.id != messageId)
        .toList(growable: false);
    state.messages = nextMessages;
    state.messagesVersion++;
    _cacheMessages(
      (cache) => cache.removeOne(state.chatId, messageId),
    );
    if (!state.controller.isClosed) {
      state.controller.add(List<ChatMessage>.unmodifiable(nextMessages));
    }
  }

  /// Removes a message from the in-memory stream (when the chat is open) and
  /// from the Hive cache. Idempotent — safe to call when the message is
  /// already gone. Used by [deleteChatMessage] so a locally-initiated delete
  /// (including the «already gone» 404 case) prunes the cache without relying
  /// on the realtime echo.
  void _pruneLocalMessage(String chatId, String messageId) {
    final normalizedMessageId = messageId.trim();
    if (normalizedMessageId.isEmpty) {
      return;
    }
    final state = _messageStates[chatId];
    if (state != null) {
      _removeRealtimeMessage(state, normalizedMessageId);
    } else {
      _cacheMessages(
        (cache) => cache.removeOne(chatId, normalizedMessageId),
      );
    }
  }

  void _applyReactionUpdate(
    _ChatMessageStreamState state,
    String messageId,
    List<dynamic> rawReactions,
  ) {
    final messageIndex = state.messages.indexWhere(
      (message) => message.id == messageId,
    );
    if (messageIndex < 0) {
      _scheduleMessageRefresh(state);
      return;
    }

    final nextMessages = List<ChatMessage>.from(state.messages);
    final nextMessage = nextMessages[messageIndex].copyWith(
      reactions: ChatMessageReactionSummary.listFromDynamic(rawReactions),
    );
    nextMessages[messageIndex] = nextMessage;
    state.messages = nextMessages;
    state.messagesVersion++;
    // Reactions arrive in bursts — debounce the Hive write instead of
    // flushing on every event.
    _scheduleDebouncedMessageCacheFlush(state);
    if (!state.controller.isClosed) {
      state.controller.add(List<ChatMessage>.unmodifiable(nextMessages));
    }
  }

  void _applyDeliveryUpdate(
    _ChatMessageStreamState state, {
    required String messageId,
    required List<String> userIds,
  }) {
    if (userIds.isEmpty) {
      return;
    }

    final messageIndex = state.messages.indexWhere(
      (message) => message.id == messageId,
    );
    if (messageIndex < 0) {
      _scheduleMessageRefresh(state);
      return;
    }

    final nextMessages = List<ChatMessage>.from(state.messages);
    final message = nextMessages[messageIndex];
    final deliveredTo = <String>{
      ...message.deliveredTo,
      ...userIds,
    }.where((userId) => userId.trim().isNotEmpty).toList(growable: false);
    final nextMessage = message.copyWith(deliveredTo: deliveredTo);
    nextMessages[messageIndex] = nextMessage;
    state.messages = nextMessages;
    state.messagesVersion++;
    // Delivery receipts can arrive several times per second when a chat
    // catches up after a reconnect — coalesce into a single Hive write.
    _scheduleDebouncedMessageCacheFlush(state);
    if (!state.controller.isClosed) {
      state.controller.add(List<ChatMessage>.unmodifiable(nextMessages));
    }
  }

  void _applyReadUpdate(
    _ChatMessageStreamState state,
    String readerUserId, {
    List<String> messageIds = const <String>[],
  }) {
    final targetMessageIds = messageIds.toSet();
    final nextMessages = state.messages.map((message) {
      if (message.senderId == readerUserId ||
          (targetMessageIds.isNotEmpty &&
              !targetMessageIds.contains(message.id))) {
        return message;
      }
      return message.copyWith(
        isRead: true,
        deliveredTo: <String>{
          ...message.deliveredTo,
          readerUserId,
        }.toList(growable: false),
        readBy: <String>{
          ...message.readBy,
          readerUserId,
        }.toList(growable: false),
      );
    }).toList(growable: false);
    state.messages = nextMessages;
    state.messagesVersion++;
    // Read markers can fire for every visible message on focus — debounce
    // the Hive flush so a single chat-open doesn't translate into N writes.
    _scheduleDebouncedMessageCacheFlush(state);
    if (!state.controller.isClosed) {
      state.controller.add(List<ChatMessage>.unmodifiable(nextMessages));
    }
  }

  List<String> _stringListFromDynamic(dynamic value) {
    if (value is! List) {
      return const <String>[];
    }
    return value
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  List<ChatMessage> _mergeMessageLists(
    List<ChatMessage> existingMessages,
    List<ChatMessage> incomingMessages,
  ) {
    if (incomingMessages.isEmpty) {
      return existingMessages;
    }

    final byId = <String, ChatMessage>{};
    for (final message in existingMessages) {
      if (message.id.trim().isNotEmpty) {
        byId[message.id] = message;
      }
    }
    for (final message in incomingMessages) {
      if (message.id.trim().isNotEmpty) {
        byId[message.id] = message;
      }
    }

    final nextMessages = byId.values.toList();
    nextMessages.sort(_sortMessagesDescending);
    return nextMessages;
  }

  List<ChatMessage> _mergeMessageListsPreservingExisting(
    List<ChatMessage> existingMessages,
    List<ChatMessage> incomingMessages,
  ) {
    if (incomingMessages.isEmpty) {
      return existingMessages;
    }

    final byId = <String, ChatMessage>{};
    for (final message in incomingMessages) {
      if (message.id.trim().isNotEmpty) {
        byId[message.id] = message;
      }
    }
    for (final message in existingMessages) {
      if (message.id.trim().isNotEmpty) {
        byId[message.id] = message;
      }
    }

    final nextMessages = byId.values.toList();
    nextMessages.sort(_sortMessagesDescending);
    return nextMessages;
  }

  /// Reconciles server-side deletions that the realtime `chat.message.deleted`
  /// event may have missed (this device was offline, the delete came from
  /// another device, or it happened before a cold start). [mergedMessages] is
  /// the union of the local state and the freshly fetched [serverPage]. A
  /// message that is absent from [serverPage] yet sits strictly INSIDE the
  /// page's window — the page returned a still-present message both newer AND
  /// older than it — is a genuine hole (a deletion) and is dropped.
  ///
  /// Only interior holes are pruned; a message at or beyond a window edge is
  /// always kept. That keeps three things safe:
  ///  * older-than-window history is never truncated (the page is only the
  ///    newest N messages);
  ///  * a transient empty/short page (fewer than two messages — e.g. mid
  ///    group/branch mutation) can't flank anything, so it prunes nothing;
  ///  * a just-sent message not yet visible to the read replica lives at the
  ///    newest edge and is preserved.
  /// Anything wrongly dropped by a rare partial-page glitch reappears on the
  /// next refetch (merge re-adds it), so the worst case is a brief flicker,
  /// never permanent loss.
  List<ChatMessage> _reconcileWithServerPage(
    List<ChatMessage> mergedMessages,
    List<ChatMessage> serverPage,
  ) {
    if (serverPage.length < 2) {
      return mergedMessages;
    }
    final serverIds = <String>{};
    var newest = serverPage.first.timestamp;
    var oldest = serverPage.first.timestamp;
    for (final message in serverPage) {
      if (message.id.trim().isNotEmpty) {
        serverIds.add(message.id);
      }
      if (message.timestamp.isAfter(newest)) {
        newest = message.timestamp;
      }
      if (message.timestamp.isBefore(oldest)) {
        oldest = message.timestamp;
      }
    }
    return mergedMessages.where((message) {
      if (serverIds.contains(message.id)) {
        return true;
      }
      final strictlyInsideWindow =
          message.timestamp.isAfter(oldest) && message.timestamp.isBefore(newest);
      return !strictlyInsideWindow;
    }).toList(growable: false);
  }

  void _cacheMessages(
    Future<void> Function(ChatMessageCache cache) operation,
  ) {
    final cache = _messageCache;
    if (cache == null) {
      return;
    }

    unawaited(() async {
      try {
        await operation(cache);
      } catch (_) {
        // Cache failures should not break chat rendering or delivery.
      }
    }());
  }

  /// Coalesce cache writes that come from rapid-fire metadata updates
  /// (reactions, delivery receipts, read markers). Each of these used to
  /// trigger an immediate full Hive read+modify+write of the 200-message
  /// window — fine for one event, expensive when 20 reactions land in
  /// half a second. Now we mark the chat dirty and flush at most once
  /// every ~800 ms, which keeps the offline cache eventually consistent
  /// without the I/O storm.
  final Map<String, Timer> _dirtyMessageCacheFlushTimers = <String, Timer>{};

  void _scheduleDebouncedMessageCacheFlush(_ChatMessageStreamState state) {
    if (_messageCache == null) return;
    _dirtyMessageCacheFlushTimers[state.chatId]?.cancel();
    _dirtyMessageCacheFlushTimers[state.chatId] = Timer(
      const Duration(milliseconds: 800),
      () {
        _dirtyMessageCacheFlushTimers.remove(state.chatId);
        // Snapshot the current message list at flush time — captures any
        // updates that arrived during the debounce window in a single
        // write rather than N separate ones.
        final snapshot = List<ChatMessage>.unmodifiable(state.messages);
        _cacheMessages(
          (cache) => cache.write(state.chatId, snapshot),
        );
      },
    );
  }

  int _sortMessagesDescending(ChatMessage left, ChatMessage right) {
    final timestampCompare = right.timestamp.compareTo(left.timestamp);
    if (timestampCompare != 0) {
      return timestampCompare;
    }
    return right.id.compareTo(left.id);
  }

  ChatMessage _parseChatMessage(Map<String, dynamic> message) {
    return ChatMessage.fromMap({
      'id': message['id'],
      'chatId': message['chatId'],
      'senderId': message['senderId'],
      'text': message['text'],
      'timestamp': message['timestamp'],
      'updatedAt': message['updatedAt'],
      'isRead': message['isRead'],
      'attachments': message['attachments'],
      'imageUrl': message['imageUrl'],
      'mediaUrls': message['mediaUrls'],
      'participants': message['participants'],
      'senderName': message['senderName'],
      'clientMessageId': message['clientMessageId'],
      'expiresAt': message['expiresAt'],
      'replyTo': message['replyTo'],
      'reactions': message['reactions'],
      'deliveredTo': message['deliveredTo'],
      'readBy': message['readBy'],
    });
  }

  ChatPinnedMessageSnapshot? _parsePinnedMessageSnapshot(dynamic value) {
    if (value is! Map) {
      return null;
    }
    final snapshot = ChatPinnedMessageSnapshot.fromJson(
      Map<String, dynamic>.from(value),
    );
    return snapshot.messageId.trim().isEmpty ? null : snapshot;
  }

  Future<List<ChatMessage>> _fetchMessages(String chatId) async {
    return (await fetchMessagesPage(chatId, limit: 100)).messages;
  }

  Future<List<ChatAttachment>> _uploadAttachments(
    List<XFile> attachments, {
    void Function(ChatSendProgress progress)? onProgress,
  }) async {
    if (attachments.isEmpty) {
      return const <ChatAttachment>[];
    }

    final storageService = _storageService ??
        (GetIt.I.isRegistered<StorageServiceInterface>()
            ? GetIt.I<StorageServiceInterface>()
            : null);
    final userId = currentUserId;
    if (storageService == null || userId == null || userId.isEmpty) {
      throw const CustomApiException('Не удалось подготовить вложения');
    }

    onProgress?.call(
      const ChatSendProgress(
        stage: ChatSendProgressStage.preparing,
        completed: 0,
        total: 1,
      ),
    );
    onProgress?.call(
      ChatSendProgress(
        stage: ChatSendProgressStage.uploading,
        completed: 0,
        total: attachments.length,
      ),
    );

    final uploadedAttachments = <ChatAttachment>[];
    for (var index = 0; index < attachments.length; index++) {
      final attachment = attachments[index];
      final initialType = _attachmentTypeForFile(attachment, '');
      final initialPresentation = _attachmentPresentationForFile(
        attachment,
        initialType,
      );
      final useVoiceFolder = _looksLikeVoiceNoteAttachment(attachment);
      final uploadedUrl = await storageService.uploadImage(
        attachment,
        initialPresentation == ChatAttachmentPresentation.voiceNote ||
                useVoiceFolder
            ? 'chat-voice/$userId'
            : 'chat-media/$userId',
      );
      if (uploadedUrl != null && uploadedUrl.isNotEmpty) {
        final attachmentType = _attachmentTypeForFile(attachment, uploadedUrl);
        final presentation = _attachmentPresentationForFile(
          attachment,
          attachmentType,
        );
        final metadata = await _buildAttachmentMetadata(
          attachment,
          attachmentType,
        );
        // V4 (ревью FR3): для исходящего видео генерим постер (первый кадр)
        // и грузим его — thumbnailUrl уезжает в сообщении, поэтому превью
        // видят и отправитель, и получатель. Best-effort: нет постера →
        // остаётся тёмная плитка с play-иконкой.
        final thumbnailUrl = attachmentType == ChatAttachmentType.video
            ? await _buildVideoPosterUrl(attachment, storageService, userId)
            : null;
        uploadedAttachments.add(
          ChatAttachment(
            type: attachmentType,
            url: uploadedUrl,
            presentation: presentation,
            mimeType: attachment.mimeType,
            fileName: _attachmentFileName(attachment, uploadedUrl),
            sizeBytes: await attachment.length(),
            durationMs: metadata.durationMs,
            waveform: metadata.waveform,
            width: metadata.width,
            height: metadata.height,
            thumbnailUrl: thumbnailUrl,
          ),
        );
      }
      onProgress?.call(
        ChatSendProgress(
          stage: ChatSendProgressStage.uploading,
          completed: index + 1,
          total: attachments.length,
        ),
      );
    }
    return uploadedAttachments;
  }

  /// V4 (ревью FR3): постер (первый кадр) локального видео → загруженный URL.
  /// Только не-web (video_thumbnail — нативный MediaMetadataRetriever на
  /// Android). Любой сбой → null: получим тёмную плитку с play-иконкой, но
  /// отправку видео не ломаем.
  Future<String?> _buildVideoPosterUrl(
    XFile attachment,
    StorageServiceInterface storageService,
    String userId,
  ) async {
    if (kIsWeb) {
      return null;
    }
    try {
      final bytes = await VideoThumbnail.thumbnailData(
        video: attachment.path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 720,
        quality: 70,
      );
      if (bytes == null || bytes.isEmpty) {
        return null;
      }
      final poster = XFile.fromData(
        bytes,
        name: 'poster_${attachment.name}.jpg',
        mimeType: 'image/jpeg',
      );
      return await storageService.uploadImage(poster, 'chat-media/$userId');
    } catch (_) {
      return null;
    }
  }

  Future<_UploadedAttachmentMetadata> _buildAttachmentMetadata(
    XFile attachment,
    ChatAttachmentType type,
  ) async {
    if (type == ChatAttachmentType.audio) {
      return _UploadedAttachmentMetadata(
        durationMs: _durationFromAttachmentName(attachment.name),
        waveform: await _buildVoiceWaveform(attachment),
      );
    }
    if (type != ChatAttachmentType.video) {
      return const _UploadedAttachmentMetadata();
    }

    final sourceUri = _attachmentUri(attachment.path);
    final controller = _isRemoteLikeUri(sourceUri)
        ? VideoPlayerController.networkUrl(sourceUri)
        : VideoPlayerController.contentUri(sourceUri);
    try {
      await controller.initialize();
      final value = controller.value;
      final durationMs = value.duration.inMilliseconds > 0
          ? value.duration.inMilliseconds
          : null;
      final width = value.size.width > 0 ? value.size.width.round() : null;
      final height = value.size.height > 0 ? value.size.height.round() : null;
      return _UploadedAttachmentMetadata(
        durationMs: durationMs,
        width: width,
        height: height,
      );
    } catch (_) {
      return const _UploadedAttachmentMetadata();
    } finally {
      await controller.dispose();
    }
  }

  Future<List<double>> _buildVoiceWaveform(XFile attachment) async {
    try {
      return buildVoiceWaveformFromBytes(await attachment.readAsBytes());
    } catch (_) {
      return const <double>[];
    }
  }

  ChatAttachmentPresentation _attachmentPresentationForFile(
    XFile attachment,
    ChatAttachmentType type,
  ) {
    if (type == ChatAttachmentType.audio &&
        _looksLikeVoiceNoteAttachment(attachment)) {
      return ChatAttachmentPresentation.voiceNote;
    }
    final normalizedName = attachment.name.toLowerCase().trim();
    if (type == ChatAttachmentType.video &&
        (normalizedName.startsWith('video_note') ||
            normalizedName.startsWith('video-note'))) {
      return ChatAttachmentPresentation.videoNote;
    }
    return ChatAttachmentPresentation.defaultPresentation;
  }

  bool _looksLikeVoiceNoteAttachment(XFile attachment) {
    final candidates = <String>[
      attachment.name,
      attachment.path,
    ].map((value) => value.toLowerCase().trim()).where((value) {
      return value.isNotEmpty;
    });
    return candidates.any((value) =>
        value.startsWith('voice_note') ||
        value.startsWith('voice-note') ||
        value.contains('/voice_note') ||
        value.contains(r'\voice_note') ||
        value.contains('/voice-note') ||
        value.contains(r'\voice-note'));
  }

  ChatAttachmentType _attachmentTypeForFile(
    XFile attachment,
    String uploadedUrl,
  ) {
    final mimeType = (attachment.mimeType ?? '').toLowerCase().trim();
    final name = attachment.name.toLowerCase().trim();
    final url = uploadedUrl.toLowerCase().trim();

    // MIME type is authoritative when present. Web voice notes are
    // `audio/webm` with a `voice_note_*.webm` filename — and `.webm` also
    // lives in the video extension list below. If the extension fall-through
    // wins, a voice message ships as an unplayable «video». So decide by
    // mimeType FIRST; only sniff the extension when there's no usable
    // `<kind>/` mime (e.g. octet-stream from a bare upload).
    if (mimeType.startsWith('image/')) {
      return ChatAttachmentType.image;
    }
    if (mimeType.startsWith('video/')) {
      return ChatAttachmentType.video;
    }
    if (mimeType.startsWith('audio/')) {
      return ChatAttachmentType.audio;
    }

    if (['.jpg', '.jpeg', '.png', '.webp', '.heic', '.gif'].any(
      (ext) => name.endsWith(ext) || url.endsWith(ext),
    )) {
      return ChatAttachmentType.image;
    }
    if (['.mp4', '.mov', '.webm', '.avi', '.mkv'].any(
      (ext) => name.endsWith(ext) || url.endsWith(ext),
    )) {
      return ChatAttachmentType.video;
    }
    if (['.m4a', '.aac', '.mp3', '.wav', '.ogg', '.flac'].any(
      (ext) => name.endsWith(ext) || url.endsWith(ext),
    )) {
      return ChatAttachmentType.audio;
    }

    return ChatAttachmentType.file;
  }

  String? _attachmentFileName(XFile attachment, String uploadedUrl) {
    final name = attachment.name.trim();
    if (name.isNotEmpty) {
      return name;
    }

    final uri = Uri.tryParse(uploadedUrl);
    final lastSegment = uri?.pathSegments.isNotEmpty == true
        ? uri!.pathSegments.last.trim()
        : '';
    return lastSegment.isNotEmpty ? lastSegment : null;
  }

  int? _durationFromAttachmentName(String rawName) {
    final match = RegExp(r'_(\d+)s_').firstMatch(rawName.trim().toLowerCase());
    final seconds = int.tryParse(match?.group(1) ?? '');
    if (seconds == null || seconds <= 0) {
      return null;
    }
    return Duration(seconds: seconds).inMilliseconds;
  }

  Uri _attachmentUri(String rawPath) {
    final parsedUri = Uri.tryParse(rawPath);
    if (parsedUri != null && parsedUri.hasScheme) {
      return parsedUri;
    }
    return Uri.file(rawPath);
  }

  bool _isRemoteLikeUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https' || scheme == 'blob';
  }

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    Map<String, String>? queryParameters,
  }) async {
    final uri = _buildUri(path, queryParameters: queryParameters);
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
      case 'PUT':
        response = await _httpClient.put(
          uri,
          headers: _headers(),
          body: jsonEncode(body ?? const <String, dynamic>{}),
        );
        break;
      case 'PATCH':
        response = await _httpClient.patch(
          uri,
          headers: _headers(),
          body: jsonEncode(body ?? const <String, dynamic>{}),
        );
        break;
      case 'DELETE':
        response = await _httpClient.delete(
          uri,
          headers: _headers(),
          body: body == null ? null : jsonEncode(body),
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

  Uri _buildUri(String path, {Map<String, String>? queryParameters}) {
    final normalizedBase = _runtimeConfig.apiBaseUrl.replaceAll(
      RegExp(r'/$'),
      '',
    );
    final uri = Uri.parse('$normalizedBase$path');
    if (queryParameters == null || queryParameters.isEmpty) {
      return uri;
    }
    return uri.replace(
      queryParameters: <String, String>{
        ...uri.queryParameters,
        ...queryParameters,
      },
    );
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
      _appStatusService?.reportSessionExpired();
      return true;
    }

    await _authService.clearSessionLocally(sessionExpired: true);
    return true;
  }
}

/// A realtime-sourced overlay for a chat-list preview. chat.updated carries the
/// full mapped chat (with photoUrl/title) — fresher than GET /v1/chats, which
/// can return a stale null group photoUrl until the backend is restarted.
/// A null field means "no override; fall through to the fetched value".
class ChatPreviewOverride {
  const ChatPreviewOverride({this.photoUrl, this.title, this.type});

  final String? photoUrl;
  final String? title;
  final String? type;

  bool get isGroup => type == 'group' || type == 'branch';

  Map<String, dynamic> toMap() => <String, dynamic>{
        'photoUrl': photoUrl,
        'title': title,
        'type': type,
      };

  factory ChatPreviewOverride.fromMap(Map<String, dynamic> map) {
    return ChatPreviewOverride(
      photoUrl: map['photoUrl']?.toString(),
      title: map['title']?.toString(),
      type: map['type']?.toString(),
    );
  }
}

/// Persists realtime chat-preview overrides (keyed by chatId) so a restored
/// group avatar survives a cold start / web reload. Without this the in-memory
/// override map is empty on boot, and the first (stale) /v1/chats refetch blanks
/// the group photo back out until a fresh chat.updated arrives.
abstract class ChatPreviewOverrideCache {
  Future<Map<String, ChatPreviewOverride>> read();

  Future<void> write(Map<String, ChatPreviewOverride> overrides);

  Future<void> clear();
}

class HiveChatPreviewOverrideCache implements ChatPreviewOverrideCache {
  HiveChatPreviewOverrideCache({this.boxName = 'chat_preview_overrides_v1'});

  final String boxName;
  static const String _key = 'overrides';
  Future<Box<String>>? _openTask;

  Future<Box<String>> _box() {
    return _openTask ??= openBoxWithRecovery<String>(boxName);
  }

  @override
  Future<Map<String, ChatPreviewOverride>> read() async {
    try {
      final raw = (await _box()).get(_key);
      if (raw == null || raw.trim().isEmpty) {
        return <String, ChatPreviewOverride>{};
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return <String, ChatPreviewOverride>{};
      }
      final result = <String, ChatPreviewOverride>{};
      decoded.forEach((key, value) {
        if (value is Map) {
          result[key.toString()] =
              ChatPreviewOverride.fromMap(Map<String, dynamic>.from(value));
        }
      });
      return result;
    } catch (_) {
      // Corrupt cache → ignore; a fresh chat.updated repopulates it.
      return <String, ChatPreviewOverride>{};
    }
  }

  @override
  Future<void> write(Map<String, ChatPreviewOverride> overrides) async {
    try {
      final encoded = <String, dynamic>{};
      overrides.forEach((key, value) {
        encoded[key] = value.toMap();
      });
      await (await _box()).put(_key, jsonEncode(encoded));
    } catch (_) {
      // Best-effort — never fail the foreground flow because of cache I/O.
    }
  }

  @override
  Future<void> clear() async {
    try {
      await (await _box()).delete(_key);
    } catch (_) {
      // Best-effort.
    }
  }
}

/// Test helper that keeps overrides in memory; pre-fill via the constructor to
/// simulate a populated Hive box after a restart.
class InMemoryChatPreviewOverrideCache implements ChatPreviewOverrideCache {
  InMemoryChatPreviewOverrideCache([
    Map<String, ChatPreviewOverride>? initial,
  ]) : _overrides = <String, ChatPreviewOverride>{...?initial};

  Map<String, ChatPreviewOverride> _overrides;

  @override
  Future<Map<String, ChatPreviewOverride>> read() async =>
      Map<String, ChatPreviewOverride>.from(_overrides);

  @override
  Future<void> write(Map<String, ChatPreviewOverride> overrides) async {
    _overrides = Map<String, ChatPreviewOverride>.from(overrides);
  }

  @override
  Future<void> clear() async {
    _overrides = <String, ChatPreviewOverride>{};
  }
}
