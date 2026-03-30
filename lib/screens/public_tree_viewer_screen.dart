import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/family_person.dart';
import '../services/public_tree_link_service.dart';
import '../services/public_tree_service.dart';
import '../widgets/interactive_family_tree.dart';

class PublicTreeViewerScreen extends StatefulWidget {
  const PublicTreeViewerScreen({
    super.key,
    required this.publicTreeId,
    this.publicTreeService,
  });

  final String publicTreeId;
  final PublicTreeServiceInterface? publicTreeService;

  @override
  State<PublicTreeViewerScreen> createState() => _PublicTreeViewerScreenState();
}

class _PublicTreeViewerScreenState extends State<PublicTreeViewerScreen> {
  late final PublicTreeServiceInterface _publicTreeService =
      widget.publicTreeService ?? PublicTreeService();

  bool _isLoading = true;
  String? _errorMessage;
  PublicTreeSnapshot? _snapshot;
  String? _branchRootPersonId;
  String? _branchRootName;

  @override
  void initState() {
    super.initState();
    _loadSnapshot();
  }

  Future<void> _loadSnapshot() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final snapshot = await _publicTreeService.getPublicTreeSnapshot(
        widget.publicTreeId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Не удалось загрузить публичное дерево.';
        _isLoading = false;
      });
    }
  }

  void _focusBranch(FamilyPerson person) {
    setState(() {
      _branchRootPersonId = person.id;
      _branchRootName = person.name;
    });
  }

  void _resetBranchFocus() {
    setState(() {
      _branchRootPersonId = null;
      _branchRootName = null;
    });
  }

  void _showPersonDetails(FamilyPerson person) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  person.name,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _ViewerChip(
                      icon: Icons.person_outline,
                      label: _genderLabel(person.gender),
                    ),
                    if (person.birthDate != null)
                      _ViewerChip(
                        icon: Icons.cake_outlined,
                        label: 'Родился: ${_formatDate(person.birthDate!)}',
                      ),
                    if (person.deathDate != null)
                      _ViewerChip(
                        icon: Icons.history_toggle_off_outlined,
                        label: 'Умер: ${_formatDate(person.deathDate!)}',
                      ),
                  ],
                ),
                if (person.notes?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Заметка',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Text(person.notes!.trim()),
                ] else if (person.bio?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: 16),
                  Text(
                    'О человеке',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Text(person.bio!.trim()),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    _focusBranch(person);
                  },
                  icon: const Icon(Icons.alt_route),
                  label: const Text('Показать ветку от этого человека'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDate(DateTime date) {
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    return '$day.$month.${date.year}';
  }

  String _genderLabel(Gender gender) {
    switch (gender) {
      case Gender.male:
        return 'Мужчина';
      case Gender.female:
        return 'Женщина';
      case Gender.other:
        return 'Другой пол';
      case Gender.unknown:
        return 'Пол не указан';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Публичный просмотр'),
        actions: [
          IconButton(
            onPressed: () async {
              final snapshot = _snapshot;
              if (snapshot == null) {
                return;
              }
              final messenger = ScaffoldMessenger.of(context);
              final publicUri = PublicTreeLinkService.buildPublicTreeUri(
                snapshot.tree.publicRouteId,
              );
              await Clipboard.setData(
                ClipboardData(text: publicUri.toString()),
              );
              if (!mounted) {
                return;
              }
              messenger.showSnackBar(
                const SnackBar(
                  content: Text('Публичная ссылка скопирована.'),
                ),
              );
            },
            icon: const Icon(Icons.link_outlined),
            tooltip: 'Показать публичную ссылку',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return _ViewerState(
        icon: Icons.error_outline,
        title: 'Не удалось загрузить дерево',
        message: _errorMessage!,
        action: FilledButton.icon(
          onPressed: _loadSnapshot,
          icon: const Icon(Icons.refresh),
          label: const Text('Повторить'),
        ),
      );
    }

    final snapshot = _snapshot;
    if (snapshot == null) {
      return _ViewerState(
        icon: Icons.public_off_outlined,
        title: 'Публичное дерево не найдено',
        message:
            'По этой ссылке сейчас нет доступного дерева. Попробуйте открыть другую ссылку.',
        action: FilledButton.icon(
          onPressed: _loadSnapshot,
          icon: const Icon(Icons.refresh),
          label: const Text('Проверить снова'),
        ),
      );
    }

    final tree = snapshot.tree;
    final branchRootPerson = _findBranchRootPerson(snapshot);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tree.name,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  tree.certificationNote?.trim().isNotEmpty == true
                      ? tree.certificationNote!.trim()
                      : (tree.description.trim().isNotEmpty
                          ? tree.description.trim()
                          : 'Гостевой просмотр открыт. Карточки можно читать, но редактирование выключено.'),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _ViewerChip(
                      icon: tree.isPrivate ? Icons.lock_outline : Icons.public,
                      label: tree.isPrivate ? 'Приватное' : 'Публичное',
                    ),
                    _ViewerChip(
                      icon: Icons.people_alt_outlined,
                      label: '${snapshot.peopleCount} человек',
                    ),
                    _ViewerChip(
                      icon: Icons.hub_outlined,
                      label: '${snapshot.relationsCount} связей',
                    ),
                    if (tree.isCertified)
                      const _ViewerChip(
                        icon: Icons.verified_outlined,
                        label: 'Сертифицировано',
                        highlighted: true,
                      ),
                    if (_branchRootName != null)
                      _ViewerChip(
                        icon: Icons.alt_route,
                        label: 'Ветка: $_branchRootName',
                        highlighted: true,
                      ),
                    const _ViewerChip(
                      icon: Icons.unfold_more_outlined,
                      label: 'Drag, zoom, + / - / 0',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _ViewerChip(
                      icon: Icons.male,
                      label: 'Синие карточки — мужчины',
                    ),
                    _ViewerChip(
                      icon: Icons.female,
                      label: 'Розовые карточки — женщины',
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (_branchRootPersonId != null)
                      OutlinedButton.icon(
                        onPressed: _resetBranchFocus,
                        icon: const Icon(Icons.account_tree_outlined),
                        label: const Text('Показать всё дерево'),
                      ),
                    if (branchRootPerson != null)
                      OutlinedButton.icon(
                        onPressed: () => _showPersonDetails(branchRootPerson),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Карточка ветки'),
                      ),
                    OutlinedButton.icon(
                      onPressed: _loadSnapshot,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Обновить'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: InteractiveFamilyTree(
              peopleData: snapshot.persons
                  .map(
                    (person) => <String, dynamic>{
                      'person': person,
                      'userProfile': null,
                    },
                  )
                  .toList(),
              relations: snapshot.relations,
              currentUserId: null,
              branchRootPersonId: _branchRootPersonId,
              onBranchFocusCleared: _resetBranchFocus,
              onPersonTap: _showPersonDetails,
              onBranchFocusRequested: _focusBranch,
              isEditMode: false,
              onAddRelativeTapWithType: (_, __) {},
              currentUserIsInTree: true,
              onAddSelfTapWithType: (_, __) {},
            ),
          ),
        ),
      ],
    );
  }

  FamilyPerson? _findBranchRootPerson(PublicTreeSnapshot snapshot) {
    final branchRootPersonId = _branchRootPersonId;
    if (branchRootPersonId == null) {
      return null;
    }

    for (final person in snapshot.persons) {
      if (person.id == branchRootPersonId) {
        return person;
      }
    }
    return null;
  }
}

class _ViewerState extends StatelessWidget {
  const _ViewerState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: 56, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(
                  message,
                  textAlign: TextAlign.center,
                ),
                if (action != null) ...[
                  const SizedBox(height: 16),
                  action!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewerChip extends StatelessWidget {
  const _ViewerChip({
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
