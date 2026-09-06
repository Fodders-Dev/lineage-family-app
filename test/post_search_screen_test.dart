// Density chunk 25: smoke + invariant tests for the post-search screen.
// No test existed for this screen before. Focus: search field renders
// as a 50dp pill in the topbar, results reuse PostCard unmodified, and
// the empty/no-results hints are compact one-line rows (not the shared
// half-screen EmptyStateWidget card).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/backend/interfaces/post_service_interface.dart';
import 'package:rodnya/models/post.dart';
import 'package:rodnya/screens/post_search_screen.dart';

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
  _FakePostService({this.results = const <Post>[], this.error});

  List<Post> results;
  Object? error;
  String? lastQuery;

  @override
  Future<List<Post>> searchPosts({
    required String query,
    String? treeId,
    int limit = 50,
  }) async {
    lastQuery = query;
    if (error != null) throw error!;
    return results;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Post _post(String id) {
  return Post(
    id: id,
    treeId: 'tree-1',
    authorId: 'author-1',
    authorName: 'Анна',
    content: 'Семейная новость $id',
    createdAt: DateTime(2026, 4, 13, 10),
    likedBy: const [],
    commentCount: 0,
  );
}

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
    'density chunk 25: search box is a 50dp pill, initial hint is compact',
    (tester) async {
      getIt.registerSingleton<PostServiceInterface>(_FakePostService());
      await tester.pumpWidget(
        const MaterialApp(home: PostSearchScreen()),
      );
      await tester.pumpAndSettle();

      final box = tester.getRect(find.byKey(const Key('post-search-box')));
      expect(
        box.height,
        50,
        reason: 'Поле поиска должно быть пилюлей 50dp в топбаре.',
      );

      final hint = tester.getRect(find.byKey(const Key('post-search-hint')));
      expect(
        hint.height,
        lessThanOrEqualTo(56),
        reason: 'Начальная подсказка — одна компактная строка ≤56dp '
            '(до чанка 25 — общий EmptyStateWidget на пол-экрана).',
      );
    },
  );

  testWidgets('typing a query calls searchPosts and renders results',
      (tester) async {
    final service = _FakePostService(results: [_post('1'), _post('2')]);
    getIt.registerSingleton<PostServiceInterface>(service);
    await tester.pumpWidget(const MaterialApp(home: PostSearchScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('post-search-field')),
      'свадьба',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(service.lastQuery, 'свадьба');
    expect(find.textContaining('Семейная новость'), findsNWidgets(2));
    expect(find.byKey(const Key('post-search-clear')), findsOneWidget);
  });

  testWidgets('no results renders compact one-line hint', (tester) async {
    getIt.registerSingleton<PostServiceInterface>(_FakePostService());
    await tester.pumpWidget(const MaterialApp(home: PostSearchScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('post-search-field')),
      'зоопарк',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    final hint = tester.getRect(find.byKey(const Key('post-search-empty')));
    expect(
      hint.height,
      lessThanOrEqualTo(56),
      reason: 'Пустой результат — одна строка ≤56dp.',
    );
    expect(find.textContaining('Ничего не нашли'), findsOneWidget);
  });

  testWidgets('search error renders retry CTA at 44dp', (tester) async {
    getIt.registerSingleton<PostServiceInterface>(
      _FakePostService(error: Exception('offline')),
    );
    await tester.pumpWidget(const MaterialApp(home: PostSearchScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('post-search-field')),
      'свадьба',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.textContaining('Не удалось выполнить поиск'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
  });

  testWidgets('clear button resets query and hint', (tester) async {
    getIt.registerSingleton<PostServiceInterface>(
      _FakePostService(results: [_post('1')]),
    );
    await tester.pumpWidget(const MaterialApp(home: PostSearchScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('post-search-field')),
      'свадьба',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('post-search-clear')), findsOneWidget);

    await tester.tap(find.byKey(const Key('post-search-clear')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('post-search-hint')), findsOneWidget);
    expect(find.byKey(const Key('post-search-clear')), findsNothing);
  });
}
