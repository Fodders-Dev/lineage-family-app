import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:lineage/models/app_notification_item.dart';
import 'package:lineage/models/family_tree.dart';
import 'package:lineage/providers/tree_provider.dart';
import 'package:lineage/screens/notifications_screen.dart';
import 'package:lineage/services/local_storage_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await getIt.reset();
    getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets(
    'NotificationsScreen показывает пустое состояние без новых уведомлений',
    (tester) async {
      await tester.pumpWidget(
        await _buildNotificationsApp(
          const NotificationsScreen(
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
    'NotificationsScreen отмечает уведомление прочитанным и открывает его по тапу',
    (tester) async {
      AppNotificationItem? openedItem;
      AppNotificationItem? readItem;

      await tester.pumpWidget(
        await _buildNotificationsApp(
          NotificationsScreen(
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
            onMarkNotificationRead: (item) async {
              readItem = item;
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
      expect(readItem?.id, 'notification-1');
      expect(find.text('Пока нет новых уведомлений'), findsOneWidget);
    },
  );

  testWidgets(
    'NotificationsScreen даёт прочитать всё одним действием',
    (tester) async {
      List<AppNotificationItem>? markedItems;

      await tester.pumpWidget(
        await _buildNotificationsApp(
          NotificationsScreen(
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
              AppNotificationItem(
                id: 'notification-2',
                type: 'chat_message',
                title: 'Анастасия',
                body: 'Привет',
                createdAt: DateTime(2026, 4, 3, 12, 31),
                data: const {'chatId': 'chat-1'},
                payload: '{"type":"chat"}',
              ),
            ],
            onMarkAllNotificationsRead: (items) async {
              markedItems = items;
            },
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.byTooltip('Прочитать всё'), findsOneWidget);
      expect(find.text('Приглашение в дерево · 1'), findsOneWidget);
      expect(find.text('Новое сообщение · 1'), findsOneWidget);

      await tester.tap(find.byTooltip('Прочитать всё'));
      await tester.pumpAndSettle();

      expect(markedItems, hasLength(2));
      expect(find.text('Пока нет новых уведомлений'), findsOneWidget);
    },
  );

  testWidgets(
    'NotificationsScreen показывает корректную грамматику в overview карточке',
    (tester) async {
      await tester.pumpWidget(
        await _buildNotificationsApp(
          NotificationsScreen(
            notificationLoader: () async => List<AppNotificationItem>.generate(
              5,
              (index) => AppNotificationItem(
                id: 'notification-$index',
                type: 'chat_message',
                title: 'Диалог $index',
                body: 'Сообщение $index',
                createdAt: DateTime(2026, 4, 3, 12, 30 + index),
                data: const {'chatId': 'chat-1'},
                payload: '{"type":"chat"}',
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Сейчас 5 новых событий'), findsOneWidget);
      expect(
        find.text(
          'Очередь активности собирается для семейного дерева. Просмотрите сообщения, приглашения и запросы в одном месте.',
        ),
        findsOneWidget,
      );
    },
  );
}

Future<List<AppNotificationItem>> _emptyLoader() async =>
    const <AppNotificationItem>[];

Future<Widget> _buildNotificationsApp(Widget child) async {
  final treeProvider = TreeProvider();
  await treeProvider.selectTree(
    'tree-1',
    'Семья Шуфляк',
    treeKind: TreeKind.family,
  );
  return ChangeNotifierProvider<TreeProvider>.value(
    value: treeProvider,
    child: MaterialApp(home: child),
  );
}

class _FakeLocalStorageService implements LocalStorageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
