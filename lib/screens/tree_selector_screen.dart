// ignore_for_file: library_private_types_in_public_api
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/models/tree_invitation.dart';
import '../models/family_tree.dart';
import '../providers/tree_provider.dart';
import '../services/public_tree_link_service.dart';
import '../utils/russian_plural.dart';
import '../widgets/glass_panel.dart';

/// Canonical tree-selection surface. Lives at `/trees` (moved off
/// `/tree?selector=1` once `/tree` became its own tab route — prefix
/// matching in go_router ignores query params, so the selector had to
/// get its own path). Earlier the app had two near-identical
/// pickers — `TreesScreen` overlay and this shell-aware selector —
/// which split the back-arrow / sidebar / BranchSwitcher into
/// different visual paths and confused users. Now this one screen
/// covers everything:
///
/// * branch list with active/own/joined sections
/// * invitations banner + accept/decline cards
/// * per-tree «Удалить» / «Покинуть» action
/// * `initialFocus: 'invitations'` jumps the scroller to the
///   invitations section on entry (so the home-feed banner can
///   deep-link there)
class TreeSelectorScreen extends StatefulWidget {
  const TreeSelectorScreen({
    super.key,
    this.initialFocus,
  });

  /// `'invitations'` to scroll the page to the invitations section
  /// on first frame; `null` (default) leaves scroll at top.
  final String? initialFocus;

  @override
  _TreeSelectorScreenState createState() => _TreeSelectorScreenState();
}

class _TreeSelectorScreenState extends State<TreeSelectorScreen> {
  final AuthServiceInterface? _authService =
      GetIt.I.isRegistered<AuthServiceInterface>()
          ? GetIt.I<AuthServiceInterface>()
          : null;
  final FamilyTreeServiceInterface _familyTreeService =
      GetIt.I<FamilyTreeServiceInterface>();

  bool _isLoading = true;
  List<FamilyTree> _userTrees = [];
  String _errorMessage = '';
  String? _selectingTreeId;

