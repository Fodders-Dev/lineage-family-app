import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/backend/models/tree_invitation.dart';
import 'package:rodnya/models/family_tree.dart';
import 'package:rodnya/providers/tree_provider.dart';
import 'package:rodnya/screens/tree_selector_screen.dart';
import 'package:rodnya/services/local_storage_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
  _FakeFamilyTreeService(
    this.trees, {
    this.invitations = const <TreeInvitation>[],
  });

  final List<FamilyTree> trees;
  final List<TreeInvitation> invitations;
  final List<String> removedTreeIds = <String>[];
  final List<MapEntry<String, bool>> invitationResponses =
      <MapEntry<String, bool>>[];

  @override
  Future<List<FamilyTree>> getUserTrees() async => trees;

  @override
  Stream<List<TreeInvitation>> getPendingTreeInvitations() =>
      Stream<List<TreeInvitation>>.value(invitations);

  @override
  Future<void> respondToTreeInvitation(String invitationId, bool accept) async {
    invitationResponses.add(MapEntry(invitationId, accept));
  }

  @override
  Future<void> removeTree(String treeId) async {
    removedTreeIds.add(treeId);
    trees.removeWhere((tree) => tree.id == treeId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocalStorageService implements LocalStorageService {
  @override
  Future<List<FamilyTree>> getAllTrees() async => const <FamilyTree>[];

  @override
  Future<FamilyTree?> getTree(String treeId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthService implements AuthServiceInterface {
  @override
  String? get currentUserId => 'user-1';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FamilyTree _buildTree({
  required String id,
  required String name,
  String creatorId = 'user-1',
  List<String> memberIds = const ['user-1'],
}) {
  final now = DateTime(2024, 1, 1);
  return FamilyTree(
    id: id,
    name: name,
    description: '',
    creatorId: creatorId,
    memberIds: memberIds,
    createdAt: now,
    updatedAt: now,
    isPrivate: true,
    members: memberIds,
  );
}

GoRouter _buildRouter({
  required Widget initial,
  Widget? createScreen,
}) {
  return GoRouter(
    initialLocation: '/tree',
    routes: [
      GoRoute(
        path: '/tree',
        builder: (context, state) => initial,
      ),
      GoRoute(
        path: '/trees/create',
        builder: (context, state) =>
            createScreen ??
            const Scaffold(body: Center(child: Text('create screen'))),
      ),
    ],
  );
}

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await getIt.reset();
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
    getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets('TreeSelectorScreen ведёт в создание дерева из пустого состояния',
      (tester) async {
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService(const []),
    );

    final router = _buildRouter(initial: const TreeSelectorScreen());

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TreeProvider(),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Создайте дерево'), findsOneWidget);
    expect(find.text('Новая семья'), findsOneWidget);
    expect(find.text('Новый круг'), findsOneWidget);
    // C2: one-line helper clarifies «Семья» vs «Круг».
    expect(
      find.text('Семья — родственники · Круг — близкие без родства'),
      findsOneWidget,
    );

    await tester.tap(find.text('Новая семья'));
    await tester.pumpAndSettle();

    expect(find.text('create screen'), findsOneWidget);
  });

  testWidgets('TreeSelectorScreen показывает быстрые действия над списком',
      (tester) async {
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService([
        _buildTree(id: 'tree-1', name: 'Семья Ивановых'),
        _buildTree(id: 'tree-2', name: 'Семья Петровых'),
      ]),
    );

    final router = _buildRouter(initial: const TreeSelectorScreen());

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TreeProvider(),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Деревья'), findsOneWidget);
    expect(find.text('Ваши деревья'), findsOneWidget);
    expect(find.text('Новая семья'), findsOneWidget);
    expect(find.text('Семья Ивановых'), findsOneWidget);
    expect(find.text('Семья Петровых'), findsOneWidget);
    // C2: kind helper present, and long tree names ellipsize (1 line).
    expect(
      find.text('Семья — родственники · Круг — близкие без родства'),
      findsWidgets,
    );
    final nameText = tester.widget<Text>(find.text('Семья Ивановых'));
    expect(nameText.maxLines, 1);
    expect(nameText.overflow, TextOverflow.ellipsis);
  });

  testWidgets('TreeSelectorScreen группирует активное, свои и чужие деревья',
      (tester) async {
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService([
        _buildTree(id: 'tree-current', name: 'Сейчас открыто'),
        _buildTree(id: 'tree-own', name: 'Моё второе дерево'),
        _buildTree(
          id: 'tree-member',
          name: 'Дерево родственников',
          creatorId: 'user-2',
          memberIds: const ['user-1', 'user-2'],
        ),
      ]),
    );

    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-current', 'Сейчас открыто');

    final router = GoRouter(
      initialLocation: '/tree',
      routes: [
        GoRoute(
          path: '/tree',
          builder: (context, state) => const TreeSelectorScreen(),
        ),
        GoRoute(
          path: '/tree/view/:treeId',
          builder: (context, state) => Scaffold(
            body: Center(child: Text(state.pathParameters['treeId']!)),
          ),
        ),
        GoRoute(
          path: '/trees/create',
          builder: (context, state) => const Scaffold(body: SizedBox.shrink()),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: treeProvider,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // "Выбрано" appears twice: once as the section header above the
    // currently-open tree card, once as a chip inside that card.
    expect(find.text('Выбрано'), findsNWidgets(2));
    expect(find.text('Остальные мои'), findsOneWidget);
    expect(find.text('Сейчас открыто'), findsWidgets);
    expect(find.text('Моё второе дерево'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('Дерево родственников'),
      find.byType(Scrollable).first,
      const Offset(0, -250),
    );
    await tester.pumpAndSettle();
    expect(find.text('По приглашению'), findsOneWidget);
    expect(find.text('Дерево родственников'), findsOneWidget);
    expect(find.text('Участник'), findsOneWidget);
  });

  testWidgets('TreeSelectorScreen показывает счётчик и карточки приглашений',
      (tester) async {
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService(
        [
          _buildTree(id: 'tree-1', name: 'Семья Кузнецовых'),
        ],
        invitations: [
          TreeInvitation(
            invitationId: 'invite-1',
            tree: _buildTree(id: 'tree-2', name: 'Семья Шуфляк'),
            invitedBy: 'Артём',
          ),
        ],
      ),
    );

    final router = _buildRouter(initial: const TreeSelectorScreen());

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TreeProvider(),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Приглашений: 1'), findsOneWidget);
    expect(find.text('Семья Шуфляк'), findsOneWidget);
    expect(find.text('Принять'), findsOneWidget);
    expect(find.text('Отклонить'), findsOneWidget);
  });

  testWidgets(
      'TreeSelectorScreen без своих деревьев но с приглашением показывает секцию',
      (tester) async {
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService(
        [],
        invitations: [
          TreeInvitation(
            invitationId: 'invite-1',
            tree: _buildTree(id: 'tree-2', name: 'Семья Шуфляк'),
          ),
        ],
      ),
    );

    final router = _buildRouter(initial: const TreeSelectorScreen());

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TreeProvider(),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // The empty state is suppressed because the user has actionable
    // content — the pending invitation. They should see the regular
    // list with just the invitation card on top.
    expect(find.text('Создайте дерево'), findsNothing);
    expect(find.text('Приглашение'), findsOneWidget);
    expect(find.text('Принять'), findsOneWidget);
  });

  testWidgets('TreeSelectorScreen даёт удалить своё дерево через меню',
      (tester) async {
    final treeService = _FakeFamilyTreeService([
      _buildTree(id: 'tree-own', name: 'Моё дерево'),
      _buildTree(
        id: 'tree-member',
        name: 'Чужое дерево',
        creatorId: 'user-2',
        memberIds: const ['user-1', 'user-2'],
      ),
    ]);
    getIt.registerSingleton<FamilyTreeServiceInterface>(treeService);

    final router = _buildRouter(initial: const TreeSelectorScreen());

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TreeProvider(),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    final menuButtons = find.byTooltip('Действия');
    expect(menuButtons, findsNWidgets(2));

    await tester.tap(menuButtons.first);
    await tester.pumpAndSettle();
    expect(find.text('Удалить'), findsOneWidget);

    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    expect(find.text('Удалить дерево?'), findsOneWidget);

    await tester.tap(find.text('Удалить дерево'));
    await tester.pumpAndSettle();

    expect(treeService.removedTreeIds, contains('tree-own'));
    expect(find.text('Моё дерево'), findsNothing);
  });

  testWidgets(
      'TreeSelectorScreen с initialFocus=invitations показывает приглашения',
      (tester) async {
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService(
        [
          _buildTree(id: 'tree-1', name: 'Семья Кузнецовых'),
        ],
        invitations: [
          TreeInvitation(
            invitationId: 'invite-1',
            tree: _buildTree(id: 'tree-2', name: 'Rodnya QA Invite'),
          ),
        ],
      ),
    );

    final router = _buildRouter(
      initial: const TreeSelectorScreen(initialFocus: 'invitations'),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TreeProvider(),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Rodnya QA Invite'), findsOneWidget);
    expect(find.text('Принять'), findsOneWidget);
    expect(find.text('Отклонить'), findsOneWidget);
  });
}
