import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:lineage/backend/interfaces/family_tree_service_interface.dart';
import 'package:lineage/models/family_tree.dart';
import 'package:lineage/providers/tree_provider.dart';
import 'package:lineage/screens/tree_selector_screen.dart';
import 'package:lineage/services/local_storage_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
  _FakeFamilyTreeService(this.trees);

  final List<FamilyTree> trees;

  @override
  Future<List<FamilyTree>> getUserTrees() async => trees;

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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await getIt.reset();
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

    final router = GoRouter(
      initialLocation: '/tree',
      routes: [
        GoRoute(
          path: '/tree',
          builder: (context, state) => const TreeSelectorScreen(),
        ),
        GoRoute(
          path: '/trees/create',
          builder: (context, state) => const Scaffold(
            body: Center(child: Text('create screen')),
          ),
        ),
        GoRoute(
          path: '/trees',
          builder: (context, state) => const Scaffold(
            body: Center(child: Text('catalog screen')),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TreeProvider(),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Создайте первое дерево'), findsOneWidget);
    expect(find.text('Создать первое дерево'), findsOneWidget);
    expect(find.text('У меня есть приглашение'), findsOneWidget);

    await tester.tap(find.text('Создать первое дерево'));
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

    final router = GoRouter(
      initialLocation: '/tree',
      routes: [
        GoRoute(
          path: '/tree',
          builder: (context, state) => const TreeSelectorScreen(),
        ),
        GoRoute(
          path: '/trees/create',
          builder: (context, state) => const Scaffold(
            body: Center(child: Text('create screen')),
          ),
        ),
        GoRoute(
          path: '/trees',
          builder: (context, state) => const Scaffold(
            body: Center(child: Text('catalog screen')),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TreeProvider(),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Семейные деревья'), findsOneWidget);
    expect(find.text('Откройте нужное дерево'), findsOneWidget);
    expect(find.text('Создать дерево'), findsOneWidget);
    expect(find.text('Семья Ивановых'), findsOneWidget);
    expect(find.text('Семья Петровых'), findsOneWidget);
  });
}
