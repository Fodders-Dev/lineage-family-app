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
import 'package:lineage/models/family_tree.dart';
import 'package:lineage/providers/tree_provider.dart';
import 'package:lineage/screens/chats_list_screen.dart';
import 'package:lineage/services/local_storage_service.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

class _FakeAuthService implements AuthServiceInterface {
  @override
  String? get currentUserId => 'user-1';

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

class _FakeFamilyTreeService extends Fake
    implements FamilyTreeServiceInterface {
  @override
  Future<List<FamilyPerson>> getRelatives(String treeId) async => [
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

  @override
  Future<List<FamilyRelation>> getRelations(String treeId) async => [
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

class _FakeLocalStorageService extends Fake implements LocalStorageService {}

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    await getIt.reset();
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
    getIt.registerSingleton<ChatServiceInterface>(_FakeChatService());
    getIt.registerSingleton<FamilyTreeServiceInterface>(
        _FakeFamilyTreeService());
    getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
  });

  tearDown(() async {
    await getIt.reset();
  });

  Widget buildApp() {
    final treeProvider = TreeProvider();
    treeProvider.selectTree('tree-1', 'Семья Кузнецовых');

    final router = GoRouter(
      initialLocation: '/chats',
      routes: [
        GoRoute(
          path: '/chats',
          builder: (context, state) => const ChatsListScreen(),
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

    expect(find.text('Пока нет чатов'), findsOneWidget);
    expect(find.text('Создать чат'), findsOneWidget);
    expect(find.text('Открыть родных'), findsOneWidget);
    expect(find.text('Открыть дерево'), findsOneWidget);
  });

  testWidgets('Пустое состояние чатов ведет в родных и дерево', (tester) async {
    await tester.pumpWidget(buildApp());

    await tester.pumpAndSettle();

    await tester.tap(find.text('Открыть родных'));
    await tester.pumpAndSettle();
    expect(find.text('relatives-screen'), findsOneWidget);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Открыть дерево'));
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

    await tester.tap(find.text('Ветка семьи'));
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
}
