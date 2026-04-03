import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:lineage/backend/interfaces/auth_service_interface.dart';
import 'package:lineage/backend/interfaces/chat_service_interface.dart';
import 'package:lineage/backend/interfaces/family_tree_service_interface.dart';
import 'package:lineage/backend/interfaces/invitation_link_service_interface.dart';
import 'package:lineage/models/chat_message.dart';
import 'package:lineage/models/chat_preview.dart';
import 'package:lineage/models/chat_send_progress.dart';
import 'package:lineage/models/family_person.dart';
import 'package:lineage/models/family_relation.dart';
import 'package:lineage/models/relation_request.dart';
import 'package:lineage/providers/tree_provider.dart';
import 'package:lineage/screens/relatives_screen.dart';
import 'package:lineage/services/local_storage_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';

class _FakeAuthService implements AuthServiceInterface {
  @override
  String? get currentUserId => 'user-1';

  @override
  String? get currentUserEmail => 'user@example.com';

  @override
  String? get currentUserDisplayName => 'Артем Кузнецов';

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
  }) async =>
      'chat-branch-1';
}

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
  final _me = FamilyPerson(
    id: 'me',
    treeId: 'tree-1',
    userId: 'user-1',
    name: 'Кузнецов Артем',
    gender: Gender.male,
    isAlive: true,
    createdAt: DateTime(2024, 1, 1),
    updatedAt: DateTime(2024, 1, 1),
  );

  final _father = FamilyPerson(
    id: 'father',
    treeId: 'tree-1',
    userId: 'user-father',
    name: 'Кузнецов Андрей Анатольевич',
    gender: Gender.male,
    isAlive: true,
    createdAt: DateTime(2024, 1, 1),
    updatedAt: DateTime(2024, 1, 1),
  );

  final _wife = FamilyPerson(
    id: 'wife',
    treeId: 'tree-1',
    userId: 'user-wife',
    name: 'Шуфляк Анастасия Эдуардовна',
    gender: Gender.female,
    isAlive: true,
    createdAt: DateTime(2024, 1, 1),
    updatedAt: DateTime(2024, 1, 1),
  );

  final _sister = FamilyPerson(
    id: 'sister',
    treeId: 'tree-1',
    userId: 'user-sister',
    name: 'Понькина Дарья Андреевна',
    gender: Gender.female,
    isAlive: true,
    createdAt: DateTime(2024, 1, 1),
    updatedAt: DateTime(2024, 1, 1),
  );

  final _grandfather = FamilyPerson(
    id: 'grandfather',
    treeId: 'tree-1',
    name: 'Кузнецов Анатолий Степанович',
    gender: Gender.male,
    isAlive: true,
    createdAt: DateTime(2024, 1, 1),
    updatedAt: DateTime(2024, 1, 1),
  );

  late final List<FamilyPerson> _people = [
    _me,
    _father,
    _wife,
    _sister,
    _grandfather,
  ];
  late final List<FamilyRelation> _relations = [
    FamilyRelation(
      id: 'father-me',
      treeId: 'tree-1',
      person1Id: 'father',
      person2Id: 'me',
      relation1to2: RelationType.parent,
      relation2to1: RelationType.child,
      isConfirmed: true,
      createdAt: DateTime(2024, 1, 1),
    ),
    FamilyRelation(
      id: 'wife-me',
      treeId: 'tree-1',
      person1Id: 'wife',
      person2Id: 'me',
      relation1to2: RelationType.spouse,
      relation2to1: RelationType.spouse,
      isConfirmed: true,
      createdAt: DateTime(2024, 1, 1),
    ),
    FamilyRelation(
      id: 'sister-me',
      treeId: 'tree-1',
      person1Id: 'sister',
      person2Id: 'me',
      relation1to2: RelationType.sibling,
      relation2to1: RelationType.sibling,
      isConfirmed: true,
      createdAt: DateTime(2024, 1, 1),
    ),
    FamilyRelation(
      id: 'grandfather-father',
      treeId: 'tree-1',
      person1Id: 'grandfather',
      person2Id: 'father',
      relation1to2: RelationType.parent,
      relation2to1: RelationType.child,
      isConfirmed: true,
      createdAt: DateTime(2024, 1, 1),
    ),
  ];

  @override
  Stream<List<FamilyPerson>> getRelativesStream(String treeId) {
    return Stream.value(_people);
  }

  @override
  Stream<List<FamilyRelation>> getRelationsStream(String treeId) {
    return Stream.value(_relations);
  }

  @override
  Future<List<RelationRequest>> getRelationRequests(
      {required String treeId}) async {
    return const <RelationRequest>[];
  }

  @override
  Future<List<FamilyPerson>> getRelatives(String treeId) async => _people;

  @override
  Future<List<FamilyRelation>> getRelations(String treeId) async => _relations;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocalStorageService implements LocalStorageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeInvitationLinkService implements InvitationLinkServiceInterface {
  @override
  Uri buildInvitationLink({required String treeId, required String personId}) {
    return Uri.parse('https://example.com/invite/$treeId/$personId');
  }
}

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await getIt.reset();
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
    getIt.registerSingleton<ChatServiceInterface>(_FakeChatService());
    getIt.registerSingleton<FamilyTreeServiceInterface>(
        _FakeFamilyTreeService());
    getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
    getIt.registerSingleton<InvitationLinkServiceInterface>(
      _FakeInvitationLinkService(),
    );
  });

  tearDown(() async {
    await getIt.reset();
  });

  Future<void> pumpRelativesScreen(WidgetTester tester) async {
    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-1', 'Семья Кузнецовых');

    final router = GoRouter(
      initialLocation: '/relatives',
      routes: [
        GoRoute(
          path: '/relatives',
          builder: (context, state) => const RelativesScreen(),
        ),
        GoRoute(
          path: '/relatives/chat/:userId',
          builder: (context, state) =>
              Text('chat:${state.pathParameters['userId']}'),
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
  }

  testWidgets('RelativesScreen показывает точные роли и быстрый чат',
      (tester) async {
    await pumpRelativesScreen(tester);

    expect(find.text('Кузнецов Андрей Анатольевич'), findsOneWidget);
    expect(find.text('Отец'), findsOneWidget);
    expect(find.text('Жена'), findsOneWidget);
    expect(find.text('Сестра'), findsOneWidget);
    expect(find.text('Можно написать'), findsNWidgets(3));
    expect(find.text('Нужно пригласить'), findsOneWidget);
    expect(
      find.byTooltip('Написать Кузнецов Андрей Анатольевич'),
      findsOneWidget,
    );
    expect(
      find.byTooltip('Пригласить Кузнецов Анатолий Степанович'),
      findsOneWidget,
    );
  });

  testWidgets('Быстрый чат из списка родных открывает маршрут чата',
      (tester) async {
    await pumpRelativesScreen(tester);

    await tester.tap(
      find.byTooltip('Написать Кузнецов Андрей Анатольевич'),
    );
    await tester.pumpAndSettle();

    expect(find.text('chat:user-father'), findsOneWidget);
  });
}
