// Phase E2c: GatheringCard renders the event fields + «Встреча» badge.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/backend/interfaces/gathering_service_interface.dart';
import 'package:rodnya/models/gathering.dart';
import 'package:rodnya/theme/app_theme.dart';
import 'package:rodnya/widgets/feed_media_gallery.dart';
import 'package:rodnya/widgets/gathering_card.dart';

class _FakeGatheringService implements GatheringServiceInterface {
  int setRsvpCalls = 0;
  String? lastStatus;
  int? lastHeadcount;

  /// When set, setRsvp returns this pending future instead of resolving —
  /// lets a test observe the optimistic frame, then complete it with an
  /// error to exercise the revert path.
  Completer<Gathering>? deferred;

  @override
  Future<Gathering> setRsvp(
    String gatheringId,
    String status, {
    int? headcount,
    String? note,
  }) {
    setRsvpCalls++;
    lastStatus = status;
    lastHeadcount = headcount;
    if (deferred != null) {
      return deferred!.future;
    }
    return Future.value(
      Gathering(
        id: gatheringId,
        treeId: 't',
        authorId: 'org',
        authorName: 'Орг',
        title: 'Встреча',
        startAt: DateTime(2026, 7, 1, 15),
        createdAt: DateTime(2026, 6, 1),
        rsvps: [
          {'userId': 'me', 'status': status, 'headcount': headcount ?? 0},
        ],
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Gathering _gathering({
  List<Map<String, dynamic>> rsvps = const [],
  List<String> imageUrls = const [],
}) {
  return Gathering(
    id: 'g1',
    treeId: 't',
    authorId: 'org',
    authorName: 'Орг',
    title: 'Встреча',
    startAt: DateTime(2026, 7, 1, 15),
    createdAt: DateTime(2026, 6, 1),
    imageUrls: imageUrls,
    rsvps: rsvps,
  );
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  testWidgets('renders the gathering title, place, author and badge',
      (tester) async {
    final gathering = Gathering(
      id: 'g1',
      treeId: 'tree-1',
      authorId: 'u1',
      authorName: 'Анна',
      title: 'Шашлыки на даче',
      description: 'Приезжайте всей семьёй',
      startAt: DateTime(2026, 7, 1, 15, 0),
      place: 'Дача в Подмосковье',
      createdAt: DateTime(2026, 6, 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(body: GatheringCard(gathering: gathering)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('gathering-card-g1')), findsOneWidget);
    expect(find.text('Шашлыки на даче'), findsOneWidget);
    expect(find.text('Дача в Подмосковье'), findsOneWidget);
    expect(find.text('Приезжайте всей семьёй'), findsOneWidget);
    expect(find.text('Анна'), findsOneWidget);
    expect(find.text('Встреча'), findsOneWidget); // type badge
  });

  testWidgets('renders gathering photos via FeedMediaGallery (B)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          // Card lives in a scrolling feed in production; give the test a
          // scroll view so the 16:9 photo doesn't overflow a fixed height.
          body: SingleChildScrollView(
            child: GatheringCard(
              gathering:
                  _gathering(imageUrls: const ['https://example.com/1.jpg']),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(FeedMediaGallery), findsOneWidget);
  });

  testWidgets('tapping «Пойду» optimistically selects and calls setRsvp',
      (tester) async {
    final svc = _FakeGatheringService();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: GatheringCard(
            gathering: _gathering(),
            serviceOverride: svc,
            currentUserId: 'me',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Ревью чанка 24: отдельной строки-тальи «Пойдут: N · Может: N ·
    // Нет: N» больше нет — счётчики переехали внутрь кнопок (как «Тепло
    // N» у PostCard, чанк 20). При нуле голосов кнопка «Пойду» не несёт
    // цифру вовсе — до первого ответа Text('0') нигде не появляется.
    expect(find.text('Пойду'), findsOneWidget);
    expect(find.text('0'), findsNothing);

    await tester.tap(find.byKey(const Key('gathering-rsvp-yes')));
    await tester.pump(); // optimistic frame — setRsvp already invoked

    expect(svc.setRsvpCalls, 1);
    expect(svc.lastStatus, 'yes');

    await tester.pumpAndSettle(); // server reconcile
    // Счётчик «Пойду» = 1 — Text('Пойду') и Text('1') оба внутри кнопки.
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('reverts the optimistic RSVP when setRsvp fails', (tester) async {
    final svc = _FakeGatheringService()..deferred = Completer<Gathering>();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: GatheringCard(
            gathering: _gathering(),
            serviceOverride: svc,
            currentUserId: 'me',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('gathering-rsvp-yes')));
    await tester.pump(); // optimistic frame (server still pending)
    expect(svc.setRsvpCalls, 1);
    expect(find.text('1'), findsOneWidget); // «Пойду 1» — optimistic count

    // Server fails → optimistic state reverts.
    svc.deferred!.completeError(Exception('boom'));
    await tester.pump(); // revert + snackbar
    expect(find.text('1'), findsNothing);
    expect(find.text('Не удалось сохранить ответ'), findsOneWidget);
  });

  testWidgets('tally counts going (with headcount), maybe and no from rsvps',
      (tester) async {
    final gathering = _gathering(
      rsvps: [
        {'userId': 'u1', 'status': 'yes', 'headcount': 0},
        {'userId': 'u2', 'status': 'yes', 'headcount': 2}, // brings 2 more
        {'userId': 'u3', 'status': 'maybe'},
        {'userId': 'u4', 'status': 'no'},
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(body: GatheringCard(gathering: gathering)),
      ),
    );
    await tester.pumpAndSettle();

    // going = u1(1) + u2(1+2) = 4; maybe = 1; no = 1. Counts now live
    // inside the RSVP buttons (ревью чанка 24) rather than a standalone
    // tally sentence.
    expect(find.text('4'), findsOneWidget); // «Пойду 4»
    expect(find.text('1'), findsNWidgets(2)); // «Может 1» и «Не пойду 1»

    // Ряд аватаров-участников (чанк 24): u1 и u2 ответили «да» → два
    // пузыря-инициала (буквы из userId, т.к. в rsvps нет имени/фото).
    expect(find.byKey(const Key('gathering-participants')), findsOneWidget);
    expect(find.text('U'), findsNWidgets(2)); // 'u1'/'u2' → инициал 'U'
  });
}
