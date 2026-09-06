import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../backend/models/semya.dart';
import '../utils/photo_url.dart';
import '../providers/semya_details_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/browse_tokens_list_section.dart';
import '../widgets/deleted_persons_section.dart';
import '../widgets/hidden_persons_section.dart';
import '../widgets/membership_action_menu.dart';
import '../widgets/share_browse_token_modal.dart';
import 'semya_invitations_list_screen.dart';

/// Ship FE2 (2026-05-26): семя details screen.
///
/// Surfaces:
///   * Header — имя семья + member count + caller's role chip
///   * Tree access tile («Открыть дерево») — placeholder в FE2, wired
///     к active tree navigation в FE4+
///   * Members section — list (avatar placeholder + name + role chip)
///   * Owner-only «Управление семьёй» tile — disabled placeholder, FE3
///     enable's rename/delete/role flows
///   * Invitations tile — disabled placeholder, FE3 surface
///
/// Loading state: full-screen progress center.
/// Error state: centered message + retry button.
/// Read-only at этой stage (mutation actions deferred к FE3/FE8).
class SemyaDetailsScreen extends StatefulWidget {
  const SemyaDetailsScreen({
    super.key,
    required this.semyaId,
    this.scrollToHidden = false,
  });

  final String semyaId;

  /// Ship FE7b (2026-05-26): scroll-to-hidden-section flag. Set когда
  /// caller arrives via settings tile «Скрытые родственники» — после
  /// первого build scrolls so HiddenPersonsSection visible immediately.
  /// Other entry points (семя switcher, browse list) leave default false.
  final bool scrollToHidden;

  @override
  State<SemyaDetailsScreen> createState() => _SemyaDetailsScreenState();
}

class _SemyaDetailsScreenState extends State<SemyaDetailsScreen> {
  late final SemyaDetailsController _controller;
  // Ship FE7b: GlobalKey на HiddenPersonsSection container — после
  // controller load completes attempts Scrollable.ensureVisible если
  // flag set. Fires once per screen instance.
  final GlobalKey _hiddenSectionKey = GlobalKey();
  bool _scrolledToHidden = false;

  @override
  void initState() {
    super.initState();
    _controller = SemyaDetailsController(semyaId: widget.semyaId);
    WidgetsBinding.instance.addPostFrameCallback((_) => _controller.load());
  }

