import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/backend/interfaces/chat_service_interface.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/backend/interfaces/tree_graph_capable_family_tree_service.dart';
import 'package:rodnya/models/chat_attachment.dart';
import 'package:rodnya/models/chat_details.dart';
import 'package:rodnya/models/chat_message.dart';
import 'package:rodnya/models/chat_message_search_result.dart';
import 'package:rodnya/models/chat_preview.dart';
import 'package:rodnya/models/chat_send_progress.dart';
import 'package:rodnya/models/family_person.dart';
import 'package:rodnya/models/family_relation.dart';
import 'package:rodnya/models/family_tree.dart';
import 'package:rodnya/models/tree_change_record.dart';
import 'package:rodnya/models/tree_graph_snapshot.dart';
import 'package:rodnya/providers/tree_provider.dart';
import 'package:rodnya/screens/tree_view_screen.dart';
import 'package:rodnya/services/app_status_service.dart';
import 'package:rodnya/services/local_storage_service.dart';
import 'package:rodnya/services/tree_mutation_history.dart';
import 'package:rodnya/widgets/interactive_family_tree.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAuthService implements AuthServiceInterface {
  @override
  String? get currentUserId => 'user-1';

  @override
  String? get currentUserEmail => 'user@example.com';

  @override
  String? get currentUserDisplayName => 'Тестовый пользователь';

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

class _FakeLocalStorageService implements LocalStorageService {
  final Map<String, Map<String, Offset>> _savedPositions =
      <String, Map<String, Offset>>{};

  @override
  Future<Map<String, Offset>> getTreeNodePositions(String treeId) async {
    return Map<String, Offset>.from(
      _savedPositions[treeId] ?? const <String, Offset>{},
    );
  }

  @override
  Future<void> saveTreeNodePositions(
    String treeId,
    Map<String, Offset> positions,
  ) async {
    _savedPositions[treeId] = Map<String, Offset>.from(positions);
  }

  @override
  Future<void> clearTreeNodePositions(String treeId) async {
    _savedPositions.remove(treeId);
  }

