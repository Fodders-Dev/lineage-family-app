import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/backend/interfaces/post_service_interface.dart';
import 'package:rodnya/backend/models/tree_invitation.dart';
import 'package:rodnya/models/family_person.dart';
import 'package:rodnya/models/family_relation.dart';
import 'package:rodnya/models/family_tree.dart';
import 'package:rodnya/models/post.dart';
import 'package:rodnya/providers/tree_provider.dart';
import 'package:rodnya/screens/home_screen.dart';
import 'package:rodnya/services/app_status_service.dart';
import 'package:rodnya/services/local_storage_service.dart';
import 'package:rodnya/backend/interfaces/story_service_interface.dart';
import 'package:rodnya/models/story.dart';
import 'package:rodnya/widgets/post_card.dart';

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
  _FakeLocalStorageService(List<FamilyTree> trees)
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
  @override
  Future<List<FamilyTree>> getUserTrees() async => [
        FamilyTree(
          id: 'tree-1',
          name: 'Тестовое дерево',
          description: '',
          creatorId: 'user-1',
          memberIds: const ['user-1'],
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
          isPrivate: true,
          members: const ['user-1'],
        ),
      ];
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
      Stream.value(const []);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePostService implements PostServiceInterface {
  _FakePostService(this.posts);
  final List<Post> posts;
  @override
  Future<List<Post>> getPosts({
    String? treeId,
    String? authorId,
    bool onlyBranches = false,
  }) async =>
      posts;
  @override
  Future<PostsPage> getPostsPage({
    String? treeId,
    int limit = 20,
    String? before,
  }) async =>
      PostsPage(posts: posts, nextCursor: null);
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

  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  setUp(() async {
    await getIt.reset();
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
    getIt.registerSingleton<LocalStorageService>(
      _FakeLocalStorageService([
        FamilyTree(
          id: 'tree-1',
          name: 'Тестовое дерево',
          description: '',
          creatorId: 'user-1',
          memberIds: const ['user-1'],
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
          isPrivate: true,
          members: const ['user-1'],
        ),
      ]),
    );
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService(),
    );
    getIt.registerSingleton<PostServiceInterface>(
      _FakePostService([
        Post(
          id: 'post-1',
          treeId: 'tree-1',
          authorId: 'a1',
          authorName: 'Анна',
          content: 'Семейная новость дня — короткий пост для теста плотности.',
          createdAt: DateTime(2026, 4, 13, 10),
        ),
      ]),
    );
    getIt.registerSingleton<StoryServiceInterface>(_FakeStoryService());
    getIt.registerSingleton<AppStatusService>(AppStatusService());
  });

  tearDown(() async {
    await getIt.reset();
  });

  for (final width in [1280.0, 1440.0]) {
    testWidgets('BEFORE probe at ${width.toInt()}x900', (tester) async {
      tester.view.physicalSize = Size(width * 2, 900 * 2);
      tester.view.devicePixelRatio = 2.0;
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

      final feedBox = find.byWidgetPredicate(
        (w) => w is ConstrainedBox && w.constraints.maxWidth == 720,
      );
      final sidebarBox = find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 340,
      );
      final scrollView = find.byType(CustomScrollView);

      final feedSize = tester.getSize(feedBox.first);
      final sidebarSize = tester.getSize(sidebarBox.first);
      final scrollViewWidth = tester.getSize(scrollView).width;
      final feedTopLeft = tester.getTopLeft(feedBox.first);
      final sidebarTopLeft = tester.getTopLeft(sidebarBox.first);
      final sidebarTopRight = tester.getTopRight(sidebarBox.first);

      final postTopLeft = tester.getTopLeft(find.byType(PostCard));
      final postSize = tester.getSize(find.byType(PostCard));

      // ignore: avoid_print
      print(
        'BEFORE width=$width feedW=${feedSize.width} sidebarW=${sidebarSize.width} '
        'scrollViewW=$scrollViewWidth feedLeft=${feedTopLeft.dx} sidebarLeft=${sidebarTopLeft.dx} '
        'sidebarRight=${sidebarTopRight.dx} postBottom=${postTopLeft.dy + postSize.height}',
      );
    });
  }
}