  void _maybeScrollToHidden() {
    if (!widget.scrollToHidden || _scrolledToHidden) return;
    final ctx = _hiddenSectionKey.currentContext;
    if (ctx == null) return;
    _scrolledToHidden = true;
    // Defer один tick — let RefreshIndicator + ListView mount fully.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<SemyaDetailsController>.value(
      value: _controller,
      child: Consumer<SemyaDetailsController>(
        builder: (context, controller, _) {
          return Scaffold(
            appBar: AppBar(
              title: Text(
                controller.details?.semya.name ?? 'Семья',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            body: _buildBody(context, controller),
          );
        },
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    SemyaDetailsController controller,
  ) {
    if (controller.isLoading && !controller.hasLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    final details = controller.details;
    if (details == null) {
      return _ErrorState(
        message: controller.errorMessage ?? 'Семья не найдена',
        onRetry: controller.refresh,
      );
    }
    // Ship FE8 (2026-05-27): surface mutation errors через snackbar
    // — runs once per error message (controller.clearMutationError
    // resets state). post-frame чтобы избежать setState-during-build.
    final mutationError = controller.mutationErrorMessage;
    if (mutationError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mutationError)),
        );
        controller.clearMutationError();
      });
    }
    // Ship FE7b: after first render с loaded details, scroll к hidden
    // section если flag passed. Called every build but guarded by
    // _scrolledToHidden bool — fires exactly once.
    if (widget.scrollToHidden) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maybeScrollToHidden();
      });
    }
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          _HeaderSection(
            details: details,
            memberCount: controller.memberships.length,
          ),
          const SizedBox(height: 8),
          _TreeAccessTile(treeId: details.semya.treeId),
          const _SectionHeader('Участники'),
          if (controller.memberships.isEmpty)
            Padding(
              key: const Key('semya-members-empty'),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Пока вы здесь одни.',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Пригласите близких — вести семейное дерево вместе '
                    'теплее и проще.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.35,
                        ),
                  ),
                  if (details.canInvite) ...[
                    const SizedBox(height: 10),
                    FilledButton.tonalIcon(
                      key: const Key('semya-members-empty-invite'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SemyaInvitationsListScreen(
                            semyaId: details.semya.id,
                            canInvite: details.canInvite,
                          ),
                        ),
                      ),
                      icon:
                          const Icon(Icons.person_add_alt_1_outlined, size: 18),
                      label: const Text('Пригласить'),
                    ),
                  ],
                ],
              ),
            )
          else
            ..._buildMemberRows(
              controller,
              controller.memberships,
              details.callerRole,
            ),
          const _SectionHeader('Управление'),
          _OwnerOnlyTile(
            icon: Icons.settings_outlined,
            label: 'Управление семьёй',
            subtitle: 'Переименовать, удалить, изменить роли участников.',
            visibleAsOwner: details.callerRole == SemyaRole.owner,
            placeholder: 'Появится в следующем обновлении',
          ),
          // Ship FE3 (2026-05-26): «Приглашения» tile активен для всех
          // member'ов (viewer+) — даже non-inviter может see existing
          // invitations и понять контекст. Кнопка «Пригласить» в самом
          // списке gated by canInvite.
          ListTile(
            key: const Key('semya-details-invitations'),
            leading: const Icon(Icons.mail_outline_rounded),
            title: const Text('Приглашения'),
            subtitle: Text(
              details.canInvite
                  ? 'Отправить или отозвать приглашения.'
                  : 'Список приглашений семьи.',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SemyaInvitationsListScreen(
                    semyaId: details.semya.id,
                    canInvite: details.canInvite,
                  ),
                ),
              );
            },
          ),
          // Ship FE6a (2026-05-26): «Поделиться деревом» tile —
          // generates browse-token capability link для read-only
          // viewing вне семя. Owner либо editor-с-grant only
          // (backend Ship 7 enforces); UI gate matches canInvite
          // since invite-grant required для editor case.
          if (details.canInvite)
            ListTile(
              key: const Key('semya-details-share-browse'),
              leading: const Icon(Icons.share_outlined),
              title: const Text('Поделиться деревом'),
              subtitle: const Text(
                'Создать ссылку для просмотра без регистрации.',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showShareBrowseTokenModal(
                context,
                semyaId: details.semya.id,
                semyaName: details.semya.name,
              ),
            ),
          // Ship FE6b (2026-05-26): «Активные ссылки» management section.
          // Same canInvite gate как share tile (UX consistency — если
          // can create, can also see/manage). Backend allows viewer+
          // listing, но showing list к viewers без revoke power adds
          // noise. Per-row revoke gated separately (owner OR creator).
          if (details.canInvite)
            BrowseTokensListSection(
              key: const Key('semya-details-browse-tokens-section'),
              semyaId: details.semya.id,
              callerRole: details.callerRole,
              currentUserId: _resolveCurrentUserId(),
            ),
          // Ship FE7 (2026-05-26): «Скрытые от меня» management section.
          // Per-user filter — каждый член семьи может скрыть кого
          // угодно из своего view (включая viewer). Backend allows
          // viewer+, поэтому секция render'ится для всех ролей.
          KeyedSubtree(
            key: _hiddenSectionKey,
            child: HiddenPersonsSection(
              key: const Key('semya-details-hidden-persons-section'),
              semyaId: details.semya.id,
              treeId: details.semya.treeId,
            ),
          ),
          // Ship Q4a frontend (2026-05-28, Ship 31b): per-семя
          // «Удалённые родственники» entry. Self-hiding tile — appears
          // только когда семья has soft-deleted persons. Tap → dedicated
          // SemyaDeletedPersonsScreen (restore / purge). Mirror global
          // Корзина (Settings, Ship 31) scoped к этой семье.
          DeletedPersonsSection(
            semyaId: details.semya.id,
            semyaName: details.semya.name,
          ),
          // Ship FE8 (2026-05-27): «Покинуть семью» tile внизу
          // секции «Управление». Доступно всем ролям (backend allows
          // self-leave for viewer+). Disabled с tooltip когда caller
          // is last active owner — backstops backend's
          // LAST_OWNER_REMOVE_FORBIDDEN invariant.
          _buildSelfLeaveTile(context, controller, details),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  List<Widget> _buildMemberRows(
    SemyaDetailsController controller,
    List<SemyaMembership> members,
    SemyaRole callerRole,
  ) {
    final currentUserId = _resolveCurrentUserId();
    return members
        .map((m) => _MemberRow(
              membership: m,
              callerRole: callerRole,
              currentUserId: currentUserId,
              controller: controller,
            ))
        .toList(growable: false);
  }

  /// Resolve caller's user id via AuthServiceInterface — used by
  /// browse-tokens revoke gate (creator-or-owner permission). Returns
  /// null если AuthService не registered (test scenarios без full
  /// GetIt bootstrap). Section degrades gracefully — revoke button
  /// hidden для non-owners когда userId unknown.
  String? _resolveCurrentUserId() {
    if (!GetIt.I.isRegistered<AuthServiceInterface>()) return null;
    return GetIt.I<AuthServiceInterface>().currentUserId;
  }

  /// Ship FE8 (2026-05-27): self-leave tile. Visible всегда (если
  /// caller membership resolvable). Enabled когда caller НЕ last
  /// active owner — backstops LAST_OWNER_REMOVE_FORBIDDEN.
  /// Confirmation dialog с destructive copy. On success pops screen.
  Widget _buildSelfLeaveTile(
    BuildContext context,
    SemyaDetailsController controller,
    SemyaDetails details,
  ) {
    final currentUserId = _resolveCurrentUserId();
    if (currentUserId == null) return const SizedBox.shrink();
    final isLastOwner = details.callerRole == SemyaRole.owner &&
        controller.activeOwnerCount <= 1;
    final isPending = controller.isPending(currentUserId);
    final theme = Theme.of(context);
    return ListTile(
      key: const Key('semya-details-self-leave'),
      enabled: !isLastOwner && !isPending,
      leading: Icon(
        Icons.logout_rounded,
        color: isLastOwner ? theme.disabledColor : theme.colorScheme.error,
      ),
      title: Text(
        'Покинуть семью',
        style: TextStyle(
          color: isLastOwner ? null : theme.colorScheme.error,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        isLastOwner
            ? 'Сначала передайте право владения другому участнику'
            : 'Вы перестанете видеть и редактировать это дерево',
      ),
      trailing: isPending
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onTap: isLastOwner || isPending
          ? null
          : () =>
              _confirmAndSelfLeave(context, controller, details, currentUserId),
    );
  }

  Future<void> _confirmAndSelfLeave(
    BuildContext context,
    SemyaDetailsController controller,
    SemyaDetails details,
    String currentUserId,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('Выйти из семьи ${details.semya.name}?'),
        content: const Text(
          'Вы больше не сможете смотреть и редактировать дерево '
          'этой семьи. Действие нельзя отменить.',
        ),
        actions: [
          TextButton(
            key: const Key('self-leave-cancel'),
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            key: const Key('self-leave-confirm'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final result = await controller.removeMember(userId: currentUserId);
    if (!context.mounted) return;
    if (result != null && result.wasSelfLeave) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Вы покинули семью ${details.semya.name}')),
      );
      Navigator.of(context).maybePop();
    }
  }
}

class _HeaderSection extends StatelessWidget {
  const _HeaderSection({
    required this.details,
    required this.memberCount,
  });

  final SemyaDetails details;
  final int memberCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            details.semya.name,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          if ((details.semya.description ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              details.semya.description!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _Chip(
                icon: Icons.group_outlined,
                label: '$memberCount '
                    '${_memberCountLabel(memberCount)}',
              ),
              _RoleChip(role: details.callerRole),
            ],
          ),
        ],
      ),
    );
  }

  static String _memberCountLabel(int n) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    if (mod10 == 1 && mod100 != 11) return 'участник';
    if ([2, 3, 4].contains(mod10) && ![12, 13, 14].contains(mod100)) {
      return 'участника';
    }
    return 'участников';
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.role});

  final SemyaRole role;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (isDark ? RodnyaDesignTokens.dark : RodnyaDesignTokens.light);
    final Color background;
    final Color foreground;
    switch (role) {
      case SemyaRole.owner:
        background = theme.colorScheme.primary.withValues(alpha: 0.16);
        foreground = theme.colorScheme.primary;
        break;
      case SemyaRole.editor:
        background = tokens.warm.withValues(alpha: 0.18);
        foreground = tokens.warm;
        break;
      case SemyaRole.viewer:
      case SemyaRole.unknown:
        background = theme.colorScheme.surfaceContainerHighest;
        foreground = theme.colorScheme.onSurfaceVariant;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        role.displayLabel,
        style: theme.textTheme.labelMedium?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Плотность (чанк 25): секционный заголовок — 28dp вместо ~44dp
/// (titleSmall с паддингом 16/8). Тот же паттерн, что и группы в
/// списке приглашений (semya_invitations_list_screen.dart).
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: SizedBox(
        height: 16,
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}

class _TreeAccessTile extends StatelessWidget {
  const _TreeAccessTile({required this.treeId});

  final String treeId;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: const Key('semya-details-open-tree'),
      leading: const Icon(Icons.account_tree_rounded),
      title: const Text('Открыть дерево'),
      subtitle: Text('id: $treeId'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).maybePop(),
    );
  }
}

