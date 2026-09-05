// N4 (widget): first-run CTA-баннер.
//   • виден при default (web) → кнопка «Включить уведомления»;
//   • тап = жест → requestPermission, баннер гаснет;
//   • «Скрыть» гасит баннер (флаг в prefs);
//   • iOS вне PWA → «добавьте на Домой», без кнопки запроса.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rodnya/services/browser_notification_bridge.dart';
import 'package:rodnya/services/custom_api_notification_service.dart';
import 'package:rodnya/theme/app_theme.dart';
import 'package:rodnya/widgets/notification_permission_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_permission_state_test.dart' show FakeBridge;

Future<void> _register(FakeBridge bridge) async {
  final prefs = await SharedPreferences.getInstance();
  final service = await CustomApiNotificationService.create(
    preferences: prefs,
    browserNotificationBridge: bridge,
    isWeb: true,
  );
  GetIt.I.registerSingleton<CustomApiNotificationService>(service);
}

Widget _host() => MaterialApp(
      theme: AppTheme.lightTheme,
      home: const Scaffold(body: NotificationPermissionBanner()),
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await GetIt.I.reset();
  });

  tearDown(() async {
    await GetIt.I.reset();
  });

  testWidgets('default → баннер с кнопкой «Включить уведомления»',
      (tester) async {
    await _register(FakeBridge(
      permission: BrowserNotificationPermissionStatus.defaultState,
    ));

    await tester.pumpWidget(_host());
    await tester.pump();

    expect(
      find.byKey(const Key('notification-permission-banner')),
      findsOneWidget,
    );
    // Плотность, чанк 17: кнопка «Включить уведомления» → «Включить»
    // (компактная строка вместо полноширинной карточки).
    expect(find.text('Включить'), findsOneWidget);
  });

  testWidgets('тап «Включить» → requestPermission (жест) и баннер гаснет',
      (tester) async {
    final bridge = FakeBridge(
      permission: BrowserNotificationPermissionStatus.defaultState,
    );
    await _register(bridge);

    await tester.pumpWidget(_host());
    await tester.pump();

    // Просто показ баннера НЕ должен ничего запрашивать.
    expect(bridge.requestPermissionCalls, 0);

    await tester.tap(find.byKey(const Key('notification-permission-enable')));
    await tester.pumpAndSettle();

    expect(bridge.requestPermissionCalls, 1);
    expect(
      find.byKey(const Key('notification-permission-banner')),
      findsNothing,
    );
  });

  testWidgets('«Скрыть» гасит баннер и ставит флаг', (tester) async {
    await _register(FakeBridge(
      permission: BrowserNotificationPermissionStatus.defaultState,
    ));

    await tester.pumpWidget(_host());
    await tester.pump();

    await tester.tap(find.byKey(const Key('notification-permission-dismiss')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('notification-permission-banner')),
      findsNothing,
    );
    expect(
      GetIt.I<CustomApiNotificationService>().isNotificationCtaDismissed,
      isTrue,
    );
  });

  testWidgets('iOS вне PWA → «добавьте на Домой», без кнопки запроса',
      (tester) async {
    final bridge = FakeBridge(
      permission: BrowserNotificationPermissionStatus.defaultState,
      iosWeb: true,
      standalone: false,
    );
    await _register(bridge);

    await tester.pumpWidget(_host());
    await tester.pump();

    expect(
      find.byKey(const Key('notification-permission-banner')),
      findsOneWidget,
    );
    expect(find.textContaining('на экран «Домой»'), findsOneWidget);
    // Кнопки запроса нет, и сам показ ничего не запрашивает.
    expect(
        find.byKey(const Key('notification-permission-enable')), findsNothing);
    expect(bridge.requestPermissionCalls, 0);
  });

  testWidgets('granted → баннер не показывается', (tester) async {
    await _register(FakeBridge(
      permission: BrowserNotificationPermissionStatus.granted,
    ));

    await tester.pumpWidget(_host());
    await tester.pump();

    expect(
      find.byKey(const Key('notification-permission-banner')),
      findsNothing,
    );
  });

  testWidgets('сервис не зарегистрирован → баннер молчит', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();
    expect(
      find.byKey(const Key('notification-permission-banner')),
      findsNothing,
    );
  });
}
