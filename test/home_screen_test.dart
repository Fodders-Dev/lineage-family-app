import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/backend/interfaces/post_service_interface.dart';
import 'package:rodnya/backend/interfaces/gathering_service_interface.dart';
import 'package:rodnya/backend/interfaces/poll_service_interface.dart';
import 'package:rodnya/backend/interfaces/story_service_interface.dart';
import 'package:rodnya/backend/backend_runtime_config.dart';
import 'package:rodnya/backend/models/tree_invitation.dart';
import 'package:rodnya/models/family_tree.dart';
import 'package:rodnya/models/family_person.dart';
import 'package:rodnya/models/family_relation.dart';
import 'package:rodnya/models/post.dart';
import 'package:rodnya/models/gathering.dart';
import 'package:rodnya/models/poll.dart';
import 'package:rodnya/models/story.dart';
import 'package:rodnya/providers/tree_provider.dart';
import 'package:rodnya/screens/home_screen.dart';
import 'package:rodnya/services/app_status_service.dart';
import 'package:rodnya/services/browser_notification_bridge.dart';
import 'package:rodnya/services/custom_api_notification_service.dart';
import 'package:rodnya/services/local_storage_service.dart';
import 'package:rodnya/widgets/event_card.dart';
import 'package:rodnya/widgets/post_card.dart';
import 'package:rodnya/widgets/gathering_card.dart';
import 'package:rodnya/widgets/poll_card.dart';
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
  _FakeFamilyTreeService({
    this.invitations = const [],
    List<FamilyTree>? trees,
    this.relativesOverride,
  }) : trees = trees ?? [_buildTree(id: 'tree-1', name: 'Тестовое дерево')];

  final List<TreeInvitation> invitations;
  final List<FamilyTree> trees;

  /// When set, `getRelatives` returns this instead of the default
  /// single relative — lets a test simulate an empty tree (no audience).
  final List<FamilyPerson>? relativesOverride;

  @override
  Future<List<FamilyTree>> getUserTrees() async => trees;

  @override
  Future<List<FamilyPerson>> getRelatives(String treeId) async =>
      relativesOverride ??
      [
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
    if (data == null) {
      throw Exception('feed unavailable');
    }
    return data;
  }

  // S3: фолбэк-семантика старого бэка — всё одной страницей.
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

class _FakeGatheringService implements GatheringServiceInterface {
  _FakeGatheringService({this.gatherings = const []});

  final List<Gathering> gatherings;

