import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/backend/interfaces/post_service_interface.dart';
import 'package:rodnya/models/post.dart';
import 'package:rodnya/widgets/post_card.dart';

void main() {
  final getIt = GetIt.instance;

  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  setUp(() async {
    await getIt.reset();
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets(
      'PostCard syncs likes from server response instead of local guess',
      (tester) async {
    getIt.registerSingleton<PostServiceInterface>(
      _FakePostService(
        onToggleLike: (_) async => Post(
          id: 'post-1',
          treeId: 'tree-1',
          authorId: 'author-1',
          authorName: 'Анна',
          content: 'Семейная новость',
          createdAt: DateTime(2026, 4, 13, 10),
          likedBy: const ['user-1', 'user-2'],
          commentCount: 0,
        ),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostCard(
            post: Post(
              id: 'post-1',
              treeId: 'tree-1',
              authorId: 'author-1',
              authorName: 'Анна',
              content: 'Семейная новость',
              createdAt: DateTime(2026, 4, 13, 10),
              likedBy: const [],
              commentCount: 0,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Ревью чанка 20: отдельной строки чипов-счётчиков больше нет —
    // счётчик стоит внутри кнопки «Тепло» рядом с единственным сердцем.
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('PostCard rolls back like state when backend rejects update',
      (tester) async {
    getIt.registerSingleton<PostServiceInterface>(
      _FakePostService(
        onToggleLike: (_) async => throw Exception('like failed'),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostCard(
            post: Post(
              id: 'post-1',
              treeId: 'tree-1',
              authorId: 'author-1',
              authorName: 'Анна',
              content: 'Семейная новость',
              createdAt: DateTime(2026, 4, 13, 10),
              likedBy: const [],
              commentCount: 0,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(find.textContaining('Не удалось обновить реакцию'), findsOneWidget);
  });

  testWidgets('PostCard keeps post visible when image URL is not renderable',
      (tester) async {
    getIt.registerSingleton<PostServiceInterface>(
      _FakePostService(onToggleLike: (_) async => throw Exception('unused')),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PostCard(
              post: Post(
                id: 'post-1',
                treeId: 'tree-1',
                authorId: 'author-1',
                authorName: 'Анна',
                content: 'Семейная новость',
                imageUrls: const ['/media/posts/broken.jpeg'],
                createdAt: DateTime(2026, 4, 13, 10),
                likedBy: const [],
                commentCount: 0,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(find.text('Семейная новость'), findsOneWidget);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ── Ship 2026-05-26 (UX audit Screen 3.5): post delete confirmation ──
  //
  // Pre-fix: plain AlertDialog с TextButton(red), barrierDismissible
  // (tap outside cancels), generic copy. Post-fix: shared
  // SafeDeleteConfirmationDialog с severity icon + destructive button
  // + barrierDismissible=false + audit-aligned consequence copy.

  testWidgets(
    'PostCard delete: overflow → menu Удалить → safe-delete dialog → confirm '
    'calls deletePost',
    (tester) async {
      final postService = _FakePostService(
        onToggleLike: (_) async => throw Exception('unused'),
      );
      getIt.registerSingleton<PostServiceInterface>(postService);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PostCard(
              post: Post(
                id: 'post-to-delete',
                treeId: 'tree-1',
                // Author matches _FakeAuthService.currentUserId='user-1' so
                // overflow menu is visible.
                authorId: 'user-1',
                authorName: 'Я',
                content: 'Удалить меня',
                createdAt: DateTime(2026, 5, 26, 10),
                likedBy: const [],
                commentCount: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open overflow menu.
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Удалить'), findsOneWidget);

      // Tap «Удалить» menu item → confirmation dialog appears.
      await tester.tap(find.text('Удалить'));
      await tester.pumpAndSettle();

      // Audit-aligned dialog surface.
      expect(find.text('Удалить публикацию?'), findsOneWidget);
      expect(
        find.textContaining('у всех родственников'),
        findsOneWidget,
        reason: 'consequence copy mentions reach (audit Screen 3.5)',
      );
      expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
      expect(find.byKey(const Key('safe-delete-cancel')), findsOneWidget);
      expect(find.byKey(const Key('safe-delete-confirm')), findsOneWidget);

      // Confirm — backend deletePost should fire.
      await tester.tap(find.byKey(const Key('safe-delete-confirm')));
      await tester.pumpAndSettle();
      expect(postService.deleteCalls, 1);
      expect(postService.lastDeletedId, 'post-to-delete');
      expect(find.text('Публикация удалена'), findsOneWidget);
    },
  );

  testWidgets(
    'PostCard action bar shows «Поделиться» (share), not a fake «Сохранить»',
    (tester) async {
      getIt.registerSingleton<PostServiceInterface>(
        _FakePostService(onToggleLike: (_) async => throw Exception('unused')),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PostCard(
              post: Post(
                id: 'post-share',
                treeId: 'tree-1',
                authorId: 'author-1',
                authorName: 'Анна',
                content: 'Поделись мной',
                createdAt: DateTime(2026, 4, 13, 10),
                likedBy: const [],
                commentCount: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The third action is wired to _sharePost — label + glyph now
      // match that. Previously a bookmark «Сохранить» with no save
      // feature behind it (PostServiceInterface has no save method).
      expect(find.text('Поделиться'), findsOneWidget);
      expect(find.byIcon(Icons.share_outlined), findsOneWidget);
      expect(find.text('Сохранить'), findsNothing);
      expect(find.byIcon(Icons.bookmark_outline_rounded), findsNothing);
    },
  );

  testWidgets(
    'PostCard multi-photo carousel shows one page-dot per photo (P3c)',
    (tester) async {
      getIt.registerSingleton<PostServiceInterface>(
        _FakePostService(onToggleLike: (_) async => throw Exception('unused')),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PostCard(
                post: Post(
                  id: 'post-gallery',
                  treeId: 'tree-1',
                  authorId: 'author-1',
                  authorName: 'Анна',
                  content: 'Галерея',
                  imageUrls: const [
                    'https://example.com/a.jpg',
                    'https://example.com/b.jpg',
                    'https://example.com/c.jpg',
                  ],
                  createdAt: DateTime(2026, 4, 13, 10),
                  likedBy: const [],
                  commentCount: 0,
                ),
              ),
            ),
          ),
        ),
      );
      // Network images never resolve in tests — they sit on the shimmer
      // placeholder, which animates forever — so pump a couple of frames
      // rather than pumpAndSettle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final dots = find.byKey(const Key('post-carousel-dots'));
      expect(dots, findsOneWidget);
      expect(
        tester.widget<Row>(dots).children.length,
        3,
        reason: 'one page-dot per photo (3 images)',
      );
    },
  );

  testWidgets(
    'PostCard delete: Cancel preserves post (no backend call)',
    (tester) async {
      final postService = _FakePostService(
        onToggleLike: (_) async => throw Exception('unused'),
      );
      getIt.registerSingleton<PostServiceInterface>(postService);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PostCard(
              post: Post(
                id: 'keep-me',
                treeId: 'tree-1',
                authorId: 'user-1',
                authorName: 'Я',
                content: 'Не трогай',
                createdAt: DateTime(2026, 5, 26, 10),
                likedBy: const [],
                commentCount: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('safe-delete-cancel')));
      await tester.pumpAndSettle();
      expect(postService.deleteCalls, 0);
      // Post still visible.
      expect(find.text('Не трогай'), findsOneWidget);
    },
  );

  testWidgets(
    'PostCard overflow «Скопировать ссылку» copies a post deep-link (E)',
    (tester) async {
      String? clipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      getIt.registerSingleton<PostServiceInterface>(
        _FakePostService(onToggleLike: (_) async => throw Exception('unused')),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PostCard(
              post: Post(
                id: 'post-xyz',
                treeId: 'tree-1',
                // Non-author — confirms copy-link is offered to everyone
                // while «Удалить» stays author-only.
                authorId: 'author-1',
                authorName: 'Анна',
                content: 'Текст',
                createdAt: DateTime(2026, 4, 13, 10),
                likedBy: const [],
                commentCount: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Скопировать ссылку'), findsOneWidget);
      // Non-author never sees the delete action.
      expect(find.text('Удалить'), findsNothing);

      await tester.tap(find.text('Скопировать ссылку'));
      await tester.pumpAndSettle();

      expect(clipboardText, isNotNull);
      expect(clipboardText, contains('/post/post-xyz'));
      expect(find.text('Ссылка на пост скопирована'), findsOneWidget);
    },
  );
}

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

class _FakePostService implements PostServiceInterface {
  _FakePostService({required this.onToggleLike});

  final Future<Post> Function(String postId) onToggleLike;

  int deleteCalls = 0;
  String? lastDeletedId;

  @override
  Future<Post> toggleLike(String postId) => onToggleLike(postId);

  @override
  Future<void> deletePost(String postId) async {
    deleteCalls += 1;
    lastDeletedId = postId;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
