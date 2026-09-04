import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/backend/interfaces/chat_service_interface.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/models/chat_attachment.dart';
import 'package:rodnya/models/chat_details.dart';
import 'package:rodnya/models/chat_message.dart';
import 'package:rodnya/models/chat_message_search_result.dart';
import 'package:rodnya/models/chat_preview.dart';
import 'package:rodnya/models/chat_send_progress.dart';
import 'package:rodnya/models/family_person.dart';
import 'package:rodnya/models/family_relation.dart';
import 'package:rodnya/models/family_tree.dart';
import 'package:rodnya/providers/tree_provider.dart';
import 'package:rodnya/screens/chats_list_screen.dart';
import 'package:rodnya/services/app_status_service.dart';
import 'package:rodnya/services/chat_archive_store.dart';
import 'package:rodnya/services/chat_draft_suppression.dart';
import 'package:rodnya/services/chat_draft_store.dart';
import 'package:rodnya/services/chat_notification_settings_store.dart';
import 'package:rodnya/services/local_storage_service.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

class _FakeAuthService implements AuthServiceInterface {
  _FakeAuthService({this.userId = 'user-1'});

  final String? userId;

  @override
  String? get currentUserId => userId;

  @override
  String? get currentUserEmail => 'user@example.com';

  @override
  String? get currentUserDisplayName => 'Артем';

  @override
  String? get currentUserPhotoUrl => null;

  @override
  List<String> get currentProviderIds => const ['password'];

  @override
  Stream<String?> get authStateChanges => const Stream.empty();

  @override
  String describeError(Object error) => error.toString();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChatService implements ChatServiceInterface {
  List<String>? createdParticipantIds;
  List<String>? createdBranchRootPersonIds;
  String? createdTitle;
  List<ChatPreview> chatPreviews = const <ChatPreview>[];
  Stream<List<ChatPreview>>? chatPreviewsStreamOverride;

  @override
  String? get currentUserId => 'user-1';

  @override
  String buildChatId(String otherUserId) => 'chat-$otherUserId';

  @override
  Stream<List<ChatPreview>> getUserChatsStream(String userId) {
    return chatPreviewsStreamOverride ?? Stream.value(chatPreviews);
  }

  @override
  Stream<int> getTotalUnreadCountStream(String userId) {
    return Stream.value(0);
  }

  @override
  Stream<List<ChatMessage>> getMessagesStream(String chatId) {
    return Stream.value(const <ChatMessage>[]);
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
  }) async {}

  @override
  Future<void> sendTextMessage({
    required String otherUserId,
    required String text,
  }) async {}

  @override
  Future<void> markChatAsRead(String chatId, String userId) async {}

  @override
  Future<String?> getOrCreateChat(String otherUserId) async =>
      'chat-$otherUserId';

  @override
  Future<String?> createGroupChat({
    required List<String> participantIds,
    String? title,
    String? treeId,
  }) async {
    createdParticipantIds = List<String>.from(participantIds);
    createdTitle = title;
    return 'chat-group-1';
  }

  @override
  Future<String?> createBranchChat({
    required String treeId,
    required List<String> branchRootPersonIds,
    String? title,
  }) async {
    createdBranchRootPersonIds = List<String>.from(branchRootPersonIds);
    createdTitle = title;
    return 'chat-branch-1';
  }

  @override
  Future<ChatDetails> getChatDetails(String chatId) async => const ChatDetails(
        chatId: 'chat-group-1',
        type: 'group',
        title: 'Семья Кузнецовых',
        participantIds: ['user-1', 'user-2'],
        participants: [
          ChatParticipantSummary(userId: 'user-1', displayName: 'Артем'),
          ChatParticipantSummary(userId: 'user-2', displayName: 'Иван'),
        ],
        branchRoots: [],
      );

  @override
  Future<ChatDetails> renameGroupChat({
    required String chatId,
    required String title,
  }) async =>
      getChatDetails(chatId);

