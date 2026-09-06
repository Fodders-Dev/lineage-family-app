// Density invariant (чанк 24 — карточка опроса в ленте): с тремя
// вариантами карточка должна укладываться в ≤260dp на 412×915dp, dpr 3
// — шапка (≤56dp, вертикаль 4/4 — плотнее, чем у GatheringCard, чтобы
// вместить строки вариантов), вопрос 18sp serif, три строки-варианта
// по 44dp с зазором 4dp между ними (не паддингом «снизу у каждой» —
// раньше лишние 8dp оставались перед строкой голосов даже на
// последнем варианте) и строка «N голосов[ · до …]» 13sp. До чанка 24
// было 312dp: padding: EdgeInsets.all(16) на весь контейнер + вопрос
// на titleLarge (≈22sp) + текст/процент вариантов ниже целевых
// 16sp/14sp + 8dp паддинга под каждым вариантом.
//
// Promoted from a throwaway measurement probe used while redesigning
// lib/widgets/poll_card.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/models/poll.dart';
import 'package:rodnya/widgets/poll_card.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  testWidgets(
    'PollCard (чанк 24): с 3 вариантами карточка ≤260dp на 412×915',
    (tester) async {
      tester.view.physicalSize = const Size(412 * 3, 915 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final poll = Poll(
        id: 'p1',
        treeId: 't',
        authorId: 'org',
        authorName: 'Анна',
        question: 'Когда едем?',
        options: const [
          PollOption(id: 'o1', text: 'Суббота'),
          PollOption(id: 'o2', text: 'Воскресенье'),
          PollOption(id: 'o3', text: 'Не еду'),
        ],
        createdAt: DateTime(2026, 6, 1),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: PollCard(poll: poll)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final size = tester.getSize(find.byType(PollCard));
      expect(
        size.height,
        lessThanOrEqualTo(260),
        reason: 'Карточка опроса из 3 вариантов (включая межкарточный '
            'зазор margin-bottom 8dp) не должна превышать 260dp — см. '
            'чанк 24. До чанка 24 было 312dp. Замерено: ${size.height}.',
      );
    },
  );
}
