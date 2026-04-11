import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:lineage/backend/interfaces/chat_service_interface.dart';
import 'package:lineage/models/chat_attachment.dart';
import 'package:lineage/models/chat_details.dart';
import 'package:lineage/models/chat_message.dart';
import 'package:lineage/models/chat_preview.dart';
import 'package:lineage/models/chat_send_progress.dart';
import 'package:lineage/models/family_tree.dart';
import 'package:lineage/providers/tree_provider.dart';
import 'package:lineage/screens/chat_screen.dart';
import 'package:lineage/services/chat_auto_delete_store.dart';
import 'package:lineage/services/chat_draft_store.dart';
import 'package:lineage/services/chat_notification_settings_store.dart';
import 'package:lineage/services/chat_pin_store.dart';
import 'package:lineage/services/chat_reaction_store.dart';
import 'package:lineage/services/local_storage_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class _MemoryChatReactionStore implements ChatReactionStore {
  final Map<String, ChatReactionCatalogSnapshot> _catalogs =
      <String, ChatReactionCatalogSnapshot>{};

  @override
  Future<void> clearCatalog(String key) async {
    _catalogs.remove(key);
  }

  @override
  Future<ChatReactionCatalogSnapshot?> getCatalog(String key) async {
    return _catalogs[key];
  }

  @override
  Future<void> saveCatalog(
      String key, ChatReactionCatalogSnapshot snapshot) async {
    _catalogs[key] = snapshot;
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
  final Completer<void> sendCompleter = Completer<void>();
  final StreamController<List<ChatMessage>> _messagesController =
      StreamController<List<ChatMessage>>.broadcast();
  final List<_SentChatRequest> sentRequests = <_SentChatRequest>[];
  ChatReplyReference? lastReplyTo;
  List<ChatAttachment> lastForwardedAttachments = const <ChatAttachment>[];
  String? lastEditedMessageId;
  String? lastEditedText;
  String? lastDeletedMessageId;
  final List<String> deletedMessageIds = <String>[];
  String? lastClientMessageId;
  int? lastExpiresInSeconds;
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
  Future<String?> getOrCreateChat(String otherUserId) async => 'chat-1';

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

  void emitMessages(List<ChatMessage> messages) {
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
    getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
  });

  tearDown(() async {
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

  testWidgets('ChatScreen lets user choose video attachment from picker sheet',
      (tester) async {
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

    await tester.tap(find.byTooltip('О чате'));
    await tester.pumpAndSettle();

    expect(find.text('О чате'), findsOneWidget);
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

    await tester.tap(find.byTooltip('О чате'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, -400));
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

    expect(find.text('Закрепленное сообщение'), findsOneWidget);
    expect(find.text('Собеседник'), findsWidgets);

    await pumpChat();

    expect(find.text('Закрепленное сообщение'), findsOneWidget);
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

    expect(find.text('Закрепленное сообщение'), findsOneWidget);

    await tester.longPress(find.text('Временный pin').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Открепить'));
    await tester.pumpAndSettle();

    expect(find.text('Закрепленное сообщение'), findsNothing);
  });

  testWidgets('ChatScreen adds reaction and restores it after reopen',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chatService = _FakeChatService();
    final reactionStore = _MemoryChatReactionStore();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    Future<void> pumpChat() async {
      await tester.pumpWidget(
        buildChatApp(
          ChatScreen(
            chatId: 'chat-1',
            title: 'Тестовый чат',
            draftStore: _MemoryChatDraftStore(),
            pinStore: _MemoryChatPinStore(),
            reactionStore: reactionStore,
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

    expect(find.text('👍 1'), findsOneWidget);

    await pumpChat();

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

  testWidgets('ChatScreen opens attachment viewer for remote file',
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
        text: '',
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
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('contract.pdf'));
    await tester.pumpAndSettle();

    expect(find.text('contract.pdf'), findsAtLeastNWidgets(1));
    expect(find.byIcon(Icons.open_in_new), findsOneWidget);
    expect(find.byIcon(Icons.file_download_outlined), findsOneWidget);
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
}
