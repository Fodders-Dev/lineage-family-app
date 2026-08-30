import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/models/app_notification_item.dart';
import 'package:rodnya/models/family_tree.dart';
import 'package:rodnya/providers/tree_provider.dart';
import 'package:rodnya/screens/notifications_screen.dart';
import 'package:rodnya/services/app_status_service.dart';
import 'package:rodnya/services/local_storage_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await getIt.reset();
    getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
    getIt.registerSingleton<AppStatusService>(AppStatusService());
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
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

      expect(find.byTooltip('Отметить всё прочитанным'), findsOneWidget);
      expect(find.text('Приглашение в дерево · 1'), findsOneWidget);
      expect(find.text('Новое сообщение · 1'), findsOneWidget);

      await tester.tap(find.byTooltip('Отметить всё прочитанным'));
      await tester.pumpAndSettle();

      expect(markedItems, hasLength(2));
      // Новая семантика (пункт 1, 31.08): прочитанное не исчезает в
      // пустоту — переезжает в секцию «Ранее» приглушённой историей.
      expect(find.text('Ранее'), findsOneWidget);
      expect(find.text('Семья Шуфляк'), findsOneWidget);
      expect(find.text('Пока нет новых уведомлений'), findsNothing);
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
          'Сообщения, приглашения и запросы для семейного дерева — всё в одном месте.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'NotificationsScreen показывает понятную ошибку при массовом обновлении',
    (tester) async {
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
            onMarkAllNotificationsRead: (_) async {
              throw Exception('boom');
            },
          ),
        ),
      );

      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Отметить всё прочитанным'));
      await tester.pump();

      expect(
        find.text(
          'Не удалось отметить уведомления прочитанными. Попробуйте ещё раз.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'NotificationsScreen объединяет типы звонков в одну понятную категорию',
    (tester) async {
      await tester.pumpWidget(
        await _buildNotificationsApp(
          NotificationsScreen(
            notificationLoader: () async => [
              AppNotificationItem(
                id: 'call-1',
                type: 'call',
                title: 'Звонок от Анны',
                body: 'Пропущенный звонок',
                createdAt: DateTime(2026, 4, 3, 12, 30),
                data: const {},
                payload: '{}',
              ),
              AppNotificationItem(
                id: 'call-2',
                type: 'call_invite',
                title: 'Анна приглашает в звонок',
                body: 'Входящий звонок',
                createdAt: DateTime(2026, 4, 3, 12, 31),
                data: const {},
                payload: '{}',
              ),
            ],
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Звонок · 2'), findsOneWidget);
      expect(find.textContaining('Уведомление ·'), findsNothing);
    },
  );
  testWidgets('«Прочитать всё» переносит уведомления в «Ранее», не в пустоту',
      (tester) async {
    final items = [
      AppNotificationItem(
        id: 'n-1',
        type: 'generic',
        title: 'Первое уведомление',
        body: '-',
        createdAt: DateTime(2026, 8, 30, 10),
        data: const {},
        payload: '',
      ),
    ];
    var markAllCalls = 0;
    await tester.pumpWidget(
      await _buildNotificationsApp(
        NotificationsScreen(
          notificationLoader: () async => items,
          onMarkAllNotificationsRead: (toMark) async {
            markAllCalls += 1;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Первое уведомление'), findsOneWidget);
    await tester.tap(find.byTooltip('Отметить всё прочитанным'));
    await tester.pumpAndSettle();

    expect(markAllCalls, 1);
    expect(find.text('Ранее'), findsOneWidget,
        reason: 'история появляется вместо пустого экрана');
    expect(find.text('Первое уведомление'), findsOneWidget,
        reason: 'уведомление переехало в «Ранее», а не пропало');
  });

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
  final FamilyTree _tree = FamilyTree(
    id: 'tree-1',
    name: 'Семья Шуфляк',
    description: '',
    creatorId: 'user-1',
    memberIds: const ['user-1'],
    createdAt: DateTime(2026, 4, 3),
    updatedAt: DateTime(2026, 4, 3),
    isPrivate: true,
    members: const ['user-1'],
  );

  @override
  Future<List<FamilyTree>> getAllTrees() async => [_tree];

  @override
  Future<FamilyTree?> getTree(String treeId) async =>
      treeId == _tree.id ? _tree : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthService implements AuthServiceInterface {
  @override
  String? get currentUserId => 'user-1';

  @override
  String describeError(Object error) => error.toString();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

}
