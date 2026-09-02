// AppTheme.bottomNavInset — сколько нижний бар занимает от края экрана,
// зеркало topbarHeight. С 02.09.2026 бар — плоская панель: высота +
// системный inset, без полей пилюли и «воздуха».

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rodnya/theme/app_theme.dart';

void main() {
  Future<double> insetFor(WidgetTester tester, double safeBottom) async {
    late double inset;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(padding: EdgeInsets.only(bottom: safeBottom)),
        child: Builder(
          builder: (context) {
            inset = AppTheme.bottomNavInset(context);
            return const SizedBox();
          },
        ),
      ),
    );
    return inset;
  }

  testWidgets('bottomNavInset = высота панели + системный inset',
      (tester) async {
    final small = await insetFor(tester, 6);
    expect(small, AppTheme.bottomNavContentHeight + 6.0);

    // Жестовая навигация: inset устройства добавляется целиком.
    final large = await insetFor(tester, 48);
    expect(large, AppTheme.bottomNavContentHeight + 48.0);

    // Inset grows with the device safe-area.
    expect(large, greaterThan(small));
  });
}
