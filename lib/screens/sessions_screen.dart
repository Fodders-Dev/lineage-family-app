import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../services/auth_sessions_service.dart';
import '../services/custom_api_auth_service.dart';

class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  late final AuthSessionsService _service = GetIt.I<AuthSessionsService>();
  Future<AuthSessionsListResult>? _future;

  @override
  void initState() {
    super.initState();
    _future = _service.listSessions();
  }

  Future<void> _refresh() async {
    final next = _service.listSessions();
    setState(() => _future = next);
    await next;
  }

  Future<void> _revoke(AuthSessionSummary session) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Завершить сеанс?'),
        content: Text(
          'Это устройство (${session.deviceName ?? 'без названия'}) '
          'выйдет из аккаунта и больше не сможет получать данные до '
          'повторного входа.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Завершить'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await _service.revokeSession(session.sessionPublicId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Сеанс «${session.deviceName ?? 'Неизвестное устройство'}» завершён',
          ),
        ),
      );
      await _refresh();
    } on CustomApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось завершить сеанс: $error')),
      );
    }
  }

  Future<void> _rename(AuthSessionSummary session) async {
    final controller = TextEditingController(text: session.deviceName ?? '');
    final newName = await showDialog<String?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Название устройства'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(
            hintText: 'Например, iPhone Иван',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(null),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext)
                .pop(controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (newName == null || newName == (session.deviceName ?? '')) return;

    try {
      await _service.renameSession(
        sessionPublicId: session.sessionPublicId,
        deviceName: newName,
      );
      await _refresh();
    } on CustomApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Активные сеансы'),
        actions: [
          IconButton(
            tooltip: 'Войти на другое устройство',
            icon: const Icon(Icons.qr_code_scanner_rounded),
            onPressed: () => context.push('/profile/sessions/scan'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<AuthSessionsListResult>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return _buildError(theme, snapshot.error);
            }
            final result = snapshot.data;
            if (result == null) {
              return const SizedBox.shrink();
            }
            final sessions = result.sessions;
            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: sessions.length + 1,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _buildHeaderHint(theme, sessions.length);
                }
                final session = sessions[index - 1];
                return _SessionTile(
                  session: session,
                  onRename: () => _rename(session),
                  onRevoke: session.isCurrent ? null : () => _revoke(session),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildError(ThemeData theme, Object? error) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 64),
        Icon(
          Icons.cloud_off_rounded,
          size: 48,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            'Не удалось загрузить сессии',
            style: theme.textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            '$error',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Center(
          child: FilledButton(
            onPressed: _refresh,
            child: const Text('Повторить'),
          ),
        ),
      ],
    );
  }

  Widget _buildHeaderHint(ThemeData theme, int count) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            Icons.devices_rounded,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              count <= 1
                  ? 'Аккаунт открыт только на этом устройстве.'
                  : 'Аккаунт открыт на $count устройствах. Завершите чужие сеансы, если потеряли устройство.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.onRename,
    required this.onRevoke,
  });

  final AuthSessionSummary session;
  final Future<void> Function() onRename;
  final Future<void> Function()? onRevoke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lastSeen = session.lastSeenAt;
    final lastSeenLabel = lastSeen == null
        ? '—'
        : DateFormat('d MMM, HH:mm', 'ru').format(lastSeen);
    final platform = session.platform ?? 'unknown';
    final deviceName = session.deviceName ?? 'Неизвестное устройство';

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onRename,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor:
                    theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
                child: Icon(
                  _platformIcon(platform),
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            deviceName,
                            style: theme.textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (session.isCurrent)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'это устройство',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _platformAndOsLabel(platform, session.osVersion) +
                          (session.appVersion != null
                              ? ' • Родня ${session.appVersion}'
                              : ''),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Активен: $lastSeenLabel',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (onRevoke != null)
                IconButton(
                  tooltip: 'Завершить',
                  icon: const Icon(Icons.logout_rounded),
                  onPressed: () {
                    onRevoke!();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _platformIcon(String platform) {
    switch (platform) {
      case 'ios':
        return Icons.phone_iphone_rounded;
      case 'android':
        return Icons.phone_android_rounded;
      case 'macos':
        return Icons.laptop_mac_rounded;
      case 'windows':
        return Icons.laptop_windows_rounded;
      case 'linux':
        return Icons.laptop_chromebook_rounded;
      case 'web':
        return Icons.public_rounded;
      default:
        return Icons.devices_other_rounded;
    }
  }

  /// "Android 14", "iOS 17.5", "Web" (no OS version — see osVersion doc on
  /// DeviceDescriptor for why web is always null).
  String _platformAndOsLabel(String platform, String? osVersion) {
    final label = _platformLabel(platform);
    if (osVersion == null || osVersion.isEmpty) return label;
    return '$label $osVersion';
  }

  String _platformLabel(String platform) {
    switch (platform) {
      case 'ios':
        return 'iOS';
      case 'android':
        return 'Android';
      case 'macos':
        return 'macOS';
      case 'windows':
        return 'Windows';
      case 'linux':
        return 'Linux';
      case 'web':
        return 'Web';
      default:
        return 'Устройство';
    }
  }
}
