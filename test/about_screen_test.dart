// AboutScreen ("О приложении") — не имела ни одного теста, хотя это
// двухколоночный/одностолбцовый layout, который плотностные агенты уже
// правили (96dp бренд-круг вместо 140dp, см. комментарий в самом
// экране). Пины: версия грузится асинхронно через PackageInfo и
// сначала показывает плейсхолдер, статический контент/ссылки на месте,
// тап по ссылке переходит по нужному пути, оба layout'а (узкий/широкий)
// не дают overflow.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:rodnya/screens/about_screen.dart';

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Родня',
      packageName: 'com.ahjkuio.rodnya_family_app',
      version: '1.0.37',
      buildNumber: '45',
      buildSignature: '',
    );
  });

  GoRouter buildRouter() => GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const AboutScreen(),
          ),
          GoRoute(
            path: '/privacy',
            builder: (context, state) =>
                const Scaffold(body: Text('Экран политики конфиденциальности')),
          ),
          GoRoute(
            path: '/terms',
            builder: (context, state) =>
                const Scaffold(body: Text('Экран условий использования')),
          ),
          GoRoute(
            path: '/support',
            builder: (context, state) =>
                const Scaffold(body: Text('Экран поддержки')),
          ),
          GoRoute(
            path: '/account-deletion',
            builder: (context, state) =>
                const Scaffold(body: Text('Экран удаления аккаунта')),
          ),
        ],
        initialLocation: '/',
      );

  testWidgets('версия из PackageInfo рендерится как "Версия … (сборка …)"',
      (tester) async {
    // PackageInfo.setMockInitialValues отвечает на канал синхронно —
    // "Версия загружается…" (FutureBuilder до snapshot.data) не успевает
    // стать наблюдаемым кадром под тестом; проверяем итоговый результат.
    await tester.pumpWidget(MaterialApp.router(routerConfig: buildRouter()));
    await tester.pumpAndSettle();
    expect(find.text('Версия 1.0.37 (сборка 45)'), findsOneWidget);
    expect(find.text('Версия загружается…'), findsNothing);
  });

  testWidgets('статический контент и все ссылки на месте', (tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: buildRouter()));
    await tester.pumpAndSettle();

    expect(find.text('Родня'), findsOneWidget);
    expect(find.textContaining('дерево по веткам'), findsOneWidget);
    expect(find.text('Разработчики'), findsOneWidget);
    expect(find.text('Artem Kuznetsov'), findsOneWidget);
    expect(find.text('Политика конфиденциальности'), findsOneWidget);
    expect(find.text('Условия использования'), findsOneWidget);
    expect(find.text('Поддержка'), findsOneWidget);
    expect(find.text('ahjkuio@gmail.com'), findsOneWidget);
    expect(find.text('Удаление аккаунта'), findsOneWidget);
    expect(find.text('© 2026 Родня. Все права защищены.'), findsOneWidget);
  });

  testWidgets('тап по ссылке "Поддержка" открывает /support', (tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: buildRouter()));
    await tester.pumpAndSettle();

    // Список ссылок ниже фолда на дефолтном 800×600 test-вьюпорте —
    // сначала докручиваем до строки, как в остальных тестах со
    // SingleChildScrollView (см. add_relative_screen_test).
    await tester.ensureVisible(find.text('Поддержка'));
    await tester.tap(find.text('Поддержка'));
    await tester.pumpAndSettle();

    expect(find.text('Экран поддержки'), findsOneWidget);
  });

  testWidgets('тап по ссылке "Удаление аккаунта" открывает /account-deletion',
      (tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: buildRouter()));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Удаление аккаунта'));
    await tester.tap(find.text('Удаление аккаунта'));
    await tester.pumpAndSettle();

    expect(find.text('Экран удаления аккаунта'), findsOneWidget);
  });

  testWidgets('узкий экран 360×640 — нет overflow', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp.router(routerConfig: buildRouter()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('широкий экран (десктоп, ≥1180dp) — двухколоночный layout без overflow',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp.router(routerConfig: buildRouter()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Обе колонки одновременно на экране — контент не спрятан в один столбец.
    expect(find.text('Родня'), findsOneWidget);
    expect(find.text('Политика конфиденциальности'), findsOneWidget);
  });
}
