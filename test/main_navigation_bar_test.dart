import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rodnya/widgets/main_navigation_bar.dart';

void main() {
  late StreamController<int> notificationsController;
  late StreamController<int> unreadController;
  late StreamController<int> invitationsController;

  setUp(() {
    notificationsController = StreamController<int>.broadcast();
    unreadController = StreamController<int>.broadcast();
    invitationsController = StreamController<int>.broadcast();
  });

  tearDown(() async {
    await notificationsController.close();
    await unreadController.close();
    await invitationsController.close();
  });

  testWidgets(
      'MainNavigationBar показывает badges для активности, чатов и приглашений',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: MainNavigationBar(
            currentIndex: 0,
            onTap: (_) {},
            unreadNotificationsStream: notificationsController.stream,
            unreadChatsStream: unreadController.stream,
            pendingInvitationsCountStream: invitationsController.stream,
          ),
        ),
      ),
    );

    notificationsController.add(3);
    unreadController.add(4);
    invitationsController.add(2);
    await tester.pump();

    expect(find.text('Лента'), findsOneWidget);
    // UX-core: relatives + tree live in one «Родные» tab; «Календарь»
    // promoted from a topbar icon to its own tab.
    expect(find.text('Родные'), findsOneWidget);
    expect(find.text('Календарь'), findsOneWidget);
    expect(find.text('Чаты'), findsOneWidget);
    // Q5: the profile tab reads «Профиль», not the terse «Я».
    expect(find.text('Профиль'), findsOneWidget);
    expect(find.text('Я'), findsNothing);
    expect(find.text('Семья'), findsNothing);
    expect(find.text('Дерево'), findsNothing);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    // Pending-invitations badge rides on «Родные» now.
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('MainNavigationBar пробрасывает выбор вкладки', (tester) async {
    int? tappedIndex;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: MainNavigationBar(
            currentIndex: 0,
            onTap: (index) => tappedIndex = index,
            unreadNotificationsStream: notificationsController.stream,
            unreadChatsStream: unreadController.stream,
            pendingInvitationsCountStream: invitationsController.stream,
          ),
        ),
      ),
    );

    notificationsController.add(0);
    unreadController.add(0);
    invitationsController.add(0);
    await tester.pump();

    // Tab order: 0 Лента · 1 Родные · 2 Календарь · 3 Чаты · 4 Профиль.
    await tester.tap(find.text('Родные'));
    await tester.pump();
    expect(tappedIndex, 1);

    await tester.tap(find.text('Календарь'));
    await tester.pump();
    expect(tappedIndex, 2);

    await tester.tap(find.text('Чаты'));
    await tester.pump();
    expect(tappedIndex, 3);
  });

  testWidgets('MainNavigationBar скрывает подписи на узких мобильных экранах',
      (tester) async {
    // Threshold lowered from 340 → 280 (Samsung-mid mobiles were
    // tripping the hide path and losing labels). Test now sets a
    // genuinely narrow viewport (260dp) so labels still hide on
    // truly cramped layouts (split-screen tablets, smartwatches).
    await tester.binding.setSurfaceSize(const Size(260, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: MainNavigationBar(
            currentIndex: 0,
            onTap: (_) {},
            unreadNotificationsStream: notificationsController.stream,
            unreadChatsStream: unreadController.stream,
            pendingInvitationsCountStream: invitationsController.stream,
          ),
        ),
      ),
    );

    notificationsController.add(0);
    unreadController.add(0);
    invitationsController.add(0);
    await tester.pump();

    expect(find.text('Лента'), findsNothing);
    expect(find.text('Родные'), findsNothing);
    expect(find.text('Календарь'), findsNothing);
    expect(find.text('Чаты'), findsNothing);
    expect(find.text('Профиль'), findsNothing);
  });
}
