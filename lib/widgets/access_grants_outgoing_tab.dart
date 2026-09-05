import 'package:flutter/material.dart';

import '../backend/interfaces/graph_person_access_capable_family_tree_service.dart';
import '../backend/models/edit_grant.dart';

/// Phase 3.4 chunk 3 (PHASE-3.4-UI-PROPOSAL.md §2.3): outgoing-таб
/// экрана «Доступы». Список grants выписанных текущим юзером —
/// группировка по графPerson'у:
///
/// ```
/// ┌──────────────────────────────────┐
/// │ [photo] Иван Петров              │  ← graphPerson preview
/// ├──────────────────────────────────┤
/// │ [ava] Алиса • может редактировать│
/// │                            [X]   │  ← grant row + revoke btn
/// │ [ava] Боб • может удалить    [X] │
/// └──────────────────────────────────┘
/// ```
///
/// Tap revoke → confirm-dialog → DELETE
/// /v1/graph-persons/:id/grants/:grantId → optimistic refetch.
///
/// Revoked-since-30d показываются серым с подписью «отозвано
/// N дней назад». Backend сам срезает revoked-более-30d.
class AccessGrantsOutgoingTab extends StatefulWidget {
  const AccessGrantsOutgoingTab({
    required this.accessService,
    required this.viewerUserId,
    super.key,
  });

  final GraphPersonAccessCapableFamilyTreeService accessService;
  final String viewerUserId;

  @override
  State<AccessGrantsOutgoingTab> createState() =>
      _AccessGrantsOutgoingTabState();
}

class _AccessGrantsOutgoingTabState extends State<AccessGrantsOutgoingTab> {
  List<EditGrant>? _grants;
  bool _isLoading = true;
  String? _error;
  final Set<String> _revokingIds = <String>{};

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
      final grants = await widget.accessService.listMyIssuedGrants();
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

  Future<void> _confirmAndRevoke(EditGrant grant) async {
    final granteeName = grant.grantee?.displayName.trim().isNotEmpty == true
        ? grant.grantee!.displayName
        : 'этому пользователю';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Отозвать доступ?'),
          content: Text(
            'После отзыва $granteeName больше не сможет '
            '${_scopeVerb(grant.scope)} эту карточку. Действие можно '
            'выписать заново в любой момент.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Отозвать'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;

    setState(() => _revokingIds.add(grant.id));
    try {
      await widget.accessService.revokeGraphPersonGrant(
        graphPersonId: grant.graphPersonId,
        grantId: grant.id,
      );
      if (!mounted) return;
      // Re-fetch чтобы UI отразил revokedAt timestamp.
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Доступ отозван')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отозвать: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _revokingIds.remove(grant.id));
      }
    }
  }

  String _scopeVerb(EditGrantScope scope) {
    switch (scope) {
      case EditGrantScope.edit:
        return 'редактировать';
      case EditGrantScope.mergeConsent:
        return 'объединять';
      case EditGrantScope.softDelete:
        return 'удалять';
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
      // Плотность: было — фиксированный SizedBox(80) сверху, который
      // на высоких экранах оставлял пустоту и сверху, и снизу (контент
      // не центрирован, просто отодвинут). Центрируем относительно
      // реальной высоты вьюпорта, pull-to-refresh остаётся доступен.
      return RefreshIndicator(
        onRefresh: _load,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: const Center(child: _EmptyOutgoingState()),
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
          return _GraphPersonGroupCard(
            graphPersonPreview: group.preview,
            graphPersonId: group.graphPersonId,
            grants: group.grants,
            revokingIds: _revokingIds,
            onRevoke: _confirmAndRevoke,
          );
        },
      ),
    );
  }

  static List<_GraphPersonGroup> _groupByGraphPerson(List<EditGrant> grants) {
    final byId = <String, _GraphPersonGroup>{};
    for (final grant in grants) {
      final id = grant.graphPersonId;
      final existing = byId[id];
      if (existing == null) {
        byId[id] = _GraphPersonGroup(
          graphPersonId: id,
          preview: grant.graphPerson,
          grants: [grant],
        );
      } else {
        existing.grants.add(grant);
        // Берём первый non-null preview если первый grant пришёл без.
        existing.preview ??= grant.graphPerson;
      }
    }
    // Sort: сначала с активными grants, потом полностью revoked.
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

class _GraphPersonGroup {
  _GraphPersonGroup({
    required this.graphPersonId,
    required this.preview,
    required this.grants,
  });

  final String graphPersonId;
  GrantPreviewSubject? preview;
  final List<EditGrant> grants;
}

class _GraphPersonGroupCard extends StatelessWidget {
  const _GraphPersonGroupCard({
    required this.graphPersonPreview,
    required this.graphPersonId,
    required this.grants,
    required this.revokingIds,
    required this.onRevoke,
  });

  final GrantPreviewSubject? graphPersonPreview;
  final String graphPersonId;
  final List<EditGrant> grants;
  final Set<String> revokingIds;
  final ValueChanged<EditGrant> onRevoke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = graphPersonPreview;
    final headerName = preview?.displayName.trim().isNotEmpty == true
        ? preview!.displayName
        : 'Карточка без имени';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Row(
              children: [
                _Avatar(photoUrl: preview?.photoUrl, displayName: headerName),
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
          ),
          const Divider(height: 1),
          for (final grant in grants)
            _GrantRow(
              grant: grant,
              isRevoking: revokingIds.contains(grant.id),
              onRevoke: onRevoke,
            ),
        ],
      ),
    );
  }
}

class _GrantRow extends StatelessWidget {
  const _GrantRow({
    required this.grant,
    required this.isRevoking,
    required this.onRevoke,
  });

  final EditGrant grant;
  final bool isRevoking;
  final ValueChanged<EditGrant> onRevoke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grantee = grant.grantee;
    final granteeName = grantee?.displayName.trim().isNotEmpty == true
        ? grantee!.displayName
        : 'Пользователь';
    final isRevoked = grant.isRevoked;
    final color = isRevoked
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          _Avatar(
            photoUrl: grantee?.photoUrl,
            displayName: granteeName,
            faded: isRevoked,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  granteeName,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: color,
                    decoration:
                        isRevoked ? TextDecoration.lineThrough : null,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  grant.scope.russianLabel,
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
                if (isRevoked)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Отозвано ${_revokedAgoLabel(grant.revokedAt)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (!isRevoked)
            isRevoking
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Отозвать доступ',
                    onPressed: () => onRevoke(grant),
                  ),
        ],
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
    this.faded = false,
  });

  final String? photoUrl;
  final String displayName;
  final bool faded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPhoto = photoUrl != null && photoUrl!.isNotEmpty;
    final initials = _initialsOf(displayName);
    final opacity = faded ? 0.55 : 1.0;
    return Opacity(
      opacity: opacity,
      child: CircleAvatar(
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

class _EmptyOutgoingState extends StatelessWidget {
  const _EmptyOutgoingState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          Icon(
            Icons.key_off_rounded,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            'Никому не выдано прав',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Когда вы разрешите кому-то редактировать, объединять или '
            'удалять карточку, выписанные права появятся здесь.',
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
