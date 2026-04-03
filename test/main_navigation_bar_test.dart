import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lineage/widgets/main_navigation_bar.dart';

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

    expect(find.text('Главная'), findsOneWidget);
    expect(find.text('Чаты'), findsOneWidget);
    expect(find.text('Моё дерево'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
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

    await tester.tap(find.text('Чаты'));
    await tester.pump();

    expect(tappedIndex, 3);
  });
}
