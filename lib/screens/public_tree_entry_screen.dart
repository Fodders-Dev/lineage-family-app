import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../models/family_tree.dart';
import '../services/public_tree_service.dart';

class PublicTreeEntryScreen extends StatefulWidget {
  const PublicTreeEntryScreen({
    super.key,
    required this.publicTreeId,
    this.publicTreeService,
  });

  final String publicTreeId;
  final PublicTreeServiceInterface? publicTreeService;

  @override
  State<PublicTreeEntryScreen> createState() => _PublicTreeEntryScreenState();
}

class _PublicTreeEntryScreenState extends State<PublicTreeEntryScreen> {
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final FamilyTreeServiceInterface _familyTreeService =
      GetIt.I<FamilyTreeServiceInterface>();

  late final PublicTreeServiceInterface _publicTreeService =
      widget.publicTreeService ?? PublicTreeService();

  bool _isLoading = true;
  String? _errorMessage;
  PublicTreePreview? _preview;
  FamilyTree? _memberTree;

  @override
  void initState() {
    super.initState();
    _loadTree();
  }

  Future<void> _loadTree() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final preview = await _publicTreeService.getPublicTreePreview(
        widget.publicTreeId,
      );
      FamilyTree? memberTree;
      if (_authService.currentUserId != null) {
        final userTrees = await _familyTreeService.getUserTrees();
        for (final tree in userTrees) {
          if (tree.publicRouteId == widget.publicTreeId.trim()) {
            memberTree = tree;
            break;
          }
        }
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _preview = preview;
        _memberTree = memberTree;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Не удалось открыть публичную ссылку.';
        _isLoading = false;
      });
    }
  }

  void _openPublicViewer() {
    context.go('/public/tree/${widget.publicTreeId}/view');
  }

  void _openMemberTree(FamilyTree tree) {
    final encodedName = Uri.encodeComponent(tree.name);
    context.go('/tree/view/${tree.id}?name=$encodedName');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Публичное дерево')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return _InfoCard(
        icon: Icons.error_outline,
        title: 'Ссылка временно недоступна',
        message: _errorMessage!,
        primaryAction: FilledButton.icon(
          onPressed: _loadTree,
          icon: const Icon(Icons.refresh),
          label: const Text('Повторить'),
        ),
      );
    }

    final preview = _preview;
    if (preview == null) {
      return _InfoCard(
        icon: Icons.account_tree_outlined,
        title: 'Публичное дерево не найдено',
        message:
            'По этой ссылке сейчас ничего не опубликовано. Возможно, дерево снова стало приватным или ссылка устарела.',
        primaryAction: FilledButton.icon(
          onPressed: _loadTree,
          icon: const Icon(Icons.refresh),
          label: const Text('Проверить снова'),
        ),
      );
    }

    final tree = preview.tree;
    final description = tree.certificationNote?.trim().isNotEmpty == true
        ? tree.certificationNote!.trim()
        : (tree.description.trim().isNotEmpty
            ? tree.description.trim()
            : 'Публичное дерево доступно для гостевого просмотра без редактирования.');

    return _InfoCard(
      icon: tree.isCertified ? Icons.verified_outlined : Icons.account_tree,
      title: tree.name,
      message: description,
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _InfoChip(
                icon: tree.isPrivate ? Icons.lock_outline : Icons.public,
                label: tree.isPrivate ? 'Приватное' : 'Публичное',
              ),
              _InfoChip(
                icon: Icons.people_alt_outlined,
                label: '${preview.peopleCount} человек',
              ),
              _InfoChip(
                icon: Icons.hub_outlined,
                label: '${preview.relationsCount} связей',
              ),
              if (tree.isCertified)
                const _InfoChip(
                  icon: Icons.workspace_premium_outlined,
                  label: 'Сертифицировано',
                  highlighted: true,
                ),
            ],
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: _openPublicViewer,
                icon: const Icon(Icons.visibility_outlined),
                label: Text(
                  _authService.currentUserId == null
                      ? 'Смотреть как гость'
                      : 'Гостевой просмотр',
                ),
              ),
              if (_memberTree != null)
                OutlinedButton.icon(
                  onPressed: () => _openMemberTree(_memberTree!),
                  icon: const Icon(Icons.login),
                  label: const Text('Открыть как участник'),
                ),
              if (_authService.currentUserId == null)
                OutlinedButton.icon(
                  onPressed: () => context.go('/login'),
                  icon: const Icon(Icons.person_outline),
                  label: const Text('Войти в аккаунт'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.message,
    this.primaryAction,
    this.footer,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? primaryAction;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 56, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (primaryAction != null) ...[
            const SizedBox(height: 20),
            primaryAction!,
          ],
          if (footer != null) ...[
            const SizedBox(height: 20),
            footer!,
          ],
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: highlighted ? colorScheme.primaryContainer : colorScheme.surface,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: highlighted
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: highlighted
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
