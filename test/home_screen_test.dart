import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:lineage/backend/interfaces/auth_service_interface.dart';
import 'package:lineage/backend/interfaces/family_tree_service_interface.dart';
import 'package:lineage/backend/models/tree_invitation.dart';
import 'package:lineage/models/family_tree.dart';
import 'package:lineage/models/family_person.dart';
import 'package:lineage/models/family_relation.dart';
import 'package:lineage/providers/tree_provider.dart';
import 'package:lineage/screens/home_screen.dart';
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
  _FakeFamilyTreeService({this.invitations = const []});

  final List<TreeInvitation> invitations;

  @override
  Future<List<FamilyPerson>> getRelatives(String treeId) async => [
        FamilyPerson(
          id: 'person-1',
          treeId: treeId,
          name: 'Иван Петров',
          gender: Gender.male,
          birthDate: DateTime.now().add(const Duration(days: 1)),
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        ),
      ];

  @override
  Future<List<FamilyRelation>> getRelations(String treeId) async => const [];

  @override
  Stream<List<TreeInvitation>> getPendingTreeInvitations() =>
      Stream.value(invitations);

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
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService(),
    );
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets(
    'HomeScreen не падает без legacy post feed и показывает fallback-секцию',
    (tester) async {
      final treeProvider = TreeProvider();
      await treeProvider.selectTree('tree-1', 'Тестовое дерево');

      await tester.pumpWidget(
        ChangeNotifierProvider<TreeProvider>.value(
          value: treeProvider,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Тестовое дерево'), findsOneWidget);
      expect(find.text('Ближайшие события'), findsOneWidget);
      expect(find.text('Главное по семье'), findsOneWidget);
      expect(
        find.text(
          'Отсюда удобно переходить в дерево, к родственникам и в личные сообщения.',
        ),
        findsOneWidget,
      );
      expect(find.text('Истории пока недоступны'), findsNothing);
      expect(find.text('Открыть дерево'), findsOneWidget);
      expect(find.text('Родные'), findsOneWidget);
      expect(find.text('Сообщения'), findsOneWidget);
      expect(find.text('День рождения'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
    },
  );

  testWidgets(
    'HomeScreen без выбранного дерева ведёт к первому действию',
    (tester) async {
      final treeProvider = TreeProvider();

      await tester.pumpWidget(
        ChangeNotifierProvider<TreeProvider>.value(
          value: treeProvider,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Главная'), findsOneWidget);
      expect(find.text('Сначала выберите дерево'), findsOneWidget);
      expect(find.text('Выбрать дерево'), findsOneWidget);
      expect(find.text('Создать дерево'), findsOneWidget);
      expect(find.text('Ближайшие события'), findsNothing);
      expect(find.text('Лента новостей'), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
    },
  );

  testWidgets(
    'HomeScreen показывает приглашение и ведёт сразу во вкладку приглашений',
    (tester) async {
      await getIt.reset();
      getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
      getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
      getIt.registerSingleton<FamilyTreeServiceInterface>(
        _FakeFamilyTreeService(
          invitations: [
            TreeInvitation(
              invitationId: 'invite-1',
              tree: FamilyTree(
                id: 'tree-2',
                name: 'Семья Шуфляк',
                description: '',
                creatorId: 'user-2',
                memberIds: const ['user-2'],
                createdAt: DateTime(2024, 1, 1),
                updatedAt: DateTime(2024, 1, 1),
                isPrivate: true,
                members: const ['user-2'],
              ),
            ),
          ],
        ),
      );

      final treeProvider = TreeProvider();
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) =>
                ChangeNotifierProvider<TreeProvider>.value(
              value: treeProvider,
              child: const HomeScreen(),
            ),
          ),
          GoRoute(
            path: '/trees',
            builder: (context, state) => Scaffold(
              body: Center(
                child: Text('trees ${state.uri.queryParameters['tab']}'),
              ),
            ),
          ),
        ],
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      expect(find.text('Вас ждёт приглашение в дерево'), findsOneWidget);
      expect(find.textContaining('Семья Шуфляк'), findsOneWidget);

      await tester.tap(find.text('Открыть приглашение'));
      await tester.pumpAndSettle();

      expect(find.text('trees invitations'), findsOneWidget);
    },
  );
}
