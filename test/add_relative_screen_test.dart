import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:lineage/backend/interfaces/auth_service_interface.dart';
import 'package:lineage/backend/interfaces/family_tree_service_interface.dart';
import 'package:lineage/backend/interfaces/profile_service_interface.dart';
import 'package:lineage/models/family_person.dart';
import 'package:lineage/models/family_relation.dart';
import 'package:lineage/models/user_profile.dart';
import 'package:lineage/screens/add_relative_screen.dart';

class _FakeAuthService implements AuthServiceInterface {
  String? lastErrorDescription;

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
  String describeError(Object error) {
    return lastErrorDescription ?? error.toString();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
  bool failOnAdd = false;

  @override
  Future<List<FamilyPerson>> getRelatives(String treeId) async => const [];

  @override
  Future<String> addRelative(String treeId, Map<String, dynamic> personData) {
    if (failOnAdd) {
      throw Exception('save failed');
    }
    return Future.value('person-1');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProfileService implements ProfileServiceInterface {
  @override
  Future<UserProfile?> getCurrentUserProfile() async => UserProfile.create(
        id: 'user-1',
        email: 'user@example.com',
        username: 'tester',
        phoneNumber: '',
        gender: Gender.male,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    await getIt.reset();
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
    getIt.registerSingleton<FamilyTreeServiceInterface>(
        _FakeFamilyTreeService());
    getIt.registerSingleton<ProfileServiceInterface>(_FakeProfileService());
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets('показывает упрощенный режим для первого человека в дереве',
      (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/add',
          builder: (context, state) =>
              const AddRelativeScreen(treeId: 'tree-1'),
        ),
      ],
      initialLocation: '/add',
    );

    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Первый человек в дереве'), findsOneWidget);
    expect(
      find.textContaining('Сначала достаточно имени и пола'),
      findsOneWidget,
    );
    expect(find.text('Что нужно сейчас'), findsOneWidget);
    expect(find.text('Добавить первого человека'), findsOneWidget);
    expect(
      find.textContaining('Связать себя с деревом можно позже'),
      findsOneWidget,
    );
  });

  testWidgets('показывает конкретную CTA для добавления из контекста дерева',
      (tester) async {
    final relatedPerson = FamilyPerson(
      id: 'person-1',
      treeId: 'tree-1',
      name: 'Петров Иван',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/add',
          builder: (context, state) => AddRelativeScreen(
            treeId: 'tree-1',
            relatedTo: relatedPerson,
            predefinedRelation: RelationType.child,
            quickAddMode: true,
          ),
        ),
      ],
      initialLocation: '/add',
    );

    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Добавить ребёнка'), findsOneWidget);
    expect(
      find.textContaining('Связь с Петров Иван уже выбрана'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Связь будет создана автоматически'),
      findsOneWidget,
    );
    expect(find.text('Режим быстрого ввода'), findsOneWidget);
    expect(find.text('Добавить ещё одного'), findsOneWidget);
    expect(find.text('Добавить и открыть на дереве'), findsOneWidget);
  });

  testWidgets('не показывает сырую ошибку сохранения карточки', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final authService = _FakeAuthService()
      ..lastErrorDescription =
          'Не удалось сохранить карточку. Проверьте данные и попробуйте ещё раз.';
    final familyService = _FakeFamilyTreeService()..failOnAdd = true;

    await getIt.reset();
    getIt.registerSingleton<AuthServiceInterface>(authService);
    getIt.registerSingleton<FamilyTreeServiceInterface>(familyService);
    getIt.registerSingleton<ProfileServiceInterface>(_FakeProfileService());

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/add',
          builder: (context, state) =>
              const AddRelativeScreen(treeId: 'tree-1'),
        ),
      ],
      initialLocation: '/add',
    );

    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Фамилия'),
      'Петров',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Имя'),
      'Иван',
    );
    await tester.tap(find.text('Мужской'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Добавить первого человека'));
    await tester.tap(find.text('Добавить первого человека'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text(
        'Не удалось сохранить карточку. Проверьте данные и попробуйте ещё раз.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Exception: save failed'), findsNothing);
  });
}
