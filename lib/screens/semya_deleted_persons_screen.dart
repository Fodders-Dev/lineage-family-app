// Ship Q4a frontend (2026-05-28, Ship 31b): per-семя «Удалённые
// родственники» screen. Семя-scoped counterpart к global Корзина
// (TrashScreen, Ship 31) — lists soft-deleted persons одной семьи с
// restore + permanent-delete actions.
//
// Reuses Ship 31 building blocks:
//   • DeletedPerson model + listDeletedPersonsForSemya service method
//   • DeletedItemRow shared widget (avatar + days-left + actions + floor)
//   • SafeDeleteConfirmationDialog для destructive purge
//
// Member-only by construction — backend GET /v1/semya/:id/deleted-persons
// requires membership, и entry point (FE2 details section) только
// reachable от members.

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/semya_capable_family_tree_service.dart';
import '../backend/models/deleted_person.dart';
import '../backend/models/semya.dart';
import '../utils/photo_url.dart';
import '../widgets/deleted_item_row.dart';
import '../widgets/safe_delete_confirmation_dialog.dart';

class SemyaDeletedPersonsScreen extends StatefulWidget {
  const SemyaDeletedPersonsScreen({
    super.key,
    required this.semyaId,
    this.semyaName,
    this.serviceOverride,
  });

  final String semyaId;

  /// Optional — shown в AppBar title когда known от caller (FE2 details).
  final String? semyaName;

  /// Test seam — production resolves via GetIt.
  final SemyaCapableFamilyTreeService? serviceOverride;

  @override
  State<SemyaDeletedPersonsScreen> createState() =>
      _SemyaDeletedPersonsScreenState();
}

class _SemyaDeletedPersonsScreenState
    extends State<SemyaDeletedPersonsScreen> {
  bool _isLoading = false;
  bool _hasLoaded = false;
  List<DeletedPerson> _persons = const <DeletedPerson>[];
  String? _errorMessage;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  SemyaCapableFamilyTreeService? _resolveService() {
    if (widget.serviceOverride != null) return widget.serviceOverride;
    if (!GetIt.I.isRegistered<FamilyTreeServiceInterface>()) return null;
    final svc = GetIt.I<FamilyTreeServiceInterface>();
    if (svc is SemyaCapableFamilyTreeService) {
      return svc as SemyaCapableFamilyTreeService;
    }
    return null;
  }

  Future<void> _load() async {
    final svc = _resolveService();
    if (svc == null) {
      setState(() {
        _hasLoaded = true;
        _errorMessage = 'Сервис недоступен';
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final rows = await svc.listDeletedPersonsForSemya(widget.semyaId);
      if (!mounted) return;
      setState(() {
        _persons = rows;
        _isLoading = false;
        _hasLoaded = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _hasLoaded = true;
        _errorMessage = _describeError(error);
      });
    }
  }

  Future<void> _restore(DeletedPerson row) async {
    final svc = _resolveService();
    if (svc == null) return;
    setState(() => _busyId = row.id);
    try {
      await svc.restoreDeletedPerson(row.id);
      if (!mounted) return;
      setState(() {
        _persons =
            _persons.where((p) => p.id != row.id).toList(growable: false);
        _busyId = null;
      });
      _snack('${row.displayName} восстановлен${_isFemale(row) ? 'а' : ''}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _busyId = null);
      _snack(_describeError(error));
    }
  }

  Future<void> _permanentlyDelete(DeletedPerson row) async {
    final confirmed = await showSafeDeleteConfirmation(
      context,
      title: 'Удалить навсегда ${row.displayName}?',
      body: 'Это нельзя отменить. ${row.displayName} удалится '
          'без возможности восстановления.',
      confirmLabel: 'Удалить навсегда',
    );
    if (!confirmed || !mounted) return;
    final svc = _resolveService();
    if (svc == null) return;
    setState(() => _busyId = row.id);
    try {
      await svc.permanentlyDeletePerson(row.id);
      if (!mounted) return;
      setState(() {
        _persons =
            _persons.where((p) => p.id != row.id).toList(growable: false);
        _busyId = null;
      });
      _snack('Удалено навсегда');
    } catch (error) {
      if (!mounted) return;
      setState(() => _busyId = null);
      _snack(_describeError(error));
    }
  }

  bool _isFemale(DeletedPerson row) => row.snapshot['gender'] == 'female';

  String _describeError(Object error) {
    if (error is SemyaError) return error.message;
    return 'Не удалось выполнить действие';
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.semyaName?.trim();
    final title = (name != null && name.isNotEmpty)
        ? 'Удалённые · $name'
        : 'Удалённые родственники';
    return Scaffold(
      appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading && !_hasLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) return _buildError();
    if (_persons.isEmpty) return _buildEmpty();
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _persons.length,
        // Hairline вместо непрозрачной Divider() по умолчанию — тот же
        // разделитель, что в глобальной «Корзине».
        separatorBuilder: (_, __) => Divider(
          height: 1,
          thickness: 0.7,
          indent: 72,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
        itemBuilder: (_, i) => _buildRow(_persons[i]),
      ),
    );
  }

  Widget _buildRow(DeletedPerson row) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final image = buildAvatarImageProvider(normalizePhotoUrl(row.photoUrl));
    return DeletedItemRow(
      key: Key('semya-trash-person-${row.id}'),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.16),
        foregroundImage: image,
        child: Text(
          row.displayName.isNotEmpty ? row.displayName[0].toUpperCase() : '?',
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      title: row.displayName,
      daysLeft: row.daysUntilHardDelete(now),
      floorPassed: row.isFloorPassed(now),
      busy: _busyId == row.id,
      onRestore: () => _restore(row),
      onPurge: () => _permanentlyDelete(row),
      restoreKey: Key('semya-trash-restore-${row.id}'),
      purgeKey: Key('semya-trash-purge-${row.id}'),
    );
  }

  Widget _buildEmpty() {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.delete_outline_rounded,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text(
              'В этой семье нет удалённых родственников',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Удалённые карточки хранятся 30 дней перед '
              'окончательным удалением.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_errorMessage ?? 'Не удалось загрузить'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }
}
