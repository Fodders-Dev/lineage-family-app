import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/app_notification_item.dart';
import '../models/family_tree.dart';
import '../providers/tree_provider.dart';
import '../services/custom_api_notification_service.dart';

IconData _notificationIconForType(String type) {
  switch (type) {
    case 'chat':
    case 'chat_message':
      return Icons.chat_bubble_outline;
    case 'tree_invitation':
      return Icons.account_tree_outlined;
    case 'birthday':
      return Icons.cake_outlined;
    case 'relation_request':
      return Icons.people_outline;
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
    case 'birthday':
      return 'Семейное событие';
    case 'relation_request':
      return 'Запрос связи';
    default:
      return 'Уведомление';
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
  bool _isLoading = true;
  bool _isMutating = false;
  Object? _loadError;
  List<AppNotificationItem> _notifications = const <AppNotificationItem>[];

  CustomApiNotificationService? get _notificationService =>
      GetIt.I.isRegistered<CustomApiNotificationService>()
          ? GetIt.I<CustomApiNotificationService>()
          : null;

  @override
  void initState() {
    super.initState();
    _refresh();
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
      setState(() {
        _notifications = notifications;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadError = error;
        _isLoading = false;
      });
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
    } finally {
      if (mounted) {
        setState(() {
          _isMutating = false;
        });
      }
    }

    final customHandler = widget.onOpenNotification;
    if (customHandler != null) {
      customHandler(item);
      return;
    }

    _notificationService?.openNotificationPayload(item.payload);
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
        await _notificationService?.markNotificationsRead(
          notificationsToMark.map((item) => item.id),
        );
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _notifications = const <AppNotificationItem>[];
      });
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
      summary.update(item.type, (count) => count + 1, ifAbsent: () => 1);
    }
    return summary;
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
        actions: [
          if (_notifications.isNotEmpty)
            IconButton(
              tooltip: 'Прочитать всё',
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
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null) {
      return _NotificationsMessageState(
        icon: Icons.error_outline,
        title: 'Не удалось загрузить активность',
        description:
            'Попробуйте обновить экран ещё раз. Новые сообщения и приглашения никуда не пропадут.',
        actionLabel: 'Повторить',
        onPressed: _refresh,
      );
    }

    if (_notifications.isEmpty) {
      return _NotificationsMessageState(
        icon: Icons.notifications_none,
        title: 'Пока нет новых уведомлений',
        description:
            'Сюда придут приглашения в $graphLabel, новые сообщения и $eventLabel.',
        actionLabel: 'На главную',
        onPressed: () => Navigator.of(context).maybePop(),
      );
    }

    final groupedNotifications = _buildGroupedNotifications(_notifications);
    final typeSummary = _buildTypeSummary();
    final sortedTypeSummary = typeSummary.entries.toList()
      ..sort((left, right) => right.value.compareTo(left.value));

    final listView = ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: groupedNotifications.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _NotificationsOverviewCard(
            totalCount: _notifications.length,
            isFriendsTree: isFriendsTree,
            graphLabel: _graphLabelForQueue(isFriendsTree),
            typeSummary: sortedTypeSummary,
          );
        }
        final group = groupedNotifications[index - 1];
        final item = group.first;
        return _NotificationCard(
          item: item,
          groupedCount: group.length,
          onTap: _isMutating ? null : () => _openNotification(item),
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
                          label: const Text('Прочитать всё'),
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
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  _notificationIconForType(item.type),
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 14),
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
    required this.actionLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String description;
  final String actionLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 48),
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
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          description,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: onPressed,
            child: Text(actionLabel),
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
                  'Очередь активности собирается для $graphLabel. Просмотрите сообщения, приглашения и запросы в одном месте.',
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
