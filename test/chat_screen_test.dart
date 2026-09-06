import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:record/record.dart';
import 'package:rodnya/controllers/chat_recording_controller.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:rodnya/backend/interfaces/chat_service_interface.dart';
import 'package:rodnya/backend/interfaces/call_service_interface.dart';
import 'package:rodnya/backend/interfaces/safety_service_interface.dart';
import 'package:rodnya/models/call_event.dart';
import 'package:rodnya/models/call_invite.dart';
import 'package:rodnya/models/call_media_mode.dart';
import 'package:rodnya/models/call_state.dart';
import 'package:rodnya/models/chat_attachment.dart';
import 'package:rodnya/models/chat_details.dart';
import 'package:rodnya/models/chat_message.dart';
import 'package:rodnya/models/chat_message_search_result.dart';
import 'package:rodnya/models/chat_preview.dart';
import 'package:rodnya/models/chat_send_progress.dart';
import 'package:rodnya/models/family_tree.dart';
import 'package:rodnya/models/user_block_record.dart';
import 'package:rodnya/providers/tree_provider.dart';
import 'package:rodnya/screens/chat_screen.dart';
import 'package:rodnya/services/call_coordinator_service.dart';
import 'package:rodnya/services/chat_auto_delete_store.dart';
import 'package:rodnya/services/chat_clipboard_image_paste.dart';
import 'package:rodnya/services/chat_draft_suppression.dart';
import 'package:rodnya/services/chat_draft_store.dart';
import 'package:rodnya/services/chat_notification_settings_store.dart';
import 'package:rodnya/services/chat_pin_store.dart';
import 'package:rodnya/services/app_status_service.dart';
import 'package:rodnya/services/local_storage_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const List<int> _onePixelPng = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

class _MemoryChatDraftStore implements ChatDraftStore {
  final Map<String, ChatDraftSnapshot> _drafts = <String, ChatDraftSnapshot>{};

  @override
  Future<void> clearDraft(String key) async {
    _drafts.remove(key);
  }

  @override
  Future<Map<String, ChatDraftSnapshot>> getAllDrafts() async {
    return Map<String, ChatDraftSnapshot>.from(_drafts);
  }

  @override
  Future<ChatDraftSnapshot?> getDraft(String key) async {
    return _drafts[key];
  }

  @override
  Future<void> saveDraft(String key, String text) async {
    _drafts[key] = ChatDraftSnapshot(
      text: text,
      updatedAt: DateTime(2026, 4, 11, 12, _drafts.length),
    );
  }
}

class _BlockingReadChatDraftStore extends _MemoryChatDraftStore {
  final Completer<void> readStarted = Completer<void>();
  final Completer<ChatDraftSnapshot?> draftToReturn =
      Completer<ChatDraftSnapshot?>();

  @override
  Future<ChatDraftSnapshot?> getDraft(String key) async {
    if (!readStarted.isCompleted) {
      readStarted.complete();
    }
    return draftToReturn.future;
  }
}

class _MemoryChatPinStore implements ChatPinStore {
  final Map<String, ChatPinnedMessageSnapshot> _pins =
      <String, ChatPinnedMessageSnapshot>{};

  @override
  Future<ChatPinnedMessageSnapshot?> getPinnedMessage(String key) async {
    return _pins[key];
  }

  @override
  Future<void> savePinnedMessage(
    String key,
    ChatPinnedMessageSnapshot snapshot,
  ) async {
    _pins[key] = snapshot;
  }

  @override
  Future<void> clearPinnedMessage(String key) async {
    _pins.remove(key);
  }
}

class _MemoryChatNotificationSettingsStore
    implements ChatNotificationSettingsStore {
  final Map<String, ChatNotificationSettingsSnapshot> _settings =
      <String, ChatNotificationSettingsSnapshot>{};

  @override
  Future<void> clearSettings(String key) async {
    _settings.remove(key);
  }

  @override
  Future<Map<String, ChatNotificationSettingsSnapshot>> getAllSettings() async {
    return Map<String, ChatNotificationSettingsSnapshot>.from(_settings);
  }

  @override
  Future<ChatNotificationSettingsSnapshot?> getSettings(String key) async {
    return _settings[key];
  }

  @override
  Future<void> saveSettings(
    String key,
    ChatNotificationSettingsSnapshot snapshot,
  ) async {
    if (snapshot.level == ChatNotificationLevel.all) {
      _settings.remove(key);
      return;
    }
    _settings[key] = snapshot;
  }
}

class _MemoryChatAutoDeleteStore implements ChatAutoDeleteStore {
  final Map<String, ChatAutoDeleteSnapshot> _settings =
      <String, ChatAutoDeleteSnapshot>{};

  @override
  Future<void> clearSettings(String key) async {
    _settings.remove(key);
  }

  @override
  Future<Map<String, ChatAutoDeleteSnapshot>> getAllSettings() async {
    return Map<String, ChatAutoDeleteSnapshot>.from(_settings);
  }

  @override
  Future<ChatAutoDeleteSnapshot?> getSettings(String key) async {
    return _settings[key];
  }

  @override
  Future<void> saveSettings(String key, ChatAutoDeleteSnapshot snapshot) async {
    if (snapshot.option == ChatAutoDeleteOption.off) {
      _settings.remove(key);
      return;
    }
    _settings[key] = snapshot;
  }
}

class _FakeLocalStorageService implements LocalStorageService {
  @override
  Future<List<FamilyTree>> getAllTrees() async => [
        FamilyTree(
          id: 'tree-1',
          name: 'Семья Кузнецовых',
          description: '',
          creatorId: 'user-1',
          memberIds: const ['user-1'],
          createdAt: DateTime(2026, 4, 11),
          updatedAt: DateTime(2026, 4, 11),
          isPrivate: true,
          members: const ['user-1'],
          kind: TreeKind.family,
        ),
      ];

