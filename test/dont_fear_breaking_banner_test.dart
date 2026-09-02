// Phase B polish C: «Не бойся сломать» banner — renders by default,
// dismiss hides it and persists (won't show again).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rodnya/widgets/dont_fear_breaking_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('renders by default, then dismiss hides + persists',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DontFearBreakingBanner())),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dont-fear-breaking-banner')), findsOneWidget);
    expect(
      find.text('Не бойся сломать — каждое действие можно отменить.'),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('dont-fear-breaking-banner-dismiss')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dont-fear-breaking-banner')), findsNothing);

    // A fresh instance stays hidden — the dismissal was persisted.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DontFearBreakingBanner())),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dont-fear-breaking-banner')), findsNothing);
  });

  testWidgets('already-dismissed pref → not shown', (tester) async {
    SharedPreferences.setMockInitialValues(
      {'dont_fear_breaking_banner_dismissed_v1': true},
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DontFearBreakingBanner())),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dont-fear-breaking-banner')), findsNothing);
  });
}
