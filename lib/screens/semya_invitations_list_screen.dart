import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../backend/models/semya_invitation.dart';
import '../providers/semya_invitations_controller.dart';
import 'semya_invite_screen.dart';

/// Ship FE3 (2026-05-26): семя invitations list screen. Shows all
/// sent invitations с status badges + per-row actions.
///
/// Actions:
///   • pending → «Скопировать ссылку», «Отозвать»
///   • terminal (accepted/revoked/expired) → read-only с status badge
///
/// CTA в app bar: «Пригласить» → SemyaInviteScreen.
class SemyaInvitationsListScreen extends StatefulWidget {
  const SemyaInvitationsListScreen({
    super.key,
    required this.semyaId,
    required this.canInvite,
  });

  final String semyaId;
  final bool canInvite;

  @override
  State<SemyaInvitationsListScreen> createState() =>
      _SemyaInvitationsListScreenState();
}

class _SemyaInvitationsListScreenState
    extends State<SemyaInvitationsListScreen> {
  late final SemyaInvitationsController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        SemyaInvitationsController(semyaId: widget.semyaId);
    WidgetsBinding.instance.addPostFrameCallback((_) => _controller.load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openInviteScreen() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SemyaInviteScreen(semyaId: widget.semyaId),
      ),
    );
    // Refresh после возврата — если invitation создалось, list updates.
    if (mounted) await _controller.refresh();
  }

  Future<void> _confirmRevoke(SemyaInvitation invitation) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Отозвать приглашение?'),
          content: Text(
            'Приглашение для ${invitation.recipientLabel} больше нельзя будет использовать.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton.tonal(
              key: const Key('semya-invitation-revoke-confirm'),
              style: FilledButton.styleFrom(
                foregroundColor: Theme.of(dialogContext).colorScheme.error,
                backgroundColor:
                    Theme.of(dialogContext).colorScheme.errorContainer,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Отозвать'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    final ok = await _controller.revoke(invitation.id);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Приглашение отозвано')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_controller.errorMessage ?? 'Не удалось отозвать'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  Future<void> _copyLink(SemyaInvitation invitation) async {
    final link =
        'https://rodnya-tree.ru/invite/${invitation.token}';
    await Clipboard.setData(ClipboardData(text: link));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ссылка скопирована')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<SemyaInvitationsController>.value(
      value: _controller,
      child: Consumer<SemyaInvitationsController>(
        builder: (context, controller, _) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('Приглашения'),
              actions: [
                if (widget.canInvite)
                  IconButton(
                    key: const Key('semya-invitations-add'),
                    tooltip: 'Пригласить',
                    icon: const Icon(Icons.person_add_alt_outlined),
                    onPressed: _openInviteScreen,
                  ),
              ],
            ),
            body: _buildBody(controller),
          );
        },
      ),
    );
  }

  Widget _buildBody(SemyaInvitationsController controller) {
    if (controller.isLoading && !controller.hasLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.invitations.isEmpty) {
      return _EmptyState(
        canInvite: widget.canInvite,
        onInvite: _openInviteScreen,
      );
    }
    // Плотность (чанк 25): группировка «Ожидают» / «История» — Telegram-
    // стиль секций вместо одного плоского списка, где ожидающие приглашения
    // тонут среди принятых/отозванных. Чисто отображение — порядок и
    // содержимое controller.invitations не меняются, только группировка
    // при рендере.
    final pending = controller.invitations.where((i) => i.isPending).toList();
    final history = controller.invitations.where((i) => i.isTerminal).toList();
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          if (pending.isNotEmpty) ...[
            const _GroupHeader(label: 'Ожидают'),
            for (final inv in pending)
              _InvitationTile(
                invitation: inv,
                onRevoke: () => _confirmRevoke(inv),
                onCopyLink: () => _copyLink(inv),
              ),
          ],
          if (history.isNotEmpty) ...[
            const _GroupHeader(label: 'История'),
            for (final inv in history)
              _InvitationTile(
                invitation: inv,
                onRevoke: null,
                onCopyLink: null,
              ),
          ],
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.canInvite, required this.onInvite});

  final bool canInvite;
  final VoidCallback onInvite;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.mail_outline_rounded,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 10),
            Text(
              'Пока нет приглашений',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              canInvite
                  ? 'Отправьте первое приглашение родственнику.'
                  : 'Когда владелец отправит приглашения — вы увидите их здесь.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (canInvite) ...[
              const SizedBox(height: 16),
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  key: const Key('semya-invitations-empty-cta'),
                  onPressed: onInvite,
                  icon: const Icon(Icons.person_add_alt_outlined),
                  label: const Text('Пригласить'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Плотность (чанк 25): секционный заголовок групп «Ожидают»/«История»
/// — 28dp, как в остальных плотных списках (уведомления, чат).
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: SizedBox(
        height: 16,
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}

/// Плотность (чанк 25): строка списка вместо ListTile — было
/// title+subtitle+trailing с дефолтными паддингами ListTile (~72dp);
/// стало кастомный Row 56dp: круглая иконка-статус 40dp вместо текстовой
/// плашки, имя+время в одной строке (16sp/12sp), статус+роль — вторая
/// строка 13sp, действия (копировать/отозвать) — тач-цели 44dp.
class _InvitationTile extends StatelessWidget {
  const _InvitationTile({
    required this.invitation,
    required this.onRevoke,
    required this.onCopyLink,
  });

  final SemyaInvitation invitation;
  final VoidCallback? onRevoke;
  final VoidCallback? onCopyLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: Key('semya-invitation-tile-${invitation.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        children: [
          _StatusAvatar(status: invitation.status),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        invitation.recipientLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatShortDate(invitation.createdAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      invitation.status.displayLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _statusForeground(theme, invitation.status),
                      ),
                    ),
                    Text(
                      ' · ${invitation.role.displayLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (onCopyLink != null)
            SizedBox(
              width: 44,
              height: 44,
              child: IconButton(
                key: Key('semya-invitation-copy-${invitation.id}'),
                tooltip: 'Скопировать ссылку',
                icon: const Icon(Icons.copy_rounded, size: 20),
                onPressed: onCopyLink,
              ),
            ),
          if (onRevoke != null)
            SizedBox(
              width: 44,
              height: 44,
              child: IconButton(
                key: Key('semya-invitation-revoke-${invitation.id}'),
                tooltip: 'Отозвать',
                icon: Icon(
                  Icons.cancel_outlined,
                  size: 20,
                  color: theme.colorScheme.error,
                ),
                onPressed: onRevoke,
              ),
            ),
        ],
      ),
    );
  }

  static String _formatShortDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    try {
      return DateFormat('d MMM', 'ru').format(dt.toLocal());
    } catch (_) {
      return '${dt.day}.${dt.month.toString().padLeft(2, '0')}';
    }
  }
}

