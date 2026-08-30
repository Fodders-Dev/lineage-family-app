import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../models/app_notification_item.dart';
import '../models/family_tree.dart';
import '../providers/tree_provider.dart';
import '../services/app_status_service.dart';
import '../services/custom_api_notification_service.dart';
import '../services/notifications_cache.dart';
import '../utils/user_facing_error.dart';

IconData _notificationIconForType(String type) {
  switch (type) {
    case 'chat':
    case 'chat_message':
      return Icons.chat_bubble_outline;
    case 'tree_invitation':
      return Icons.account_tree_outlined;
    case 'tree_update':
      return Icons.account_tree_outlined;
    case 'call':
    case 'call_invite':
      return Icons.call_outlined;
    case 'birthday':
      return Icons.cake_outlined;
    case 'relation_request':
      return Icons.people_outline;
    case 'merge_proposal':
      return Icons.merge_type_outlined;
    case 'identity_claim':
      return Icons.verified_user_outlined;
    case 'post_reaction':
    case 'comment_reaction':
    case 'story_reaction':
      return Icons.favorite_border;
    case 'comment_reply':
      return Icons.reply_outlined;
    case 'post_created':
      return Icons.post_add_outlined;
    default:
      return Icons.notifications_none;
  }
}

String _notificationLabelForType(String type) {
  switch (type) {
    case 'chat':
    case 'chat_message':
      return 'Новое сообщение';
    case 'tree_invitation':
      return 'Приглашение в дерево';
    case 'tree_update':
      return 'Обновление дерева';
    case 'call':
    case 'call_invite':
      return 'Звонок';
    case 'birthday':
      return 'Семейное событие';
    case 'relation_request':
      return 'Запрос связи';
    case 'merge_proposal':
      return 'Возможное совпадение';
    case 'identity_claim':
      return 'Запрос личности';
    case 'post_reaction':
      return 'Реакция на пост';
    case 'comment_reaction':
      return 'Реакция на комментарий';
    case 'story_reaction':
      return 'Реакция на историю';
    case 'comment_reply':
      return 'Ответ на комментарий';
    case 'post_created':
      return 'Новый пост';
    default:
      return 'Уведомление';
  }
}

String _notificationSummaryType(String type) {
  switch (type) {
    case 'chat':
    case 'chat_message':
      return 'chat_message';
    case 'call':
    case 'call_invite':
      return 'call';
    default:
      return type;
  }
}

String _activityEventCountLabel(int count) {
  final mod10 = count % 10;
  final mod100 = count % 100;
  if (mod10 == 1 && mod100 != 11) {
    return 'новое событие';
  }
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return 'новых события';
  }
  return 'новых событий';
}

String _graphLabelForInvitations(bool isFriendsTree) {
  return isFriendsTree ? 'круг друзей' : 'семейное дерево';
}