  @override
  Future<FamilyTree?> getTree(String treeId) async {
    return FamilyTree(
      id: treeId,
      name: 'Семья Кузнецовых',
      description: '',
      creatorId: 'user-1',
      memberIds: const ['user-1'],
      createdAt: DateTime(2026, 4, 11),
      updatedAt: DateTime(2026, 4, 11),
      isPrivate: true,
      members: const ['user-1'],
      kind: TreeKind.family,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChatService implements ChatServiceInterface {
  _FakeChatService({
    this.supportsServerSearch = false,
    this.serverSearchResults = const <ChatMessageSearchResult>[],
  });

  final Completer<void> sendCompleter = Completer<void>();
  final StreamController<List<ChatMessage>> _messagesController =
      StreamController<List<ChatMessage>>.broadcast();
  List<ChatMessage> _latestMessages = const <ChatMessage>[];
  final List<_SentChatRequest> sentRequests = <_SentChatRequest>[];
  ChatReplyReference? lastReplyTo;
  List<ChatAttachment> lastForwardedAttachments = const <ChatAttachment>[];
  String? lastEditedMessageId;
  String? lastEditedText;
  String? lastDeletedMessageId;
  final List<String> deletedMessageIds = <String>[];
  final List<String> getOrCreateChatCalls = <String>[];
  String? lastReactionMessageId;
  String? lastReactionEmoji;
  String? lastClientMessageId;
  int? lastExpiresInSeconds;
  bool supportsServerSearch;
  List<ChatMessageSearchResult> serverSearchResults;
  final List<String> searchQueries = <String>[];
  String? lastSearchChatId;
  int? lastSearchLimit;
  String? leftChatId;
  ChatDetails details = const ChatDetails(
    chatId: 'chat-group-1',
    type: 'group',
    title: 'Семья Кузнецовых',
    participantIds: ['user-1', 'user-2', 'user-3'],
    participants: [
      ChatParticipantSummary(userId: 'user-1', displayName: 'Артем'),
      ChatParticipantSummary(userId: 'user-2', displayName: 'Андрей'),
      ChatParticipantSummary(userId: 'user-3', displayName: 'Дарья'),
    ],
    branchRoots: [],
    treeId: 'tree-1',
  );

  @override
  String? get currentUserId => 'user-1';

  @override
  String buildChatId(String otherUserId) => 'chat-$otherUserId';

  @override
  Stream<List<ChatPreview>> getUserChatsStream(String userId) {
    return Stream.value(const <ChatPreview>[]);
  }

  @override
  Stream<int> getTotalUnreadCountStream(String userId) {
    return Stream.value(0);
  }

  @override
  Stream<List<ChatMessage>> getMessagesStream(String chatId) {
    return _messagesController.stream;
  }

  @override
  Future<void> refreshMessages(String chatId) async {}

  @override
  Future<void> sendMessage({
    required String otherUserId,
    String text = '',
    List<XFile> attachments = const <XFile>[],
  }) async {}

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
    lastReplyTo = replyTo;
    lastForwardedAttachments = forwardedAttachments;
    lastClientMessageId = clientMessageId;
    lastExpiresInSeconds = expiresInSeconds;
    sentRequests.add(
      _SentChatRequest(
        chatId: chatId,
        text: text,
        attachments: attachments,
        forwardedAttachments: forwardedAttachments,
        replyTo: replyTo,
        clientMessageId: clientMessageId,
        expiresInSeconds: expiresInSeconds,
      ),
    );
    onProgress?.call(
      const ChatSendProgress(
        stage: ChatSendProgressStage.sending,
        completed: 1,
        total: 1,
      ),
    );
    await sendCompleter.future;
  }

  @override
  Future<void> sendTextMessage({
    required String otherUserId,
    required String text,
  }) async {}

  @override
  Future<void> markChatAsRead(String chatId, String userId) async {}

  @override
  Future<String?> getOrCreateChat(String otherUserId) async {
    getOrCreateChatCalls.add(otherUserId);
    return 'chat-1';
  }

  @override
  Future<String?> createGroupChat({
    required List<String> participantIds,
    String? title,
    String? treeId,
  }) async =>
      'chat-group-1';

  @override
  Future<String?> createBranchChat({
    required String treeId,
    required List<String> branchRootPersonIds,
    String? title,
  }) async =>
      'chat-branch-1';

  @override
  Future<ChatDetails> getChatDetails(String chatId) async => details;

  @override
  Future<ChatDetails> renameGroupChat({
    required String chatId,
    required String title,
  }) async {
    details = ChatDetails(
      chatId: details.chatId,
      type: details.type,
      title: title,
      photoUrl: details.photoUrl,
      participantIds: details.participantIds,
      participants: details.participants,
      branchRoots: details.branchRoots,
      treeId: details.treeId,
    );
    return details;
  }

  @override
  Future<ChatDetails> updateGroupChatPhoto({
    required String chatId,
    required XFile photo,
  }) async {
    details = ChatDetails(
      chatId: details.chatId,
      type: details.type,
      title: details.title,
      photoUrl: 'https://example.com/chat-photo.jpg',
      participantIds: details.participantIds,
      participants: details.participants,
      branchRoots: details.branchRoots,
      treeId: details.treeId,
    );
    return details;
  }

  @override
  Future<ChatDetails> addGroupParticipants({
    required String chatId,
    required List<String> participantIds,
  }) async =>
      details;

  @override
  Future<ChatDetails> removeGroupParticipant({
    required String chatId,
    required String participantId,
  }) async =>
      details;

  @override
  Future<void> leaveGroup(String chatId) async {
    leftChatId = chatId;
  }

  @override
  Future<void> editChatMessage({
    required String chatId,
    required String messageId,
    required String text,
  }) async {
    lastEditedMessageId = messageId;
    lastEditedText = text;
  }

  @override
  Future<void> deleteChatMessage({
    required String chatId,
    required String messageId,
  }) async {
    lastDeletedMessageId = messageId;
    deletedMessageIds.add(messageId);
  }

  @override
  Future<void> toggleMessageReaction({
    required String chatId,
    required String messageId,
    required String emoji,
  }) async {
    lastReactionMessageId = messageId;
    lastReactionEmoji = emoji;

    final currentUserId = this.currentUserId!;
    _latestMessages = _latestMessages.map((message) {
      if (message.id != messageId) {
        return message;
      }
      final reactions =
          message.reactions.map((reaction) => reaction.toMap()).toList();
      final existingIndex = reactions.indexWhere(
        (reaction) => reaction['emoji'] == emoji,
      );
      if (existingIndex >= 0) {
        final userIds = List<String>.from(
          (reactions[existingIndex]['userIds'] as List<dynamic>? ?? [])
              .map((value) => value.toString()),
        );
        if (userIds.contains(currentUserId)) {
          userIds.remove(currentUserId);
        } else {
          userIds.add(currentUserId);
        }
        if (userIds.isEmpty) {
          reactions.removeAt(existingIndex);
        } else {
          reactions[existingIndex] = <String, dynamic>{
            'emoji': emoji,
            'userIds': userIds,
            'count': userIds.length,
          };
        }
      } else {
        reactions.add(<String, dynamic>{
          'emoji': emoji,
          'userIds': <String>[currentUserId],
          'count': 1,
        });
      }
      return message.copyWith(
        reactions: ChatMessageReactionSummary.listFromDynamic(reactions),
      );
    }).toList(growable: false);
    _messagesController.add(_latestMessages);
  }

  @override
  Future<List<ChatMessageSearchResult>> searchMessages({
    required String query,
    String? chatId,
    int limit = 50,
  }) async {
    searchQueries.add(query);
    lastSearchChatId = chatId;
    lastSearchLimit = limit;
    if (!supportsServerSearch) {
      throw UnsupportedError('searchMessages is not supported');
    }
    return serverSearchResults;
  }

  void emitMessages(List<ChatMessage> messages) {
    _latestMessages = messages;
    _messagesController.add(messages);
  }
}

class _SentChatRequest {
  const _SentChatRequest({
    required this.chatId,
    required this.text,
    required this.attachments,
    required this.forwardedAttachments,
    required this.replyTo,
    required this.clientMessageId,
    required this.expiresInSeconds,
  });

  final String chatId;
  final String text;
  final List<XFile> attachments;
  final List<ChatAttachment> forwardedAttachments;
  final ChatReplyReference? replyTo;
  final String? clientMessageId;
  final int? expiresInSeconds;
}

class _FakeCallService implements CallServiceInterface {
  CallInvite? activeCall;
  String? startedChatId;
  CallMediaMode? startedMediaMode;
  List<String>? startedParticipantIds;

  @override
  String? get currentUserId => 'user-1';

  @override
  Stream<CallEvent> get events => const Stream<CallEvent>.empty();

  @override
  Future<void> startRealtimeBridge() async {}

  @override
  Future<void> stopRealtimeBridge() async {}

  @override
  Future<CallInvite?> getActiveCall({String? chatId}) async {
    if (chatId == null || chatId.isEmpty) {
      return activeCall;
    }
    return activeCall?.chatId == chatId ? activeCall : null;
  }

  @override
  Future<CallInvite?> getCall(String callId) async {
    return activeCall?.id == callId ? activeCall : null;
  }

  @override
  Future<CallInvite> acceptCall(String callId) {
    throw UnimplementedError();
  }

  @override
  Future<CallInvite> cancelCall(String callId) {
    throw UnimplementedError();
  }

  @override
  Future<CallInvite> hangUp(String callId) {
    throw UnimplementedError();
  }

  @override
  Future<CallInvite> rejectCall(String callId) {
    throw UnimplementedError();
  }

  @override
  Future<CallInvite> startCall({
    required String chatId,
    required CallMediaMode mediaMode,
    List<String>? participantIds,
  }) async {
    startedChatId = chatId;
    startedMediaMode = mediaMode;
    startedParticipantIds = participantIds;
    final now = DateTime(2026, 4, 20, 10);
    final normalizedParticipants = <String>[
      currentUserId!,
      ...?participantIds,
    ];
    activeCall = CallInvite(
      id: 'call-1',
      chatId: chatId,
      initiatorId: currentUserId!,
      recipientId: participantIds == null || participantIds.isEmpty
          ? 'user-2'
          : participantIds.first,
      participantIds: normalizedParticipants,
      mediaMode: mediaMode,
      state: CallState.cancelled,
      createdAt: now,
      updatedAt: now,
    );
    return activeCall!;
  }

  @override
  Future<CallInvite> joinCall(String callId) => acceptCall(callId);

  @override
  Future<CallInvite> nudgeCallParticipants(
    String callId, {
    List<String>? participantIds,
  }) async {
    if (activeCall != null) {
      return activeCall!;
    }
    throw UnimplementedError();
  }
}

class _FakeSafetyService implements SafetyServiceInterface {
  String? lastReportedTargetType;
  String? lastReportedTargetId;
  String? lastReportedReason;
  String? lastBlockedUserId;
  String? lastBlockReason;
  final List<UserBlockRecord> blockedUsers = <UserBlockRecord>[];

  @override
  Future<UserBlockRecord> blockUser({
    required String userId,
    String? reason,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) async {
    lastBlockedUserId = userId;
    lastBlockReason = reason;
    final record = UserBlockRecord(
      id: 'block-$userId',
      blockedUserId: userId,
      blockedUserDisplayName: 'Собеседник',
      createdAt: DateTime(2026, 4, 12, 10),
      reason: reason,
    );
    blockedUsers.add(record);
    return record;
  }

  @override
  Future<List<UserBlockRecord>> listBlockedUsers() async =>
      List<UserBlockRecord>.from(blockedUsers);

  @override
  Future<void> reportTarget({
    required String targetType,
    required String targetId,
    required String reason,
    String? details,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) async {
    lastReportedTargetType = targetType;
    lastReportedTargetId = targetId;
    lastReportedReason = reason;
  }

  @override
  Future<void> unblockUser(String blockId) async {
    blockedUsers.removeWhere((entry) => entry.id == blockId);
  }
}

void main() {
  final getIt = GetIt.instance;

  Widget buildChatApp(Widget child) {
    final treeProvider = TreeProvider();
    treeProvider.selectTree(
      'tree-1',
      'Семья Кузнецовых',
      treeKind: TreeKind.family,
    );

    return ChangeNotifierProvider<TreeProvider>.value(
      value: treeProvider,
      child: MaterialApp(home: child),
    );
  }

  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  setUp(() async {
    await getIt.reset();
    SharedPreferences.setMockInitialValues({});
    ChatDraftSuppression.instance.resetForTesting();
    getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
    getIt.registerSingleton<AppStatusService>(AppStatusService());
    final callService = _FakeCallService();
    getIt.registerSingleton<CallServiceInterface>(callService);
    getIt.registerSingleton<CallCoordinatorService>(
      CallCoordinatorService(callService: callService),
    );
  });

  tearDown(() async {
    if (getIt.isRegistered<CallCoordinatorService>()) {
      getIt<CallCoordinatorService>().dispose();
    }
    await getIt.reset();
  });

  testWidgets('ChatScreen shows sending and sent states for optimistic message',
      (tester) async {
    final chatService = _FakeChatService();
    final draftStore = _MemoryChatDraftStore();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: draftStore,
          pinStore: _MemoryChatPinStore(),
        ),
      ),
    );

    chatService._messagesController.add(const <ChatMessage>[]);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextField), 'Привет!');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(find.text('Привет!'), findsOneWidget);
    expect(find.text('Отправляется...'), findsOneWidget);

    chatService.sendCompleter.complete();
    await tester.pump();

    expect(find.text('Отправлено'), findsOneWidget);
    expect(
      await draftStore
          .getDraft(SharedPreferencesChatDraftStore.chatKey('chat-1')),
      isNull,
    );
  });

  testWidgets('ChatScreen does not restore a stale draft echo after send',
      (tester) async {
    final chatService = _FakeChatService();
    final draftStore = _MemoryChatDraftStore();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: draftStore,
          pinStore: _MemoryChatPinStore(),
        ),
      ),
    );

    chatService._messagesController.add(const <ChatMessage>[]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Уже отправленный текст');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    chatService.sendCompleter.complete();
    await tester.pump();

    await draftStore.saveDraft(
      SharedPreferencesChatDraftStore.chatKey('chat-1'),
      'Уже отправленный текст',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: draftStore,
          pinStore: _MemoryChatPinStore(),
        ),
      ),
    );
    chatService._messagesController.add(const <ChatMessage>[]);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, isEmpty);
    expect(
      await draftStore.getDraft(
        SharedPreferencesChatDraftStore.chatKey('chat-1'),
      ),
      isNull,
    );
  });

  test(
      'ChatDraftSuppression ignores sent-draft variants until the next local edit',
      () {
    final suppression = ChatDraftSuppression.instance;
    suppression.resetForTesting();

    suppression.suppressSentDraft(
      chatId: 'chat-1',
      text: 'Тебе можете писать друг другу!',
      now: DateTime(2026, 7, 1, 13),
    );

    expect(
      suppression.shouldSuppressDraft(
        chatId: 'chat-1',
        text: 'Тебе можете писать друг другу',
        now: DateTime(2026, 7, 1, 13, 1),
      ),
      isTrue,
    );

    suppression.recordLocalDraftEdit(
      key: SharedPreferencesChatDraftStore.chatKey('chat-1'),
      text: 'Новый черновик',
      now: DateTime(2026, 7, 1, 13, 2),
    );

    expect(
      suppression.shouldSuppressDraft(
        chatId: 'chat-1',
        text: 'Новый черновик',
        now: DateTime(2026, 7, 1, 13, 2),
      ),
      isFalse,
    );
  });

  testWidgets('ChatScreen attaches a pasted clipboard image', (tester) async {
    final chatService = _FakeChatService();
    final clipboardImages = StreamController<ChatClipboardImage>.broadcast();
    addTearDown(clipboardImages.close);
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
          pinStore: _MemoryChatPinStore(),
          clipboardImages: clipboardImages.stream,
        ),
      ),
    );

    chatService._messagesController.add(const <ChatMessage>[]);
    await tester.pumpAndSettle();

    clipboardImages.add(
      ChatClipboardImage(
        bytes: Uint8List.fromList(_onePixelPng),
        mimeType: 'image/png',
        name: 'clipboard-shot.png',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Фото перед отправкой'), findsOneWidget);
    expect(find.text('1 фото'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Скрин из буфера');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(chatService.sentRequests, hasLength(1));
    expect(chatService.sentRequests.single.text, 'Скрин из буфера');
    expect(chatService.sentRequests.single.attachments, hasLength(1));
    expect(
      chatService.sentRequests.single.attachments.single.mimeType,
      'image/png',
    );
    expect(
      await chatService.sentRequests.single.attachments.single.readAsBytes(),
      _onePixelPng,
    );

    chatService.sendCompleter.complete();
  });

  testWidgets('ChatScreen shows sent, delivered and read receipts',
      (tester) async {
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
          pinStore: _MemoryChatPinStore(),
        ),
      ),
    );

    ChatMessage message({
      List<String> deliveredTo = const <String>['user-1'],
      List<String> readBy = const <String>['user-1'],
      bool isRead = false,
    }) {
      return ChatMessage(
        id: 'm-receipt-1',
        chatId: 'chat-1',
        senderId: 'user-1',
        text: 'Статус доставки',
        timestamp: DateTime(2026, 4, 11, 12, 0),
        isRead: isRead,
        participants: const ['user-1', 'other-user'],
        senderName: 'Я',
        deliveredTo: deliveredTo,
        readBy: readBy,
      );
    }

    chatService.emitMessages([message()]);
    await tester.pumpAndSettle();
    expect(find.text('Отправлено'), findsOneWidget);

    chatService.emitMessages([
      message(deliveredTo: const ['user-1', 'other-user']),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Доставлено'), findsOneWidget);

    chatService.emitMessages([
      message(
        deliveredTo: const ['user-1', 'other-user'],
        readBy: const ['user-1', 'other-user'],
        isRead: true,
      ),
    ]);
    await tester.pumpAndSettle();
    // Renamed Просмотрено → Прочитано to match the Telegram-style
    // spoken wording the rest of the read-receipt UX uses.
    expect(find.text('Прочитано'), findsOneWidget);
  });

  testWidgets('ChatScreen applies auto-delete option to outgoing messages',
      (tester) async {
    final chatService = _FakeChatService()
      ..details = const ChatDetails(
        chatId: 'chat-1',
        type: 'direct',
        title: 'Андрей',
        participantIds: ['user-1', 'user-2'],
        participants: [
          ChatParticipantSummary(userId: 'user-1', displayName: 'Артем'),
          ChatParticipantSummary(userId: 'user-2', displayName: 'Андрей'),
        ],
        branchRoots: [],
      );
    final autoDeleteStore = _MemoryChatAutoDeleteStore();
    await autoDeleteStore.saveSettings(
      SharedPreferencesChatAutoDeleteStore.chatKey('chat-1'),
      ChatAutoDeleteSnapshot(
        option: ChatAutoDeleteOption.oneDay,
        updatedAt: DateTime(2026, 4, 11, 12),
      ),
    );
    chatService.sendCompleter.complete();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Андрей',
          initialChatDetails: chatService.details,
          draftStore: _MemoryChatDraftStore(),
          pinStore: _MemoryChatPinStore(),
          autoDeleteStore: autoDeleteStore,
        ),
      ),
    );

    chatService.emitMessages(const <ChatMessage>[]);
    await tester.pumpAndSettle();

    expect(find.text('Автоудаление: 1 день'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Сообщение с TTL');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(chatService.lastExpiresInSeconds, const Duration(days: 1).inSeconds);
    expect(chatService.lastClientMessageId, isNotNull);
  });

  testWidgets('ChatScreen restores saved draft for chat', (tester) async {
    final chatService = _FakeChatService();
    final draftStore = _MemoryChatDraftStore();
    await draftStore.saveDraft(
      SharedPreferencesChatDraftStore.chatKey('chat-1'),
      'Не забыть написать семье',
    );
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: draftStore,
          pinStore: _MemoryChatPinStore(),
        ),
      ),
    );

    chatService._messagesController.add(const <ChatMessage>[]);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'Не забыть написать семье');
  });

  testWidgets('ChatScreen does not overwrite typed text with late draft',
      (tester) async {
    final chatService = _FakeChatService();
    final draftStore = _BlockingReadChatDraftStore();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: draftStore,
          pinStore: _MemoryChatPinStore(),
        ),
      ),
    );

    chatService._messagesController.add(const <ChatMessage>[]);
    await draftStore.readStarted.future;
    await tester.enterText(find.byType(TextField), 'Пишу новое сообщение');
    await tester.pump();

    draftStore.draftToReturn.complete(
      ChatDraftSnapshot(
        text: 'Старый черновик',
        updatedAt: DateTime(2026, 4, 11, 12),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'Пишу новое сообщение');
  });

  testWidgets('ChatScreen lets user choose video attachment from picker sheet',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          pickVideo: () async => XFile.fromData(
            Uint8List.fromList(<int>[1, 2, 3]),
            name: 'clip.mp4',
            mimeType: 'video/mp4',
          ),
        ),
      ),
    );

    chatService._messagesController.add(const <ChatMessage>[]);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byTooltip('Добавить вложение'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Видео'));
    await tester.pumpAndSettle();

    expect(find.text('Видео перед отправкой'), findsOneWidget);
    expect(find.text('1 вложение'), findsOneWidget);
    expect(find.text('1 видео'), findsOneWidget);
    expect(
      find.text(
        'Видео отправится как вложение. Можно добавить подпись к отправке.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Очистить'));
    await tester.pumpAndSettle();

    expect(find.text('Видео перед отправкой'), findsNothing);
    expect(find.text('1 вложение'), findsNothing);
  });

  testWidgets('ChatScreen shows sender labels for incoming branch messages',
      (tester) async {
    final chatService = _FakeChatService();
    chatService.details = const ChatDetails(
      chatId: 'chat-branch-1',
      type: 'branch',
      title: 'Ветка Кузнецовых',
      participantIds: ['user-1', 'user-2', 'user-3'],
      participants: [
        ChatParticipantSummary(userId: 'user-1', displayName: 'Артем'),
        ChatParticipantSummary(
          userId: 'user-2',
          displayName: 'Андрей Кузнецов',
        ),
        ChatParticipantSummary(userId: 'user-3', displayName: 'Дарья'),
      ],
      branchRoots: [
        ChatBranchRootSummary(
          personId: 'person-root-1',
          name: 'Кузнецовы',
        ),
      ],
      treeId: 'tree-1',
    );
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        const ChatScreen(
          chatId: 'chat-branch-1',
          title: 'Ветка Кузнецовых',
          chatType: 'branch',
          initialChatDetails: ChatDetails(
            chatId: 'chat-branch-1',
            type: 'branch',
            title: 'Ветка Кузнецовых',
            participantIds: ['user-1', 'user-2', 'user-3'],
            participants: [
              ChatParticipantSummary(userId: 'user-1', displayName: 'Артем'),
              ChatParticipantSummary(
                userId: 'user-2',
                displayName: 'Андрей Кузнецов',
              ),
              ChatParticipantSummary(userId: 'user-3', displayName: 'Дарья'),
            ],
            branchRoots: [
              ChatBranchRootSummary(
                personId: 'person-root-1',
                name: 'Кузнецовы',
              ),
            ],
            treeId: 'tree-1',
          ),
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-1',
        chatId: 'chat-branch-1',
        senderId: 'user-2',
        senderName: 'Андрей Кузнецов',
        text: 'Сбор у дома в 19:00',
        timestamp: DateTime(2026, 4, 3, 19, 0),
        isRead: false,
        participants: const ['user-1', 'user-2', 'user-3'],
      ),
    ]);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('1 ветка · 3 участников'), findsOneWidget);
    expect(find.text('Андрей Кузнецов'), findsOneWidget);
    expect(find.text('Сбор у дома в 19:00'), findsOneWidget);
  });

  testWidgets(
      'J: тап по аватару ГРУППЫ открывает «О чате» с участниками '
      '(раньше был мёртв)', (tester) async {
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        const ChatScreen(
          chatId: 'chat-group-1',
          title: 'Семья Кузнецовых',
          chatType: 'group',
          initialChatDetails: ChatDetails(
            chatId: 'chat-group-1',
            type: 'group',
            title: 'Семья Кузнецовых',
            participantIds: ['user-1', 'user-2'],
            participants: [
              ChatParticipantSummary(userId: 'user-1', displayName: 'Артем'),
              ChatParticipantSummary(userId: 'user-2', displayName: 'Андрей'),
            ],
            branchRoots: [],
            treeId: 'tree-1',
          ),
        ),
      ),
    );

    chatService.emitMessages(const <ChatMessage>[]);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));

    // Аватар группы в шапке (иконка group_outlined в AppBar).
    await tester.tap(
      find
          .descendant(
            of: find.byType(AppBar),
            matching: find.byIcon(Icons.group_outlined),
          )
          .first,
    );
    await tester.pumpAndSettle();

    expect(find.text('О чате'), findsOneWidget);
    expect(find.text('Участники'), findsOneWidget);
    // Строки участников на месте, свой помечен «Вы».
    expect(find.text('Андрей'), findsOneWidget);
    expect(find.text('Вы'), findsOneWidget);
  });

  testWidgets('ChatScreen opens chat info for group chat', (tester) async {
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        const ChatScreen(
          chatId: 'chat-group-1',
          title: 'Семья Кузнецовых',
          chatType: 'group',
          initialChatDetails: ChatDetails(
            chatId: 'chat-group-1',
            type: 'group',
            title: 'Семья Кузнецовых',
            participantIds: ['user-1', 'user-2', 'user-3'],
            participants: [
              ChatParticipantSummary(userId: 'user-1', displayName: 'Артем'),
              ChatParticipantSummary(userId: 'user-2', displayName: 'Андрей'),
              ChatParticipantSummary(userId: 'user-3', displayName: 'Дарья'),
            ],
            branchRoots: [],
            treeId: 'tree-1',
          ),
        ),
      ),
    );

    chatService.emitMessages(const <ChatMessage>[]);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Семья Кузнецовых').first);
    await tester.pumpAndSettle();

    expect(find.text('О чате'), findsOneWidget);
    // Для групп секция «Участники» теперь идёт сразу после чипов —
    // быстрые действия ниже, доскролливаем шит.
    expect(find.text('Участники'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('Быстрые действия'), findsOneWidget);
    expect(find.text('Поиск в чате'), findsOneWidget);
    expect(find.text('Открыть дерево'), findsOneWidget);

    await tester.tap(find.text('Поиск в чате'));
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Поиск по сообщениям',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      'G2: групповой чат показывает «Покинуть чат» и вызывает leaveGroup',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    final treeProvider = TreeProvider();
    treeProvider.selectTree(
      'tree-1',
      'Семья Кузнецовых',
      treeKind: TreeKind.family,
    );
    final router = GoRouter(
      initialLocation: '/chat',
      routes: [
        GoRoute(
          path: '/chat',
          builder: (context, state) => const ChatScreen(
            chatId: 'chat-group-1',
            title: 'Семья Кузнецовых',
            chatType: 'group',
            initialChatDetails: ChatDetails(
              chatId: 'chat-group-1',
              type: 'group',
              title: 'Семья Кузнецовых',
              participantIds: ['user-1', 'user-2', 'user-3'],
              participants: [
                ChatParticipantSummary(userId: 'user-1', displayName: 'Артем'),
                ChatParticipantSummary(userId: 'user-2', displayName: 'Андрей'),
                ChatParticipantSummary(userId: 'user-3', displayName: 'Дарья'),
              ],
              branchRoots: [],
              treeId: 'tree-1',
            ),
          ),
        ),
        GoRoute(
          path: '/chats',
          builder: (context, state) => const Text('chats-list'),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    chatService.emitMessages(const <ChatMessage>[]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Семья Кузнецовых').first);
    await tester.pumpAndSettle();

    final leaveButton = find.byKey(const Key('chat-info-leave-group'));
    await tester.scrollUntilVisible(
      leaveButton,
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(leaveButton);
    await tester.pumpAndSettle();

    // Подтверждение выхода.
    expect(find.text('Выйти'), findsOneWidget);
    await tester.tap(find.text('Выйти'));
    await tester.pumpAndSettle();

    expect(chatService.leftChatId, 'chat-group-1');
    expect(find.text('chats-list'), findsOneWidget);
  });

  testWidgets('ChatScreen exposes group call actions for group chat',
      (tester) async {
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        const ChatScreen(
          chatId: 'chat-group-1',
          title: 'Семья Кузнецовых',
          chatType: 'group',
          initialChatDetails: ChatDetails(
            chatId: 'chat-group-1',
            type: 'group',
            title: 'Семья Кузнецовых',
            participantIds: ['user-1', 'user-2', 'user-3'],
            participants: [
              ChatParticipantSummary(userId: 'user-1', displayName: 'Артем'),
              ChatParticipantSummary(userId: 'user-2', displayName: 'Андрей'),
              ChatParticipantSummary(userId: 'user-3', displayName: 'Дарья'),
            ],
            branchRoots: [],
            treeId: 'tree-1',
          ),
        ),
      ),
    );

    chatService.emitMessages(const <ChatMessage>[]);
    await tester.pumpAndSettle();

    expect(find.byTooltip('Групповой аудиозвонок'), findsOneWidget);
    expect(find.byTooltip('Групповой видеозвонок'), findsOneWidget);
  });

  testWidgets('ChatScreen starts group call only for selected participants',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final chatService = _FakeChatService();
    final callService = getIt<CallServiceInterface>() as _FakeCallService;
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        const ChatScreen(
          chatId: 'chat-group-1',
          title: 'Семья Кузнецовых',
          chatType: 'group',
          initialChatDetails: ChatDetails(
            chatId: 'chat-group-1',
            type: 'group',
            title: 'Семья Кузнецовых',
            participantIds: ['user-1', 'user-2', 'user-3'],
            participants: [
              ChatParticipantSummary(userId: 'user-1', displayName: 'Артем'),
              ChatParticipantSummary(userId: 'user-2', displayName: 'Андрей'),
              ChatParticipantSummary(userId: 'user-3', displayName: 'Дарья'),
            ],
            branchRoots: [],
            treeId: 'tree-1',
          ),
        ),
      ),
    );

    chatService.emitMessages(const <ChatMessage>[]);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Групповой аудиозвонок'));
    await tester.pumpAndSettle();

    expect(find.text('Кого позвать?'), findsOneWidget);
    expect(find.text('Андрей'), findsOneWidget);
    expect(find.text('Дарья'), findsOneWidget);
    expect(find.text('Никто не выбран'), findsOneWidget);

    await tester.tap(find.text('Андрей'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Позвонить 1 участнику'));
    await tester.pumpAndSettle();

    expect(callService.startedChatId, 'chat-group-1');
    expect(callService.startedMediaMode, CallMediaMode.audio);
    expect(callService.startedParticipantIds, ['user-2']);
  });

  testWidgets('ChatScreen stores per-chat notification mode from info sheet',
      (tester) async {
    final chatService = _FakeChatService();
    final notificationSettingsStore = _MemoryChatNotificationSettingsStore();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    Future<void> pumpChat() async {
      await tester.pumpWidget(
        buildChatApp(
          ChatScreen(
            chatId: 'chat-group-1',
            title: 'Семья Кузнецовых',
            chatType: 'group',
            notificationSettingsStore: notificationSettingsStore,
            initialChatDetails: const ChatDetails(
              chatId: 'chat-group-1',
              type: 'group',
              title: 'Семья Кузнецовых',
              participantIds: ['user-1', 'user-2', 'user-3'],
              participants: [
                ChatParticipantSummary(userId: 'user-1', displayName: 'Артем'),
                ChatParticipantSummary(
                  userId: 'user-2',
                  displayName: 'Андрей',
                ),
                ChatParticipantSummary(userId: 'user-3', displayName: 'Дарья'),
              ],
              branchRoots: [],
              treeId: 'tree-1',
            ),
          ),
        ),
      );
      chatService.emitMessages(const <ChatMessage>[]);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
    }

    await pumpChat();

    await tester.tap(find.text('Семья Кузнецовых').first);
    await tester.pumpAndSettle();
    // «Участники» у групп теперь выше — секция уведомлений уехала
    // глубже, скроллим сильнее.
    await tester.drag(find.byType(ListView).last, const Offset(0, -700));
    await tester.pumpAndSettle();

    expect(find.text('Уведомления'), findsOneWidget);

    final muteChip = find.widgetWithText(ChoiceChip, 'Выключены');
    await tester.ensureVisible(muteChip);
    await tester.pumpAndSettle();
    await tester.tap(muteChip, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(
      notificationSettingsStore.getSettings(
        SharedPreferencesChatNotificationSettingsStore.chatKey(
          'chat-group-1',
        ),
      ),
      completion(
        isA<ChatNotificationSettingsSnapshot>().having(
          (item) => item.level,
          'level',
          ChatNotificationLevel.muted,
        ),
      ),
    );
  });

  testWidgets('ChatScreen filters messages in local search mode',
      (tester) async {
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        const ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-1',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Сбор у дома в 19:00',
        timestamp: DateTime(2026, 4, 11, 10, 0),
        isRead: false,
        participants: const ['user-1', 'other-user'],
      ),
      ChatMessage(
        id: 'm-2',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Завтра принесем фотоальбом',
        timestamp: DateTime(2026, 4, 11, 10, 5),
        isRead: false,
        participants: const ['user-1', 'other-user'],
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Поиск по чату'));
    await tester.pumpAndSettle();
    final searchField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Поиск по сообщениям',
    );
    await tester.enterText(searchField, 'фото');
    await tester.pumpAndSettle();

    expect(find.text('Найдено 1 сообщение'), findsOneWidget);
    expect(find.text('Сбор у дома в 19:00'), findsNothing);
    expect(find.textContaining('Ничего не найдено'), findsNothing);
  });

  testWidgets('ChatScreen uses server-side message search results',
      (tester) async {
    final chatService = _FakeChatService(
      supportsServerSearch: true,
      serverSearchResults: [
        ChatMessageSearchResult(
          messageId: 'm-2',
          chatId: 'chat-1',
          senderId: 'other-user',
          senderName: 'Собеседник',
          snippet: 'Сервер нашёл это сообщение по вложению',
          matchedAt: DateTime(2026, 4, 11, 10, 5),
        ),
      ],
    );
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        const ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-1',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Сбор у дома в 19:00',
        timestamp: DateTime(2026, 4, 11, 10, 0),
        isRead: false,
        participants: const ['user-1', 'other-user'],
      ),
      ChatMessage(
        id: 'm-2',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Вложение без искомого слова',
        timestamp: DateTime(2026, 4, 11, 10, 5),
        isRead: false,
        participants: const ['user-1', 'other-user'],
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Поиск по чату'));
    await tester.pumpAndSettle();
    final searchField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Поиск по сообщениям',
    );
    await tester.enterText(searchField, 'архив');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(chatService.searchQueries, contains('архив'));
    expect(chatService.lastSearchChatId, 'chat-1');
    expect(find.text('Найдено 1 сообщение'), findsOneWidget);
    expect(
      find.text('Вложение без искомого слова', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Сбор у дома в 19:00'), findsNothing);
    expect(find.textContaining('Ничего не найдено'), findsNothing);
  });

  testWidgets('ChatScreen shows unread divider for unread incoming messages',
      (tester) async {
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        const ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-2',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Непрочитанное сообщение',
        timestamp: DateTime(2026, 4, 11, 10, 0),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Собеседник',
      ),
      ChatMessage(
        id: 'm-1',
        chatId: 'chat-1',
        senderId: 'user-1',
        text: 'Моё сообщение',
        timestamp: DateTime(2026, 4, 11, 9, 55),
        isRead: true,
        participants: const ['user-1', 'other-user'],
        senderName: 'Артем',
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Непрочитанные'), findsOneWidget);
  });

  testWidgets('ChatScreen shows jump-to-latest button after scrolling',
      (tester) async {
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        const ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
        ),
      ),
    );

    chatService.emitMessages(List<ChatMessage>.generate(
      24,
      (index) => ChatMessage(
        id: 'm-$index',
        chatId: 'chat-1',
        senderId: index.isEven ? 'user-1' : 'other-user',
        text: 'Сообщение $index',
        timestamp: DateTime(2026, 4, 11, 10, index),
        isRead: true,
        participants: const ['user-1', 'other-user'],
        senderName: index.isEven ? 'Артем' : 'Собеседник',
      ),
    ));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView).first, const Offset(0, 500));
    await tester.pumpAndSettle();

    expect(find.byTooltip('К последним сообщениям'), findsOneWidget);

    await tester.tap(find.byTooltip('К последним сообщениям'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('К последним сообщениям'), findsNothing);
  });

  testWidgets(
      'G: бейдж «новые снизу» на jump-FAB — входящее при отскролле '
      'считается, свои и возврат вниз сбрасывают', (tester) async {
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        const ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
        ),
      ),
    );

    final history = List<ChatMessage>.generate(
      24,
      (index) => ChatMessage(
        id: 'm-$index',
        chatId: 'chat-1',
        senderId: index.isEven ? 'user-1' : 'other-user',
        text: 'Сообщение $index',
        timestamp: DateTime(2026, 4, 11, 10, index),
        isRead: true,
        participants: const ['user-1', 'other-user'],
        senderName: index.isEven ? 'Артем' : 'Собеседник',
      ),
    );
    chatService.emitMessages(history);
    await tester.pumpAndSettle();

    // Отскроллились вверх — FAB виден, бейджа ещё нет.
    await tester.drag(find.byType(ListView).first, const Offset(0, 500));
    await tester.pumpAndSettle();
    expect(find.byTooltip('К последним сообщениям'), findsOneWidget);
    expect(find.byType(Badge), findsOneWidget);
    expect((tester.widget<Badge>(find.byType(Badge))).isLabelVisible, isFalse);

    // Пришло входящее, пока мы наверху → бейдж «1».
    chatService.emitMessages([
      ...history,
      ChatMessage(
        id: 'm-new-1',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Новое сообщение',
        timestamp: DateTime(2026, 4, 11, 11, 0),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Собеседник',
      ),
    ]);
    await tester.pumpAndSettle();
    expect((tester.widget<Badge>(find.byType(Badge))).isLabelVisible, isTrue);
    expect(find.text('1'), findsOneWidget);

    // Тап по FAB — вниз, бейдж и FAB исчезают.
    await tester.tap(find.byTooltip('К последним сообщениям'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('К последним сообщениям'), findsNothing);
  });

  testWidgets('ChatScreen lets user reply to a message with quote preview',
      (tester) async {
    final chatService = _FakeChatService();
    final draftStore = _MemoryChatDraftStore();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: draftStore,
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-1',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Сбор у дома в 19:00',
        timestamp: DateTime(2026, 4, 11, 10, 0),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Собеседник',
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Сбор у дома в 19:00'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ответить'));
    await tester.pumpAndSettle();

    expect(find.text('Ответ: Собеседник'), findsOneWidget);
    expect(find.text('Сбор у дома в 19:00'), findsWidgets);

    await tester.enterText(find.byType(TextField), 'Подтверждаю');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(chatService.lastReplyTo?.messageId, 'm-1');
    expect(find.text('Собеседник'), findsWidgets);
    expect(find.text('Подтверждаю'), findsOneWidget);
    // S4: завершаем отправку — иначе send-timeout остаётся pending Timer.
    chatService.sendCompleter.complete();
    await tester.pump();
  });

  testWidgets('ChatScreen keeps reply quote card compact', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-reply',
        chatId: 'chat-1',
        senderId: 'user-1',
        text: 'Готово',
        timestamp: DateTime(2026, 4, 11, 12),
        isRead: true,
        participants: const ['user-1', 'other-user'],
        senderName: 'Dev User',
        replyTo: const ChatReplyReference(
          messageId: 'm-origin',
          senderId: 'other-user',
          senderName: 'Собеседник',
          text: 'Да',
        ),
      ),
    ]);
    await tester.pumpAndSettle();

    final quoteSize = tester.getSize(
      find.byKey(const ValueKey<String>('chat-reply-quote-card')),
    );

    expect(quoteSize.width, lessThanOrEqualTo(370));
  });

  testWidgets('ChatScreen opens direct chat from group message actions',
      (tester) async {
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);
    String? openedChatId;
    String? openedTitle;
    String? openedOtherUserId;

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-group-1',
          chatType: 'group',
          title: 'Группа',
          draftStore: _MemoryChatDraftStore(),
          onOpenDirectChat: ({
            required chatId,
            required title,
            photoUrl,
            otherUserId,
          }) {
            openedChatId = chatId;
            openedTitle = title;
            openedOtherUserId = otherUserId;
          },
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-group',
        chatId: 'chat-group-1',
        senderId: 'user-2',
        text: 'Привет в группе',
        timestamp: DateTime(2026, 4, 11, 12),
        isRead: false,
        participants: const ['user-1', 'user-2', 'user-3'],
        senderName: 'Андрей',
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Привет в группе'));
    await tester.pumpAndSettle();
    expect(find.text('Написать в личку'), findsOneWidget);

    await tester.tap(find.text('Написать в личку'));
    await tester.pumpAndSettle();

    expect(chatService.getOrCreateChatCalls, ['user-2']);
    expect(openedChatId, 'chat-1');
    expect(openedTitle, 'Андрей');
    expect(openedOtherUserId, 'user-2');
  });

  testWidgets('ChatScreen forwards message attachments through composer',
      (tester) async {
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-1',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Перешли, пожалуйста, это фото',
        timestamp: DateTime(2026, 4, 11, 10, 0),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Собеседник',
        attachments: const [
          ChatAttachment(
            type: ChatAttachmentType.image,
            url: 'https://example.com/photo.jpg',
            fileName: 'photo.jpg',
          ),
        ],
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Перешли, пожалуйста, это фото'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Переслать'));
    await tester.pumpAndSettle();

    expect(find.text('Пересылаете: Собеседник'), findsOneWidget);
    expect(find.text('1 вложение'), findsOneWidget);

    await tester.tap(find.byTooltip('Отправить'));
    await tester.pump();

    expect(chatService.lastForwardedAttachments, hasLength(1));
    expect(
      chatService.lastForwardedAttachments.first.url,
      'https://example.com/photo.jpg',
    );
    // S4: завершаем отправку — иначе send-timeout остаётся pending Timer.
    chatService.sendCompleter.complete();
    await tester.pump();
  });

  testWidgets('ChatScreen edits own remote message through composer',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-own-1',
        chatId: 'chat-1',
        senderId: 'user-1',
        text: 'Старый текст',
        timestamp: DateTime(2026, 4, 11, 10, 0),
        isRead: true,
        participants: const ['user-1', 'other-user'],
        senderName: 'Артем',
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Старый текст'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Редактировать'));
    await tester.pumpAndSettle();

    expect(find.text('Редактируете сообщение'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Исправленный текст');
    await tester.pump();
    await tester.tap(find.byTooltip('Сохранить изменения'));
    await tester.pumpAndSettle();

    expect(chatService.lastEditedMessageId, 'm-own-1');
    expect(chatService.lastEditedText, 'Исправленный текст');
    expect(find.text('Редактируете сообщение'), findsNothing);
  });

  testWidgets('ChatScreen deletes own remote message after confirmation',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-own-2',
        chatId: 'chat-1',
        senderId: 'user-1',
        text: 'Удаляемое сообщение',
        timestamp: DateTime(2026, 4, 11, 10, 5),
        isRead: true,
        participants: const ['user-1', 'other-user'],
        senderName: 'Артем',
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Удаляемое сообщение'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить сообщение'));
    await tester.pumpAndSettle();

    expect(find.text('Это действие нельзя отменить.'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
    await tester.pumpAndSettle();

    expect(chatService.lastDeletedMessageId, 'm-own-2');
  });

  testWidgets('ChatScreen pins message and restores pinned banner',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chatService = _FakeChatService();
    final pinStore = _MemoryChatPinStore();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    Future<void> pumpChat() async {
      await tester.pumpWidget(
        buildChatApp(
          ChatScreen(
            chatId: 'chat-1',
            title: 'Тестовый чат',
            draftStore: _MemoryChatDraftStore(),
            pinStore: pinStore,
          ),
        ),
      );
      chatService.emitMessages([
        ChatMessage(
          id: 'm-pin-1',
          chatId: 'chat-1',
          senderId: 'other-user',
          text: 'Сохрани это сообщение сверху',
          timestamp: DateTime(2026, 4, 11, 11, 0),
          isRead: false,
          participants: const ['user-1', 'other-user'],
          senderName: 'Собеседник',
        ),
      ]);
      await tester.pumpAndSettle();
    }

    await pumpChat();

    await tester.longPress(find.text('Сохрани это сообщение сверху'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Закрепить'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('pinned-message-banner')), findsOneWidget);
    expect(find.text('Собеседник'), findsWidgets);

    await pumpChat();

    expect(find.byKey(const ValueKey<String>('pinned-message-banner')), findsOneWidget);
    expect(find.text('Сохрани это сообщение сверху'), findsWidgets);
  });

  testWidgets('ChatScreen unpins message from action sheet', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chatService = _FakeChatService();
    final pinStore = _MemoryChatPinStore();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
          pinStore: pinStore,
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-pin-2',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Временный pin',
        timestamp: DateTime(2026, 4, 11, 11, 5),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Собеседник',
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Временный pin'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Закрепить'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('pinned-message-banner')), findsOneWidget);

    await tester.longPress(find.text('Временный pin').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Открепить'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('pinned-message-banner')), findsNothing);
  });

  testWidgets('ChatScreen jumps to original message from reply quote',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
          pinStore: _MemoryChatPinStore(),
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-reply',
        chatId: 'chat-1',
        senderId: 'user-1',
        text: 'Ответ на старое сообщение',
        timestamp: DateTime(2026, 4, 11, 12),
        isRead: true,
        participants: const ['user-1', 'other-user'],
        senderName: 'Dev User',
        replyTo: const ChatReplyReference(
          messageId: 'm-origin',
          senderId: 'other-user',
          senderName: 'Собеседник',
          text: 'Цитата цели',
        ),
      ),
      for (var index = 0; index < 36; index++)
        ChatMessage(
          id: 'm-fill-$index',
          chatId: 'chat-1',
          senderId: index.isEven ? 'user-1' : 'other-user',
          text: 'Промежуточное сообщение $index',
          timestamp: DateTime(2026, 4, 11, 11, 59 - index),
          isRead: true,
          participants: const ['user-1', 'other-user'],
          senderName: index.isEven ? 'Dev User' : 'Собеседник',
        ),
      ChatMessage(
        id: 'm-origin',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Целевой оригинал для перехода',
        timestamp: DateTime(2026, 4, 11, 10),
        isRead: true,
        participants: const ['user-1', 'other-user'],
        senderName: 'Собеседник',
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Цитата цели'), findsOneWidget);
    expect(find.text('Целевой оригинал для перехода'), findsNothing);

    await tester.tap(find.text('Цитата цели'));
    await tester.pumpAndSettle();

    expect(find.text('Целевой оригинал для перехода'), findsOneWidget);
  });

  testWidgets('ChatScreen toggles server-synced message reactions',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    Future<void> pumpChat() async {
      await tester.pumpWidget(
        buildChatApp(
          ChatScreen(
            chatId: 'chat-1',
            title: 'Тестовый чат',
            draftStore: _MemoryChatDraftStore(),
            pinStore: _MemoryChatPinStore(),
          ),
        ),
      );
      chatService.emitMessages([
        ChatMessage(
          id: 'm-react-1',
          chatId: 'chat-1',
          senderId: 'other-user',
          text: 'Отметь реакцией',
          timestamp: DateTime(2026, 4, 11, 12, 0),
          isRead: false,
          participants: const ['user-1', 'other-user'],
          senderName: 'Собеседник',
        ),
      ]);
      await tester.pumpAndSettle();
    }

    await pumpChat();

    await tester.longPress(find.text('Отметь реакцией'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '👍'));
    await tester.pumpAndSettle();

    expect(chatService.lastReactionMessageId, 'm-react-1');
    expect(chatService.lastReactionEmoji, '👍');
    expect(find.text('👍 1'), findsOneWidget);

    await pumpChat();
    chatService.emitMessages([
      ChatMessage(
        id: 'm-react-1',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Отметь реакцией',
        timestamp: DateTime(2026, 4, 11, 12, 0),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Собеседник',
        reactions: const [
          ChatMessageReactionSummary(
            emoji: '👍',
            userIds: ['user-1'],
            count: 1,
          ),
        ],
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('👍 1'), findsOneWidget);
  });

  testWidgets('ChatScreen copies selected messages as transcript',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? clipboardText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText =
            (call.arguments as Map<Object?, Object?>)['text'] as String?;
        return null;
      }
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': clipboardText};
      }
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-copy-1',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'сдэк еще не пришел ?',
        timestamp: DateTime(2026, 4, 8, 9, 19),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Анастасия<3',
      ),
      ChatMessage(
        id: 'm-copy-2',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Катя',
        timestamp: DateTime(2026, 4, 8, 9, 20),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Анастасия<3',
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('сдэк еще не пришел ?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбрать'));
    await tester.pumpAndSettle();

    expect(find.text('Выбрано: 1'), findsOneWidget);

    await tester.tap(find.text('Катя'));
    await tester.pumpAndSettle();

    expect(find.text('Выбрано: 2'), findsOneWidget);

    await tester.tap(find.byTooltip('Скопировать выбранное'));
    await tester.pumpAndSettle();

    expect(
      clipboardText,
      '[08.04.2026 9:19] Анастасия<3: сдэк еще не пришел ?\n'
      '[08.04.2026 9:20] Анастасия<3: Катя',
    );
  });

  testWidgets('ChatScreen opens attachment gallery for remote files',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-file-1',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Первый документ',
        timestamp: DateTime(2026, 4, 8, 9, 19),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Анастасия<3',
        attachments: const [
          ChatAttachment(
            type: ChatAttachmentType.file,
            url: 'https://example.com/contract.pdf',
            fileName: 'contract.pdf',
          ),
        ],
      ),
      ChatMessage(
        id: 'm-file-2',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Второй документ',
        timestamp: DateTime(2026, 4, 8, 9, 21),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Анастасия<3',
        attachments: const [
          ChatAttachment(
            type: ChatAttachmentType.file,
            url: 'https://example.com/notes.pdf',
            fileName: 'notes.pdf',
          ),
        ],
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('contract.pdf'));
    await tester.pumpAndSettle();

    expect(find.text('contract.pdf'), findsAtLeastNWidgets(1));
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text('Анастасия<3 • 08.04.2026 9:19'), findsAtLeastNWidgets(1));
    expect(find.text('Первый документ'), findsAtLeastNWidgets(1));
    expect(find.byIcon(Icons.open_in_new), findsOneWidget);
    expect(find.byIcon(Icons.file_download_outlined), findsOneWidget);

    await tester.tap(find.byTooltip('Следующее вложение'));
    await tester.pumpAndSettle();

    expect(find.text('notes.pdf'), findsAtLeastNWidgets(1));
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text('Второй документ'), findsAtLeastNWidgets(1));
  });

  testWidgets(
      'C1: записанное голосовое рендерится как voice-player, не как файл-тайл',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-voice-1',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: '',
        timestamp: DateTime(2026, 4, 8, 9, 25),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Анастасия<3',
        attachments: const [
          ChatAttachment(
            type: ChatAttachmentType.audio,
            presentation: ChatAttachmentPresentation.voiceNote,
            url: 'https://example.com/voice_note_5s_1.m4a',
            fileName: 'voice_note_5s_1.m4a',
            durationMs: 5000,
            waveform: [0.2, 0.6, 0.9, 0.4, 0.7],
          ),
        ],
      ),
    ]);
    await tester.pumpAndSettle();

    // Бабл — это voice-player (его уникальный tooltip), а не файл-тайл
    // с именем voice_note_*.m4a, который при тапе уходил бы в исключённый
    // для аудио просмотрщик.
    expect(
      find.byTooltip('Воспроизвести голосовое сообщение'),
      findsOneWidget,
    );
    expect(find.text('voice_note_5s_1.m4a'), findsNothing);
    // Ленивый плеер: простой рендер бабла не трогает плагин audioplayers.
    expect(tester.takeException(), isNull);
  });

  testWidgets('C2: recording-бар показывает живую волну по амплитуде',
      (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('chat_bar_test');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    PathProviderPlatform.instance = _FakeBarPathProvider(tempDir.path);

    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    final recorder = _FakeRecorderForBar();
    final recordingController = ChatRecordingController(
      recorder: recorder,
      permissionRequester: () async => true,
    );
    addTearDown(recordingController.dispose);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
          recordingController: recordingController,
        ),
      ),
    );
    chatService.emitMessages(const <ChatMessage>[]);
    await tester.pumpAndSettle();

    // Запускаем запись напрямую через внедрённый контроллер. start()
    // делает реальный async (path_provider/File) — в testWidgets его надо
    // гонять через runAsync, иначе он не завершится. pumpAndSettle нельзя
    // — пульсация бара бесконечная.
    await tester.runAsync(() => recordingController.start());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Пока замеров нет — показывается подсказка про жесты.
    expect(find.text('← отмена  ↑ фиксация'), findsOneWidget);
    expect(find.byKey(const Key('recording-live-waveform')), findsNothing);

    // Пришли амплитуды → бар рисует живую волну.
    await tester.runAsync(() async {
      recorder.pushAmplitude(-10);
      recorder.pushAmplitude(-4);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();

    expect(find.byKey(const Key('recording-live-waveform')), findsOneWidget);
    expect(find.text('← отмена  ↑ фиксация'), findsNothing);

    await tester.runAsync(() => recordingController.cancelCurrent());
    await tester.pump();
  });

  testWidgets('C2: тап по кружку играет видео inline, не открывая просмотрщик',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform();

    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-note-1',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: '',
        timestamp: DateTime(2026, 4, 8, 9, 30),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Анастасия<3',
        attachments: const [
          ChatAttachment(
            type: ChatAttachmentType.video,
            presentation: ChatAttachmentPresentation.videoNote,
            url: 'https://example.com/video_note_3s_1.mp4',
            fileName: 'video_note_3s_1.mp4',
            thumbnailUrl: 'https://example.com/thumb.jpg',
            durationMs: 3000,
          ),
        ],
      ),
    ]);
    await tester.pumpAndSettle();

    // До тапа — статичная превью-кнопка кружка, инлайн-плеера ещё нет.
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byKey(const Key('video-note-inline-player')), findsNothing);

    // Тап играет на месте: появляется инлайн-плеер, просмотрщик НЕ
    // открывается (pumpAndSettle нельзя — у плеера бесконечный спиннер).
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();

    expect(find.byKey(const Key('video-note-inline-player')), findsOneWidget);
    // Превью-кнопка ушла (кружок переключился в плеер), и просмотрщик не
    // открылся. open_in_new — безусловная иконка вьюера (в отличие от
    // download, который зависит от supportsChatAttachmentDownload), так
    // что её отсутствие — надёжный признак, что перехода во вьюер не было.
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(find.byIcon(Icons.open_in_new), findsNothing);
  });

  testWidgets(
      'C2c: сбой инициализации кружка показывает error-affordance, не спиннер',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform(failInit: true);

    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
        ),
      ),
    );
    chatService.emitMessages([
      ChatMessage(
        id: 'm-note-err',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: '',
        timestamp: DateTime(2026, 4, 8, 9, 31),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Анастасия<3',
        attachments: const [
          ChatAttachment(
            type: ChatAttachmentType.video,
            presentation: ChatAttachmentPresentation.videoNote,
            url: 'https://example.com/broken.mp4',
            fileName: 'video_note_broken.mp4',
            thumbnailUrl: 'https://example.com/thumb.jpg',
            durationMs: 3000,
          ),
        ],
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // Affordance ошибки (с повтором по тапу), а не вечный спиннер.
    expect(find.byKey(const Key('video-note-error')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets(
      'C2c: тап по второму кружку ставит первый на паузу (one-at-a-time)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final platform = _FakeVideoPlayerPlatform(completeInit: true);
    VideoPlayerPlatform.instance = platform;

    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
        ),
      ),
    );
    chatService.emitMessages([
      ChatMessage(
        id: 'm-notes-two',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: '',
        timestamp: DateTime(2026, 4, 8, 9, 32),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Анастасия<3',
        attachments: const [
          ChatAttachment(
            type: ChatAttachmentType.video,
            presentation: ChatAttachmentPresentation.videoNote,
            url: 'https://example.com/note_a.mp4',
            fileName: 'video_note_a.mp4',
            thumbnailUrl: 'https://example.com/a.jpg',
            durationMs: 3000,
          ),
          ChatAttachment(
            type: ChatAttachmentType.video,
            presentation: ChatAttachmentPresentation.videoNote,
            url: 'https://example.com/note_b.mp4',
            fileName: 'video_note_b.mp4',
            thumbnailUrl: 'https://example.com/b.jpg',
            durationMs: 3000,
          ),
        ],
      ),
    ]);
    await tester.pumpAndSettle();

    // Два кружка-превью.
    expect(find.byIcon(Icons.play_arrow_rounded), findsNWidgets(2));

    // Тап по первому → играет (player 1). pumpAndSettle нельзя — у
    // играющего video_player крутится таймер позиции; гоняем кадры руками.
    await tester.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // Остался один превью-кружок (второй) — первый уже в плеере.
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    // Тап по второму → играет (player 2), реестр паузит первого.
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(platform.calls, contains('play:1'));
    expect(platform.calls, contains('play:2'));
    // Ключевое: первый кружок поставлен на паузу ПОСЛЕ того, как заиграл
    // (это и есть one-at-a-time от реестра; video_player ещё дёргает
    // pause в собственном setup, поэтому проверяем именно порядок).
    final play1Index = platform.calls.indexOf('play:1');
    final pause1AfterPlay = platform.calls.lastIndexOf('pause:1');
    expect(play1Index, isNonNegative);
    expect(pause1AfterPlay, greaterThan(play1Index),
        reason: 'старт второго кружка обязан поставить первый на паузу');
  });

  testWidgets(
      'C2c: после dispose первого кружка реестр чист — второй играет без ошибки',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform(completeInit: true);

    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
        ),
      ),
    );

    ChatMessage videoNoteMessage(String id, String url, int minute) =>
        ChatMessage(
          id: id,
          chatId: 'chat-1',
          senderId: 'other-user',
          text: '',
          timestamp: DateTime(2026, 4, 8, 9, minute),
          isRead: false,
          participants: const ['user-1', 'other-user'],
          senderName: 'Анастасия<3',
          attachments: [
            ChatAttachment(
              type: ChatAttachmentType.video,
              presentation: ChatAttachmentPresentation.videoNote,
              url: url,
              fileName: '${id}_note.mp4',
              thumbnailUrl: 'https://example.com/$id.jpg',
              durationMs: 3000,
            ),
          ],
        );

    final noteA = videoNoteMessage('m-a', 'https://example.com/a.mp4', 30);
    final noteB = videoNoteMessage('m-b', 'https://example.com/b.mp4', 31);
    chatService.emitMessages([noteA, noteB]);
    await tester.pumpAndSettle();

    // Играем A (player 1).
    await tester.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // Убираем сообщение A → его кружок размонтируется (dispose → resign
    // чистит реестр; до фикса identical-over-tear-off реестр оставлял
    // ссылку на disposed-контроллер).
    chatService.emitMessages([noteB]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Играем B — стейл-колбэк к disposed A не должен сорвать запуск.
    await tester.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('video-note-error')), findsNothing);
    expect(find.byKey(const Key('video-note-inline-player')), findsOneWidget);
  });

  testWidgets('ChatScreen forwards selected messages as a batch',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chatService = _FakeChatService();
    chatService.sendCompleter.complete();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-forward-1',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Первое выбранное сообщение',
        timestamp: DateTime(2026, 4, 8, 9, 19),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Анастасия<3',
      ),
      ChatMessage(
        id: 'm-forward-2',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Второе выбранное сообщение',
        timestamp: DateTime(2026, 4, 8, 9, 20),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Анастасия<3',
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Первое выбранное сообщение'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбрать'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Второе выбранное сообщение'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Переслать выбранное'));
    await tester.pumpAndSettle();

    expect(find.text('Пересылаете 2 сообщений'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(chatService.sentRequests, hasLength(2));
    expect(
      chatService.sentRequests.map((request) => request.text),
      ['Первое выбранное сообщение', 'Второе выбранное сообщение'],
    );
    expect(find.text('Пересылаете 2 сообщений'), findsNothing);
  });

  testWidgets('ChatScreen deletes selected own messages', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
          draftStore: _MemoryChatDraftStore(),
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-delete-1',
        chatId: 'chat-1',
        senderId: 'user-1',
        text: 'Моё первое сообщение',
        timestamp: DateTime(2026, 4, 8, 9, 19),
        isRead: true,
        participants: const ['user-1', 'other-user'],
        senderName: 'Tema Kuznetsov',
      ),
      ChatMessage(
        id: 'm-delete-2',
        chatId: 'chat-1',
        senderId: 'user-1',
        text: 'Моё второе сообщение',
        timestamp: DateTime(2026, 4, 8, 9, 20),
        isRead: true,
        participants: const ['user-1', 'other-user'],
        senderName: 'Tema Kuznetsov',
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Моё первое сообщение'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбрать'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Моё второе сообщение'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Удалить выбранное'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
    await tester.pumpAndSettle();

    expect(chatService.deletedMessageIds, ['m-delete-1', 'm-delete-2']);
  });

  testWidgets(
      'ChatScreen opens desktop context popover on right click instead of bottom sheet',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      buildChatApp(
        Theme(
          data: ThemeData(platform: TargetPlatform.windows),
          child: ChatScreen(
            chatId: 'chat-1',
            title: 'Тестовый чат',
            draftStore: _MemoryChatDraftStore(),
          ),
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'm-desktop-1',
        chatId: 'chat-1',
        senderId: 'other-user',
        text: 'Контекст на ПК',
        timestamp: DateTime(2026, 4, 11, 12, 30),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Собеседник',
      ),
    ]);
    await tester.pumpAndSettle();

    final target = find.text('Контекст на ПК');
    final position = tester.getCenter(target);
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: position);
    await tester.pump();
    await gesture.down(position);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Ответить'), findsOneWidget);
    expect(find.text('Переслать'), findsOneWidget);
    expect(find.text('Копировать текст'), findsOneWidget);
    expect(find.text('👍'), findsOneWidget);
  });

  testWidgets('ChatScreen blocks direct peer from message actions',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chatService = _FakeChatService()
      ..details = const ChatDetails(
        chatId: 'chat-direct-1',
        type: 'direct',
        title: null,
        participantIds: ['user-1', 'other-user'],
        participants: [
          ChatParticipantSummary(
              userId: 'other-user', displayName: 'Собеседник'),
        ],
        branchRoots: [],
      );
    final safetyService = _FakeSafetyService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);
    getIt.registerSingleton<SafetyServiceInterface>(safetyService);

    await tester.pumpWidget(
      buildChatApp(
        ChatScreen(
          chatId: 'chat-direct-1',
          otherUserId: 'other-user',
          title: 'Собеседник',
          chatType: 'direct',
          draftStore: _MemoryChatDraftStore(),
        ),
      ),
    );

    chatService.emitMessages([
      ChatMessage(
        id: 'msg-remote-1',
        chatId: 'chat-direct-1',
        senderId: 'other-user',
        text: 'Напиши позже',
        timestamp: DateTime(2026, 4, 12, 10, 15),
        isRead: false,
        participants: const ['user-1', 'other-user'],
        senderName: 'Собеседник',
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Напиши позже'));
    await tester.pumpAndSettle();

    expect(find.text('Пожаловаться'), findsOneWidget);
    expect(find.text('Заблокировать'), findsOneWidget);

    await tester.ensureVisible(find.text('Заблокировать'));
    await tester.tap(find.text('Заблокировать'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Спам'));
    await tester.tap(find.text('Спам'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Продолжить'));
    await tester.pumpAndSettle();

    expect(safetyService.lastBlockedUserId, 'other-user');
    expect(find.text('Список блокировок'), findsOneWidget);
    expect(find.text('Сообщение...'), findsNothing);
  });
}

/// C2: фейковый рекордер для виджет-теста живой волны recording-бара.
class _FakeRecorderForBar implements AudioRecorder {
  final StreamController<Amplitude> _amp =
      StreamController<Amplitude>.broadcast();

  @override
  Future<void> start(RecordConfig config, {required String path}) async {}

  @override
  Future<String?> stop() async => null;

  @override
  Future<void> cancel() async {}

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) => _amp.stream;

  @override
  Future<void> dispose() async {
    await _amp.close();
  }

  void pushAmplitude(double current) {
    _amp.add(Amplitude(current: current, max: 0));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBarPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakeBarPathProvider(this.tempPath);

  final String tempPath;

  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

/// C2: минимальный фейк video_player для inline-кружка. initialize()
/// остаётся в «загрузке» (videoEventsFor не эмитит) — этого хватает,
/// чтобы _VideoNotePlayer отрисовался без падения на плагине; тест
/// проверяет именно подмену перехода в просмотрщик на inline-плеер.
class _FakeVideoPlayerPlatform extends VideoPlayerPlatform
    with MockPlatformInterfaceMixin {
  _FakeVideoPlayerPlatform({this.completeInit = false, this.failInit = false});

  /// Эмитить ли событие initialized (тогда initialize() завершится и
  /// пойдёт цепочка .then → activate/play). Для теста one-at-a-time.
  final bool completeInit;

  /// Кидать ли на create — initialize() зареджектится → error-UI.
  final bool failInit;

  int _nextId = 0;
  final Map<int, StreamController<VideoEvent>> _events = {};

  /// Лог вызовов play/pause по playerId — для проверки one-at-a-time.
  final List<String> calls = <String>[];

  Future<int?> _create() async {
    if (failInit) {
      throw PlatformException(code: 'init', message: 'boom');
    }
    final id = ++_nextId;
    _events[id] = StreamController<VideoEvent>.broadcast();
    return id;
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose(int playerId) async {
    await _events[playerId]?.close();
    _events.remove(playerId);
  }

  @override
  Future<int?> create(DataSource dataSource) => _create();

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) => _create();

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    final controller =
        _events[playerId] ??= StreamController<VideoEvent>.broadcast();
    if (completeInit) {
      scheduleMicrotask(() {
        if (!controller.isClosed) {
          controller.add(VideoEvent(
            eventType: VideoEventType.initialized,
            duration: const Duration(seconds: 3),
            size: const Size(320, 320),
          ));
        }
      });
    }
    return controller.stream;
  }

  @override
  Widget buildView(int playerId) => const SizedBox.shrink();

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async {
    calls.add('play:$playerId');
  }

  @override
  Future<void> pause(int playerId) async {
    calls.add('pause:$playerId');
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
}
