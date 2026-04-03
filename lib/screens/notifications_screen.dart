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
  });

  final Future<List<AppNotificationItem>> Function()? notificationLoader;
  final ValueChanged<AppNotificationItem>? onOpenNotification;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  late Future<List<AppNotificationItem>> _notificationsFuture;

  CustomApiNotificationService? get _notificationService =>
      GetIt.I.isRegistered<CustomApiNotificationService>()
          ? GetIt.I<CustomApiNotificationService>()
          : null;

  @override
  void initState() {
    super.initState();
    _notificationsFuture = _loadNotifications();
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
      _notificationsFuture = _loadNotifications();
    });
    await _notificationsFuture;
  }

  void _openNotification(AppNotificationItem item) {
    final customHandler = widget.onOpenNotification;
    if (customHandler != null) {
      customHandler(item);
      return;
    }

    _notificationService?.openNotificationPayload(item.payload);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Активность'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
            onPressed: _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<AppNotificationItem>>(
          future: _notificationsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return _NotificationsMessageState(
                icon: Icons.error_outline,
                title: 'Не удалось загрузить активность',
                description:
                    'Попробуйте обновить экран ещё раз. Новые сообщения и приглашения никуда не пропадут.',
                actionLabel: 'Повторить',
                onPressed: _refresh,
              );
            }

            final notifications =
                snapshot.data ?? const <AppNotificationItem>[];
            if (notifications.isEmpty) {
              return _NotificationsMessageState(
                icon: Icons.notifications_none,
                title: 'Пока нет новых уведомлений',
                description:
                    'Сюда придут приглашения в дерево, новые сообщения и важные семейные события.',
                actionLabel: 'На главную',
                onPressed: () => Navigator.of(context).maybePop(),
              );
            }

            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              itemCount: notifications.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final item = notifications[index];
                return _NotificationCard(
                  item: item,
                  onTap: () => _openNotification(item),
                );
              },
            );
          },
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
  final VoidCallback onTap;

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
