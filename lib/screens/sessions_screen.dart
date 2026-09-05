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
            'Сеанс «${session.deviceName ?? 'устройство'}» завершён',
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
            // Плотность: раньше каждая сессия была отдельной скруглённой
            // Material-карточкой (паддинг 16 со всех сторон, radius 16)
            // с 8dp зазором — «Заблокированные» до чанка 9b раздувались
            // тем же паттерном. Теперь это плоский список с hairline-
            // разделителем; шапка-подсказка остаётся единственной рамкой.
            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: sessions.length + 1,
              separatorBuilder: (_, index) {
                if (index == 0) return const SizedBox(height: 12);
                return Divider(
                  height: 1,
                  thickness: 0.7,
                  indent: 60,
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
                );
              },
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
    // Было: фиксированный SizedBox(64) сверху + иконка без Center —
    // на широких экранах прижималась к левому краю, а не к центру
    // сообщения об ошибке. Центрируем весь блок относительно
    // реальной высоты вьюпорта, а не магическим отступом.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.cloud_off_rounded,
                  size: 44,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 12),
                Text(
                  'Не удалось загрузить сессии',
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _refresh,
                  child: const Text('Повторить'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderHint(ThemeData theme, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
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
    final deviceName = session.deviceName ?? 'Безымянное устройство';
    final platformLine = _platformLabel(platform) +
        (session.appVersion != null ? ' • ${session.appVersion}' : '');

    // Плотность: было — своя скруглённая Material-карточка (паддинг 16
    // по кругу, radius 16) + две отдельных строки подписи ≈100dp на
    // сессию. Теперь плоская строка списка (как «Активные устройства»
    // в Telegram): платформа+версия и «Активен» — одной строкой.
    return ListTile(
      visualDensity: const VisualDensity(vertical: -1),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      onTap: onRename,
      leading: CircleAvatar(
        radius: 20,
        backgroundColor:
            theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
        child: Icon(
          _platformIcon(platform),
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              deviceName,
              style: theme.textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (session.isCurrent) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'этот',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        '$platformLine • Активен: $lastSeenLabel',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: onRevoke == null
          ? null
          : IconButton(
              tooltip: 'Завершить',
              icon: const Icon(Icons.logout_rounded),
              onPressed: () {
                onRevoke!();
              },
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
