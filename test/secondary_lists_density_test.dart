// Плотность (чанк 23) — инвариант для трёх второстепенных списков
// (уведомления, календарь-список, альбом семьи). Проверяет число полностью
// видимых строк/плиток на первом экране 412×915 (devicePixelRatio 3) и
// закрепляет пороги из ТЗ (>=10 уведомлений, >=8 событий, >=12 плиток),
// чтобы дальнейшие правки вёрстки не «съели» плотность обратно.
//
// Гарнитуры (fakes) намеренно зеркалят существующие
// notifications_screen_test.dart / family_calendar_screen_test.dart /
// family_album_screen_test.dart — не импортируются оттуда, т.к. это
// приватные классы конкретных test-файлов.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/backend/interfaces/post_service_interface.dart';
import 'package:rodnya/models/app_notification_item.dart';
import 'package:rodnya/models/family_person.dart';
import 'package:rodnya/models/family_relation.dart';
import 'package:rodnya/models/family_tree.dart';
import 'package:rodnya/models/post.dart';
import 'package:rodnya/providers/tree_provider.dart';
import 'package:rodnya/screens/family_album_screen.dart';
import 'package:rodnya/screens/family_calendar_screen.dart';
import 'package:rodnya/screens/notifications_screen.dart';
import 'package:rodnya/services/app_status_service.dart';
import 'package:rodnya/services/event_service.dart';
import 'package:rodnya/services/local_storage_service.dart';