  @override
  Future<ChatDetails> updateGroupChatPhoto({
    required String chatId,
    required XFile photo,
  }) async =>
      getChatDetails(chatId);

  @override
  Future<ChatDetails> addGroupParticipants({
    required String chatId,
    required List<String> participantIds,
  }) async =>
      getChatDetails(chatId);

  @override
  Future<ChatDetails> removeGroupParticipant({
    required String chatId,
    required String participantId,
  }) async =>
      getChatDetails(chatId);

  @override
  Future<void> leaveGroup(String chatId) async {}

  @override
  Future<void> editChatMessage({
    required String chatId,
    required String messageId,
    required String text,
  }) async {}

  @override
  Future<void> deleteChatMessage({
    required String chatId,
    required String messageId,
  }) async {}

  @override
  Future<void> toggleMessageReaction({
    required String chatId,
    required String messageId,
    required String emoji,
  }) async {}

  @override
  Future<List<ChatMessageSearchResult>> searchMessages({
    required String query,
    String? chatId,
    int limit = 50,
  }) async =>
      const <ChatMessageSearchResult>[];
}

class _FakeFamilyTreeService extends Fake
    implements FamilyTreeServiceInterface {
  _FakeFamilyTreeService({
    this.getRelativesDelay,
    this.relativesOverride,
    this.relationsOverride,
  });

  final Future<void>? getRelativesDelay;

  /// When set, replaces the default 4 relatives — lets a test drive the
  /// empty participant/branch selectors (B recovery CTAs).
  final List<FamilyPerson>? relativesOverride;
  final List<FamilyRelation>? relationsOverride;
  int getRelativesCallCount = 0;

  @override
  Future<List<FamilyPerson>> getRelatives(String treeId) async {
    getRelativesCallCount += 1;
    await getRelativesDelay;
    if (relativesOverride != null) return relativesOverride!;
    return [
      FamilyPerson(
        id: 'person-root-1',
        treeId: treeId,
        userId: 'user-root-1',
        name: 'Иван Кузнецов',
        gender: Gender.male,
        isAlive: true,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        relation: 'Отец',
      ),
      FamilyPerson(
        id: 'person-root-2',
        treeId: treeId,
        userId: 'user-root-2',
        name: 'Мария Понькина',
        gender: Gender.female,
        isAlive: true,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        relation: 'Сестра',
      ),
      FamilyPerson(
        id: 'person-child-1',
        treeId: treeId,
        userId: 'user-child-1',
        name: 'Олег Кузнецов',
        gender: Gender.male,
        isAlive: true,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        relation: 'Брат',
      ),
      FamilyPerson(
        id: 'person-child-2',
        treeId: treeId,
        userId: 'user-child-2',
        name: 'Катя Понькина',
        gender: Gender.female,
        isAlive: true,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        relation: 'Племянница',
      ),
    ];
  }

  @override
  Future<List<FamilyRelation>> getRelations(String treeId) async =>
      relationsOverride ??
      [
        FamilyRelation(
          id: 'rel-1',
          treeId: treeId,
          person1Id: 'person-root-1',
          person2Id: 'person-child-1',
          relation1to2: RelationType.parent,
          relation2to1: RelationType.child,
          isConfirmed: true,
          createdAt: DateTime(2026),
        ),
        FamilyRelation(
          id: 'rel-2',
          treeId: treeId,
          person1Id: 'person-root-2',
          person2Id: 'person-child-2',
          relation1to2: RelationType.parent,
          relation2to1: RelationType.child,
          isConfirmed: true,
          createdAt: DateTime(2026),
        ),
      ];

  @override
  Future<List<FamilyTree>> getUserTrees() async => const <FamilyTree>[];
}

class _FakeLocalStorageService extends Fake implements LocalStorageService {
  FamilyTree _treeFor(String treeId) {
    return FamilyTree(
      id: treeId,
      name: 'Семья Кузнецовых',
      description: '',
      creatorId: 'user-1',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      memberIds: const ['user-1', 'user-root-1', 'user-root-2'],
      isPrivate: true,
      members: const ['user-1', 'user-root-1', 'user-root-2'],
      kind: TreeKind.family,
    );
  }

