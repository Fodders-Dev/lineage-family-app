import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:lineage/backend/interfaces/auth_service_interface.dart';
import 'package:lineage/backend/interfaces/chat_service_interface.dart';
import 'package:lineage/backend/interfaces/family_tree_service_interface.dart';
import 'package:lineage/models/chat_details.dart';
import 'package:lineage/models/chat_message.dart';
import 'package:lineage/models/chat_preview.dart';
import 'package:lineage/models/chat_send_progress.dart';
import 'package:lineage/models/family_person.dart';
import 'package:lineage/models/family_relation.dart';
import 'package:lineage/providers/tree_provider.dart';
import 'package:lineage/screens/tree_view_screen.dart';
import 'package:lineage/services/local_storage_service.dart';
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
}

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
  final List<String> requestedTreeIds = [];
  bool showFirstPerson = false;
  bool showBranchFamily = false;

  @override
  Future<List<FamilyPerson>> getRelatives(String treeId) async {
    requestedTreeIds.add(treeId);
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
  Future<bool> isCurrentUserInTree(String treeId) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await getIt.reset();
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
    getIt.registerSingleton<ChatServiceInterface>(_FakeChatService());
    getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
  });

  tearDown(() async {
    await getIt.reset();
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

    expect(find.text('Добавить первого человека'), findsOneWidget);

    await tester.tap(find.text('Добавить первого человека'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить человека'));
    await tester.pumpAndSettle();

    expect(find.text('Иван Петров'), findsOneWidget);
    expect(
      familyService.requestedTreeIds.where((id) => id == 'tree-1').length,
      greaterThanOrEqualTo(2),
    );
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
    expect(find.text('Добавить'), findsOneWidget);
    expect(find.text('Сменить'), findsOneWidget);
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

    await tester.longPress(find.text('Иван Петров').first);
    await tester.pumpAndSettle();

    expect(find.text('Написать ветке'), findsOneWidget);

    await tester.tap(find.text('Написать ветке'));
    await tester.pumpAndSettle();

    expect(chatService.createdBranchTreeId, 'tree-1');
    expect(chatService.createdBranchRootIds, ['person-1']);
    expect(chatService.createdBranchTitle, 'Ветка Иван Петров');
    expect(find.textContaining('chat:chat-branch-1'), findsOneWidget);
  });
}
