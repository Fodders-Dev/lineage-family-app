import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:lineage/backend/models/tree_invitation.dart';
import 'package:lineage/backend/interfaces/auth_service_interface.dart';
import 'package:lineage/backend/interfaces/family_tree_service_interface.dart';
import 'package:lineage/models/family_tree.dart';
import 'package:lineage/providers/tree_provider.dart';
import 'package:lineage/screens/trees_screen.dart';
import 'package:lineage/services/local_storage_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAuthService implements AuthServiceInterface {
  @override
  String? get currentUserId => 'user-1';

  @override
  String? get currentUserEmail => 'user-1@example.com';

  @override
  String? get currentUserDisplayName => 'User';

  @override
  String? get currentUserPhotoUrl => null;

  @override
  List<String> get currentProviderIds => const ['password'];

  @override
  Stream<String?> get authStateChanges => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
  _FakeFamilyTreeService({
    required List<FamilyTree> trees,
    required List<TreeInvitation> invitations,
  })  : _trees = trees,
        _invitations = invitations;

  final List<FamilyTree> _trees;
  final List<TreeInvitation> _invitations;

  @override
  Future<List<FamilyTree>> getUserTrees() async => _trees;

  @override
  Stream<List<TreeInvitation>> getPendingTreeInvitations() =>
      Stream<List<TreeInvitation>>.value(_invitations);

  @override
  Future<void> respondToTreeInvitation(
      String invitationId, bool accept) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocalStorageService implements LocalStorageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FamilyTree _buildTree({
  required String id,
  required String name,
}) {
  final now = DateTime(2024, 1, 1);
  return FamilyTree(
    id: id,
    name: name,
    description: '',
    creatorId: 'user-1',
    memberIds: const ['user-1'],
    createdAt: now,
    updatedAt: now,
    isPrivate: true,
    members: const ['user-1'],
  );
}

void main() {
  final getIt = GetIt.instance;
  _FakeFamilyTreeService? treeService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await getIt.reset();
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
    getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
  });

  tearDown(() async {
    treeService = null;
    await getIt.reset();
  });

  testWidgets('TreesScreen показывает заметный баннер и счётчик приглашений',
      (tester) async {
    treeService = _FakeFamilyTreeService(
      trees: [
        _buildTree(id: 'tree-1', name: 'Семья Кузнецовых'),
      ],
      invitations: [
        TreeInvitation(
          invitationId: 'invite-1',
          tree: _buildTree(id: 'tree-2', name: 'Семья Шуфляк'),
          invitedBy: 'Артём',
        ),
      ],
    );
    getIt.registerSingleton<FamilyTreeServiceInterface>(treeService!);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TreeProvider(),
        child: const MaterialApp(home: TreesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Приглашения (1)'), findsOneWidget);
    expect(find.text('Вас пригласили в дерево'), findsOneWidget);
    expect(find.textContaining('Семья Шуфляк'), findsOneWidget);

    await tester.tap(find.text('Открыть приглашения').first);
    await tester.pumpAndSettle();

    expect(find.text('Принять'), findsOneWidget);
    expect(find.text('Отклонить'), findsOneWidget);
  });

  testWidgets('TreesScreen в пустом состоянии выводит CTA на приглашения',
      (tester) async {
    treeService = _FakeFamilyTreeService(
      trees: const [],
      invitations: [
        TreeInvitation(
          invitationId: 'invite-1',
          tree: _buildTree(id: 'tree-2', name: 'Семья Шуфляк'),
        ),
      ],
    );
    getIt.registerSingleton<FamilyTreeServiceInterface>(treeService!);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TreeProvider(),
        child: const MaterialApp(home: TreesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('У вас уже есть приглашение в дерево'), findsOneWidget);
    expect(find.text('Открыть приглашения'), findsOneWidget);
    expect(find.text('Создать своё дерево'), findsOneWidget);
  });

  testWidgets('TreesScreen открывает вкладку приглашений по initialTab',
      (tester) async {
    treeService = _FakeFamilyTreeService(
      trees: [
        _buildTree(id: 'tree-1', name: 'Семья Кузнецовых'),
      ],
      invitations: [
        TreeInvitation(
          invitationId: 'invite-1',
          tree: _buildTree(id: 'tree-2', name: 'Rodnya QA Invite'),
        ),
      ],
    );
    getIt.registerSingleton<FamilyTreeServiceInterface>(treeService!);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TreeProvider(),
        child: const MaterialApp(
          home: TreesScreen(initialTab: 'invitations'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.controller?.index, 1);
    expect(find.text('Принять'), findsOneWidget);
    expect(find.text('Отклонить'), findsOneWidget);
  });
}