  StreamSubscription<List<TreeInvitation>>? _invitationsSub;
  List<TreeInvitation> _pendingInvitations = const <TreeInvitation>[];
  bool _isInvitationsLoading = true;
  String? _processingInvitationId;
  String? _processingRemovalTreeId;
  bool _hasScrolledToInitialFocus = false;
  final GlobalKey _invitationsAnchorKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _loadUserTrees();
    _subscribeToInvitations();
  }

  @override
  void dispose() {
    _invitationsSub?.cancel();
    super.dispose();
  }

  void _subscribeToInvitations() {
    final stream = _familyTreeService.getPendingTreeInvitations();
    _invitationsSub = stream.listen(
      (invitations) {
        if (!mounted) return;
        setState(() {
          _pendingInvitations = invitations;
          _isInvitationsLoading = false;
        });
        _maybeScrollToInitialFocus();
      },
      onError: (Object error, StackTrace stack) {
        debugPrint('Invitations stream error: $error');
        if (!mounted) return;
        setState(() {
          _isInvitationsLoading = false;
        });
      },
    );
  }

  Future<void> _loadUserTrees() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final trees = await _familyTreeService.getUserTrees();
      if (!mounted) return;

      setState(() {
        _userTrees = trees;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Ошибка загрузки деревьев: $e');
      if (!mounted) return;

      setState(() {
        _errorMessage = 'Не удалось загрузить список деревьев.';
        _isLoading = false;
      });
    }
  }

  void _maybeScrollToInitialFocus() {
    if (_hasScrolledToInitialFocus) return;
    if (widget.initialFocus != 'invitations') return;
    if (_pendingInvitations.isEmpty) return;
    _hasScrolledToInitialFocus = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _invitationsAnchorKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0.05,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Деревья'),
        // The selector is a top-level surface now (no longer a tab). When
        // it's pushed (e.g. the BranchSwitcher chip) the back button pops;
        // when it's reached via `go` (compose / banner shortcuts) there's
        // nothing to pop, so fall back to the «Семья» tab rather than
        // stranding the user with no way out.
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Назад',
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              context.go('/tree');
            }
          },
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.primary.withValues(alpha: 0.07),
              theme.colorScheme.surface,
              theme.colorScheme.secondary.withValues(alpha: 0.04),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _errorMessage.isNotEmpty
                      ? _buildErrorState()
                      : (_userTrees.isEmpty && _pendingInvitations.isEmpty)
                          ? _buildEmptyState()
                          : _buildTreeList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: GlassPanel(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 14),
              Text(
                'Не удалось загрузить деревья',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _errorMessage,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: _loadUserTrees,
                icon: const Icon(Icons.refresh),
                label: const Text('Повторить'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: GlassPanel(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Icon(
                  Icons.account_tree_outlined,
                  color: theme.colorScheme.primary,
                  size: 30,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Создайте дерево',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _isInvitationsLoading
                    ? 'Загружаем приглашения…'
                    : 'Или дождитесь приглашения от родственников.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Новая семья'),
                    onPressed: _openCreateTree,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.diversity_3_outlined),
                    label: const Text('Новый круг'),
                    onPressed: _openCreateFriendsTree,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Семья — родственники · Круг — близкие без родства',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTreeList() {
    final treeProvider = context.read<TreeProvider>();
    final selectedTreeId = context.select<TreeProvider, String?>(
      (provider) => provider.selectedTreeId,
    );
    final currentTree = selectedTreeId == null
        ? null
        : _userTrees.cast<FamilyTree?>().firstWhere(
              (tree) => tree?.id == selectedTreeId,
              orElse: () => null,
            );
    final ownTrees = _userTrees
        .where(
          (tree) => _isOwnedByCurrentUser(tree) && tree.id != selectedTreeId,
        )
        .toList()
      ..sort((left, right) => left.name.compareTo(right.name));
    final memberTrees = _userTrees
        .where(
          (tree) => !_isOwnedByCurrentUser(tree) && tree.id != selectedTreeId,
        )
        .toList()
      ..sort((left, right) => left.name.compareTo(right.name));

    return RefreshIndicator(
      onRefresh: _loadUserTrees,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          GlassPanel(
            margin: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ваши деревья',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Каждое дерево — отдельная семейная схема: можно вести '
                  'общую родню, ветку другой фамилии или свой близкий круг.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (currentTree != null)
                      _SelectorChip(
                        icon: Icons.check_circle_outline,
                        label: currentTree.name,
                        highlighted: true,
                      ),
                    if (_userTrees.isNotEmpty)
                      _SelectorChip(
                        icon: Icons.forest_outlined,
                        label: '${_userTrees.length} ${russianPluralForm(
                          _userTrees.length,
                          one: 'дерево',
                          few: 'дерева',
                          many: 'деревьев',
                        )}',
                      ),
                    if (_pendingInvitations.isNotEmpty)
                      _SelectorChip(
                        icon: Icons.mark_email_unread_outlined,
                        label: 'Приглашений: ${_pendingInvitations.length}',
                        highlighted: true,
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _openCreateTree,
                      icon: const Icon(Icons.add),
                      label: const Text('Новая семья'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _openCreateFriendsTree,
                      icon: const Icon(Icons.diversity_3_outlined),
                      label: const Text('Новый круг'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Clarify the two — «Семья» vs «Круг» read alike otherwise.
                Text(
                  'Семья — родственники · Круг — близкие без родства',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          if (_pendingInvitations.isNotEmpty) ...[
            _SelectorSectionHeader(
              key: _invitationsAnchorKey,
              title: _pendingInvitations.length == 1
                  ? 'Приглашение'
                  : 'Приглашения',
            ),
            ..._pendingInvitations.map(_buildInvitationCard),
          ],
          if (currentTree != null) ...[
            const _SelectorSectionHeader(title: 'Выбрано'),
            _buildTreeCard(
              tree: currentTree,
              treeProvider: treeProvider,
              isSelected: true,
            ),
          ],
          if (ownTrees.isNotEmpty) ...[
            _SelectorSectionHeader(
              title: 'Остальные мои',
            ),
            ...ownTrees.map(
              (tree) => _buildTreeCard(
                tree: tree,
                treeProvider: treeProvider,
                isSelected: false,
              ),
            ),
          ],
          if (memberTrees.isNotEmpty) ...[
            _SelectorSectionHeader(
              title: 'По приглашению',
            ),
            ...memberTrees.map(
              (tree) => _buildTreeCard(
                tree: tree,
                treeProvider: treeProvider,
                isSelected: false,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInvitationCard(TreeInvitation invitation) {
    final theme = Theme.of(context);
    final isProcessing = _processingInvitationId == invitation.invitationId;
    final tree = invitation.tree;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassPanel(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: theme.colorScheme.tertiary,
                  child: Icon(
                    tree.isFriendsTree
                        ? Icons.diversity_3_outlined
                        : Icons.family_restroom,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tree.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        invitation.invitedBy != null &&
                                invitation.invitedBy!.trim().isNotEmpty
                            ? 'Приглашает: ${invitation.invitedBy}'
                            : 'Вас пригласили присоединиться.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (tree.description.trim().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          tree.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (isProcessing)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else ...[
                  TextButton(
                    onPressed: () => _handleInvitation(invitation, false),
                    child: const Text('Отклонить'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => _handleInvitation(invitation, true),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Принять'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleInvitation(
    TreeInvitation invitation,
    bool accept,
  ) async {
    if (_processingInvitationId != null) return;
    setState(() {
      _processingInvitationId = invitation.invitationId;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _familyTreeService.respondToTreeInvitation(
        invitation.invitationId,
        accept,
      );
      if (!mounted) return;
      // Re-pull the tree list when accepting so the freshly-joined
      // tree appears in «Другие» without a manual refresh.
      if (accept) {
        await _loadUserTrees();
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            accept ? 'Приглашение принято' : 'Приглашение отклонено',
          ),
        ),
      );
    } catch (e) {
      debugPrint('Ошибка при обработке приглашения: $e');
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Не удалось обработать приглашение.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _processingInvitationId = null;
        });
      }
    }
  }

  Widget _buildTreeCard({
    required FamilyTree tree,
    required TreeProvider treeProvider,
    required bool isSelected,
  }) {
    final treeId = tree.id;
    final treeName = tree.name;
    final createdAt = tree.createdAt;
    final certificationNote = tree.certificationNote?.trim();
    final isSelecting = _selectingTreeId == treeId;
    final isOwned = _isOwnedByCurrentUser(tree);
    final destructiveLabel = isOwned ? 'Удалить' : 'Покинуть';
    final isRemoving = _processingRemovalTreeId == treeId;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: isSelecting || isRemoving
              ? null
              : () async {
                  setState(() {
                    _selectingTreeId = treeId;
                  });
                  await treeProvider.selectTree(
                    treeId,
                    treeName,
                    treeKind: tree.kind,
                  );
                  if (!mounted) {
                    return;
                  }
                  setState(() {
                    _selectingTreeId = null;
                  });
                  final encodedName = Uri.encodeComponent(treeName);
                  if (!context.mounted) {
                    return;
                  }
                  context.go('/tree/view/$treeId?name=$encodedName');
                },
          child: GlassPanel(
            color: isSelected
                ? Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.56)
                : null,
            borderRadius: BorderRadius.circular(28),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: Icon(
                    tree.isFriendsTree
                        ? Icons.diversity_3_outlined
                        : Icons.account_tree,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        treeName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (isSelected)
                            const _SelectorChip(
                              icon: Icons.check_circle_outline,
                              label: 'Выбрано',
                              highlighted: true,
                            ),
                          if (tree.isCertified)
                            const _SelectorChip(
                              icon: Icons.verified_outlined,
                              label: 'Проверено',
                              highlighted: true,
                            ),
                          _SelectorChip(
                            icon: isOwned
                                ? Icons.star_outline
                                : Icons.groups_2_outlined,
                            label: isOwned ? 'Создатель' : 'Участник',
                          ),
                          _SelectorChip(
                            icon: tree.isPrivate
                                ? Icons.lock_outline
                                : Icons.public,
                            label: tree.isPrivate
                                ? 'Только участникам'
                                : 'Публичный доступ',
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Создано ${_formatDate(createdAt)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                      if (certificationNote != null &&
                          certificationNote.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          certificationNote,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (isSelecting || isRemoving)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (tree.isPublic)
                        IconButton(
                          tooltip: 'Скопировать публичную ссылку',
                          onPressed: () => _copyPublicLink(tree),
                          icon: const Icon(Icons.link_outlined),
                        ),
                      PopupMenuButton<_TreeMenuAction>(
                        tooltip: 'Действия',
                        icon: const Icon(Icons.more_vert),
                        onSelected: (action) {
                          if (action == _TreeMenuAction.remove) {
                            _confirmRemoveTree(tree);
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem<_TreeMenuAction>(
                            value: _TreeMenuAction.remove,
                            child: Row(
                              children: [
                                Icon(
                                  isOwned ? Icons.delete_outline : Icons.logout,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                                const SizedBox(width: 8),
                                Text(destructiveLabel),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Icon(Icons.chevron_right_rounded),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    return '$day.$month.${date.year}';
  }

  Future<void> _copyPublicLink(FamilyTree tree) async {
    final publicUri = PublicTreeLinkService.buildPublicTreeUri(
      tree.publicRouteId,
      publicAppUrl: BackendRuntimeConfig.current.publicAppUrl,
    );
    await Clipboard.setData(ClipboardData(text: publicUri.toString()));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Публичная ссылка скопирована.')),
    );
  }

  Future<void> _confirmRemoveTree(FamilyTree tree) async {
    final isOwner = _isOwnedByCurrentUser(tree);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(isOwner ? 'Удалить дерево?' : 'Покинуть дерево?'),
          content: Text(
            isOwner
                ? 'Дерево "${tree.name}" исчезнет для всех участников вместе с его карточками и связями.'
                : 'Вы перестанете видеть дерево "${tree.name}" в своём списке. Само дерево останется у остальных участников.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogContext).colorScheme.error,
                foregroundColor: Theme.of(dialogContext).colorScheme.onError,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(isOwner ? 'Удалить дерево' : 'Покинуть дерево'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _processingRemovalTreeId = tree.id;
    });
    final messenger = ScaffoldMessenger.of(context);
    final treeProvider = Provider.of<TreeProvider>(context, listen: false);
    final wasSelected = treeProvider.selectedTreeId == tree.id;

    try {
      await _familyTreeService.removeTree(tree.id);
      await _loadUserTrees();
      if (!mounted) {
        return;
      }

      if (wasSelected) {
        if (_userTrees.isNotEmpty) {
          final nextTree = _userTrees.first;
          await treeProvider.selectTree(
            nextTree.id,
            nextTree.name,
            treeKind: nextTree.kind,
          );
        } else {
          await treeProvider.clearSelection();
        }
      }

      messenger.showSnackBar(
        SnackBar(
          content: Text(
            isOwner ? 'Дерево удалено.' : 'Вы покинули дерево.',
          ),
        ),
      );
    } catch (e) {
      debugPrint('Ошибка при удалении дерева: $e');
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            isOwner
                ? 'Не удалось удалить дерево.'
                : 'Не удалось покинуть дерево.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _processingRemovalTreeId = null;
        });
      }
    }
  }

  void _openCreateTree() {
    context.push('/trees/create').then((result) {
      if (result == true) {
        _loadUserTrees();
      }
    });
  }

  void _openCreateFriendsTree() {
    context.push('/trees/create?kind=friends').then((result) {
      if (result == true) {
        _loadUserTrees();
      }
    });
  }

  bool _isOwnedByCurrentUser(FamilyTree tree) {
    final currentUserId = _authService?.currentUserId;
    if (currentUserId == null || currentUserId.isEmpty) {
      return true;
    }
    return tree.creatorId == currentUserId;
  }
}

enum _TreeMenuAction { remove }

class _SelectorSectionHeader extends StatelessWidget {
  const _SelectorSectionHeader({
    super.key,
    required this.title,
  });

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectorChip extends StatelessWidget {
  const _SelectorChip({
    required this.icon,
    required this.label,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final chipBackground = highlighted
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHighest.withValues(alpha: 0.82);
    final chipForeground = highlighted
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: chipBackground,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: chipForeground),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: chipForeground,
            ),
          ),
        ],
      ),
    );
  }
}
