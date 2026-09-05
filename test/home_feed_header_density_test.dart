// Density invariant (chunk 19 — шапка ленты на главной): the header
// sections above the feed (stories rail, compose pill, hub tiles) must
// stay compact enough that the first post starts well within the first
// screen on a typical phone. Promoted from a throwaway measurement probe
// used to compare before/after numbers while redesigning
// _buildStoriesSection/_StoryRing, _buildComposeTeaser, _buildHubTile and
// _buildFeedEmptyState/_buildFamilyConnectionPromptCard in
// lib/screens/home_screen.dart and home_screen_sections.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/backend/interfaces/post_service_interface.dart';
import 'package:rodnya/backend/interfaces/story_service_interface.dart';
import 'package:rodnya/backend/models/tree_invitation.dart';
import 'package:rodnya/models/family_person.dart';
import 'package:rodnya/models/family_relation.dart';
import 'package:rodnya/models/family_tree.dart';
import 'package:rodnya/models/post.dart';
import 'package:rodnya/models/story.dart';
import 'package:rodnya/providers/tree_provider.dart';
import 'package:rodnya/screens/home_screen.dart';
import 'package:rodnya/services/app_status_service.dart';
import 'package:rodnya/services/local_storage_service.dart';
import 'package:rodnya/widgets/post_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

// --- Minimal fakes (mirrors test/home_screen_test.dart) — only the
// services HomeScreen looks up unconditionally; everything else is
// guarded by `GetIt.I.isRegistered<...>()` in the screen itself. ---

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
  _FakeLocalStorageService([List<FamilyTree> trees = const []])
      : _treesById = {for (final tree in trees) tree.id: tree};

  final Map<String, FamilyTree> _treesById;

  @override
  Future<List<FamilyTree>> getAllTrees() async => _treesById.values.toList();
  @override
  Future<FamilyTree?> getTree(String treeId) async => _treesById[treeId];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
  _FakeFamilyTreeService({List<FamilyTree>? trees})
      : trees = trees ?? [_buildTree(id: 'tree-1', name: 'Тестовое дерево')];

  final List<FamilyTree> trees;

  @override
  Future<List<FamilyTree>> getUserTrees() async => trees;

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
      Stream.value(const <TreeInvitation>[]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePostService implements PostServiceInterface {
  _FakePostService({this.posts});

  final List<Post>? posts;

  @override
  Future<List<Post>> getPosts({
    String? treeId,
    String? authorId,
    bool onlyBranches = false,
  }) async {
    final data = posts;
    if (data == null) throw Exception('feed unavailable');
    return data;
  }

  @override
  Future<PostsPage> getPostsPage({
    String? treeId,
    int limit = 20,
    String? before,
  }) async {
    return PostsPage(posts: await getPosts(treeId: treeId), nextCursor: null);
  }

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

FamilyTree _buildTree({required String id, required String name}) {
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

  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  testWidgets(
    'HomeScreen (чанк 19): верх первого поста ≤330dp на 412x915 без плашек',
    (tester) async {
      SharedPreferences.setMockInitialValues(
        <String, Object>{'coach_marks_home_tour_shown_v1': true},
      );
      await getIt.reset();
      getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
      getIt.registerSingleton<LocalStorageService>(
        _FakeLocalStorageService(
            [_buildTree(id: 'tree-1', name: 'Тестовое дерево')]),
      );
      getIt.registerSingleton<FamilyTreeServiceInterface>(
        _FakeFamilyTreeService(),
      );
      getIt.registerSingleton<PostServiceInterface>(
        _FakePostService(posts: [
          Post(
            id: 'post-1',
            treeId: 'tree-1',
            authorId: 'author-1',
            authorName: 'Анна',
            content: 'Семейная новость',
            createdAt: DateTime(2026, 4, 13, 10),
          ),
        ]),
      );
      getIt.registerSingleton<StoryServiceInterface>(_FakeStoryService());
      getIt.registerSingleton<AppStatusService>(AppStatusService());
      addTearDown(getIt.reset);

      // 412x915dp phone canvas, dpr 3 — the pain-audit screenshot size.
      tester.view.physicalSize = const Size(412 * 3, 915 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final treeProvider = TreeProvider();
      await treeProvider.selectTree('tree-1', 'Тестовое дерево');
      await tester.pumpWidget(
        ChangeNotifierProvider<TreeProvider>.value(
          value: treeProvider,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Top of the scrollable feed body — right below the fixed topbar,
      // which this chunk explicitly does not touch.
      final bodyTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
      final postTop = tester.getTopLeft(find.byType(PostCard)).dy;

      expect(
        postTop - bodyTop,
        lessThanOrEqualTo(330),
        reason: 'Шапка ленты (истории/композер/хабы) не должна выталкивать '
            'первый пост ниже 330dp на 412×915 — см. docs/DoD чанка 19.',
      );
    },
  );
}
