// Phase E2b: «Новая встреча» composer — create calls the service with the
// entered fields; title + startAt are required.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/backend/interfaces/gathering_service_interface.dart';
import 'package:rodnya/models/gathering.dart';
import 'package:rodnya/models/post.dart' show TreeContentScopeType;
import 'package:rodnya/screens/create_gathering_screen.dart';
import 'package:rodnya/theme/app_theme.dart';

class _FakeGatheringService implements GatheringServiceInterface {
  int createCalls = 0;
  String? lastTitle;
  DateTime? lastStartAt;
  String? lastTreeId;
  String? lastPlace;

  @override
  Future<List<Gathering>> getGatherings({required String treeId}) async =>
      const [];

  int lastImageCount = 0;

  @override
  Future<Gathering> createGathering({
    required String treeId,
    required String title,
    String? description,
    required DateTime startAt,
    DateTime? endAt,
    bool isAllDay = false,
    String? place,
    List<XFile> images = const [],
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const [],
    String? circleId,
    List<String>? branchIds,
  }) async {
    createCalls++;
    lastTitle = title;
    lastStartAt = startAt;
    lastTreeId = treeId;
    lastPlace = place;
    lastImageCount = images.length;
    return Gathering(
      id: 'g-new',
      treeId: treeId,
      authorId: 'u',
      authorName: 'Я',
      title: title,
      startAt: startAt,
      createdAt: DateTime(2026, 6, 1),
    );
  }

  @override
  Future<void> deleteGathering(String gatheringId) async {}

  @override
  Future<Gathering> setRsvp(
    String gatheringId,
    String status, {
    int? headcount,
    String? note,
  }) async {
    throw UnimplementedError();
  }
}

Widget _plainHost(_FakeGatheringService svc, {DateTime? initialStartAt}) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    home: CreateGatheringScreen(
      serviceOverride: svc,
      treeId: 'tree-1',
      initialStartAt: initialStartAt,
    ),
  );
}

Widget _routerHost(_FakeGatheringService svc,
    {required DateTime initialStartAt}) {
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
        builder: (_, __) => CreateGatheringScreen(
          serviceOverride: svc,
          treeId: 'tree-1',
          initialStartAt: initialStartAt,
        ),
      ),
    ],
  );
  return MaterialApp.router(theme: AppTheme.lightTheme, routerConfig: router);
}

// Плотность (чанк 24): «Создать» переехало из AppBar-action (всегда на
// экране) в CTA внизу прокручиваемой формы (см. CreateGatheringScreen).
// flutter_test по умолчанию даёт крошечный canvas (800×600лп) — сильно
// меньше формы с аудиторией/медиа — и ListView строит offscreen-детей
// лениво, так что find.byKey('gathering-submit') не находит вообще
// ничего без прокрутки. Высокий тестовый canvas решает это без
// добавления scroll-хореографии в сами тесты.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800 * 2, 3000 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  testWidgets('create calls the service with title + startAt + treeId',
      (tester) async {
    _useTallViewport(tester);
    final svc = _FakeGatheringService();
    final start = DateTime(2026, 7, 1, 15, 0);
    await tester.pumpWidget(_routerHost(svc, initialStartAt: start));
    await tester.pumpAndSettle();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('gathering-title-field')),
      'Пикник у реки',
    );
    await tester.enterText(
      find.byKey(const Key('gathering-place-field')),
      'Берег',
    );
    await tester.tap(find.byKey(const Key('gathering-submit')));
    await tester.pumpAndSettle();

    expect(svc.createCalls, 1);
    expect(svc.lastTitle, 'Пикник у реки');
    expect(svc.lastStartAt, start);
    expect(svc.lastTreeId, 'tree-1');
    expect(svc.lastPlace, 'Берег');
    // Popped back to home after a successful create.
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('validation: missing startAt blocks create', (tester) async {
    _useTallViewport(tester);
    final svc = _FakeGatheringService();
    await tester.pumpWidget(_plainHost(svc)); // no initialStartAt
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('gathering-title-field')),
      'Без даты',
    );
    await tester.tap(find.byKey(const Key('gathering-submit')));
    await tester.pump(); // surface the SnackBar

    expect(svc.createCalls, 0);
    expect(find.text('Укажите дату и время встречи'), findsOneWidget);
  });

  testWidgets('validation: missing title blocks create', (tester) async {
    _useTallViewport(tester);
    final svc = _FakeGatheringService();
    await tester.pumpWidget(
      _plainHost(svc, initialStartAt: DateTime(2026, 7, 1, 15, 0)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('gathering-submit')));
    await tester.pump();

    expect(svc.createCalls, 0);
    expect(find.text('Укажите название встречи'), findsOneWidget);
  });
}
