import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/backend/interfaces/post_service_interface.dart';
import 'package:rodnya/backend/interfaces/profile_service_interface.dart';
import 'package:rodnya/models/account_linking_status.dart';
import 'package:rodnya/backend/interfaces/story_service_interface.dart';
import 'package:rodnya/models/post.dart';
import 'package:rodnya/models/family_person.dart';
import 'package:rodnya/models/family_relation.dart';
import 'package:rodnya/models/family_tree.dart';
import 'package:rodnya/models/profile_contribution.dart';
import 'package:rodnya/models/profile_note.dart';
import 'package:rodnya/models/story.dart';
import 'package:rodnya/models/tree_change_record.dart';
import 'package:rodnya/models/user_profile.dart';
import 'package:rodnya/providers/tree_provider.dart';
import 'package:rodnya/screens/profile_screen.dart';
import 'package:rodnya/services/app_status_service.dart';
import 'package:rodnya/services/local_storage_service.dart';
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
  final List<TreeChangeRecord> historyRecords = [
    TreeChangeRecord(
      id: 'change-1',
      treeId: 'tree-1',
      actorId: 'user-1',
      type: 'person.updated',
      personId: 'self-person',
      personIds: ['self-person'],
      createdAt: DateTime(2024, 1, 2, 12, 0),
    ),
  ];

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
  Future<List<TreeChangeRecord>> getTreeHistory({
    required String treeId,
    String? personId,
    String? type,
    String? actorId,
  }) async {
    return historyRecords.where((record) {
      if (record.treeId != treeId) {
        return false;
      }
      if (personId != null &&
          personId.isNotEmpty &&
          record.personId != personId) {
        return false;
      }
      return true;
    }).toList();
  }

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
  Future<AccountLinkingStatus> getCurrentAccountLinkingStatus() async =>
      const AccountLinkingStatus(
        summaryTitle: 'Аккаунт подтверждён через Telegram',
        summaryDetail: 'Основной канал: Telegram',
        mergeStrategySummary:
            'Для объединения используем identity провайдера, email и приглашения.',
        trustedChannels: [
          AccountTrustedChannel(
            provider: 'telegram',
            label: 'Telegram',
            description: 'Подтверждённый канал',
            verificationLabel: 'Связь подтверждена через Telegram',
            isLinked: true,
            isTrustedChannel: true,
            isLoginMethod: true,
            isPrimary: true,
          ),
          AccountTrustedChannel(
            provider: 'google',
            label: 'Google',
            description: 'Резервный вход',
            verificationLabel: 'Аккаунт подтверждён через Google',
            isLinked: true,
            isTrustedChannel: true,
            isLoginMethod: true,
            isPrimary: false,
          ),
        ],
      );

  @override
  Future<List<ProfileContribution>> getPendingProfileContributions() async =>
      const <ProfileContribution>[];

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

class _FakeStoryService implements StoryServiceInterface {
  @override
  Future<List<Story>> getStories({
    String? treeId,
    String? authorId,
    bool includeArchive = false,
  }) async =>
      const <Story>[];

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
    getIt.registerSingleton<StoryServiceInterface>(_FakeStoryService());
    getIt.registerSingleton<AppStatusService>(AppStatusService());
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

    // Labels follow the actual counts instead of using one fixed form.
    expect(find.text('родственника'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('дерева'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets(
      'ProfileScreen показывает карточку пользователя в активном дереве',
      (tester) async {
    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-1', 'Первое дерево');

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );

    await tester.pumpAndSettle();

    // Profile Redesign: the new ProfileHeroCard is taller than the
    // legacy PersonDossierView, so the inline tree-card sits below
    // the 600 px test viewport. We assert presence regardless of
    // viewport position via skipOffstage: false — the user reaches it
    // by scrolling.
    expect(
      find.text('Карточка в дереве', skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.text('Алексей Петров', skipOffstage: false),
      findsWidgets,
    );
    expect(
      find.byTooltip('Фото пока нет', skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.byTooltip('Открыть карточку', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byTooltip('История', skipOffstage: false), findsOneWidget);
  });

  testWidgets('ProfileScreen показывает доверенные каналы и профильный код',
      (tester) async {
    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-1', 'Первое дерево');

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );

    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Настройки аккаунта'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('Настройки аккаунта'), findsOneWidget);
    // Chunk 14 density pass: the row's standalone «Настройки» button
    // became a chevron (Telegram-style nav row) — assert the
    // affordance instead of the button label it replaced.
    expect(find.byIcon(Icons.chevron_right_rounded), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('Профильный код'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Профильный код'), findsOneWidget);
    expect(find.textContaining('@petrov'), findsWidgets);
  });

  testWidgets(
      'ProfileScreen открывает историю из карточки пользователя в активном дереве',
      (tester) async {
    final treeProvider = TreeProvider();
    await treeProvider.selectTree('tree-1', 'Первое дерево');

    await tester.pumpWidget(
      ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );

    await tester.pumpAndSettle();

    // Tree-card is now below the redesign hero, so scroll it into the
    // viewport before the tap — `find.byTooltip` defaults to skipping
    // offstage widgets, and `tester.tap` requires hit-testable hits.
    await tester.scrollUntilVisible(
      find.byTooltip('История'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('История'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('История изменений'), findsOneWidget);
    expect(find.text('Обновлён профиль'), findsOneWidget);
  });

  testWidgets(
    'ProfileScreen renders the bottom «Выйти из аккаунта» button',
    (tester) async {
      // Profile Redesign: the sign-out button is now a prominent
      // surface at the tail of the profile, not just a popup-menu
      // entry. We assert presence + redesign warm-coloured ink so the
      // styling can't silently regress.
      final treeProvider = TreeProvider();
      await tester.pumpWidget(
        ChangeNotifierProvider<TreeProvider>.value(
          value: treeProvider,
          child: const MaterialApp(home: ProfileScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Выйти из аккаунта', skipOffstage: false),
        findsOneWidget,
      );
    },
  );
}