/// Плотность (чанк 25): круглая иконка-статус 40dp вместо текстовой
/// плашки — цвет несёт смысл (ожидает/принято/отклонено), а сам статус
/// остаётся читаемым текстом в строке ниже (13sp).
class _StatusAvatar extends StatelessWidget {
  const _StatusAvatar({required this.status});

  final SemyaInvitationStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: _statusBackground(theme, status),
        shape: BoxShape.circle,
      ),
      child: Icon(
        _statusIcon(status),
        size: 20,
        color: _statusForeground(theme, status),
      ),
    );
  }
}

Color _statusBackground(ThemeData theme, SemyaInvitationStatus status) {
  switch (status) {
    case SemyaInvitationStatus.pending:
      return theme.colorScheme.primary.withValues(alpha: 0.14);
    case SemyaInvitationStatus.accepted:
      return Colors.green.withValues(alpha: 0.14);
    case SemyaInvitationStatus.revoked:
      return theme.colorScheme.errorContainer.withValues(alpha: 0.5);
    case SemyaInvitationStatus.expired:
    case SemyaInvitationStatus.unknown:
      return theme.colorScheme.surfaceContainerHighest;
  }
}

Color _statusForeground(ThemeData theme, SemyaInvitationStatus status) {
  switch (status) {
    case SemyaInvitationStatus.pending:
      return theme.colorScheme.primary;
    case SemyaInvitationStatus.accepted:
      return Colors.green.shade800;
    case SemyaInvitationStatus.revoked:
      return theme.colorScheme.error;
    case SemyaInvitationStatus.expired:
    case SemyaInvitationStatus.unknown:
      return theme.colorScheme.onSurfaceVariant;
  }
}

IconData _statusIcon(SemyaInvitationStatus status) {
  switch (status) {
    case SemyaInvitationStatus.pending:
      return Icons.hourglass_top_rounded;
    case SemyaInvitationStatus.accepted:
      return Icons.check_rounded;
    case SemyaInvitationStatus.revoked:
      return Icons.close_rounded;
    case SemyaInvitationStatus.expired:
    case SemyaInvitationStatus.unknown:
      return Icons.schedule_rounded;
  }
}
