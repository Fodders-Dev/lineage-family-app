// Баннер «включите уведомления» подписан на ревизию CTA сервиса: состояние
// разрешения на Android выясняется асинхронно ПОСЛЕ первого build, и без
// подписки баннер показывался только если проверка успевала раньше.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rodnya/services/browser_notification_bridge.dart';
import 'package:rodnya/services/custom_api_notification_service.dart';
import 'package:rodnya/theme/app_theme.dart';
import 'package:rodnya/widgets/notification_permission_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_permission_state_test.dart' show FakeBridge;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await GetIt.I.reset();
  });
  tearDown(() async => GetIt.I.reset());

  testWidgets('состояние CTA изменилось после первого build → баннер появляется',
      (tester) async {
    final bridge = FakeBridge(
      permission: BrowserNotificationPermissionStatus.granted,
    );
    final prefs = await SharedPreferences.getInstance();
    final service = await CustomApiNotificationService.create(
      preferences: prefs,
      browserNotificationBridge: bridge,
      isWeb: true,
    );
    GetIt.I.registerSingleton<CustomApiNotificationService>(service);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: const Scaffold(body: NotificationPermissionBanner()),
    ));
    await tester.pump();
    expect(
      find.byKey(const Key('notification-permission-banner')),
      findsNothing,
    );

    // Разрешение «ещё не решено» выяснилось позже первого build — как
    // асинхронная Android-проверка в сервисе. Без подписки баннер бы не
    // появился до следующего постороннего rebuild.
    bridge.permission = BrowserNotificationPermissionStatus.defaultState;
    service.permissionCtaRevision.value += 1;
    await tester.pump();
    expect(
      find.byKey(const Key('notification-permission-banner')),
      findsOneWidget,
    );

    // Дисмисс поднимает ревизию сам — баннер гаснет без внешнего setState.
    await service.dismissNotificationCta();
    await tester.pump();
    expect(
      find.byKey(const Key('notification-permission-banner')),
      findsNothing,
    );
  });
}