  @override
  Future<List<Gathering>> getGatherings({required String treeId}) async =>
      gatherings;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePollService implements PollServiceInterface {
  _FakePollService({this.polls = const []});

  final List<Poll> polls;

  @override
  Future<List<Poll>> getPolls({String? treeId}) async => polls;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBrowserNotificationBridge implements BrowserNotificationBridge {
  _FakeBrowserNotificationBridge({
    required this.permissionStatusValue,
  });

  BrowserNotificationPermissionStatus permissionStatusValue;
  int permissionRequests = 0;
  int pushSubscriptionRequests = 0;
  int pushUnsubscribeCalls = 0;

  @override
  bool get isSupported => true;

  @override
  bool get isPushSupported => true;

  @override
  bool get isIosWeb => false;

  @override
  bool get isStandalone => false;

  @override
  BrowserNotificationPermissionStatus get permissionStatus =>
      permissionStatusValue;

  @override
  Future<BrowserNotificationPermissionStatus> requestPermission({
    bool prompt = true,
  }) async {
    permissionRequests += 1;
    if (permissionStatusValue ==
        BrowserNotificationPermissionStatus.defaultState) {
      permissionStatusValue = BrowserNotificationPermissionStatus.granted;
    }
    return permissionStatusValue;
  }

  @override
  Future<void> showNotification({
    required String title,
    required String body,
    String? tag,
    VoidCallback? onClick,
  }) async {}

  @override
  Future<BrowserPushSubscription?> subscribeToPush({
    required String publicKey,
  }) async {
    pushSubscriptionRequests += 1;
    return const BrowserPushSubscription(token: '{"endpoint":"test"}');
  }

  @override
  Future<void> unsubscribeFromPush() async {
    pushUnsubscribeCalls += 1;
  }
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

  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  setUp(() async {
    // Coach-mark tour pre-marked as shown by default so unrelated tests
    // don't schedule its delayed timer (would linger as a pending timer).
    // The E first-launch test clears this explicitly.
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
    getIt.registerSingleton<PostServiceInterface>(_FakePostService());
    getIt.registerSingleton<StoryServiceInterface>(_FakeStoryService());
    getIt.registerSingleton<AppStatusService>(AppStatusService());
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets(
    'HomeScreen не падает без legacy post feed и показывает fallback-секцию',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
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

      expect(find.text('Родня'), findsWidgets);
      expect(find.text('Дерево активно'), findsNothing);
      expect(find.text('Поделиться с роднёй...'), findsOneWidget);
      // Legacy «Семья» chip removed in Step 1 audience-mode rework.
      expect(find.widgetWithText(ChoiceChip, 'Семья'), findsNothing);
      expect(find.text('Новый пост'), findsNothing);
      expect(find.text('День рождения'), findsOneWidget);
      // CTA hierarchy (P4b): the redundant compose FAB was removed — the
      // inline «Поделиться с роднёй…» teaser is the single compose CTA.
      expect(find.byType(FloatingActionButton), findsNothing);
      // 2a: альбом-иконка из топбара убрана (дедуп) — единственный вход
      // теперь подписанный тайл «Альбом семьи» в строке хабов.
      expect(find.byIcon(Icons.photo_library_outlined), findsNothing);
      expect(find.byIcon(Icons.photo_album_outlined), findsOneWidget);
      // UX-core SC4: «Календарь» is a nav tab now — its topbar icon was
      // removed as a duplicate (the events-rail «Все события» link stays).
      expect(find.byIcon(Icons.calendar_month_outlined), findsNothing);
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

      expect(find.text('Родня'), findsWidgets);
      expect(find.text('Выберите дерево'), findsOneWidget);
      expect(find.text('Нет активного дерева'), findsNothing);
      expect(find.text('Создать граф'), findsNothing);
      expect(find.text('Лента новостей'), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
    },
  );

  testWidgets(
    'HomeScreen показывает приглашение и ведёт сразу во вкладку приглашений',
    (tester) async {
      await getIt.reset();
      getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
      getIt.registerSingleton<LocalStorageService>(
        _FakeLocalStorageService(
            [_buildTree(id: 'tree-1', name: 'Тестовое дерево')]),
      );
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
      getIt.registerSingleton<PostServiceInterface>(_FakePostService());
      getIt.registerSingleton<StoryServiceInterface>(_FakeStoryService());
      getIt.registerSingleton<AppStatusService>(AppStatusService());

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
          // The home banner deep-links to the canonical selector
          // surface (`/tree?selector=1&tab=invitations`), not the
          // legacy `/trees` overlay which has been folded into it.
          // We register both as catch-alls so this test stays
          // resilient if the routing convention is tweaked again.
          GoRoute(
            path: '/tree',
            builder: (context, state) => Scaffold(
              body: Center(
                child: Text('selector ${state.uri.queryParameters['tab']}'),
              ),
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

      expect(find.text('Семья Шуфляк'), findsOneWidget);
      expect(find.textContaining('Семья Шуфляк'), findsOneWidget);

      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();

      // Assertion is path-agnostic: any of the legacy banner targets
      // is acceptable as long as the `tab=invitations` query made
      // it through.
      final landed = find.textContaining('invitations');
      expect(landed, findsOneWidget);
    },
  );

  testWidgets(
    'HomeScreen монтируется с browser notification service без отдельного prompt',
    (tester) async {
      final bridge = _FakeBrowserNotificationBridge(
        permissionStatusValue: BrowserNotificationPermissionStatus.defaultState,
      );
      final notificationService = await CustomApiNotificationService.create(
        runtimeConfig: const BackendRuntimeConfig(),
        browserNotificationBridge: bridge,
      );
      await notificationService.setNotificationsEnabled(false);
      getIt
          .registerSingleton<CustomApiNotificationService>(notificationService);

      final treeProvider = TreeProvider();
      await treeProvider.selectTree('tree-1', 'Тестовое дерево');

      await tester.pumpWidget(
        ChangeNotifierProvider<TreeProvider>.value(
          value: treeProvider,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Включите уведомления о семье'), findsNothing);
      expect(find.byTooltip('Активность'), findsOneWidget);
      expect(notificationService.notificationsEnabled, isFalse);
      expect(bridge.permissionRequests, 0);
    },
  );

  testWidgets(
    'HomeScreen показывает компактные фильтры событий на главной',
    (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
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

      expect(find.widgetWithText(ChoiceChip, 'Все'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Родня'), findsOneWidget);
      expect(find.bySemanticsLabel('home-event-filter-all'), findsOneWidget);
      expect(find.bySemanticsLabel('home-event-filter-rodnya'), findsOneWidget);
      expect(find.byType(EventCard), findsAtLeastNWidgets(2));

      await tester.tap(find.widgetWithText(ChoiceChip, 'Родня'));
      await tester.pumpAndSettle();

      expect(find.byType(EventCard), findsOneWidget);
      expect(find.text('День рождения'), findsOneWidget);
      semantics.dispose();
    },
  );

  // Earlier this asserted on the «Семья / Близкие / Архив /
  // Истории» content-type chip strip. Step 1's audience-mode
  // rework collapsed the home feed onto a single axis — branch
  // chips — and dropped the content-type strip entirely. The new
  // assertion just verifies that the audience-mode load delivers
  // every post the fake service hands back; branch-chip behavior
  // is exercised separately when there's >1 branch in the
  // TreeProvider (which would require a fuller fixture and a
  // dedicated test — punted to keep this one focused).
  testWidgets(
    'HomeScreen рендерит все посты из аудитории без content-type фильтра',
    (tester) async {
      // P1: posts render in a virtualized SliverList. Give the test a
      // tall narrow viewport (width < 1180 → phone layout) so all three
      // short posts mount in-frame without needing to scroll.
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await getIt.unregister<PostServiceInterface>();
      getIt.registerSingleton<PostServiceInterface>(
        _FakePostService(
          posts: [
            Post(
              id: 'post-family',
              treeId: 'tree-1',
              authorId: 'author-1',
              authorName: 'Анна',
              content: 'Семейная новость',
              createdAt: DateTime(2026, 4, 13, 10),
            ),
            Post(
              id: 'post-circle',
              treeId: 'tree-1',
              authorId: 'author-2',
              authorName: 'Иван',
              content: 'Новость круга',
              createdAt: DateTime(2026, 4, 13, 11),
              circleId: 'circle-1',
            ),
            Post(
              id: 'post-public',
              treeId: 'tree-1',
              authorId: 'author-4',
              authorName: 'Олег',
              content: 'Публичная новость',
              createdAt: DateTime(2026, 4, 13, 13),
              isPublic: true,
            ),
          ],
        ),
      );

      final treeProvider = TreeProvider();
      await treeProvider.selectTree('tree-1', 'Тестовое дерево');

      await tester.pumpWidget(
        ChangeNotifierProvider<TreeProvider>.value(
          value: treeProvider,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Legacy content-type chips are gone.
      expect(find.widgetWithText(ChoiceChip, 'Близкие'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Архив'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Истории'), findsNothing);
      // Every post the fake service returned is on screen — feed
      // doesn't narrow by content type, only by branch via the
      // chip strip (which is hidden with a single branch).
      expect(find.text('Семейная новость'), findsOneWidget);
      expect(find.text('Новость круга'), findsOneWidget);
      expect(find.text('Публичная новость'), findsOneWidget);
    },
  );

  testWidgets(
    'HomeScreen mixes posts, gatherings and polls, newest-first (E5d)',
    (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await getIt.unregister<PostServiceInterface>();
      getIt.registerSingleton<PostServiceInterface>(
        _FakePostService(
          posts: [
            Post(
              id: 'post-1',
              treeId: 'tree-1',
              authorId: 'a1',
              authorName: 'Анна',
              content: 'Семейная новость',
              createdAt: DateTime(2026, 4, 13, 10), // oldest
            ),
          ],
        ),
      );
      getIt.registerSingleton<GatheringServiceInterface>(
        _FakeGatheringService(
          gatherings: [
            Gathering(
              id: 'gath-1',
              treeId: 'tree-1',
              authorId: 'a2',
              authorName: 'Иван',
              title: 'Шашлыки на даче',
              startAt: DateTime(2026, 7, 1, 15),
              createdAt: DateTime(2026, 4, 13, 12), // middle
            ),
          ],
        ),
      );
      getIt.registerSingleton<PollServiceInterface>(
        _FakePollService(
          polls: [
            Poll(
              id: 'poll-1',
              treeId: 'tree-1',
              authorId: 'a3',
              authorName: 'Оля',
              question: 'Когда удобнее?',
              options: const [
                PollOption(id: 'o1', text: 'Суббота'),
                PollOption(id: 'o2', text: 'Воскресенье'),
              ],
              createdAt: DateTime(2026, 4, 13, 14), // newest
            ),
          ],
        ),
      );

      final treeProvider = TreeProvider();
      await treeProvider.selectTree('tree-1', 'Тестовое дерево');

      await tester.pumpWidget(
        ChangeNotifierProvider<TreeProvider>.value(
          value: treeProvider,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // All three kinds of content are in the feed.
      expect(find.byType(PostCard), findsOneWidget);
      expect(find.byType(GatheringCard), findsOneWidget);
      expect(find.byType(PollCard), findsOneWidget);
      expect(find.text('Семейная новость'), findsOneWidget);
      expect(find.text('Шашлыки на даче'), findsOneWidget);
      expect(find.text('Когда удобнее?'), findsOneWidget);

      // Newest-first: poll (14:00) above gathering (12:00) above post (10:00).
      final pollY = tester.getTopLeft(find.byType(PollCard)).dy;
      final gatheringY = tester.getTopLeft(find.byType(GatheringCard)).dy;
      final postY = tester.getTopLeft(find.byType(PostCard)).dy;
      expect(pollY, lessThan(gatheringY));
      expect(gatheringY, lessThan(postY));

      // The composer consolidates every create entry into one «+» menu;
      // open it and confirm the poll entry is surfaced there.
      await tester.tap(find.byKey(const Key('compose-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('compose-poll')), findsOneWidget);
    },
  );

  testWidgets(
    'composer teaser keeps text single-line and hides inline create icons',
    (tester) async {
      // Narrow phone width: before consolidation, four inline create icons
      // squeezed «Поделиться с роднёй…» into a cramped wrap. Now the text is
      // single-line + ellipsis and only one «+» entry sits beside it.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
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

      final teaser = tester.widget<Text>(find.text('Поделиться с роднёй...'));
      expect(teaser.maxLines, 1);
      expect(teaser.overflow, TextOverflow.ellipsis);

      // A single consolidated «+» entry; the old inline icons are gone from
      // the row (they now live inside the menu, mounted only when opened).
      expect(find.byKey(const Key('compose-open')), findsOneWidget);
      expect(find.byKey(const Key('compose-gathering')), findsNothing);
      expect(find.byKey(const Key('compose-poll')), findsNothing);

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compose «+» opens a menu with all five create entries',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
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

      await tester.tap(find.byKey(const Key('compose-open')));
      await tester.pumpAndSettle();

      // All five create flows are reachable from the one menu.
      expect(find.byKey(const Key('compose-post')), findsOneWidget);
      expect(find.byKey(const Key('compose-photo')), findsOneWidget);
      expect(find.byKey(const Key('compose-video')), findsOneWidget);
      expect(find.byKey(const Key('compose-gathering')), findsOneWidget);
      expect(find.byKey(const Key('compose-poll')), findsOneWidget);
      expect(find.text('Пост'), findsOneWidget);
      expect(find.text('Опрос'), findsOneWidget);
    },
  );

  testWidgets(
    'Q3: topbar icon buttons have ≥48dp touch targets',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
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

      for (final tip in const [
        'Поиск по постам',
        'Активность',
      ]) {
        final size = tester.getSize(find.byTooltip(tip));
        expect(size.width, greaterThanOrEqualTo(48.0), reason: tip);
        expect(size.height, greaterThanOrEqualTo(48.0), reason: tip);
      }
    },
  );

  testWidgets(
    'HomeScreen виртуализирует ленту — офф-скрин карточки не монтируются (P1)',
    (tester) async {
      // Narrow width (phone layout) + modest height. A non-virtualized
      // Column inside one SliverToBoxAdapter would mount all 30
      // PostCards regardless of viewport; the P1 SliverList only builds
      // the cards near the viewport, so the mounted count stays well
      // below 30.
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await getIt.unregister<PostServiceInterface>();
      getIt.registerSingleton<PostServiceInterface>(
        _FakePostService(
          posts: List.generate(
            30,
            (i) => Post(
              id: 'post-$i',
              treeId: 'tree-1',
              authorId: 'author-$i',
              authorName: 'Автор $i',
              content: 'Запись номер $i с достаточным текстом, чтобы карточка '
                  'занимала заметную высоту в ленте.',
              createdAt: DateTime(2026, 4, 13, 10).add(Duration(minutes: i)),
            ),
          ),
        ),
      );

      final treeProvider = TreeProvider();
      await treeProvider.selectTree('tree-1', 'Тестовое дерево');

      await tester.pumpWidget(
        ChangeNotifierProvider<TreeProvider>.value(
          value: treeProvider,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final mountedCards = find.byType(PostCard).evaluate().length;
      expect(mountedCards, greaterThan(0));
      expect(
        mountedCards,
        lessThan(30),
        reason: 'SliverList must recycle off-screen cards, not mount all 30',
      );
      // The top of the feed is rendered (first post visible).
      expect(find.textContaining('Запись номер 0'), findsOneWidget);
    },
  );

  testWidgets(
    'HomeScreen открывает экран активности из app bar',
    (tester) async {
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
            path: '/notifications',
            builder: (context, state) =>
                const Scaffold(body: Center(child: Text('notifications'))),
          ),
        ],
      );
      if (!getIt.isRegistered<PostServiceInterface>()) {
        getIt.registerSingleton<PostServiceInterface>(_FakePostService());
      }

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Активность'));
      await tester.pumpAndSettle();

      expect(find.text('notifications'), findsOneWidget);
    },
  );

  testWidgets(
    'HomeScreen показывает семейный вопрос дня и ведёт в ask-story route',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await getIt.unregister<FamilyTreeServiceInterface>();
      getIt.registerSingleton<FamilyTreeServiceInterface>(
        _FakeFamilyTreeService(
          relativesOverride: [
            FamilyPerson(
              id: 'grandmother',
              treeId: 'tree-1',
              userId: 'anna-user',
              name: 'Петрова Анна',
              relation: 'бабушка',
              gender: Gender.female,
              birthDate: DateTime(1945, 5, 3),
              isAlive: true,
              createdAt: DateTime(2024, 1, 1),
              updatedAt: DateTime(2024, 1, 1),
            ),
          ],
        ),
      );

      final treeProvider = TreeProvider();
      await treeProvider.selectTree('tree-1', 'Тестовое дерево');
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
            path: '/relative/details/:personId',
            builder: (context, state) => Scaffold(
              body: Text(
                'details ${state.pathParameters['personId']} '
                '${state.uri.queryParameters['action']}',
              ),
            ),
          ),
        ],
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('home-family-connection-prompt')),
          findsOneWidget);
      expect(find.text('Спросить, пока можно услышать'), findsOneWidget);

      await tester.tap(find.byKey(const Key('family-connection-ask-story')));
      await tester.pumpAndSettle();

      expect(find.text('details grandmother story'), findsOneWidget);
    },
  );

  testWidgets(
    'HomeScreen пустая лента без родни → CTA «Добавить родственника» (P4)',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // Empty feed + a tree with nobody but the viewer (no relatives).
      await getIt.unregister<FamilyTreeServiceInterface>();
      getIt.registerSingleton<FamilyTreeServiceInterface>(
        _FakeFamilyTreeService(relativesOverride: const <FamilyPerson>[]),
      );
      await getIt.unregister<PostServiceInterface>();
      getIt.registerSingleton<PostServiceInterface>(
        _FakePostService(posts: const <Post>[]),
      );

      final treeProvider = TreeProvider();
      await treeProvider.selectTree('tree-1', 'Тестовое дерево');

      await tester.pumpWidget(
        ChangeNotifierProvider<TreeProvider>.value(
          value: treeProvider,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Начните своё дерево'), findsOneWidget);
      expect(find.text('Добавить родственника'), findsOneWidget);
      expect(find.text('Написать'), findsNothing);
    },
  );

  testWidgets(
    'HomeScreen пустая лента с роднёй → CTA «Написать» (P4)',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // Empty feed but the default fake tree HAS a relative → audience
      // exists → guide to write, not to add a relative.
      await getIt.unregister<PostServiceInterface>();
      getIt.registerSingleton<PostServiceInterface>(
        _FakePostService(posts: const <Post>[]),
      );

      final treeProvider = TreeProvider();
      await treeProvider.selectTree('tree-1', 'Тестовое дерево');

      await tester.pumpWidget(
        ChangeNotifierProvider<TreeProvider>.value(
          value: treeProvider,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Пока тихо в ленте'), findsOneWidget);
      expect(find.text('Написать'), findsOneWidget);
      expect(find.text('Добавить родственника'), findsNothing);
    },
  );

  testWidgets(
    'HomeScreen: на узкой раскладке вместо рельса — компактный тайл ближайшего события (2a)',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
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

      // 2a: тяжёлый рельс (шапка + чипы + горизонтальный скролл) на узкой
      // раскладке заменён одним слим-тайлом «<когда> — <кто>» → /calendar.
      expect(find.byKey(const Key('home-calendar-entry')), findsOneWidget);
      expect(find.text('Ближайшие события'), findsNothing);
      expect(find.bySemanticsLabel('home-event-filter-all'), findsNothing);
      // Тайл подписан «Все события» — вход в календарь остаётся именованным.
      expect(find.text('Все события'), findsOneWidget);
    },
  );

  testWidgets(
    'S3: feed exposes labelled Calendar and Album entries',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
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

      // Calendar: the events-rail caption carries a labelled «Все события»
      // link with a real tap handler (routes to /calendar in production).
      expect(find.text('Все события'), findsOneWidget);
      final calendarLink = tester.widget<InkWell>(
        find
            .ancestor(
              of: find.text('Все события'),
              matching: find.byType(InkWell),
            )
            .first,
      );
      expect(calendarLink.onTap, isNotNull);

      // Album: a named link-card with its own tap target (→ /post/album).
      expect(find.byKey(const Key('home-album-entry')), findsOneWidget);
      expect(find.text('Альбом семьи'), findsOneWidget);
      final albumLink =
          tester.widget<InkWell>(find.byKey(const Key('home-album-entry')));
      expect(albumLink.onTap, isNotNull);
    },
  );

  testWidgets(
    'HomeScreen scroll-aware action does not cover the feed',
    (tester) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await getIt.unregister<PostServiceInterface>();
      getIt.registerSingleton<PostServiceInterface>(
        _FakePostService(
          posts: List.generate(
            30,
            (i) => Post(
              id: 'post-$i',
              treeId: 'tree-1',
              authorId: 'author-$i',
              authorName: 'Автор $i',
              content: 'Запись $i с достаточным текстом для высоты карточки.',
              createdAt: DateTime(2026, 4, 13, 10).add(Duration(minutes: i)),
            ),
          ),
        ),
      );

      final treeProvider = TreeProvider();
      await treeProvider.selectTree('tree-1', 'Тестовое дерево');

      await tester.pumpWidget(
        ChangeNotifierProvider<TreeProvider>.value(
          value: treeProvider,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // At the top the inline compose teaser is the CTA — no sticky action.
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byKey(const Key('compose-action-bar')), findsNothing);

      // Scroll past the teaser → a layout-owned action row takes over.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();

      final actionBar = find.byKey(const Key('compose-action-bar'));
      expect(actionBar, findsOneWidget);
      expect(find.byKey(const Key('compose-action')), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
      final feedRect = tester.getRect(find.byType(CustomScrollView));
      final actionBarRect = tester.getRect(actionBar);
      expect(feedRect.bottom <= actionBarRect.top, isTrue);
      expect(feedRect.overlaps(actionBarRect), isFalse);
    },
  );

  testWidgets(
    'HomeScreen показывает coach-mark тур на первом запуске, скип персистится (E)',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
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

      // Gated behind a short delay so anchors lay out → not shown yet.
      expect(find.byKey(const Key('coach-mark-tour')), findsNothing);

      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('coach-mark-tour')), findsOneWidget);

      // Skip → dismissed (and persisted via markShown).
      await tester.tap(find.byKey(const Key('coach-mark-skip')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('coach-mark-tour')), findsNothing);
    },
  );

  testWidgets(
    'HomeScreen НЕ показывает тур, если он уже показан (E)',
    (tester) async {
      SharedPreferences.setMockInitialValues(
        <String, Object>{'coach_marks_home_tour_shown_v1': true},
      );
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
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
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('coach-mark-tour')), findsNothing);
    },
  );
}
