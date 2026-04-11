import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:lineage/backend/interfaces/auth_service_interface.dart';
import 'package:lineage/backend/interfaces/family_tree_service_interface.dart';
import 'package:lineage/backend/interfaces/post_service_interface.dart';
import 'package:lineage/backend/interfaces/profile_service_interface.dart';
import 'package:lineage/models/post.dart';
import 'package:lineage/models/family_person.dart';
import 'package:lineage/models/family_relation.dart';
import 'package:lineage/models/family_tree.dart';
import 'package:lineage/models/profile_note.dart';
import 'package:lineage/models/user_profile.dart';
import 'package:lineage/providers/tree_provider.dart';
import 'package:lineage/screens/profile_screen.dart';
import 'package:lineage/services/local_storage_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAuthService implements AuthServiceInterface {
  @override
  String? get currentUserId => 'user-1';

  @override
  String? get currentUserEmail => 'user@example.com';

  @override
  String? get currentUserDisplayName => 'Алексей Петров';

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

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
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
    final now = DateTime(2024, 1, 1);
    if (treeId == 'tree-1') {
      return [
        FamilyPerson(
          id: 'self-person',
          treeId: treeId,
          userId: 'user-1',
          name: 'Алексей Петров',
          gender: Gender.male,
          isAlive: true,
          createdAt: now,
          updatedAt: now,
        ),
        FamilyPerson(
          id: 'relative-1',
          treeId: treeId,
          name: 'Иван Петров',
          gender: Gender.male,
          isAlive: true,
          createdAt: now,
          updatedAt: now,
        ),
        FamilyPerson(
          id: 'relative-2',
          treeId: treeId,
          name: 'Мария Петрова',
          gender: Gender.female,
          isAlive: true,
          createdAt: now,
          updatedAt: now,
        ),
      ];
    }

    return [
      FamilyPerson(
        id: 'relative-3',
        treeId: treeId,
        name: 'Алексей Петров',
        gender: Gender.male,
        isAlive: true,
        createdAt: now,
        updatedAt: now,
      ),
    ];
  }

  @override
  Future<List<FamilyRelation>> getRelations(String treeId) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProfileService implements ProfileServiceInterface {
  @override
  Future<UserProfile?> getUserProfile(String userId) async =>
      UserProfile.create(
        id: userId,
        email: 'user@example.com',
        displayName: 'Алексей Петров',
        username: 'petrov',
        phoneNumber: '',
        gender: Gender.male,
      );

  @override
  Stream<List<ProfileNote>> getProfileNotesStream(String userId) =>
      Stream.value(const []);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocalStorageService implements LocalStorageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePostService implements PostServiceInterface {
  @override
  Future<List<Post>> getPosts({
    String? treeId,
    String? authorId,
    bool onlyBranches = false,
  }) async =>
      const <Post>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await getIt.reset();
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService(),
    );
    getIt.registerSingleton<ProfileServiceInterface>(_FakeProfileService());
    getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
    getIt.registerSingleton<PostServiceInterface>(_FakePostService());
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets('ProfileScreen показывает реальное количество родственников',
      (tester) async {
    final treeProvider = TreeProvider();

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Родственники'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Деревья'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });
}