String _graphLabelForQueue(bool isFriendsTree) {
  return isFriendsTree ? 'круга друзей' : 'семейного дерева';
}

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({
    super.key,
    this.notificationLoader,
    this.onOpenNotification,
    this.onMarkNotificationRead,
    this.onMarkAllNotificationsRead,
  });

  final Future<List<AppNotificationItem>> Function()? notificationLoader;
  final ValueChanged<AppNotificationItem>? onOpenNotification;
  final Future<void> Function(AppNotificationItem item)? onMarkNotificationRead;
  final Future<void> Function(List<AppNotificationItem> items)?
      onMarkAllNotificationsRead;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final AppStatusService _appStatusService = GetIt.I<AppStatusService>();
  bool _isLoading = true;
  bool _isMutating = false;
  Object? _loadError;
  List<AppNotificationItem> _notifications = const <AppNotificationItem>[];

  /// Секция «Ранее»: прочитанная история страницами (keyset-cursor
  /// бэкенда). После «Прочитать всё» уведомления не исчезают в пустоту —
  /// переезжают сюда; подгрузка ленивая по скроллу.
  List<AppNotificationItem> _readHistory = const <AppNotificationItem>[];
  String? _readHistoryCursor;
  bool _readHistoryExhausted = false;
  bool _isLoadingHistory = false;

  CustomApiNotificationService? get _notificationService =>
      GetIt.I.isRegistered<CustomApiNotificationService>()
          ? GetIt.I<CustomApiNotificationService>()
          : null;

  NotificationsCache? get _notificationsCache =>
      GetIt.I.isRegistered<NotificationsCache>()
          ? GetIt.I<NotificationsCache>()
          : null;

  @override
  void initState() {
    super.initState();
    _hydrateFromCache();
    _refresh();
  }

  /// Cache-first hydrate: paint cached notifications immediately so
  /// the inbox isn't blank while the API call is in flight (or
  /// failing offline). The API refresh inside [_refresh] will overwrite
  /// once it returns.
  Future<void> _hydrateFromCache() async {
    final cache = _notificationsCache;
    if (cache == null) return;
    try {
      final cached = await cache.read();
      if (cached.isEmpty || !mounted) return;
      setState(() {
        if (_notifications.isEmpty) _notifications = cached;
        _isLoading = false;
      });
    } catch (_) {
      // Cache read failure is non-fatal.
    }
  }

  Future<List<AppNotificationItem>> _loadNotifications() {
    final customLoader = widget.notificationLoader;
    if (customLoader != null) {
      return customLoader();
    }

    final notificationService = _notificationService;
    if (notificationService == null) {
      return Future.value(const <AppNotificationItem>[]);
    }

    return notificationService.fetchUnreadNotifications();
  }

  Future<void> _refresh() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final notifications = await _loadNotifications();
      if (!mounted) {
        return;
      }
      // Persist to disk so the next cold-start / offline open shows
      // the latest known list immediately.
      unawaited(_notificationsCache?.write(notifications));
      setState(() {
        _notifications = notifications;
        _readHistory = const <AppNotificationItem>[];
        _readHistoryCursor = null;
        _readHistoryExhausted = false;
        _isLoading = false;
      });
      unawaited(_loadMoreHistory());
    } catch (error) {
      _appStatusService.reportError(
        error,
        fallbackMessage: 'Не удалось загрузить уведомления.',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _loadError = error;
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMoreHistory() async {
    final notificationService = _notificationService;
    // Тестовые сиды (widget.notificationLoader) живут без пагинации —
    // история для них выключена.
    if (notificationService == null ||
        widget.notificationLoader != null ||
        _isLoadingHistory ||
        _readHistoryExhausted) {
      return;
    }
    _isLoadingHistory = true;
    try {
      final page = await notificationService.fetchNotificationsPage(
        status: 'read',
        cursor: _readHistoryCursor,
      );
      if (!mounted) return;
      setState(() {
        _readHistory = [..._readHistory, ...page.items];
        _readHistoryCursor = page.nextCursor;
        _readHistoryExhausted = page.nextCursor == null;
      });
    } catch (_) {
      // История — вторична: тихо остановим подгрузку до следующего
      // pull-to-refresh, основной unread-поток уже на экране.
      if (mounted) {
        setState(() => _readHistoryExhausted = true);
      }
    } finally {
      _isLoadingHistory = false;
    }
  }

  Future<void> _markNotificationRead(AppNotificationItem item) async {
    final customHandler = widget.onMarkNotificationRead;
    if (customHandler != null) {
      await customHandler(item);
    } else {
      await _notificationService?.markNotificationRead(item.id);
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _notifications = _notifications
          .where((notification) => notification.id != item.id)
          .toList();
    });
  }

  Future<void> _openNotification(AppNotificationItem item) async {
    setState(() {
      _isMutating = true;
    });

    try {
      await _markNotificationRead(item);
      final customHandler = widget.onOpenNotification;
      if (customHandler != null) {
        customHandler(item);
        return;
      }

      _notificationService?.openNotificationPayload(item.payload);
    } catch (error) {
      _appStatusService.reportError(
        error,
        fallbackMessage: 'Не удалось открыть уведомление.',
      );
      _showMessage(
        describeUserFacingError(
          authService: _authService,
          error: error,
          fallbackMessage: _appStatusService.isOffline
              ? 'Нет соединения. Уведомление откроется, когда интернет вернётся.'
              : 'Не удалось открыть уведомление. Попробуйте ещё раз.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isMutating = false;
        });
      }
    }
  }

  Future<void> _markAllAsRead() async {
    if (_notifications.isEmpty) {
      return;
    }

    final notificationsToMark = List<AppNotificationItem>.from(_notifications);
    setState(() {
      _isMutating = true;
    });

    try {
      final customHandler = widget.onMarkAllNotificationsRead;
      if (customHandler != null) {
        await customHandler(notificationsToMark);
      } else {
        // Один bulk-запрос вместо N поштучных POST'ов (роут read-all).
        await _notificationService?.markAllNotificationsRead(
          fallbackIds:
              notificationsToMark.map((item) => item.id).toList(growable: false),
        );
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _notifications = const <AppNotificationItem>[];
        // Прочитанное не исчезает в пустоту — сразу видно в «Ранее».
        _readHistory = [
          ...notificationsToMark.map(
            (item) => AppNotificationItem(
              id: item.id,
              type: item.type,
              title: item.title,
              body: item.body,
              createdAt: item.createdAt,
              data: item.data,
              payload: item.payload,
              isRead: true,
            ),
          ),
          ..._readHistory,
        ];
      });
    } catch (error) {
      _appStatusService.reportError(
        error,
        fallbackMessage: 'Не удалось обновить уведомления.',
      );
      _showMessage(
        describeUserFacingError(
          authService: _authService,
          error: error,
          fallbackMessage: _appStatusService.isOffline
              ? 'Нет соединения. Отметьте уведомления прочитанными, когда интернет вернётся.'
              : 'Не удалось отметить уведомления прочитанными. Попробуйте ещё раз.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isMutating = false;
        });
      }
    }
  }

  bool _isWideLayout(BuildContext context) =>
      MediaQuery.of(context).size.width >= 1180;

  Map<String, int> _buildTypeSummary() {
    final summary = <String, int>{};
    for (final item in _notifications) {
      final type = _notificationSummaryType(item.type);
      summary.update(type, (count) => count + 1, ifAbsent: () => 1);
    }
    return summary;
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final treeProvider = context.watch<TreeProvider>();
    final isFriendsTree = treeProvider.selectedTreeKind == TreeKind.friends;
    final graphLabel = _graphLabelForInvitations(isFriendsTree);
    final eventLabel =
        isFriendsTree ? 'важные события круга' : 'важные семейные события';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Активность'),
        // User-reported: «когда заходишь через уведомление, кнопки
        // вернуться нет». Push-нотификация навигирует через
        // `router.go('/notifications')` — это REPLACES весь стек,
        // поэтому `automaticallyImplyLeading` не рисует стрелку
        // (Navigator.canPop = false) и юзер залипает на экране.
        // Явный leading с fallback на главную закрывает оба пути:
        // если стек есть (пришли через context.push из home) —
        // обычный pop; если стека нет (пришли через тап
        // уведомления) — улетаем на главный shell-route, где
        // снова видна нижняя навигация.
        leading: _BackToHomeLeading(),
        actions: [
          if (_notifications.isNotEmpty)
            IconButton(
              tooltip: 'Отметить всё прочитанным',
              onPressed: _isMutating ? null : _markAllAsRead,
              icon: const Icon(Icons.done_all),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
            onPressed: _isMutating ? null : _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _buildBody(
          isFriendsTree: isFriendsTree,
          graphLabel: graphLabel,
          eventLabel: eventLabel,
        ),
      ),
    );
  }

  Widget _buildBody({
    required bool isFriendsTree,
    required String graphLabel,
    required String eventLabel,
  }) {
    if (_isLoading) {
      return _NotificationsMessageState(
        icon: Icons.sync,
        title: 'Собираем активность',
        description:
            'Подтягиваем новые сообщения, приглашения и семейные события.',
        showProgress: true,
      );
    }

    // Only show the full error screen when we have NOTHING to fall
    // back on. If we already loaded notifications previously the
    // user prefers to see that list rather than a "couldn't reach
    // server" panel — the offline banner at the top of the app
    // already communicates the state.
    if (_loadError != null && _notifications.isEmpty) {
      return _NotificationsMessageState(
        icon: _appStatusService.isOffline
            ? Icons.cloud_off_outlined
            : Icons.error_outline,
        title: _appStatusService.isOffline
            ? 'Нет соединения'
            : 'Не удалось загрузить активность',
        description: _appStatusService.isOffline
            ? 'Уведомления подтянутся автоматически, когда интернет вернётся.'
            : 'Попробуйте обновить экран ещё раз. Новые сообщения и приглашения никуда не пропадут.',
        actionLabel: 'Повторить',
        onPressed: () {
          _appStatusService.requestRetry();
          unawaited(_refresh());
        },
      );
    }

    if (_notifications.isEmpty && _readHistory.isEmpty) {
      return _NotificationsMessageState(
        icon: Icons.notifications_none,
        title: 'Пока нет новых уведомлений',
        description:
            'Сюда придут приглашения в $graphLabel, новые сообщения и $eventLabel.',
        actionLabel: 'На главную',
        // Was Navigator.maybePop — silently a no-op when the
        // user landed here via push notification (empty stack).
        // context.go('/') always lands on the feed shell route
        // regardless of how we got here.
        onPressed: () => context.go('/'),
      );
    }

    final groupedNotifications = _buildGroupedNotifications(_notifications);
    final typeSummary = _buildTypeSummary();
    final sortedTypeSummary = typeSummary.entries.toList()
      ..sort((left, right) => right.value.compareTo(left.value));

    final historyBlockCount = _readHistory.isEmpty
        ? 0
        : _readHistory.length + 1; // заголовок «Ранее» + карточки
    // Маячок-подгрузчик — только в «живом» режиме: тестовые сиды
    // (notificationLoader) без пагинации, иначе вечный спиннер.
    final showHistoryLoader = !_readHistoryExhausted &&
        _readHistory.isNotEmpty &&
        widget.notificationLoader == null &&
        _notificationService != null;
    // Overview-карта имеет смысл только при непрочитанных: после
    // «прочитать всё» экран открывается сразу историей.
    final headerCount = _notifications.isEmpty ? 0 : 1;
    final listView = ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: groupedNotifications.length +
          headerCount +
          historyBlockCount +
          (showHistoryLoader ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        if (headerCount > 0 && index == 0) {
          return _NotificationsOverviewCard(
            totalCount: _notifications.length,
            isFriendsTree: isFriendsTree,
            graphLabel: _graphLabelForQueue(isFriendsTree),
            typeSummary: sortedTypeSummary,
          );
        }
        final groupIndex = index - headerCount;
        if (groupIndex < groupedNotifications.length) {
          final group = groupedNotifications[groupIndex];
          final item = group.first;
          return _NotificationCard(
            item: item,
            groupedCount: group.length,
            onTap: _isMutating ? null : () => _openNotification(item),
          );
        }
        final historyIndex = groupIndex - groupedNotifications.length;
        if (historyIndex == 0) {
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Ранее',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          );
        }
        final readItemIndex = historyIndex - 1;
        if (readItemIndex >= _readHistory.length) {
          // Маячок в хвосте: докатились — тянем следующую страницу.
          unawaited(_loadMoreHistory());
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final item = _readHistory[readItemIndex];
        return Opacity(
          opacity: 0.62,
          child: _NotificationCard(
            item: item,
            groupedCount: 1,
            // Прочитанное открывается без повторного markRead.
            onTap: _isMutating
                ? null
                : () =>
                    _notificationService?.openNotificationPayload(item.payload),
          ),
        );
      },
    );

    if (!_isWideLayout(context)) {
      return listView;
    }

    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: listView),
              const SizedBox(width: 16),
              SizedBox(
                width: 320,
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.45,
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Центр активности',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color:
                              theme.colorScheme.primary.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isFriendsTree
                                  ? Icons.diversity_3_outlined
                                  : Icons.account_tree_outlined,
                              size: 16,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              isFriendsTree
                                  ? 'Контекст круга друзей'
                                  : 'Контекст семейного дерева',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Здесь собираются новые сообщения, приглашения в $graphLabel и $eventLabel. На desktop проще быстро просматривать очередь уведомлений и сразу переходить в нужный раздел.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Всего новых: ${_notifications.length}',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildPanelStatChip(
                            theme,
                            icon: Icons.notifications_active_outlined,
                            label: '${_notifications.length} в очереди',
                          ),
                          _buildPanelStatChip(
                            theme,
                            icon: Icons.chat_bubble_outline,
                            label:
                                '${typeSummary['chat_message'] ?? typeSummary['chat'] ?? 0} чатов',
                          ),
                          _buildPanelStatChip(
                            theme,
                            icon: Icons.people_outline,
                            label:
                                '${typeSummary['relation_request'] ?? 0} запросов',
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_notifications.isNotEmpty)
                        FilledButton.icon(
                          onPressed: _isMutating ? null : _markAllAsRead,
                          icon: const Icon(Icons.done_all),
                          label: const Text('Отметить всё прочитанным'),
                        ),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: () => context.go('/chats'),
                        icon: const Icon(Icons.chat_bubble_outline),
                        label: const Text('Открыть чаты'),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: () => context.go('/tree'),
                        icon: const Icon(Icons.account_tree_outlined),
                        label: Text(
                          isFriendsTree ? 'Открыть круг' : 'Открыть дерево',
                        ),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: () => context.go('/identity/review'),
                        icon: const Icon(Icons.merge_type_outlined),
                        label: const Text('Проверить совпадения'),
                      ),
                      const SizedBox(height: 16),
                      ...sortedTypeSummary.map(
                        (entry) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            children: [
                              Icon(
                                _notificationIconForType(entry.key),
                                size: 18,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _notificationLabelForType(entry.key),
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                              Text(
                                '${entry.value}',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPanelStatChip(
    ThemeData theme, {
    required IconData icon,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  List<List<AppNotificationItem>> _buildGroupedNotifications(
    List<AppNotificationItem> notifications,
  ) {
    final grouped = <List<AppNotificationItem>>[];

    for (final item in notifications) {
      if (grouped.isEmpty) {
        grouped.add(<AppNotificationItem>[item]);
        continue;
      }

      final previousGroup = grouped.last;
      final previousItem = previousGroup.first;
      final sameType = previousItem.type == item.type;
      final sameTitle = previousItem.title == item.title;
      final closeInTime = _isSameDay(previousItem.createdAt, item.createdAt);
      final sameChat = previousItem.data['chatId'] == item.data['chatId'];

      if (sameType && sameTitle && closeInTime && (sameChat || sameType)) {
        previousGroup.add(item);
      } else {
        grouped.add(<AppNotificationItem>[item]);
      }
    }

    return grouped;
  }

  bool _isSameDay(DateTime? left, DateTime? right) {
    if (left == null || right == null) {
      return false;
    }

    return left.year == right.year &&
        left.month == right.month &&
        left.day == right.day;
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({
    required this.item,
    required this.groupedCount,
    required this.onTap,
  });

  final AppNotificationItem item;
  final int groupedCount;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeLabel = _formatTimeLabel(item.createdAt);

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  _notificationIconForType(item.type),
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          _notificationLabelForType(item.type),
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (groupedCount > 1) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.10,
                              ),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '$groupedCount',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      groupedCount > 1
                          ? '${item.title} · ещё ${groupedCount - 1}'
                          : item.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (item.body.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        _formatBody(item.body),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                    ],
                    if (timeLabel != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        timeLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String? _formatTimeLabel(DateTime? createdAt) {
    if (createdAt == null) {
      return null;
    }

    try {
      return DateFormat('d MMM, HH:mm', 'ru').format(createdAt.toLocal());
    } catch (_) {
      final localTime = createdAt.toLocal();
      final day = localTime.day.toString().padLeft(2, '0');
      final month = localTime.month.toString().padLeft(2, '0');
      final hour = localTime.hour.toString().padLeft(2, '0');
      final minute = localTime.minute.toString().padLeft(2, '0');
      return '$day.$month $hour:$minute';
    }
  }

  String _formatBody(String rawBody) {
    final normalized = rawBody.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) {
      return '';
    }
    if (normalized.length <= 140) {
      return normalized;
    }
    return '${normalized.substring(0, 137).trimRight()}...';
  }
}

class _NotificationsMessageState extends StatelessWidget {
  const _NotificationsMessageState({
    required this.icon,
    required this.title,
    required this.description,
    this.actionLabel,
    this.onPressed,
    this.showProgress = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final String? actionLabel;
  final VoidCallback? onPressed;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Center the state card so it doesn't pin against the left edge
    // on desktop / tablet viewports (where the previous left-aligned
    // ListView read as half a screen of empty space). Cap at 480 so
    // the title doesn't sprawl across a 1920px monitor.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 34, color: theme.colorScheme.primary),
                ),
                const SizedBox(height: 20),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  description,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                if (showProgress) ...[
                  const SizedBox(height: 24),
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                ],
                if (actionLabel != null && onPressed != null) ...[
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: onPressed,
                    child: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NotificationsOverviewCard extends StatelessWidget {
  const _NotificationsOverviewCard({
    required this.totalCount,
    required this.isFriendsTree,
    required this.graphLabel,
    required this.typeSummary,
  });

  final int totalCount;
  final bool isFriendsTree;
  final String graphLabel;
  final List<MapEntry<String, int>> typeSummary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSecondaryContainer
                  .withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              isFriendsTree
                  ? Icons.diversity_3_outlined
                  : Icons.notifications_active_outlined,
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Сейчас $totalCount ${_activityEventCountLabel(totalCount)}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Сообщения, приглашения и запросы для $graphLabel — всё в одном месте.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                    height: 1.4,
                  ),
                ),
                if (typeSummary.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: typeSummary
                        .take(3)
                        .map(
                          (entry) => Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.onSecondaryContainer
                                  .withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _notificationIconForType(entry.key),
                                  size: 16,
                                  color: theme.colorScheme.onSecondaryContainer,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${_notificationLabelForType(entry.key)} · ${entry.value}',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color:
                                        theme.colorScheme.onSecondaryContainer,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// AppBar leading that prefers Navigator.pop when there's a stack
/// (regular in-app push), and falls back to `context.go('/')` when
/// there isn't (push-notification deep-link replaced the whole
/// stack). Replaces the default `automaticallyImplyLeading`, which
/// silently disappears when the stack is empty — leaving the user
/// stranded on the screen with no way back to the feed.
class _BackToHomeLeading extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Назад',
      icon: const Icon(Icons.arrow_back_rounded),
      onPressed: () {
        final navigator = Navigator.of(context);
        if (navigator.canPop()) {
          navigator.pop();
          return;
        }
        // No stack to pop — we got here via a push-notification
        // deep-link. Go back to the home shell route so the user
        // sees the bottom nav again.
        context.go('/');
      },
    );
  }
}
