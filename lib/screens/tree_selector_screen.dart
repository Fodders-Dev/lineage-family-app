// ignore_for_file: library_private_types_in_public_api
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// Убираем импорт TreeViewScreen, так как переход будет в другое место
// import 'tree_view_screen.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../providers/tree_provider.dart';
import 'package:get_it/get_it.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../models/family_tree.dart';
import '../services/public_tree_link_service.dart';

class TreeSelectorScreen extends StatefulWidget {
  const TreeSelectorScreen({super.key});

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

  @override
  void initState() {
    super.initState();
    _loadUserTrees();
  }

  Future<void> _loadUserTrees() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final trees = await _familyTreeService.getUserTrees();

      if (mounted) {
        setState(() {
          _userTrees = trees;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Ошибка загрузки деревьев: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Не удалось загрузить список деревьев.';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = MediaQuery.sizeOf(context).width < 600;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Деревья и круги'),
        actions: [
          if (isCompact)
            IconButton(
              tooltip: 'Все деревья',
              onPressed: () => context.push('/trees'),
              icon: const Icon(Icons.explore_outlined),
            )
          else
            TextButton.icon(
              onPressed: () => context.push('/trees'),
              icon: const Icon(Icons.explore_outlined),
              label: const Text('Все деревья'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _errorMessage.isNotEmpty
                ? _buildErrorState()
                : _userTrees.isEmpty
                    ? _buildEmptyState()
                    : _buildTreeList(),
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 56, color: Colors.red.shade300),
            const SizedBox(height: 16),
            const Text(
              'Не удалось загрузить деревья',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[700]),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _loadUserTrees,
              icon: const Icon(Icons.refresh),
              label: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.account_tree, size: 80, color: Colors.grey[400]),
            const SizedBox(height: 16),
            const Text(
              'Создайте первое дерево',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              'Сразу после создания откроется схема семьи или дружеского круга. Потом сможете добавить первого человека и пригласить нужных людей.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600]),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Создать первое дерево'),
              onPressed: _openCreateTree,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.diversity_3_outlined),
              label: const Text('Создать круг друзей'),
              onPressed: _openCreateFriendsTree,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => context.push('/trees'),
              icon: const Icon(Icons.mail_outline),
              label: const Text('У меня есть приглашение'),
            ),
          ],
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
            (tree) => _isOwnedByCurrentUser(tree) && tree.id != selectedTreeId)
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
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Откройте нужное дерево',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  'Активное дерево идёт первым. Семейные деревья и дружеские круги живут в одном переключателе.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _openCreateTree,
                      icon: const Icon(Icons.add),
                      label: const Text('Создать семью'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _openCreateFriendsTree,
                      icon: const Icon(Icons.diversity_3_outlined),
                      label: const Text('Создать круг'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _loadUserTrees,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Обновить'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (currentTree != null) ...[
            const _SelectorSectionHeader(
              title: 'Активное дерево',
              subtitle: 'Откроется первым и уже выбрано для текущей сессии.',
            ),
            _buildTreeCard(
              tree: currentTree,
              treeProvider: treeProvider,
              isSelected: true,
            ),
          ],
          if (ownTrees.isNotEmpty) ...[
            _SelectorSectionHeader(
              title: 'Мои деревья',
              subtitle: ownTrees.length == 1
                  ? 'Дерево или круг, который вы создали.'
                  : 'Деревья и круги, которые вы создали сами.',
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
              title: 'Другие деревья',
              subtitle: memberTrees.length == 1
                  ? 'Дерево или круг, куда вас пригласили.'
                  : 'Деревья и круги, куда вас пригласили другие люди.',
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

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: isSelected
          ? Theme.of(context).colorScheme.primaryContainer.withValues(
                alpha: 0.45,
              )
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: isSelecting
            ? null
            : () async {
                debugPrint(
                  '[TreeSelectorScreen] Selecting tree: $treeId ($treeName)',
                );
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
        child: Padding(
          padding: const EdgeInsets.all(16),
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
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _SelectorChip(
                          icon: tree.isPrivate
                              ? Icons.lock_outline
                              : Icons.public,
                          label: tree.isPrivate ? 'Приватное' : 'Публичное',
                        ),
                        _SelectorChip(
                          icon: tree.isFriendsTree
                              ? Icons.diversity_3_outlined
                              : Icons.family_restroom,
                          label: tree.kindLabel,
                        ),
                        _SelectorChip(
                          icon: _isOwnedByCurrentUser(tree)
                              ? Icons.star_outline
                              : Icons.groups_2_outlined,
                          label: _isOwnedByCurrentUser(tree)
                              ? 'Создатель'
                              : 'Участник',
                        ),
                        if (tree.isCertified)
                          _SelectorChip(
                            icon: Icons.verified_outlined,
                            label: 'Сертифицировано',
                            highlighted: true,
                          ),
                        if (isSelected)
                          _SelectorChip(
                            icon: Icons.check_circle_outline,
                            label: 'Открыто сейчас',
                            highlighted: true,
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Создано ${_formatDate(createdAt)}',
                      style: TextStyle(color: Colors.grey[700]),
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
              isSelecting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (tree.isPublic)
                          IconButton(
                            tooltip: 'Скопировать публичную ссылку',
                            onPressed: () => _copyPublicLink(tree),
                            icon: const Icon(Icons.link_outlined),
                          ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
            ],
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

class _SelectorSectionHeader extends StatelessWidget {
  const _SelectorSectionHeader({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
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
    final chipBackground =
        highlighted ? colorScheme.primary : colorScheme.surfaceContainerHighest;
    final chipForeground =
        highlighted ? colorScheme.onPrimary : colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: chipBackground,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: chipForeground,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: chipForeground,
            ),
          ),
        ],
      ),
    );
  }
}
