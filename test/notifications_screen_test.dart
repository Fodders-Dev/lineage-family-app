import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lineage/models/app_notification_item.dart';
import 'package:lineage/screens/notifications_screen.dart';

void main() {
  testWidgets(
    'NotificationsScreen показывает пустое состояние без новых уведомлений',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: NotificationsScreen(
            notificationLoader: _emptyLoader,
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Пока нет новых уведомлений'), findsOneWidget);
      expect(find.text('На главную'), findsOneWidget);
    },
  );

  testWidgets(
    'NotificationsScreen показывает уведомление и открывает его по тапу',
    (tester) async {
      AppNotificationItem? openedItem;

      await tester.pumpWidget(
        MaterialApp(
          home: NotificationsScreen(
            notificationLoader: () async => [
              AppNotificationItem(
                id: 'notification-1',
                type: 'tree_invitation',
                title: 'Семья Шуфляк',
                body: 'Вас пригласили в дерево',
                createdAt: DateTime(2026, 4, 3, 12, 30),
                data: const {'treeId': 'tree-1'},
                payload: '{"type":"tree_invitation"}',
              ),
            ],
            onOpenNotification: (item) {
              openedItem = item;
            },
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Приглашение в дерево'), findsOneWidget);
      expect(find.text('Семья Шуфляк'), findsOneWidget);
      expect(find.text('Вас пригласили в дерево'), findsOneWidget);

      await tester.tap(find.text('Семья Шуфляк'));
      await tester.pumpAndSettle();

      expect(openedItem?.id, 'notification-1');
    },
  );
}

Future<List<AppNotificationItem>> _emptyLoader() async =>
    const <AppNotificationItem>[];