  @override
  Future<List<FamilyTree>> getAllTrees() async {
    return <FamilyTree>[_treeFor('tree-1')];
  }

  @override
  Future<FamilyTree?> getTree(String treeId) async {
    return _treeFor(treeId);
  }
}

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

class _MemoryChatArchiveStore implements ChatArchiveStore {
  final Map<String, ChatArchiveSnapshot> _archived =
      <String, ChatArchiveSnapshot>{};

  @override
  Future<void> clearArchivedChat(String key) async {
    _archived.remove(key);
  }

  @override
  Future<Map<String, ChatArchiveSnapshot>> getAllArchivedChats() async {
    return Map<String, ChatArchiveSnapshot>.from(_archived);
  }

  @override
  Future<ChatArchiveSnapshot?> getArchivedChat(String key) async {
    return _archived[key];
  }

  @override
  Future<void> saveArchivedChat(
      String key, ChatArchiveSnapshot snapshot) async {
    _archived[key] = snapshot;
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

void main() {
  final getIt = GetIt.instance;

  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  setUp(() async {
    await getIt.reset();
    ChatDraftSuppression.instance.resetForTesting();
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
    getIt.registerSingleton<ChatServiceInterface>(_FakeChatService());
    getIt.registerSingleton<FamilyTreeServiceInterface>(
        _FakeFamilyTreeService());
    getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
    getIt.registerSingleton<AppStatusService>(AppStatusService());
  });

  tearDown(() async {
    await getIt.reset();
  });

  Widget buildApp({
    ChatDraftStore? draftStore,
    ChatArchiveStore? archiveStore,
    ChatNotificationSettingsStore? notificationSettingsStore,
  }) {
    final treeProvider = TreeProvider();
    treeProvider.selectTree(
      'tree-1',
      'Семья Кузнецовых',
      treeKind: TreeKind.family,
    );

    final router = GoRouter(
      initialLocation: '/chats',
      routes: [
        GoRoute(
          path: '/chats',
          builder: (context, state) => ChatsListScreen(
            draftStore: draftStore,
            archiveStore: archiveStore,
            notificationSettingsStore: notificationSettingsStore,
          ),
        ),
        GoRoute(
          path: '/chats/view/:chatId',
          builder: (context, state) => Text(state.uri.toString()),
        ),
        GoRoute(
          path: '/relatives',
          builder: (context, state) => const Text('relatives-screen'),
        ),
        GoRoute(
          path: '/tree',
          builder: (context, state) => const Text('tree-screen'),
        ),
        GoRoute(
          path: '/login',
          builder: (context, state) =>
              Text('login-screen:${state.uri.queryParameters['from'] ?? ''}'),
        ),
      ],
    );

    return ChangeNotifierProvider<TreeProvider>.value(
      value: treeProvider,
      child: MaterialApp.router(routerConfig: router),
    );
  }

  testWidgets('ChatsListScreen показывает CTA в пустом состоянии',
      (tester) async {
    await tester.pumpWidget(buildApp());

    await tester.pumpAndSettle();

    expect(find.text('Чатов нет'), findsOneWidget);
    expect(find.text('Создать чат'), findsOneWidget);
    expect(find.text('Родные'), findsOneWidget);
    expect(find.text('Дерево'), findsOneWidget);
  });

  testWidgets('Q3: topbar pill buttons have ≥48dp touch targets',
      (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // Поиск снова в топбаре (раскрывается на месте заголовка, как в
    // Telegram) — отдельной строки поиска под шапкой больше нет.
    for (final tip in const ['Поиск', 'Новый чат']) {
      final size = tester.getSize(find.byTooltip(tip));
      expect(size.width, greaterThanOrEqualTo(48.0), reason: tip);
      expect(size.height, greaterThanOrEqualTo(48.0), reason: tip);
    }
  });

  testWidgets(
    'ChatsListScreen предлагает войти снова после истечения сессии',
    (tester) async {
      await getIt.reset();
      getIt.registerSingleton<AuthServiceInterface>(
        _FakeAuthService(userId: null),
      );
      getIt.registerSingleton<ChatServiceInterface>(_FakeChatService());
      getIt.registerSingleton<FamilyTreeServiceInterface>(
        _FakeFamilyTreeService(),
      );
      getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
      getIt.registerSingleton<AppStatusService>(AppStatusService());

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      expect(find.text('Нужно снова войти'), findsOneWidget);
      expect(
        find.text(
          'Сессия закончилась. Войдите снова, чтобы открыть чаты и черновики.',
        ),
        findsOneWidget,
      );
      expect(find.text('Войти снова'), findsOneWidget);

      await tester.tap(find.text('Войти снова'));
      await tester.pumpAndSettle();

      expect(find.text('login-screen:/chats'), findsOneWidget);
    },
  );

  testWidgets(
      'ChatsListScreen показывает оболочку сразу, пока чаты догружаются',
      (tester) async {
    final chatService = getIt<ChatServiceInterface>() as _FakeChatService;
    final controller = StreamController<List<ChatPreview>>();
    chatService.chatPreviewsStreamOverride = controller.stream;
    addTearDown(controller.close);

    await tester.pumpWidget(buildApp());
    await tester.pump();

    expect(find.text('Чаты'), findsOneWidget);
    // Мобильный поиск спрятан за иконкой в топбаре (как в Telegram):
    // поле появляется только после тапа.
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('chats-search-toggle')));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.text('Пока нет чатов'), findsNothing);

    controller.add(const <ChatPreview>[]);
    await tester.pumpAndSettle();

    expect(find.text('Чатов нет'), findsOneWidget);
  });

  testWidgets(
    'ChatsListScreen не запускает повторную загрузку родных, пока первая в работе',
    (tester) async {
      await getIt.reset();
      final relativesLoad = Completer<void>();
      final familyTreeService = _FakeFamilyTreeService(
        getRelativesDelay: relativesLoad.future,
      );
      getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
      getIt.registerSingleton<ChatServiceInterface>(_FakeChatService());
      getIt.registerSingleton<FamilyTreeServiceInterface>(familyTreeService);
      getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
      getIt.registerSingleton<AppStatusService>(AppStatusService());

      await tester.pumpWidget(buildApp());
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(familyTreeService.getRelativesCallCount, 1);

      relativesLoad.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('Пустое состояние чатов ведет в родных и дерево', (tester) async {
    await tester.pumpWidget(buildApp());

    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Родные'));
    await tester.tap(find.text('Родные'));
    await tester.pumpAndSettle();
    expect(find.text('relatives-screen'), findsOneWidget);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Дерево'));
    await tester.tap(find.text('Дерево'));
    await tester.pumpAndSettle();
    expect(find.text('tree-screen'), findsOneWidget);
  });

  testWidgets('Composer creates multi-branch chat from selected roots',
      (tester) async {
    final chatService = getIt<ChatServiceInterface>() as _FakeChatService;

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Новый чат'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Несколько'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Иван Кузнецов'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Мария Понькина'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Открыть чат веток'));
    await tester.pumpAndSettle();

    expect(
      chatService.createdBranchRootPersonIds,
      equals(['person-root-1', 'person-root-2']),
    );
    expect(chatService.createdTitle, 'Ветки: Иван Кузнецов, Мария Понькина');
    expect(
      find.textContaining(
        '/chats/view/chat-branch-1?type=branch&title=',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'ChatsListScreen surfaces the wide-layout side panel on desktop',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      // The earlier mobile-only flow wasted ~600px of desktop space —
      // user feedback was "выглядит как растянутый телефон". Now wide
      // viewports (>= 1100) get the chat list on the left and the
      // "Связь" side panel on the right.
      expect(find.text('Связь'), findsOneWidget);
      expect(find.text('Семья Кузнецовых'), findsAtLeastNWidgets(1));
    },
  );

  testWidgets('ChatsListScreen склоняет overview counts корректно',
      (tester) async {
    // Обзорная строка (контекст дерева + счётчик новых) осталась только в
    // десктопной панели; на мобильном первый чат идёт сразу под табами.
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('Семья Кузнецовых'), findsAtLeastNWidgets(1));
    expect(find.text('Нет непрочитанных'), findsOneWidget);
  });

  testWidgets('Mobile chat filters stay in one compact row', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final allTop = tester
        .getTopLeft(
          find.byKey(const ValueKey<String>('chats-filter-all')),
        )
        .dy;
    final unreadTop = tester
        .getTopLeft(
          find.byKey(const ValueKey<String>('chats-filter-unread')),
        )
        .dy;
    final archiveTop = tester
        .getTopLeft(
          find.byKey(const ValueKey<String>('chats-filter-archive')),
        )
        .dy;

    expect(unreadTop, allTop);
    expect(archiveTop, allTop);
  });

  testWidgets('ChatsListScreen shows draft preview and draft count',
      (tester) async {
    final chatService = getIt<ChatServiceInterface>() as _FakeChatService;
    chatService.chatPreviews = [
      ChatPreview(
        id: 'preview-1',
        chatId: 'chat-1',
        userId: 'user-1',
        otherUserId: 'user-root-1',
        otherUserName: 'Иван Кузнецов',
        lastMessage: 'Старое сообщение',
        lastMessageTime: DateTime(2026, 4, 10, 18, 0),
        unreadCount: 0,
        lastMessageSenderId: 'user-root-1',
      ),
    ];
    final draftStore = _MemoryChatDraftStore();
    await draftStore.saveDraft(
      SharedPreferencesChatDraftStore.chatKey('chat-1'),
      'Нужно обсудить встречу в воскресенье',
    );

    await tester.pumpWidget(buildApp(draftStore: draftStore));
    await tester.pumpAndSettle();

    expect(
      find.text('Черновик: Нужно обсудить встречу в воскресенье'),
      findsOneWidget,
    );
    expect(find.text('Черновик'), findsNothing);
  });

  testWidgets('ChatsListScreen clears visible draft on local send suppression',
      (tester) async {
    final chatService = getIt<ChatServiceInterface>() as _FakeChatService;
    chatService.chatPreviews = [
      ChatPreview(
        id: 'preview-1',
        chatId: 'chat-1',
        userId: 'user-1',
        otherUserId: 'user-root-1',
        otherUserName: 'Иван Кузнецов',
        lastMessage: 'Старое сообщение',
        lastMessageTime: DateTime(2026, 4, 10, 18, 0),
        unreadCount: 0,
        lastMessageSenderId: 'user-root-1',
      ),
    ];
    final draftStore = _MemoryChatDraftStore();
    await draftStore.saveDraft(
      SharedPreferencesChatDraftStore.chatKey('chat-1'),
      'Только что отправленный текст',
    );

    await tester.pumpWidget(buildApp(draftStore: draftStore));
    await tester.pumpAndSettle();
    expect(
      find.text('Черновик: Только что отправленный текст'),
      findsOneWidget,
    );

    ChatDraftSuppression.instance.suppressSentDraft(
      chatId: 'chat-1',
      text: 'Только что отправленный текст',
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Черновик: Только что отправленный текст'),
      findsNothing,
    );
    expect(
      await draftStore.getDraft(
        SharedPreferencesChatDraftStore.chatKey('chat-1'),
      ),
      isNull,
    );
  });

  testWidgets('ChatsListScreen hides stale draft echo after message send',
      (tester) async {
    final chatService = getIt<ChatServiceInterface>() as _FakeChatService;
    chatService.chatPreviews = [
      ChatPreview(
        id: 'preview-1',
        chatId: 'chat-1',
        userId: 'user-1',
        otherUserId: 'user-root-1',
        otherUserName: 'Иван Кузнецов',
        lastMessage: 'Уже отправленный текст',
        lastMessageTime: DateTime(2026, 4, 10, 18, 0),
        unreadCount: 0,
        lastMessageSenderId: 'user-1',
      ),
    ];
    final draftStore = _MemoryChatDraftStore();
    await draftStore.saveDraft(
      SharedPreferencesChatDraftStore.chatKey('chat-1'),
      'Уже отправленный текст',
    );
    ChatDraftSuppression.instance.suppressSentDraft(
      chatId: 'chat-1',
      text: 'Уже отправленный текст',
    );

    await tester.pumpWidget(buildApp(draftStore: draftStore));
    await tester.pumpAndSettle();

    expect(find.text('Черновик: Уже отправленный текст'), findsNothing);
    expect(find.text('Уже отправленный текст'), findsOneWidget);
    expect(
      await draftStore.getDraft(
        SharedPreferencesChatDraftStore.chatKey('chat-1'),
      ),
      isNull,
    );
  });

  testWidgets('ChatsListScreen shows muted chat indicator and overview',
      (tester) async {
    final chatService = getIt<ChatServiceInterface>() as _FakeChatService;
    chatService.chatPreviews = [
      ChatPreview(
        id: 'preview-muted-1',
        chatId: 'chat-muted-1',
        userId: 'user-1',
        otherUserId: 'user-root-1',
        otherUserName: 'Иван Кузнецов',
        lastMessage: 'Напиши, когда доедешь',
        lastMessageTime: DateTime(2026, 4, 10, 19, 0),
        unreadCount: 2,
        lastMessageSenderId: 'user-root-1',
      ),
    ];
    final notificationSettingsStore = _MemoryChatNotificationSettingsStore();
    await notificationSettingsStore.saveSettings(
      SharedPreferencesChatNotificationSettingsStore.chatKey('chat-muted-1'),
      ChatNotificationSettingsSnapshot(
        level: ChatNotificationLevel.muted,
        updatedAt: DateTime(2026, 4, 11, 12, 0),
      ),
    );

    await tester.pumpWidget(
      buildApp(notificationSettingsStore: notificationSettingsStore),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.notifications_off_outlined), findsWidgets);
  });

  testWidgets('ChatsListScreen archives chat and moves it out of main flow',
      (tester) async {
    final chatService = getIt<ChatServiceInterface>() as _FakeChatService;
    chatService.chatPreviews = [
      ChatPreview(
        id: 'preview-1',
        chatId: 'chat-1',
        userId: 'user-1',
        otherUserId: 'user-root-1',
        otherUserName: 'Иван Кузнецов',
        lastMessage: 'Старое сообщение',
        lastMessageTime: DateTime(2026, 4, 10, 18, 0),
        unreadCount: 0,
        lastMessageSenderId: 'user-root-1',
      ),
      ChatPreview(
        id: 'preview-2',
        chatId: 'chat-2',
        userId: 'user-1',
        otherUserId: 'user-root-2',
        otherUserName: 'Мария Понькина',
        lastMessage: 'Новый чат',
        lastMessageTime: DateTime(2026, 4, 10, 19, 0),
        unreadCount: 2,
        lastMessageSenderId: 'user-root-2',
      ),
    ];
    final archiveStore = _MemoryChatArchiveStore();

    await tester.pumpWidget(buildApp(archiveStore: archiveStore));
    await tester.pumpAndSettle();

    expect(find.text('Иван Кузнецов'), findsOneWidget);
    expect(find.text('Мария Понькина'), findsOneWidget);

    await tester.longPress(find.text('Иван Кузнецов'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Архивировать чат'));
    await tester.pumpAndSettle();

    expect(find.text('Иван Кузнецов'), findsNothing);
    expect(find.text('Мария Понькина'), findsOneWidget);
    expect(find.text('1 чат в архиве'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey<String>('chats-filter-archive')));
    await tester.pumpAndSettle();

    expect(find.text('Иван Кузнецов'), findsOneWidget);
    expect(find.text('Мария Понькина'), findsNothing);
  });

  testWidgets('ChatsListScreen unarchives chat from archive filter',
      (tester) async {
    final chatService = getIt<ChatServiceInterface>() as _FakeChatService;
    chatService.chatPreviews = [
      ChatPreview(
        id: 'preview-1',
        chatId: 'chat-1',
        userId: 'user-1',
        otherUserId: 'user-root-1',
        otherUserName: 'Иван Кузнецов',
        lastMessage: 'Старое сообщение',
        lastMessageTime: DateTime(2026, 4, 10, 18, 0),
        unreadCount: 0,
        lastMessageSenderId: 'user-root-1',
      ),
    ];
    final archiveStore = _MemoryChatArchiveStore();
    await archiveStore.saveArchivedChat(
      SharedPreferencesChatArchiveStore.chatKey('chat-1'),
      ChatArchiveSnapshot(archivedAt: DateTime(2026, 4, 11, 12, 0)),
    );

    await tester.pumpWidget(buildApp(archiveStore: archiveStore));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('chats-filter-archive')));
    await tester.pumpAndSettle();

    expect(find.text('Иван Кузнецов'), findsOneWidget);

    await tester.longPress(find.text('Иван Кузнецов'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Вернуть в основной список'));
    await tester.pumpAndSettle();

    expect(find.text('Иван Кузнецов'), findsOneWidget);
    expect(find.text('Архив (1)'), findsNothing);
  });

  testWidgets(
    'Пустой селектор участников: CTA «Добавить родственника» ведёт в /relatives',
    (tester) async {
      // Tall viewport so the modal sheet's selector panel has room for
      // the richer empty state (subtitle + CTA) without a tiny-sheet
      // overflow.
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await getIt.reset();
      getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
      getIt.registerSingleton<ChatServiceInterface>(_FakeChatService());
      getIt.registerSingleton<FamilyTreeServiceInterface>(
        _FakeFamilyTreeService(
          relativesOverride: const <FamilyPerson>[],
          relationsOverride: const <FamilyRelation>[],
        ),
      );
      getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
      getIt.registerSingleton<AppStatusService>(AppStatusService());

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Новый чат'));
      await tester.pumpAndSettle();

      // «Группа» → participant selector; empty tree → recovery CTA.
      await tester.tap(find.text('Группа'));
      await tester.pumpAndSettle();

      expect(find.text('Родных пока нет'), findsOneWidget);
      final cta = find.byKey(const Key('chat-empty-add-relative'));
      expect(cta, findsOneWidget);

      await tester.tap(cta);
      await tester.pumpAndSettle();

      expect(find.text('relatives-screen'), findsOneWidget);
    },
  );

  testWidgets(
    'Пустой селектор веток: CTA «Открыть дерево» ведёт в /tree',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await getIt.reset();
      getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
      getIt.registerSingleton<ChatServiceInterface>(_FakeChatService());
      getIt.registerSingleton<FamilyTreeServiceInterface>(
        _FakeFamilyTreeService(
          relativesOverride: const <FamilyPerson>[],
          relationsOverride: const <FamilyRelation>[],
        ),
      );
      getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
      getIt.registerSingleton<AppStatusService>(AppStatusService());

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Новый чат'));
      await tester.pumpAndSettle();

      // «Одна ветка» → branch selector; no branches → recovery CTA.
      await tester.tap(find.text('Одна ветка'));
      await tester.pumpAndSettle();

      expect(find.text('Веток пока нет'), findsOneWidget);
      final cta = find.byKey(const Key('chat-empty-open-tree'));
      expect(cta, findsOneWidget);

      await tester.tap(cta);
      await tester.pumpAndSettle();

      expect(find.text('tree-screen'), findsOneWidget);
    },
  );
}
