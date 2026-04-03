import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lineage/widgets/main_navigation_bar.dart';

void main() {
  late StreamController<int> unreadController;
  late StreamController<int> invitationsController;

  setUp(() {
    unreadController = StreamController<int>.broadcast();
    invitationsController = StreamController<int>.broadcast();
  });

  tearDown(() async {
    await unreadController.close();
    await invitationsController.close();
  });

  testWidgets('MainNavigationBar показывает badges для чатов и приглашений',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: MainNavigationBar(
            currentIndex: 0,
            onTap: (_) {},
            unreadChatsStream: unreadController.stream,
            pendingInvitationsCountStream: invitationsController.stream,
          ),
        ),
      ),
    );

    unreadController.add(4);
    invitationsController.add(2);
    await tester.pump();

    expect(find.text('Чаты'), findsOneWidget);
    expect(find.text('Моё дерево'), findsOneWidget);
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
            unreadChatsStream: unreadController.stream,
            pendingInvitationsCountStream: invitationsController.stream,
          ),
        ),
      ),
    );

    unreadController.add(0);
    invitationsController.add(0);
    await tester.pump();

    await tester.tap(find.text('Чаты'));
    await tester.pump();

    expect(tappedIndex, 3);
  });
}
