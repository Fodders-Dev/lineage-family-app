import 'package:flutter/material.dart';

import '../backend/interfaces/graph_person_access_capable_family_tree_service.dart';
import '../backend/models/edit_grant.dart';

/// Phase 3.4 chunk 3 (PHASE-3.4-UI-PROPOSAL.md §2.3): incoming-таб
/// экрана «Доступы». Список grants выписанных мне на чужие
/// graphPerson'ы — informational, без revoke (отзывает только
/// grantor через свой outgoing-таб).
///
/// ```
/// ┌──────────────────────────────────┐
/// │ [photo] Иван Петров              │  ← graphPerson preview
/// │   Может редактировать            │  ← chip
/// │   Может удалить                  │
/// └──────────────────────────────────┘
/// ```
///
/// Backend `/v1/me/edit-grants` не hydrate'ит grantor preview
/// (см. edit_grant.dart): show graphPerson preview + scope chips.
/// Имя того *кто* разрешил намеренно опущено — собственник может
/// быть любой звено claim chain'а, не критично для viewer'а.
class AccessGrantsIncomingTab extends StatefulWidget {
  const AccessGrantsIncomingTab({
    required this.accessService,
    required this.viewerUserId,
    super.key,
  });

  final GraphPersonAccessCapableFamilyTreeService accessService;
  final String viewerUserId;

  @override
  State<AccessGrantsIncomingTab> createState() =>
      _AccessGrantsIncomingTabState();
}

class _AccessGrantsIncomingTabState extends State<AccessGrantsIncomingTab> {
  List<EditGrant>? _grants;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final grants = await widget.accessService.listMyEditGrants();
      if (!mounted) return;
      setState(() {
        _grants = grants;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorState(message: _error!, onRetry: _load);
    }
    final grants = _grants ?? const <EditGrant>[];
    if (grants.isEmpty) {
      // Плотность: см. outgoing-таб — центрируем по реальной высоте
      // вместо фиксированного отступа сверху.
      return RefreshIndicator(
        onRefresh: _load,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: const Center(child: _EmptyIncomingState()),
            ),
          ),
        ),
      );
    }

    final groups = _groupByGraphPerson(grants);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: groups.length,
        itemBuilder: (context, index) {
          final group = groups[index];
          return _IncomingCard(group: group);
        },
      ),
    );
  }

  static List<_IncomingGroup> _groupByGraphPerson(List<EditGrant> grants) {
    final byId = <String, _IncomingGroup>{};
    for (final grant in grants) {
      final id = grant.graphPersonId;
      final existing = byId[id];
      if (existing == null) {
        byId[id] = _IncomingGroup(
          graphPersonId: id,
          preview: grant.graphPerson,
          grants: [grant],
        );
      } else {
        existing.grants.add(grant);
        existing.preview ??= grant.graphPerson;
      }
    }
    final groups = byId.values.toList();
    groups.sort((a, b) {
      final aActive = a.grants.any((g) => !g.isRevoked);
      final bActive = b.grants.any((g) => !g.isRevoked);
      if (aActive != bActive) return aActive ? -1 : 1;
      return (a.preview?.displayName ?? '')
          .compareTo(b.preview?.displayName ?? '');
    });
    return groups;
  }
}

class _IncomingGroup {
  _IncomingGroup({
    required this.graphPersonId,
    required this.preview,
    required this.grants,
  });

  final String graphPersonId;
  GrantPreviewSubject? preview;
  final List<EditGrant> grants;
}

class _IncomingCard extends StatelessWidget {
  const _IncomingCard({required this.group});

  final _IncomingGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = group.preview;
    final headerName = preview?.displayName.trim().isNotEmpty == true
        ? preview!.displayName
        : 'Карточка без имени';
    final activeGrants =
        group.grants.where((g) => !g.isRevoked).toList(growable: false);
    final revokedGrants =
        group.grants.where((g) => g.isRevoked).toList(growable: false);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Avatar(
                  photoUrl: preview?.photoUrl,
                  displayName: headerName,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    headerName,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            if (activeGrants.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final grant in activeGrants)
                    Chip(
                      label: Text(grant.scope.russianLabel),
                      visualDensity: VisualDensity.compact,
                      backgroundColor:
                          theme.colorScheme.primaryContainer.withValues(
                        alpha: 0.45,
                      ),
                      side: BorderSide.none,
                    ),
                ],
              ),
            ],
            if (revokedGrants.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final grant in revokedGrants)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Доступ «${grant.scope.russianLabel}» отозван '
                    '${_revokedAgoLabel(grant.revokedAt)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  static String _revokedAgoLabel(String? revokedAt) {
    if (revokedAt == null || revokedAt.isEmpty) return 'недавно';
    final parsed = DateTime.tryParse(revokedAt);
    if (parsed == null) return 'недавно';
    final days = DateTime.now().difference(parsed).inDays;
    if (days <= 0) return 'сегодня';
    if (days == 1) return 'вчера';
    if (days < 7) return '$days ${_pluralDays(days)} назад';
    if (days < 30) {
      final weeks = (days / 7).floor();
      return '$weeks ${_pluralWeeks(weeks)} назад';
    }
    return '$days ${_pluralDays(days)} назад';
  }

  static String _pluralDays(int n) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    if (mod10 == 1 && mod100 != 11) return 'день';
    if ([2, 3, 4].contains(mod10) && ![12, 13, 14].contains(mod100)) {
      return 'дня';
    }
    return 'дней';
  }

  static String _pluralWeeks(int n) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    if (mod10 == 1 && mod100 != 11) return 'неделю';
    if ([2, 3, 4].contains(mod10) && ![12, 13, 14].contains(mod100)) {
      return 'недели';
    }
    return 'недель';
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.photoUrl,
    required this.displayName,
  });

  final String? photoUrl;
  final String displayName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPhoto = photoUrl != null && photoUrl!.isNotEmpty;
    final initials = _initialsOf(displayName);
    return CircleAvatar(
      backgroundColor: theme.colorScheme.primaryContainer,
      backgroundImage: hasPhoto ? NetworkImage(photoUrl!) : null,
      child: hasPhoto
          ? null
          : Text(
              initials,
              style: TextStyle(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
    );
  }

  static String _initialsOf(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

class _EmptyIncomingState extends StatelessWidget {
  const _EmptyIncomingState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          Icon(
            Icons.lock_open_rounded,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            'Вам не выдано прав на чужие карточки',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Когда родственник разрешит вам редактировать или объединять '
            'свою карточку, она появится здесь.',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              'Не удалось загрузить доступы',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: onRetry,
              child: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }
}
