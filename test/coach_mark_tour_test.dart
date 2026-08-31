// E: coach-mark tour overlay — steps through targets, dismisses on skip
// or after the last step, and gates/persists via prefs (shows once).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rodnya/theme/app_theme.dart';
import 'package:rodnya/widgets/coach_mark_tour.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(List<CoachMarkTarget> targets, VoidCallback onDismiss) {
    return MaterialApp(
      theme: AppTheme.lightTheme,
      home: Scaffold(
        body: SizedBox.expand(
          child: Stack(
            children: [
              Positioned.fill(
                child: Column(
                  children: [
                    for (final t in targets)
                      SizedBox(key: t.key, width: 120, height: 40),
                  ],
                ),
              ),
              CoachMarkTour(targets: targets, onDismiss: onDismiss),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('steps through targets, «Понятно» on last dismisses',
      (tester) async {
    var dismissed = false;
    final targets = [
      CoachMarkTarget(
          key: GlobalKey(), title: 'Шаг один', body: 'Тело один'),
      CoachMarkTarget(key: GlobalKey(), title: 'Шаг два', body: 'Тело два'),
    ];
    await tester.pumpWidget(host(targets, () => dismissed = true));
    await tester.pumpAndSettle();

    // Anchors resolved → tour overlay rendered, step 1 shown.
    expect(find.byKey(const Key('coach-mark-tour')), findsOneWidget);
    expect(find.text('Шаг один'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('coach-mark-next')));
    await tester.pumpAndSettle();
    expect(find.text('Шаг два'), findsOneWidget);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text('Понятно'), findsOneWidget);

    await tester.tap(find.byKey(const Key('coach-mark-next')));
    await tester.pumpAndSettle();
    expect(dismissed, isTrue);
  });

  testWidgets('«Пропустить» dismisses immediately', (tester) async {
    var dismissed = false;
    final targets = [
      CoachMarkTarget(key: GlobalKey(), title: 'Шаг', body: 'Тело'),
      CoachMarkTarget(key: GlobalKey(), title: 'Ещё', body: 'Тело'),
    ];
    await tester.pumpWidget(host(targets, () => dismissed = true));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('coach-mark-skip')));
    await tester.pumpAndSettle();
    expect(dismissed, isTrue);
  });

  testWidgets('шаг без анкера показывается карточкой по центру',
      (tester) async {
    // Вкладка «Дерево» живёт в шелле, ключа на неё у ленты нет — шаг
    // без анкера обязан отрисоваться (скрим без дырки), иначе новичку
    // некому назвать ядро продукта.
    var dismissed = false;
    final targets = <CoachMarkTarget>[
      const CoachMarkTarget(title: 'Дерево', body: 'Внизу по центру'),
      CoachMarkTarget(key: GlobalKey(), title: 'Второй', body: 'Тело'),
    ];
    await tester.pumpWidget(host(targets, () => dismissed = true));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('coach-mark-tour')), findsOneWidget);
    expect(find.text('Дерево'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('coach-mark-next')));
    await tester.pumpAndSettle();
    expect(find.text('Второй'), findsOneWidget);
    expect(dismissed, isFalse);
  });

  test('shouldShow gates on prefs; markShown persists', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    expect(await CoachMarkTour.shouldShow(), isTrue);
    await CoachMarkTour.markShown();
    expect(await CoachMarkTour.shouldShow(), isFalse);
  });

  testWidgets(
      'F4: оверлей под топбаром — буббл целится в блок, а не мимо',
      (tester) async {
    // Прод-структура home: Scaffold с appBar, тур — в Stack ВНУТРИ body.
    // До фикса rect таргета оставался глобальным, и спотлайт с бубблом
    // съезжали вниз на высоту топбара (заметно на wide web).
    final targetKey = GlobalKey();
    final targets = [
      CoachMarkTarget(key: targetKey, title: 'Шаг', body: 'Тело'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(120),
            child: Container(color: Colors.green),
          ),
          body: Stack(
            children: [
              Positioned.fill(
                child: Column(
                  children: [
                    SizedBox(key: targetKey, width: 200, height: 48),
                  ],
                ),
              ),
              CoachMarkTour(targets: targets, onDismiss: () {}),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Буббл (заголовок шага) должен сидеть на 14px ниже НИЗА таргета —
    // в глобальных координатах, независимо от смещения оверлея.
    final targetBottom = tester.getBottomLeft(find.byKey(targetKey)).dy;
    final bubbleTop = tester
        .getTopLeft(find.byKey(const Key('coach-mark-bubble')))
        .dy;
    expect((bubbleTop - targetBottom - 14).abs(), lessThan(1.0));
  });
}
