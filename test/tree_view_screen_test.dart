import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:lineage/backend/interfaces/auth_service_interface.dart';
import 'package:lineage/backend/interfaces/family_tree_service_interface.dart';
import 'package:lineage/models/family_person.dart';
import 'package:lineage/models/family_relation.dart';
import 'package:lineage/providers/tree_provider.dart';
import 'package:lineage/screens/tree_view_screen.dart';
import 'package:lineage/services/local_storage_service.dart';
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

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
  final List<String> requestedTreeIds = [];
  bool showFirstPerson = false;

  @override
  Future<List<FamilyPerson>> getRelatives(String treeId) async {
    requestedTreeIds.add(treeId);
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
  Future<List<FamilyRelation>> getRelations(String treeId) async => const [];

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
}
