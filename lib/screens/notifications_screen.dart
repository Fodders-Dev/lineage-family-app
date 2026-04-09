import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/intl.dart';

import '../models/app_notification_item.dart';
import '../services/custom_api_notification_service.dart';

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

  @override
  Widget build(BuildContext context) {
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
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
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
            'Сюда придут приглашения в дерево, новые сообщения и важные семейные события.',
        actionLabel: 'На главную',
        onPressed: () => Navigator.of(context).maybePop(),
      );
    }

    final listView = ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: _notifications.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final item = _notifications[index];
        return _NotificationCard(
          item: item,
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
                      Text(
                        'Здесь собираются новые сообщения, приглашения в дерево и важные обновления семьи. На desktop проще быстро просматривать очередь уведомлений и сразу переходить в нужный раздел.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.4,
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
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({
    required this.item,
    required this.onTap,
  });

  final AppNotificationItem item;
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
                  _iconForType(item.type),
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _labelForType(item.type),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (item.body.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        item.body,
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

  static IconData _iconForType(String type) {
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

  static String _labelForType(String type) {
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
