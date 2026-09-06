// Phase E5c: «Новый опрос» composer — create calls the service with the
// question + options; question + ≥2 non-empty options are required.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/backend/interfaces/poll_service_interface.dart';
import 'package:rodnya/models/poll.dart';
import 'package:rodnya/models/post.dart' show TreeContentScopeType;
import 'package:rodnya/screens/create_poll_screen.dart';
import 'package:rodnya/theme/app_theme.dart';

class _FakePollService implements PollServiceInterface {
  int createCalls = 0;
  String? lastQuestion;
  List<String>? lastOptions;
  String? lastTreeId;
  bool? lastAllowMultiple;

  @override
  Future<Poll> createPoll({
    required String treeId,
    required String question,
    required List<String> options,
    bool allowMultiple = false,
    DateTime? closesAt,
    List<XFile> images = const [],
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const [],
    String? circleId,
    List<String>? branchIds,
  }) async {
    createCalls++;
    lastQuestion = question;
    lastOptions = options;
    lastTreeId = treeId;
    lastAllowMultiple = allowMultiple;
    return Poll(
      id: 'p-new',
      treeId: treeId,
      authorId: 'u',
      authorName: 'Я',
      question: question,
      options: options.map((o) => PollOption(id: o, text: o)).toList(),
      createdAt: DateTime(2026, 6, 1),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _plainHost(_FakePollService svc) => MaterialApp(
      theme: AppTheme.lightTheme,
      home: CreatePollScreen(serviceOverride: svc, treeId: 'tree-1'),
    );

Widget _routerHost(_FakePollService svc) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (ctx, _) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => ctx.push('/create'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/create',
        builder: (_, __) =>
            CreatePollScreen(serviceOverride: svc, treeId: 'tree-1'),
      ),
    ],
  );
  return MaterialApp.router(theme: AppTheme.lightTheme, routerConfig: router);
}

// Плотность (чанк 24): «Создать» переехало из AppBar-action в CTA внизу
// прокручиваемой формы (см. CreateGatheringScreen'а аналогичный
// комментарий). flutter_test даёт по умолчанию крошечный canvas
// (800×600лп) — меньше формы с аудиторией/медиа — и ListView строит
// offscreen-детей лениво, так что find.byKey('poll-submit') не находит
// ничего без прокрутки. Высокий тестовый canvas решает это без
// scroll-хореографии в самих тестах.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800 * 2, 3000 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  testWidgets('create calls the service with question + options',
      (tester) async {
    _useTallViewport(tester);
    final svc = _FakePollService();
    await tester.pumpWidget(_routerHost(svc));
    await tester.pumpAndSettle();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('poll-question-field')),
      'Когда собираемся?',
    );
    await tester.enterText(
      find.byKey(const Key('poll-option-0')),
      'Суббота',
    );
    await tester.enterText(
      find.byKey(const Key('poll-option-1')),
      'Воскресенье',
    );
    await tester.tap(find.byKey(const Key('poll-submit')));
    await tester.pumpAndSettle();

    expect(svc.createCalls, 1);
    expect(svc.lastQuestion, 'Когда собираемся?');
    expect(svc.lastOptions, ['Суббота', 'Воскресенье']);
    expect(svc.lastTreeId, 'tree-1');
    expect(find.text('open'), findsOneWidget); // popped back
  });

  testWidgets('validation: missing question blocks create', (tester) async {
    _useTallViewport(tester);
    final svc = _FakePollService();
    await tester.pumpWidget(_plainHost(svc));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('poll-option-0')), 'А');
    await tester.enterText(find.byKey(const Key('poll-option-1')), 'Б');
    await tester.tap(find.byKey(const Key('poll-submit')));
    await tester.pump();

    expect(svc.createCalls, 0);
    expect(find.text('Укажите вопрос опроса'), findsOneWidget);
  });

  testWidgets('validation: fewer than two options blocks create',
      (tester) async {
    _useTallViewport(tester);
    final svc = _FakePollService();
    await tester.pumpWidget(_plainHost(svc));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('poll-question-field')),
      'Вопрос?',
    );
    await tester.enterText(
        find.byKey(const Key('poll-option-0')), 'Только один');
    // option-1 left empty → only one non-empty option.
    await tester.tap(find.byKey(const Key('poll-submit')));
    await tester.pump();

    expect(svc.createCalls, 0);
    expect(find.text('Нужно минимум два варианта ответа'), findsOneWidget);
  });
}