class _OwnerOnlyTile extends StatelessWidget {
  const _OwnerOnlyTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.visibleAsOwner,
    required this.placeholder,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final bool visibleAsOwner;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEnabled = visibleAsOwner;
    return ListTile(
      enabled: false, // FE2 — disabled placeholder for both states.
      leading: Icon(
        icon,
        color: isEnabled
            ? theme.colorScheme.onSurfaceVariant
            : theme.disabledColor,
      ),
      title: Text(label),
      subtitle: Text(isEnabled ? placeholder : subtitle),
      trailing: const Icon(Icons.lock_outline_rounded, size: 16),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.membership,
    required this.callerRole,
    required this.currentUserId,
    required this.controller,
  });

  final SemyaMembership membership;
  final SemyaRole callerRole;
  final String? currentUserId;
  final SemyaDetailsController controller;

  bool get _isSelf =>
      currentUserId != null && currentUserId == membership.userId;

  /// Ship FE8 (2026-05-27): menu visible только для owner caller
  /// AND target ≠ self. Self-row uses dedicated «Покинуть семью»
  /// tile внизу секции «Управление».
  bool get _showMenu => callerRole == SemyaRole.owner && !_isSelf;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initials = _initialsOf(membership.displayLabel);
    // Плотность (чанк 25): было ListTile (title+subtitle+leading+trailing
    // дефолтные паддинги, ~76dp); стало кастомный Row 56dp — аватар 40dp,
    // имя 16sp + подпись «дата вступления» 13sp, роль+меню справа
    // (меню — тач-цель 44dp).
    return Container(
      key: ValueKey('semya-member-row-${membership.userId}'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
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
          _buildAvatar(theme, initials),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        membership.displayLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontSize: 16,
                          fontWeight:
                              _isSelf ? FontWeight.w700 : FontWeight.w600,
                        ),
                      ),
                    ),
                    if (_isSelf)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          '(это я)',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _formatJoinedAt(membership.joinedAt),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 13,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _RoleChip(role: membership.role),
          if (_showMenu) ...[
            const SizedBox(width: 4),
            SizedBox(
              width: 44,
              height: 44,
              child: MembershipActionMenu(
                membership: membership,
                isPending: controller.isPending(membership.userId),
                actions: MembershipActions(
                  onChangeRole: (role) => controller.updateMemberRoleOrGrant(
                    userId: membership.userId,
                    role: role,
                  ),
                  onToggleInviteGrant: (enabled) =>
                      controller.updateMemberRoleOrGrant(
                    userId: membership.userId,
                    hasInviteGrant: enabled,
                  ),
                  onKick: () async {
                    // Capture the messenger BEFORE the kick — a successful
                    // kick reloads the list and disposes this row (and its
                    // context), so we can't show the undo toast from the
                    // row's context afterwards.
                    final messenger = ScaffoldMessenger.of(context);
                    final removed = await controller.removeMember(
                      userId: membership.userId,
                    );
                    if (removed == null || removed.wasSelfLeave) return;
                    final kicked = removed.membership;
                    messenger.showSnackBar(
                      SnackBar(
                        content: const Text('Участник удалён'),
                        duration: const Duration(seconds: 10),
                        action: SnackBarAction(
                          label: 'Отменить',
                          onPressed: () async {
                            // Re-add restores editor/viewer (owners aren't
                            // kicked). joinedAt is reassigned server-side.
                            final restored = await controller.addMember(
                              userId: kicked.userId,
                              role: kicked.role,
                              hasInviteGrant: kicked.hasInviteGrant,
                            );
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text(
                                  restored
                                      ? 'Участник восстановлен'
                                      : 'Не удалось восстановить участника',
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAvatar(ThemeData theme, String initials) {
    final fallback = CircleAvatar(
      radius: 20,
      backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.16),
      child: Text(
        initials,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    final raw = membership.avatarUrl?.trim();
    if (raw == null || raw.isEmpty) return fallback;
    final url = normalizePhotoUrl(raw) ?? raw;
    return ClipOval(
      child: SizedBox(
        width: 40,
        height: 40,
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          placeholder: (_, __) => fallback,
          errorWidget: (_, __, ___) => fallback,
        ),
      ),
    );
  }

  static String _initialsOf(String label) {
    final parts =
        label.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final p = parts.first;
      return p.substring(0, p.length.clamp(0, 2)).toUpperCase();
    }
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  static String _formatJoinedAt(String iso) {
    if (iso.isEmpty) return '';
    // ISO date-only display — ignore time component для readability.
    final dot = iso.indexOf('T');
    if (dot > 0) {
      return 'Присоединился ${iso.substring(0, dot)}';
    }
    return 'Присоединился $iso';
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              color: Theme.of(context).colorScheme.error,
              size: 36,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => onRetry(),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }
}
