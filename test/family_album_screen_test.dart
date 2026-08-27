// Album v1: «Альбом семьи» collects every photo from the family's posts
// into a grid; tap → MediaLightbox; warm empty state when there are none.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:get_it/get_it.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:rodnya/backend/interfaces/post_service_interface.dart';
import 'package:rodnya/models/media_upload_progress.dart';
import 'package:rodnya/providers/tree_provider.dart';
import 'package:rodnya/services/local_storage_service.dart';
import 'package:rodnya/models/post.dart';
import 'package:rodnya/screens/family_album_screen.dart';
import 'package:rodnya/theme/app_theme.dart';
import 'package:rodnya/widgets/media_lightbox.dart';

class _FakePostService implements PostServiceInterface {
  _FakePostService({required this.posts});

  final List<Post> posts;

  @override
  Future<List<Post>> getPosts({
    String? treeId,
    String? authorId,
    bool onlyBranches = false,
  }) async =>
      posts;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThrowingPostService implements PostServiceInterface {
  @override
  Future<List<Post>> getPosts({
    String? treeId,
    String? authorId,
    bool onlyBranches = false,
  }) async {
    throw Exception('network down');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Post _post({
  required String id,
  required String authorId,
  required String authorName,
  required List<String> imageUrls,
  required DateTime createdAt,
}) {
  return Post(
    id: id,
    treeId: 'tree-1',
    authorId: authorId,
    authorName: authorName,
    content: '',
    imageUrls: imageUrls,
    createdAt: createdAt,
  );
}

Widget _host(PostServiceInterface svc, {DateTime Function()? now}) =>
    MaterialApp(
      theme: AppTheme.lightTheme,
      home: FamilyAlbumScreen(serviceOverride: svc, nowProvider: now),
    );

/// Фейк для шага 4: запоминает переданные файлы и, как настоящий сервис,
/// прокидывает прогресс по мере «загрузки».
class _UploadingPostService implements PostServiceInterface {
  _UploadingPostService();

  List<Post> posts = const [];
  List<XFile>? receivedImages;
  String? receivedTreeId;
  String? receivedContent;
  int getPostsCalls = 0;

  @override
  Future<List<Post>> getPosts({
    String? treeId,
    String? authorId,
    bool onlyBranches = false,
  }) async {
    getPostsCalls += 1;
    return posts;
  }

  @override
  Future<Post> createPost({
    required String treeId,
    required String content,
    List<XFile> images = const [],
    bool isPublic = false,
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const [],
    String? circleId,
    List<String>? branchIds,
    void Function(MediaUploadProgress progress)? onProgress,
  }) async {
    receivedTreeId = treeId;
    receivedContent = content;
    receivedImages = images;
    onProgress?.call(MediaUploadProgress(
      stage: MediaUploadStage.preparing,
      completed: 0,
      total: images.length,
    ));
    for (var i = 1; i <= images.length; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      onProgress?.call(MediaUploadProgress(
        stage: MediaUploadStage.uploading,
        completed: i,
        total: images.length,
      ));
    }
    // После публикации альбом перечитывает посты — отдадим новый пост.
    posts = [
      ...posts,
      _post(
        id: 'new-post',
        authorId: 'me',
        authorName: 'Я',
        imageUrls: List<String>.generate(
          images.length,
          (i) => 'https://cdn/new-$i.jpg',
        ),
        createdAt: DateTime(2026, 8, 27),
      ),
    ];
    return posts.last;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// TreeProvider резолвит LocalStorageService в конструкторе через GetIt,
/// хотя альбому нужен только id дерева — отдаём пустышку.
class _FakeLocalStorageService implements LocalStorageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// TreeProvider с фиксированным выбором: настоящий тянет GetIt-зависимости
/// и SharedPreferences, а тесту альбома нужен только id дерева.
class _FixedTreeProvider extends TreeProvider {
  _FixedTreeProvider(this._treeId);

  final String? _treeId;

  @override
  String? get selectedTreeId => _treeId;
}

Widget _hostWithTree(
  PostServiceInterface svc, {
  Future<List<XFile>> Function()? picker,
  String? treeId = 'tree-1',
}) {
  return ChangeNotifierProvider<TreeProvider>.value(
    value: _FixedTreeProvider(treeId),
    child: MaterialApp(
      theme: AppTheme.lightTheme,
      home: FamilyAlbumScreen(
        serviceOverride: svc,
        mediaPickerOverride: picker,
      ),
    ),
  );
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ru');
    if (!GetIt.I.isRegistered<LocalStorageService>()) {
      GetIt.I.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
    }
  });

  tearDownAll(() {
    if (GetIt.I.isRegistered<LocalStorageService>()) {
      GetIt.I.unregister<LocalStorageService>();
    }
  });

  testWidgets('renders photos from all posts in a grid (newest-first)',
      (tester) async {
    final svc = _FakePostService(
      posts: [
        _post(
          id: 'p1',
          authorId: 'a1',
          authorName: 'Анна',
          imageUrls: const [
            'https://example.com/1.jpg',
            'https://example.com/2.jpg',
          ],
          createdAt: DateTime(2026, 4, 2),
        ),
        _post(
          id: 'p2',
          authorId: 'a2',
          authorName: 'Иван',
          imageUrls: const ['https://example.com/3.jpg'],
          createdAt: DateTime(2026, 4, 1),
        ),
      ],
    );

    await tester.pumpWidget(_host(svc));
    await tester.pumpAndSettle();

    expect(find.text('Альбом семьи'), findsOneWidget);
    // 3 photos collected across both posts.
    expect(find.byKey(const Key('album-thumb-0')), findsOneWidget);
    expect(find.byKey(const Key('album-thumb-1')), findsOneWidget);
    expect(find.byKey(const Key('album-thumb-2')), findsOneWidget);
    expect(find.byKey(const Key('album-thumb-3')), findsNothing);
    // >1 author → the «по автору» filter strip appears.
    expect(find.byKey(const Key('album-author-all')), findsOneWidget);
  });

  testWidgets('dedups repeated photo URLs and skips video URLs',
      (tester) async {
    final svc = _FakePostService(
      posts: [
        _post(
          id: 'p1',
          authorId: 'a1',
          authorName: 'Анна',
          imageUrls: const [
            'https://example.com/dup.jpg',
            'https://example.com/dup.jpg', // duplicate
            'https://example.com/clip.mp4', // video → skipped
          ],
          createdAt: DateTime(2026, 4, 2),
        ),
      ],
    );

    await tester.pumpWidget(_host(svc));
    await tester.pumpAndSettle();

    // Only the single unique photo remains.
    expect(find.byKey(const Key('album-thumb-0')), findsOneWidget);
    expect(find.byKey(const Key('album-thumb-1')), findsNothing);
    // Single author → no filter strip.
    expect(find.byKey(const Key('album-author-all')), findsNothing);
  });

  testWidgets('shows warm empty state when there are no photos',
      (tester) async {
    final svc = _FakePostService(posts: const []);
    await tester.pumpWidget(_host(svc));
    await tester.pumpAndSettle();

    expect(find.text('Пока нет фотографий'), findsOneWidget);
    expect(find.textContaining('Поделись первым моментом'), findsOneWidget);
    expect(find.byKey(const Key('album-thumb-0')), findsNothing);
  });

  testWidgets(
    'groups photos into month sections (newest first) and filters within them',
    (tester) async {
      final svc = _FakePostService(
        posts: [
          _post(
            id: 'p-jun',
            authorId: 'a1',
            authorName: 'Анна',
            imageUrls: const ['https://example.com/jun.jpg'],
            createdAt: DateTime(2026, 6, 3),
          ),
          _post(
            id: 'p-may1',
            authorId: 'a2',
            authorName: 'Иван',
            imageUrls: const ['https://example.com/may1.jpg'],
            createdAt: DateTime(2026, 5, 20),
          ),
          _post(
            id: 'p-may2',
            authorId: 'a1',
            authorName: 'Анна',
            imageUrls: const ['https://example.com/may2.jpg'],
            createdAt: DateTime(2026, 5, 1),
          ),
        ],
      );

      await tester.pumpWidget(_host(svc));
      await tester.pumpAndSettle();

      // Two month sections; all three photos placed (global indices 0..2).
      expect(find.text('Июнь 2026'), findsOneWidget);
      expect(find.text('Май 2026'), findsOneWidget);
      expect(find.byKey(const Key('album-thumb-0')), findsOneWidget);
      expect(find.byKey(const Key('album-thumb-2')), findsOneWidget);

      // Filter to Иван (May only) → June section disappears.
      await tester.tap(find.text('Иван'));
      await tester.pumpAndSettle();
      expect(find.text('Май 2026'), findsOneWidget);
      expect(find.text('Июнь 2026'), findsNothing);
      expect(find.byKey(const Key('album-thumb-0')), findsOneWidget);
      expect(find.byKey(const Key('album-thumb-1')), findsNothing);
    },
  );

  testWidgets('surfaces «N лет назад» memories from this day in past years',
      (tester) async {
    final svc = _FakePostService(
      posts: [
        _post(
          id: 'today',
          authorId: 'a1',
          authorName: 'Анна',
          imageUrls: const ['https://example.com/today.jpg'],
          createdAt: DateTime(2026, 6, 4), // this year → not a memory
        ),
        _post(
          id: 'twoyears',
          authorId: 'a1',
          authorName: 'Анна',
          imageUrls: const ['https://example.com/memory.jpg'],
          createdAt: DateTime(2024, 6, 3), // 2 years ago, within ±3 days
        ),
      ],
    );

    await tester.pumpWidget(_host(svc, now: () => DateTime(2026, 6, 4)));
    await tester.pumpAndSettle();

    expect(find.text('2 года назад'), findsOneWidget);
    expect(find.byKey(const Key('album-memory-0')), findsOneWidget);
  });

  testWidgets('no memory section when nothing matches this day in past years',
      (tester) async {
    final svc = _FakePostService(
      posts: [
        _post(
          id: 'thisyear',
          authorId: 'a1',
          authorName: 'Анна',
          imageUrls: const ['https://example.com/a.jpg'],
          createdAt: DateTime(2026, 1, 15), // this year
        ),
        _post(
          id: 'farday',
          authorId: 'a1',
          authorName: 'Анна',
          imageUrls: const ['https://example.com/b.jpg'],
          createdAt: DateTime(2024, 3, 1), // past year but far from today
        ),
      ],
    );

    await tester.pumpWidget(_host(svc, now: () => DateTime(2026, 6, 4)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('album-memory-0')), findsNothing);
    expect(find.textContaining('назад'), findsNothing);
  });

  testWidgets('shows error + «Повторить» when load fails with no cache (CP-4)',
      (tester) async {
    await tester.pumpWidget(_host(_ThrowingPostService()));
    await tester.pumpAndSettle();

    expect(find.text('Не удалось загрузить альбом'), findsOneWidget);
    expect(find.byKey(const Key('album-retry')), findsOneWidget);
    expect(find.byKey(const Key('album-thumb-0')), findsNothing);
  });

  testWidgets('thumbnails use an InkWell tap target for ripple (CP-3)',
      (tester) async {
    final svc = _FakePostService(
      posts: [
        _post(
          id: 'p1',
          authorId: 'a1',
          authorName: 'Анна',
          imageUrls: const ['https://example.com/1.jpg'],
          createdAt: DateTime(2026, 4, 2),
        ),
      ],
    );
    await tester.pumpWidget(_host(svc));
    await tester.pumpAndSettle();

    expect(
        tester.widget(find.byKey(const Key('album-thumb-0'))), isA<InkWell>());
  });

  testWidgets('tapping a thumb opens the MediaLightbox', (tester) async {
    final svc = _FakePostService(
      posts: [
        _post(
          id: 'p1',
          authorId: 'a1',
          authorName: 'Анна',
          imageUrls: const ['https://example.com/1.jpg'],
          createdAt: DateTime(2026, 4, 2),
        ),
      ],
    );

    await tester.pumpWidget(_host(svc));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('album-thumb-0')));
    // The lightbox image loader never "settles" (network image spinner),
    // so pump a couple of frames past the open transition rather than
    // pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(MediaLightbox), findsOneWidget);
  });

  testWidgets('шаг 4: «+» в альбоме грузит пачку фото и обновляет альбом',
      (tester) async {
    // Раньше альбом был только для чтения: чтобы фото туда попали, надо было
    // идти в ленту и создавать пост. Теперь загрузка живёт прямо в альбоме.
    final svc = _UploadingPostService();
    final files = List<XFile>.generate(4, (i) => XFile('/tmp/p$i.jpg'));

    await tester.pumpWidget(_hostWithTree(svc, picker: () async => files));
    await tester.pumpAndSettle();

    expect(find.text('Добавить фото'), findsOneWidget);
    final callsBefore = svc.getPostsCalls;

    await tester.tap(find.text('Добавить фото'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 8));

    // Во время загрузки кнопка показывает живой счётчик, а не застывший спиннер.
    expect(find.textContaining('Загружено'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(svc.receivedImages, hasLength(4));
    expect(svc.receivedTreeId, 'tree-1');
    expect(svc.receivedContent, '', reason: 'подпись пустая — пришли за фото');
    expect(find.text('4 фото добавлены в альбом.'), findsOneWidget);
    expect(svc.getPostsCalls, greaterThan(callsBefore),
        reason: 'альбом должен перечитаться, чтобы фото появились сразу');
  });

  testWidgets('шаг 4: без выбранного дерева «+» не публикует пустоту',
      (tester) async {
    final svc = _UploadingPostService();
    await tester.pumpWidget(_hostWithTree(
      svc,
      picker: () async => [XFile('/tmp/p0.jpg')],
      treeId: null,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Добавить фото'));
    await tester.pumpAndSettle();

    expect(svc.receivedImages, isNull);
    expect(find.text('Сначала выберите дерево.'), findsOneWidget);
  });

  testWidgets('шаг 4: отменённый выбор ничего не публикует', (tester) async {
    final svc = _UploadingPostService();
    await tester.pumpWidget(
      _hostWithTree(svc, picker: () async => const <XFile>[]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Добавить фото'));
    await tester.pumpAndSettle();

    expect(svc.receivedImages, isNull);
    expect(find.text('Добавить фото'), findsOneWidget);
  });

}
