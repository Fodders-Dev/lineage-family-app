// StoryArchiveScreen ("Архив историй") — не имела ни одного теста, хотя
// плотностные агенты уже переверстали пустое/error состояния (центр по
// высоте вьюпорта вместо top-anchored колонки, см. комментарий в самом
// экране). Пины текущее поведение: skeleton → загруженный грид, пустое
// состояние, ошибка + повтор, тап открывает MediaLightbox, отсутствие
// overflow на узком экране.
//
// Все фикстуры — истории типа text: постер для text-типа рисуется
// градиентным Container без CachedNetworkImage/video_player, так что
// тест не зависит от сетевых картинок и не подвисает на pumpAndSettle.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/backend/interfaces/story_service_interface.dart';
import 'package:rodnya/models/story.dart';
import 'package:rodnya/screens/story_archive_screen.dart';
import 'package:rodnya/widgets/media_lightbox.dart';

class _FakeAuthService implements AuthServiceInterface {
  _FakeAuthService({this.userId = 'user-1'});

  final String? userId;

  @override
  String? get currentUserId => userId;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStoryService implements StoryServiceInterface {
  _FakeStoryService({
    this.stories = const <Story>[],
    this.error,
    this.completer,
  });

  List<Story> stories;
  Object? error;
  Completer<List<Story>>? completer;
  int callCount = 0;

  @override
  Future<List<Story>> getStories({
    String? treeId,
    String? authorId,
    bool includeArchive = false,
  }) {
    callCount += 1;
    if (completer != null) return completer!.future;
    if (error != null) return Future.error(error!);
    return Future.value(stories);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// expiresAt/createdAt всегда относительно DateTime.now() теста — экран
// сам фильтрует по "expiresAt.isBefore(now)", так что фикстуры должны
// оставаться "просроченными" независимо от того, когда прогоняется тест.
Story _textStory({required String id, required String text}) {
  final now = DateTime.now();
  return Story(
    id: id,
    treeId: 'tree-1',
    authorId: 'user-1',
    type: StoryType.text,
    text: text,
    createdAt: now.subtract(const Duration(days: 2)),
    expiresAt: now.subtract(const Duration(days: 1)),
  );
}

void main() {
  final getIt = GetIt.instance;

  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  setUp(() async {
    await getIt.reset();
  });

  tearDown(() async {
    await getIt.reset();
  });

  Future<void> pumpArchive(
    WidgetTester tester, {
    required _FakeStoryService storyService,
    String? userId = 'user-1',
  }) async {
    getIt.registerSingleton<StoryServiceInterface>(storyService);
    getIt.registerSingleton<AuthServiceInterface>(
      _FakeAuthService(userId: userId),
    );
    await tester.pumpWidget(const MaterialApp(home: StoryArchiveScreen()));
  }

  testWidgets('загрузка → список из архива с 3 историями', (tester) async {
    final completer = Completer<List<Story>>();
    final service = _FakeStoryService(completer: completer);
    await pumpArchive(tester, storyService: service);

    // Один pump — до резолва фьючи: контент архива ещё не должен
    // быть на экране (реальный skeleton вместо него).
    await tester.pump();
    expect(find.text('Первая история'), findsNothing);

    completer.complete([
      _textStory(id: 's-1', text: 'Первая история'),
      _textStory(id: 's-2', text: 'Вторая история'),
      _textStory(id: 's-3', text: 'Третья история'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Первая история'), findsOneWidget);
    expect(find.text('Вторая история'), findsOneWidget);
    expect(find.text('Третья история'), findsOneWidget);
  });

  testWidgets('пустой архив — заголовок и подсказка', (tester) async {
    final service = _FakeStoryService(stories: const <Story>[]);
    await pumpArchive(tester, storyService: service);
    await tester.pumpAndSettle();

    expect(find.text('Архив пуст'), findsOneWidget);
    expect(
      find.text(
        'Истории, которым больше 24 часов, появятся здесь автоматически. '
        'Так вы сможете пересматривать их в любое время.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('ошибка загрузки — сообщение и «Повторить» вызывает сервис ещё раз',
      (tester) async {
    final service = _FakeStoryService(error: Exception('network down'));
    await pumpArchive(tester, storyService: service);
    await tester.pumpAndSettle();

    expect(find.textContaining('Не удалось загрузить архив'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
    expect(service.callCount, 1);

    service.error = null;
    service.stories = [_textStory(id: 's-1', text: 'Восстановленная история')];
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();

    expect(service.callCount, 2);
    expect(find.text('Восстановленная история'), findsOneWidget);
  });

  testWidgets('тап по истории открывает MediaLightbox', (tester) async {
    final service = _FakeStoryService(
      stories: [_textStory(id: 's-1', text: 'История для лайтбокса')],
    );
    await pumpArchive(tester, storyService: service);
    await tester.pumpAndSettle();

    expect(find.byType(MediaLightbox), findsNothing);
    await tester.tap(find.text('История для лайтбокса'));
    await tester.pumpAndSettle();

    expect(find.byType(MediaLightbox), findsOneWidget);
  });

  testWidgets('на узком экране 360×640 нет переполнения', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final service = _FakeStoryService(
      stories: [
        _textStory(id: 's-1', text: 'Первая история'),
        _textStory(id: 's-2', text: 'Вторая история'),
      ],
    );
    await pumpArchive(tester, storyService: service);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
