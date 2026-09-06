// Density invariant (чанк 24 — карточка встречи в ленте): без медиа
// карточка должна укладываться в ≤190dp на 412×915dp, dpr 3 — шапка
// (≤56dp: аватар 40 + 8/8 вертикали), заголовок 18sp serif + «когда·где»
// одной строкой (иконки 18, аудитория переехала в строку метаданных
// шапки — отдельного чипа больше нет) и строка RSVP-действий (44dp,
// счётчики внутри кнопок вместо отдельной строки-тальи «Пойдут: N ·
// Может: N · Нет: N»). До чанка 24 было 284dp: padding: EdgeInsets.
// all(16) на весь контейнер + раздельные строки schedule/place +
// отдельный чип аудитории + отдельная строка-таблица под кнопками.
//
// Promoted from a throwaway measurement probe used while redesigning
// lib/widgets/gathering_card.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/models/gathering.dart';
import 'package:rodnya/widgets/gathering_card.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  testWidgets(
    'GatheringCard (чанк 24): без медиа карточка ≤190dp на 412×915',
    (tester) async {
      tester.view.physicalSize = const Size(412 * 3, 915 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final gathering = Gathering(
        id: 'g1',
        treeId: 't',
        authorId: 'org',
        authorName: 'Анна',
        title: 'Шашлыки на даче',
        startAt: DateTime(2026, 7, 1, 15),
        place: 'Дача',
        createdAt: DateTime(2026, 6, 1),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: GatheringCard(gathering: gathering),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final size = tester.getSize(find.byType(GatheringCard));
      expect(
        size.height,
        lessThanOrEqualTo(190),
        reason: 'Карточка встречи без медиа (включая межкарточный '
            'зазор margin-bottom 8dp) не должна превышать 190dp — см. '
            'чанк 24. До чанка 24 было 284dp. Замерено: ${size.height}.',
      );
    },
  );
}