  @override
  Future<FamilyTree?> getTree(String treeId) async {
    final now = DateTime(2024, 1, 1);
    return FamilyTree(
      id: treeId,
      name: treeId == 'tree-2' ? 'Второе дерево' : 'Первое дерево',
      description: '',
      creatorId: 'user-1',
      memberIds: const ['user-1'],
      createdAt: now,
      updatedAt: now,
      isPrivate: true,
      members: const ['user-1'],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChatService implements ChatServiceInterface {
  String? createdBranchTreeId;
  List<String> createdBranchRootIds = const <String>[];
  String? createdBranchTitle;

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
  }) async =>
      'chat-group-1';

  @override
  Future<String?> createBranchChat({
    required String treeId,
    required List<String> branchRootPersonIds,
    String? title,
  }) async {
    createdBranchTreeId = treeId;
    createdBranchRootIds = List<String>.from(branchRootPersonIds);
    createdBranchTitle = title;
    return 'chat-branch-1';
  }

  @override
  Future<ChatDetails> getChatDetails(String chatId) async => const ChatDetails(
        chatId: 'chat-group-1',
        type: 'group',
        title: 'Группа',
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

class _FakeFamilyTreeService
    implements FamilyTreeServiceInterface, TreeGraphCapableFamilyTreeService {
  final List<String> requestedTreeIds = [];
  bool showFirstPerson = false;
  bool showBranchFamily = false;
  final List<TreeChangeRecord> historyRecords = [
    TreeChangeRecord(
      id: 'change-1',
      treeId: 'tree-1',
      actorId: 'user-1',
      type: 'person.updated',
      personId: 'person-1',
      personIds: ['person-1'],
      createdAt: DateTime(2024, 1, 2, 12, 0),
    ),
  ];

  @override
  Future<List<FamilyTree>> getUserTrees() async {
    final now = DateTime(2024, 1, 1);
    return [
      FamilyTree(
        id: 'tree-1',
        name: 'Первое дерево',
        description: '',
        creatorId: 'user-1',
        memberIds: const ['user-1'],
        createdAt: now,
        updatedAt: now,
        isPrivate: true,
        members: const ['user-1'],
      ),
      FamilyTree(
        id: 'tree-2',
        name: 'Второе дерево',
        description: '',
        creatorId: 'user-1',
        memberIds: const ['user-1'],
        createdAt: now,
        updatedAt: now,
        isPrivate: true,
        members: const ['user-1'],
      ),
    ];
  }

  @override
  Future<List<FamilyPerson>> getRelatives(String treeId) async {
    requestedTreeIds.add(treeId);
    return _peopleForTree(treeId);
  }

  List<FamilyPerson> _peopleForTree(String treeId) {
    if (showBranchFamily) {
      return [
        FamilyPerson(
          id: 'person-1',
          treeId: treeId,
          userId: 'user-1',
          name: 'Иван Петров',
          gender: Gender.male,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        ),
        FamilyPerson(
          id: 'person-2',
          treeId: treeId,
          userId: 'user-2',
          name: 'Мария Петрова',
          gender: Gender.female,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        ),
      ];
    }
    if (!showFirstPerson) {
      return const [];
    }
    return [
      FamilyPerson(
        id: 'person-1',
        treeId: treeId,
        name: 'Иван Петров',
        gender: Gender.male,
        isAlive: true,
        createdAt: DateTime(2024, 1, 1),
        updatedAt: DateTime(2024, 1, 1),
      ),
    ];
  }

  @override
  Future<List<FamilyRelation>> getRelations(String treeId) async {
    return _relationsForTree(treeId);
  }

  List<FamilyRelation> _relationsForTree(String treeId) {
    if (!showBranchFamily) {
      return const [];
    }

    return [
      FamilyRelation(
        id: 'relation-1',
        treeId: treeId,
        person1Id: 'person-1',
        person2Id: 'person-2',
        relation1to2: RelationType.spouse,
        relation2to1: RelationType.spouse,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
        updatedAt: DateTime(2024, 1, 1),
      ),
    ];
  }

  @override
  Future<TreeGraphSnapshot> getTreeGraphSnapshot(String treeId) async {
    requestedTreeIds.add(treeId);
    final people = _peopleForTree(treeId);
    final relations = _relationsForTree(treeId);
    final branchBlocks = showBranchFamily
        ? const <TreeGraphBranchBlock>[
            TreeGraphBranchBlock(
              id: 'branch-1',
              rootUnitId: 'unit-1',
              label: 'Ветка Иван Петров',
              memberPersonIds: ['person-1', 'person-2'],
            ),
          ]
        : const <TreeGraphBranchBlock>[];
    final generationRows = people.isEmpty
        ? const <TreeGraphGenerationRow>[]
        : <TreeGraphGenerationRow>[
            TreeGraphGenerationRow(
              row: 0,
              label: people.length == 1 ? 'Поколение 1' : 'Старшее поколение',
              personIds: people.map((person) => person.id).toList(),
              familyUnitIds: showBranchFamily ? const ['unit-1'] : const [],
            ),
          ];
    final familyUnits = showBranchFamily
        ? const <TreeGraphFamilyUnit>[
            TreeGraphFamilyUnit(
              id: 'unit-1',
              rootParentSetId: null,
              adultIds: ['person-1', 'person-2'],
              childIds: <String>[],
              relationIds: ['relation-1'],
              unionId: 'union-1',
              unionType: 'spouse',
              unionStatus: 'current',
              parentSetType: null,
              isPrimaryParentSet: true,
              label: 'Семья Ивана и Марии',
            ),
          ]
        : const <TreeGraphFamilyUnit>[];

    return TreeGraphSnapshot(
      treeId: treeId,
      viewerPersonId: people.any((person) => person.userId == 'user-1')
          ? people.firstWhere((person) => person.userId == 'user-1').id
          : null,
      people: people,
      relations: relations,
      familyUnits: familyUnits,
      viewerDescriptors: const <TreeGraphViewerDescriptor>[],
      branchBlocks: branchBlocks,
      generationRows: generationRows,
      warnings: const <TreeGraphWarning>[],
    );
  }

  @override
  Future<bool> isCurrentUserInTree(String treeId) async => true;

  @override
  Future<List<TreeChangeRecord>> getTreeHistory({
    required String treeId,
    String? personId,
    String? type,
    String? actorId,
  }) async {
    return historyRecords.where((record) {
      if (record.treeId != treeId) {
        return false;
      }
      if (personId != null &&
          personId.isNotEmpty &&
          record.personId != personId) {
        return false;
      }
      if (type != null && type.isNotEmpty && record.type != type) {
        return false;
      }
      if (actorId != null && actorId.isNotEmpty && record.actorId != actorId) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  Future<List<String>> getRelationPath({
    required String treeId,
    required String targetPersonId,
  }) async {
    return <String>[targetPersonId];
  }

  @override
  Future<void> reassignParentSet({
    required String treeId,
    required String childPersonId,
    required String parentPersonId,
    required String parentSetId,
    String? parentSetType,
    bool isPrimaryParentSet = true,
  }) async {}

  @override
  Future<void> disconnectRelation({
    required String treeId,
    required String relationId,
  }) async {}

  @override
  Future<void> setRelationType({
    required String treeId,
    required FamilyPerson anchorPerson,
    required FamilyPerson targetPerson,
    required String relationType,
    String? customRelationLabel1to2,
    String? customRelationLabel2to1,
  }) async {}

  @override
  Future<void> setUnionStatus({
    required String treeId,
    required String relationId,
    required String unionStatus,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // A-CTA: dismiss гида статичен на сессию — сбрасываем между тестами,
    // иначе одно закрытие протекло бы в соседние кейсы.
    TreeViewScreen.debugResetGuidedCtaDismissal();
    await getIt.reset();
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
    getIt.registerSingleton<ChatServiceInterface>(_FakeChatService());
    getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
    getIt.registerSingleton<AppStatusService>(AppStatusService());
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets('без единого дерева вкладка зовёт создать семью прямо здесь',
      (tester) async {
    final familyService = _FakeFamilyTreeService();
    getIt.registerSingleton<FamilyTreeServiceInterface>(familyService);
    // Новичок: ничего не выбрано и выбирать нечего.
    final treeProvider = TreeProvider();
    expect(treeProvider.availableTrees, isEmpty);

    final router = GoRouter(
      initialLocation: '/tree',
      routes: [
        GoRoute(
          path: '/tree',
          builder: (context, state) => const TreeViewScreen(),
        ),
        GoRoute(
          path: '/trees/create',
          builder: (context, state) =>
              Text('create:${state.uri.queryParameters['kind'] ?? 'family'}'),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Здесь будет ваше дерево'), findsOneWidget);
    expect(find.text('Выберите дерево'), findsNothing,
        reason: 'селектор без деревьев — тупик, не предлагаем');
    expect(find.byKey(const Key('tree-empty-create-friends')), findsOneWidget);

    await tester.tap(find.byKey(const Key('tree-empty-create-family')));
    await tester.pumpAndSettle();
    expect(find.text('create:family'), findsOneWidget);
  });

  testWidgets('явный routeTreeId обновляет выбранное дерево в TreeProvider',
      (tester) async {
    final familyService = _FakeFamilyTreeService();
    getIt.registerSingleton<FamilyTreeServiceInterface>(familyService);
    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-1', 'Первое дерево');

    final router = GoRouter(
      initialLocation:
          '/tree/view/tree-2?name=%D0%92%D1%82%D0%BE%D1%80%D0%BE%D0%B5%20%D0%B4%D0%B5%D1%80%D0%B5%D0%B2%D0%BE',
      routes: [
        GoRoute(
          path: '/tree/view/:treeId',
          builder: (context, state) => TreeViewScreen(
            routeTreeId: state.pathParameters['treeId'],
            routeTreeName: state.uri.queryParameters['name'],
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.pumpAndSettle();

    expect(treeProvider.selectedTreeId, 'tree-2');
    expect(treeProvider.selectedTreeName, 'Второе дерево');
    expect(familyService.requestedTreeIds, contains('tree-2'));
  });

  testWidgets(
      'после возврата true из add-relative дерево перезагружается и показывает нового человека',
      (tester) async {
    final familyService = _FakeFamilyTreeService();
    getIt.registerSingleton<FamilyTreeServiceInterface>(familyService);
    final treeProvider = TreeProvider();

    final router = GoRouter(
      initialLocation: '/tree/view/tree-1?name=%D0%A2%D0%B5%D1%81%D1%82',
      routes: [
        GoRoute(
          path: '/tree/view/:treeId',
          builder: (context, state) => TreeViewScreen(
            routeTreeId: state.pathParameters['treeId'],
            routeTreeName: state.uri.queryParameters['name'],
          ),
        ),
        GoRoute(
          path: '/relatives/add/:treeId',
          builder: (context, state) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () {
                  familyService.showFirstPerson = true;
                  context.pop(true);
                },
                child: const Text('Сохранить человека'),
              ),
            ),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.pumpAndSettle();

    // Ship 2026-05-26 (UX audit Screen 4.1): empty-tree state now
    // surfaces relation-first guided CTAs (мама/папа/ребёнок/партнёр)
    // + «Другой родственник» secondary. Single «Добавить» button gone.
    // Tap «Добавить маму» CTA — routes к /relatives/add same path.
    expect(find.text('Начни своё семейное дерево'), findsOneWidget);
    expect(find.byKey(const Key('empty-tree-cta-mama')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('empty-tree-cta-mama')));
    await tester.tap(find.byKey(const Key('empty-tree-cta-mama')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить человека'));
    await tester.pumpAndSettle();

    // Card splits the displayed name: fname 'Иван' (Lora big) + lname
    // 'Петров' (Manrope small). Both must render after add-relative reload.
    expect(find.text('Иван'), findsOneWidget);
    expect(find.text('Петров'), findsOneWidget);
    expect(
      familyService.requestedTreeIds.where((id) => id == 'tree-1').length,
      greaterThanOrEqualTo(2),
    );
  });

  testWidgets(
      'A-CTA: dismiss гида скрывает его и переживает пересоздание экрана (сессия)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final familyService = _FakeFamilyTreeService(); // пустое дерево
    getIt.registerSingleton<FamilyTreeServiceInterface>(familyService);
    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-1', 'Тест');

    GoRouter buildRouter() => GoRouter(
          initialLocation: '/tree/view/tree-1?name=%D0%A2%D0%B5%D1%81%D1%82',
          routes: [
            GoRoute(
              path: '/tree/view/:treeId',
              builder: (context, state) => TreeViewScreen(
                routeTreeId: state.pathParameters['treeId'],
                routeTreeName: state.uri.queryParameters['name'],
              ),
            ),
          ],
        );

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: buildRouter()),
      ),
    );
    await tester.pumpAndSettle();

    // Гид виден, крестик присутствует.
    expect(find.byKey(const Key('empty-tree-cta-mama')), findsOneWidget);
    expect(find.byKey(const Key('empty-tree-cta-dismiss')), findsOneWidget);

    // Закрываем гид.
    await tester.tap(find.byKey(const Key('empty-tree-cta-dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('empty-tree-cta-mama')), findsNothing);

    // Пересоздаём экран с нуля (новый стейт) — гид НЕ возвращается,
    // потому что dismiss запомнен на сессию.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: buildRouter()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('empty-tree-cta-mama')), findsNothing);
  });

  testWidgets('компактный tree view не забивает экран длинной шапкой',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final familyService = _FakeFamilyTreeService()..showFirstPerson = true;
    getIt.registerSingleton<FamilyTreeServiceInterface>(familyService);
    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-1', 'Тест');

    final router = GoRouter(
      initialLocation: '/tree/view/tree-1?name=%D0%A2%D0%B5%D1%81%D1%82',
      routes: [
        GoRoute(
          path: '/tree/view/:treeId',
          builder: (context, state) => TreeViewScreen(
            routeTreeId: state.pathParameters['treeId'],
            routeTreeName: state.uri.queryParameters['name'],
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Тест'), findsWidgets);
    expect(
      find.textContaining('Открывайте карточки людей, чтобы смотреть детали'),
      findsNothing,
    );
    expect(find.text('Граф готов к просмотру'), findsNothing);
    // Primary creation lives in the topbar instead of floating over people
    // and relationship lines or shrinking the canvas with a bottom row.
    expect(find.byTooltip('Добавить родственника'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byKey(const Key('tree-primary-action-bar')), findsNothing);
    expect(find.byTooltip('Действия дерева'), findsOneWidget);
  });

  testWidgets(
      'topbar trailing actions live in a horizontal scroll (no overflow)',
      (tester) async {
    // Bug 1 fix: the trailing action controls are wrapped in a horizontal
    // SingleChildScrollView, so the topbar Row can never overflow — it
    // scrolls instead. We assert the wrapper is present + actions reachable
    // at a phone width. Behavioural «no RenderFlex overflow at any width»
    // follows structurally from the scroll wrap (a scrollable child has
    // unbounded main-axis extent).
    //
    // UX-T1.2 FR-c: на телефоне (390 — iPhone-class) вторичные контролы
    // (undo/redo/поиск/фильтры) переехали в overflow «•••», в топ-баре
    // остаются switcher + «•••». TreeMutationHistory всё равно регистрируем —
    // undo/redo теперь пункты меню, но топ-бар по-прежнему скроллируемый.
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    getIt.registerSingleton<TreeMutationHistory>(TreeMutationHistory());
    final familyService = _FakeFamilyTreeService()..showFirstPerson = true;
    getIt.registerSingleton<FamilyTreeServiceInterface>(familyService);
    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-1', 'Длинное имя дерева Ивановых');

    final router = GoRouter(
      initialLocation: '/tree/view/tree-1?name=%D0%A2%D0%B5%D1%81%D1%82',
      routes: [
        GoRoute(
          path: '/tree/view/:treeId',
          builder: (context, state) => TreeViewScreen(
            routeTreeId: state.pathParameters['treeId'],
            routeTreeName: state.uri.queryParameters['name'],
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The fix is wired: trailing actions are inside the horizontal scroll.
    expect(
      find.byKey(const Key('tree-topbar-actions-scroll')),
      findsOneWidget,
    );
    // Actions remain reachable (the «⋮» menu is the rightmost, kept in view).
    expect(find.byTooltip('Действия дерева'), findsOneWidget);
  });

  testWidgets(
      'body tree toolbar не overflow\'ит на 360dp (branch chip Flexible)',
      (tester) async {
    // The body toolbar (branch filter chip + семя badge + action icons)
    // overflowed ~22px past the icons at 360dp because the branch chip was a
    // fixed maxWidth-128 element. With it wrapped in Flexible, the
    // informational cluster yields and the Row fits. This test pumps at the
    // S20 FE width and asserts no RenderFlex overflow. (UX-T1.2 FR-a: stat
    // pills больше не в тулбаре — статы переехали в раскрываемую hero-панель.)
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final familyService = _FakeFamilyTreeService()..showFirstPerson = true;
    getIt.registerSingleton<FamilyTreeServiceInterface>(familyService);
    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-1', 'Длинное имя дерева Ивановых');

    final router = GoRouter(
      initialLocation: '/tree/view/tree-1?name=%D0%A2%D0%B5%D1%81%D1%82',
      routes: [
        GoRoute(
          path: '/tree/view/:treeId',
          builder: (context, state) => TreeViewScreen(
            routeTreeId: state.pathParameters['treeId'],
            routeTreeName: state.uri.queryParameters['name'],
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The action is part of the horizontally scrollable topbar, so it stays
    // reachable without covering the tree canvas.
    expect(find.byTooltip('Добавить родственника'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets(
      'UX-T1.2: компактный handle виден и раскрывает панель статов по тапу',
      (tester) async {
    // Телефонная ширина (<720 → isCompact): хром плавает над канвасом.
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final familyService = _FakeFamilyTreeService()..showFirstPerson = true;
    getIt.registerSingleton<FamilyTreeServiceInterface>(familyService);
    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-1', 'Тест');

    final router = GoRouter(
      initialLocation: '/tree/view/tree-1?name=%D0%A2%D0%B5%D1%81%D1%82',
      routes: [
        GoRoute(
          path: '/tree/view/:treeId',
          builder: (context, state) => TreeViewScreen(
            routeTreeId: state.pathParameters['treeId'],
            routeTreeName: state.uri.queryParameters['name'],
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // FR-b: вместо неочевидного шеврона — видимый handle с подписью-тизером
    // (одним счётчиком статов), чтобы юзер понимал, что там детали.
    expect(find.byKey(const Key('tree-chrome-handle')), findsOneWidget);
    expect(find.textContaining('подробнее'), findsOneWidget);

    // FR-a: статы/быстрые действия не маячат — «Расставить» (из панели
    // быстрых действий) скрыто, пока хром свёрнут.
    expect(find.text('Расставить'), findsNothing);

    // Тап по handle раскрывает единственный дом статов/действий.
    await tester.tap(find.byKey(const Key('tree-chrome-handle')));
    await tester.pumpAndSettle();

    expect(find.text('Расставить'), findsOneWidget);
  });

  testWidgets(
      'desktop tree view показывает контекстную колонку и быстрые действия',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1024));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final familyService = _FakeFamilyTreeService()..showBranchFamily = true;
    getIt.registerSingleton<FamilyTreeServiceInterface>(familyService);
    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-1', 'Тест');

    final router = GoRouter(
      initialLocation: '/tree/view/tree-1?name=%D0%A2%D0%B5%D1%81%D1%82',
      routes: [
        GoRoute(
          path: '/tree/view/:treeId',
          builder: (context, state) => TreeViewScreen(
            routeTreeId: state.pathParameters['treeId'],
            routeTreeName: state.uri.queryParameters['name'],
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Карта рода'), findsOneWidget);
    expect(find.text('Сразу к делу'), findsOneWidget);
    expect(find.text('Состояние дерева'), findsOneWidget);
    expect(find.text('Чаты'), findsOneWidget);
    expect(find.text('Пост'), findsOneWidget);
  });

  testWidgets('tap по узлу открывает bottom sheet с действиями карточки',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final familyService = _FakeFamilyTreeService()..showFirstPerson = true;
    getIt.registerSingleton<FamilyTreeServiceInterface>(familyService);
    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-1', 'Тест');

    final router = GoRouter(
      initialLocation: '/tree/view/tree-1?name=%D0%A2%D0%B5%D1%81%D1%82',
      routes: [
        GoRoute(
          path: '/tree/view/:treeId',
          builder: (context, state) => TreeViewScreen(
            routeTreeId: state.pathParameters['treeId'],
            routeTreeName: state.uri.queryParameters['name'],
          ),
        ),
        GoRoute(
          path: '/relative/details/:personId',
          builder: (context, state) =>
              Text('details:${state.pathParameters['personId']}'),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.pumpAndSettle();

    final treeWidget = tester.widget<InteractiveFamilyTree>(
      find.byType(InteractiveFamilyTree),
    );
    final person = treeWidget.peopleData.first['person']! as FamilyPerson;
    treeWidget.onPersonTap(person);
    await tester.pumpAndSettle();

    // Ship Q4 (2026-05-26): tap on tree person теперь surface'ит modal
    // action sheet (UX audit 2026-05-25 Critical #4) — Профиль / Edit /
    // Add / Connect / Delete доступны immediately, без chevron-to-expand
    // peek dance. Inline sheet остаётся selected underneath для
    // edit-mode workflows; modal pops on top in non-edit mode.
    expect(find.text('Открыть профиль'), findsOneWidget);
    expect(find.text('Редактировать'), findsOneWidget);
    expect(find.text('Добавить родственника'), findsOneWidget);
    expect(find.text('Связать с существующим'), findsOneWidget);
    expect(find.text('Удалить'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tree-action-open-profile')));
    await tester.pumpAndSettle();

    expect(find.text('details:${person.id}'), findsOneWidget);
  });

  testWidgets('после фокуса на ветке можно открыть общий чат ветки',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final familyService = _FakeFamilyTreeService()..showBranchFamily = true;
    final chatService = _FakeChatService();
    getIt.unregister<ChatServiceInterface>();
    getIt.registerSingleton<ChatServiceInterface>(chatService);
    getIt.registerSingleton<FamilyTreeServiceInterface>(familyService);
    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-1', 'Тест');

    final router = GoRouter(
      initialLocation: '/tree/view/tree-1?name=%D0%A2%D0%B5%D1%81%D1%82',
      routes: [
        GoRoute(
          path: '/tree/view/:treeId',
          builder: (context, state) => TreeViewScreen(
            routeTreeId: state.pathParameters['treeId'],
            routeTreeName: state.uri.queryParameters['name'],
          ),
        ),
        GoRoute(
          path: '/chats/view/:chatId',
          builder: (context, state) => Text(
            'chat:${state.pathParameters['chatId']}|${state.uri.queryParameters['title']}',
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.pumpAndSettle();

    final treeWidget = tester.widget<InteractiveFamilyTree>(
      find.byType(InteractiveFamilyTree),
    );
    final branchRootPerson =
        treeWidget.peopleData.first['person']! as FamilyPerson;
    treeWidget.onBranchFocusRequested?.call(branchRootPerson);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Действия дерева'));
    await tester.pumpAndSettle();
    expect(find.text('Написать ветке'), findsOneWidget);
    await tester.tap(find.text('Написать ветке'));
    await tester.pumpAndSettle();

    expect(chatService.createdBranchTreeId, 'tree-1');
    expect(chatService.createdBranchRootIds, ['person-1']);
    expect(chatService.createdBranchTitle, 'Ветка Иван Петров');
    expect(find.textContaining('chat:chat-branch-1'), findsOneWidget);
  });

  testWidgets(
      'быстрые действия из tree view открывают чаты (без дубля «родных»)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1024));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final familyService = _FakeFamilyTreeService()..showFirstPerson = true;
    getIt.registerSingleton<FamilyTreeServiceInterface>(familyService);
    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-1', 'Тест');

    final router = GoRouter(
      initialLocation: '/tree/view/tree-1?name=%D0%A2%D0%B5%D1%81%D1%82',
      routes: [
        GoRoute(
          path: '/tree/view/:treeId',
          builder: (context, state) => TreeViewScreen(
            routeTreeId: state.pathParameters['treeId'],
            routeTreeName: state.uri.queryParameters['name'],
          ),
        ),
        GoRoute(
          path: '/chats',
          builder: (context, state) => const Text('chats-screen'),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Действия дерева'));
    await tester.pumpAndSettle();
    // SC3: the tree→relatives cross-entry is gone — Список лежит за тем же
    // toggle'ом в «Семье». «Открыть чаты» остаётся (чаты — отдельный таб).
    expect(find.text('Открыть родных'), findsNothing);
    expect(find.text('Открыть связи'), findsNothing);
    await tester.ensureVisible(find.text('Открыть чаты').last);
    await tester.tap(find.text('Открыть чаты').last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('chats-screen'), findsOneWidget);
  });

  testWidgets('inline inspector в tree view открывает историю выбранного узла',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1024));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final familyService = _FakeFamilyTreeService()..showFirstPerson = true;
    getIt.registerSingleton<FamilyTreeServiceInterface>(familyService);
    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-1', 'Тест');

    final router = GoRouter(
      initialLocation: '/tree/view/tree-1?name=%D0%A2%D0%B5%D1%81%D1%82',
      routes: [
        GoRoute(
          path: '/tree/view/:treeId',
          builder: (context, state) => TreeViewScreen(
            routeTreeId: state.pathParameters['treeId'],
            routeTreeName: state.uri.queryParameters['name'],
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.pumpAndSettle();

    final treeWidget = tester.widget<InteractiveFamilyTree>(
      find.byType(InteractiveFamilyTree),
    );
    final person = treeWidget.peopleData.first['person']! as FamilyPerson;
    treeWidget.onOpenPersonHistory?.call(person);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('История изменений'), findsOneWidget);
    // Tree card splits name; 'Иван' renders in the card (and may also appear
    // in the history sheet header).
    expect(find.text('Иван'), findsWidgets);
    expect(find.text('Обновлён профиль'), findsOneWidget);
  });

  testWidgets('toolbar tree view открывает общий журнал изменений дерева',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1024));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final familyService = _FakeFamilyTreeService()..showFirstPerson = true;
    getIt.registerSingleton<FamilyTreeServiceInterface>(familyService);
    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-1', 'Тест');

    final router = GoRouter(
      initialLocation: '/tree/view/tree-1?name=%D0%A2%D0%B5%D1%81%D1%82',
      routes: [
        GoRoute(
          path: '/tree/view/:treeId',
          builder: (context, state) => TreeViewScreen(
            routeTreeId: state.pathParameters['treeId'],
            routeTreeName: state.uri.queryParameters['name'],
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Действия дерева'));
    await tester.pumpAndSettle();
    expect(find.text('История изменений'), findsOneWidget);

    await tester.tap(find.text('История изменений'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('История дерева'), findsOneWidget);
    expect(find.text('Все'), findsOneWidget);
    expect(find.text('Фото'), findsOneWidget);
    expect(find.text('Обновлён профиль'), findsOneWidget);
  });
}