const double _viewportWidth = 412;
const double _viewportHeight = 915;
const double _appBarBottom = kToolbarHeight; // 56 — контент ниже топбара

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  Future<void> setPhoneViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(_viewportWidth * 3, _viewportHeight * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  /// Полностью ли виден прямоугольник [rect] на первом экране (ниже AppBar,
  /// не обрезан нижней границей вьюпорта).
  bool fullyVisible(Rect rect) =>
      rect.top >= _appBarBottom - 0.5 && rect.bottom <= _viewportHeight + 0.5;

  group('Уведомления', () {
    Future<Widget> buildApp(Widget child) async {
      final treeProvider = TreeProvider();
      await treeProvider.selectTree(
        'tree-1',
        'Семья Шуфляк',
        treeKind: TreeKind.family,
      );
      return ChangeNotifierProvider<TreeProvider>.value(
        value: treeProvider,
        child: MaterialApp(home: child),
      );
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await GetIt.instance.reset();
      GetIt.instance
          .registerSingleton<LocalStorageService>(_ProbeLocalStorageService());
      GetIt.instance.registerSingleton<AppStatusService>(AppStatusService());
      GetIt.instance.registerSingleton<AuthServiceInterface>(_ProbeAuthService());
    });

    tearDown(() async {
      await GetIt.instance.reset();
    });

    testWidgets('зонд: видимых строк на первом экране (15 уведомлений)',
        (tester) async {
      await setPhoneViewport(tester);

      final items = List<AppNotificationItem>.generate(
        15,
        (i) => AppNotificationItem(
          id: 'n-$i',
          type: 'chat_message',
          title: 'Уведомление номер $i',
          body: 'Текст уведомления $i с деталями события',
          createdAt: DateTime(2026, 9, 5, 10, i),
          data: {'chatId': 'chat-$i'},
          payload: '{}',
        ),
      );

      await tester.pumpWidget(
        await buildApp(
          NotificationsScreen(notificationLoader: () async => items),
        ),
      );
      await tester.pumpAndSettle();

      var visibleRows = 0;
      for (final item in items) {
        final finder = find.text(item.title);
        if (finder.evaluate().isEmpty) continue;
        final rect = tester.getRect(finder);
        if (fullyVisible(rect)) visibleRows += 1;
      }

      // Высота одной строки — по её заголовку InkWell-предку.
      final firstCardInkWell = find.ancestor(
        of: find.text(items.first.title),
        matching: find.byType(InkWell),
      );
      final rowHeight = firstCardInkWell.evaluate().isNotEmpty
          ? tester.getRect(firstCardInkWell).height
          : double.nan;

      // eslint-disable-next-line: печать для отчёта «до/после».
      // ignore: avoid_print
      print(
        '[density23][notifications] visibleRows=$visibleRows rowHeight=$rowHeight',
      );

      expect(visibleRows, greaterThanOrEqualTo(10),
          reason: 'на первом экране должно быть видно ≥10 уведомлений');
    });
  });

  group('Календарь', () {
    testWidgets('зонд: видимых событий в списке на первом экране (12 событий)',
        (tester) async {
      await setPhoneViewport(tester);

      final now = DateTime.now();
      final relatives = [
        for (var i = 0; i < 12; i++)
          FamilyPerson(
            id: 'p$i',
            treeId: 'tree-1',
            name: 'Родственник $i',
            gender: Gender.male,
            birthDate: DateTime(
              1950 + i,
              now.add(Duration(days: i + 1)).month,
              now.add(Duration(days: i + 1)).day,
            ),
            isAlive: true,
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
          ),
      ];
      final service = EventService(
        familyTreeService: _ProbeFamilyTreeService(relatives: relatives),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: FamilyCalendarScreen(
            serviceOverride: service,
            treeId: 'tree-1',
            initialMonth: now,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('calendar-view-list')));
      await tester.pumpAndSettle();

      var visibleEvents = 0;
      for (var i = 0; i < relatives.length; i++) {
        final finder = find.text(relatives[i].name);
        if (finder.evaluate().isEmpty) continue;
        final rect = tester.getRect(finder.first);
        if (fullyVisible(rect)) visibleEvents += 1;
      }

      final firstTileInkWell = find.ancestor(
        of: find.text(relatives.first.name),
        matching: find.byType(InkWell),
      );
      final tileHeight = firstTileInkWell.evaluate().isNotEmpty
          ? tester.getRect(firstTileInkWell).height
          : double.nan;

      // ignore: avoid_print
      print(
        '[density23][calendar] visibleEvents=$visibleEvents tileHeight=$tileHeight',
      );

      expect(visibleEvents, greaterThanOrEqualTo(8),
          reason: 'на первом экране списка должно быть видно ≥8 событий');
    });
  });

  group('Альбом', () {
    testWidgets('зонд: видимых плиток на первом экране (24 фото)',
        (tester) async {
      await setPhoneViewport(tester);
      if (!GetIt.I.isRegistered<LocalStorageService>()) {
        GetIt.I.registerSingleton<LocalStorageService>(
          _ProbeLocalStorageService(),
        );
      }
      addTearDown(() {
        if (GetIt.I.isRegistered<LocalStorageService>()) {
          GetIt.I.unregister<LocalStorageService>();
        }
      });

      final svc = _ProbePostService(
        posts: [
          _post(
            id: 'p-batch',
            authorId: 'a1',
            authorName: 'Анна',
            imageUrls: List<String>.generate(
              24,
              (i) => 'https://example.com/photo-$i.jpg',
            ),
            createdAt: DateTime(2026, 9, 1),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: FamilyAlbumScreen(
            serviceOverride: svc,
            nowProvider: () => DateTime(2026, 9, 5),
          ),
        ),
      );
      await tester.pumpAndSettle();

      var visibleTiles = 0;
      for (var i = 0; i < 24; i++) {
        final finder = find.byKey(Key('album-thumb-$i'));
        if (finder.evaluate().isEmpty) continue;
        final rect = tester.getRect(finder);
        if (fullyVisible(rect)) visibleTiles += 1;
      }

      final tileRect = tester.getRect(find.byKey(const Key('album-thumb-0')));

      // ignore: avoid_print
      print(
        '[density23][album] visibleTiles=$visibleTiles tileSize=${tileRect.width}x${tileRect.height}',
      );

      expect(visibleTiles, greaterThanOrEqualTo(12),
          reason: 'на первом экране должно быть видно ≥12 плиток');
    });
  });
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

class _ProbeFamilyTreeService implements FamilyTreeServiceInterface {
  _ProbeFamilyTreeService({required this.relatives});

  final List<FamilyPerson> relatives;

  @override
  Future<List<FamilyPerson>> getRelatives(String treeId) async => relatives;

  @override
  Future<List<FamilyRelation>> getRelations(String treeId) async =>
      const <FamilyRelation>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProbeLocalStorageService implements LocalStorageService {
  final FamilyTree _tree = FamilyTree(
    id: 'tree-1',
    name: 'Семья Шуфляк',
    description: '',
    creatorId: 'user-1',
    memberIds: const ['user-1'],
    createdAt: DateTime(2026, 4, 3),
    updatedAt: DateTime(2026, 4, 3),
    isPrivate: true,
    members: const ['user-1'],
  );

  @override
  Future<List<FamilyTree>> getAllTrees() async => [_tree];

  @override
  Future<FamilyTree?> getTree(String treeId) async =>
      treeId == _tree.id ? _tree : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProbeAuthService implements AuthServiceInterface {
  @override
  String? get currentUserId => 'user-1';

  @override
  String describeError(Object error) => error.toString();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProbePostService implements PostServiceInterface {
  _ProbePostService({required this.posts});

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
