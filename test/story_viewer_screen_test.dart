import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rodnya/backend/interfaces/story_service_interface.dart';
import 'package:rodnya/models/post.dart' show TreeContentScopeType;
import 'package:rodnya/models/reaction_summary.dart';
import 'package:rodnya/models/story.dart';
import 'package:rodnya/screens/story_viewer_screen.dart';

class _FakeStoryService implements StoryServiceInterface {
  final List<String> markedStoryIds = <String>[];
  final List<String> deletedStoryIds = <String>[];
  final Map<String, Story> storiesById;

  _FakeStoryService(this.storiesById);

  @override
  Future<List<Story>> getStories({
    String? treeId,
    String? authorId,
    bool includeArchive = false,
  }) async =>
      storiesById.values.toList(growable: false);

  @override
  Future<Story> createStory({
    required String treeId,
    required StoryType type,
    String? text,
    media,
    String? thumbnailUrl,
    DateTime? expiresAt,
    String? circleId,
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const <String>[],
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Story> markViewed(String storyId) async {
    markedStoryIds.add(storyId);
    final story = storiesById[storyId]!;
    final updated = story.copyWith(
      viewedBy: <String>[...story.viewedBy, 'user-1'],
    );
    storiesById[storyId] = updated;
    return updated;
  }

  @override
  Future<void> deleteStory(String storyId) async {
    deletedStoryIds.add(storyId);
    storiesById.remove(storyId);
  }

  @override
  Future<List<ReactionSummary>> toggleStoryReaction({
    required String storyId,
    required String emoji,
  }) async => const <ReactionSummary>[];
}

void main() {
  final getIt = GetIt.instance;

  Story buildStory({
    required String id,
    required String authorId,
    required String authorName,
    List<String>? viewedBy,
  }) {
    return Story(
      id: id,
      treeId: 'tree-1',
      authorId: authorId,
      authorName: authorName,
      type: StoryType.text,
      text: 'Семейное обновление',
      createdAt: DateTime(2026, 4, 13, 12),
      expiresAt: DateTime(2026, 4, 14, 12),
      viewedBy: viewedBy,
    );
  }

  setUp(() async {
    await getIt.reset();
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets('StoryViewerScreen отмечает чужую story как просмотренную',
      (tester) async {
    final story = buildStory(
      id: 'story-1',
      authorId: 'user-2',
      authorName: 'Анна',
    );
    final service = _FakeStoryService({'story-1': story});
    getIt.registerSingleton<StoryServiceInterface>(service);

    await tester.pumpWidget(
      MaterialApp(
        home: StoryViewerScreen(
          stories: [story],
          currentUserId: 'user-1',
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(service.markedStoryIds, ['story-1']);
    expect(find.text('Просмотрено'), findsOneWidget);
  });

  testWidgets('StoryViewerScreen не считает автора просмотревшим свою story',
      (tester) async {
    final story = buildStory(
      id: 'story-2',
      authorId: 'user-1',
      authorName: 'Алексей',
      viewedBy: const ['user-1', 'user-2'],
    );
    final service = _FakeStoryService({'story-2': story});
    getIt.registerSingleton<StoryServiceInterface>(service);

    await tester.pumpWidget(
      MaterialApp(
        home: StoryViewerScreen(
          stories: [story],
          currentUserId: 'user-1',
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(service.markedStoryIds, isEmpty);
    expect(find.text('Просмотров: 1'), findsOneWidget);
  });

  testWidgets(
    'Чанк 26: на телефоне (412×915) шапка ≤44dp, нижняя строка ≤56dp, '
    'прогресс-полоски 2dp',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final story = buildStory(
        id: 'story-1',
        authorId: 'user-2',
        authorName: 'Анна',
      );
      final service = _FakeStoryService({'story-1': story});
      getIt.registerSingleton<StoryServiceInterface>(service);

      await tester.pumpWidget(
        MaterialApp(
          home: StoryViewerScreen(
            stories: [story],
            currentUserId: 'user-1',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Раньше шапка была ~64dp (44dp аватар + вертикальные паддинги
      // 10+10 внутри своей чёрной плашки) — теперь аватар 32dp и без
      // паддингов-рамки, строка укладывается в целевые ≤44dp.
      final headerSize =
          tester.getSize(find.byKey(const Key('story-viewer-header')));
      expect(headerSize.height, lessThanOrEqualTo(44.0));

      // Строка реакций/статуса — фиксированные 48dp (в рамках ≤56dp).
      final actionRowSize =
          tester.getSize(find.byKey(const Key('story-viewer-action-row')));
      expect(actionRowSize.height, lessThanOrEqualTo(56.0));

      final progressBars = tester
          .widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          )
          .toList();
      expect(progressBars, isNotEmpty);
      for (final bar in progressBars) {
        expect(bar.minHeight, 2.0);
      }
    },
  );

  testWidgets(
    'Чанк 26: на десктопе (1280×900) сторис — кадр 9:16 по центру на всю '
    'высоту, без карточки',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final story = buildStory(
        id: 'story-1',
        authorId: 'user-2',
        authorName: 'Анна',
      );
      final service = _FakeStoryService({'story-1': story});
      getIt.registerSingleton<StoryServiceInterface>(service);

      await tester.pumpWidget(
        MaterialApp(
          home: StoryViewerScreen(
            stories: [story],
            currentUserId: 'user-1',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final frameSize = tester.getSize(find.byType(AspectRatio));
      // Кадр занимает всю доступную высоту (не растягивается на всё
      // окно шириной, как раньше на широких вьюпортах).
      expect(frameSize.height, closeTo(900.0, 1.0));
      expect(frameSize.width / frameSize.height, closeTo(9 / 16, 0.01));
    },
  );
}
