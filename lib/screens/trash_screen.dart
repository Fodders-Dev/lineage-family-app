// Ship Q4a frontend (2026-05-28, Ship 31): «Корзина» screen — cross-
// семя view of caller's soft-deleted persons + posts. Two tabs:
//   • Родственники (persons)
//   • Посты (posts author=caller)
//
// Per-row UI:
//   • Avatar/thumbnail + display name либо body preview
//   • «Удалена N дней назад» + «Осталось N дней до удаления»
//   • [Восстановить] action
//   • [Удалить навсегда] action — disabled с tooltip пока 3h floor
//     не пройден (earliestHardDelete > now)
//
// Empty state: «Корзина пуста — удалённые элементы будут здесь 30
// дней перед окончательным удалением.»
//
// Architecture: stateful screen owns loading + actions для both tabs.
// Backend gives full snapshot rows — no extra round-trips для names.

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/semya_capable_family_tree_service.dart';
import '../backend/models/deleted_person.dart';
import '../backend/models/deleted_post.dart';
import '../backend/models/semya.dart';
import '../utils/photo_url.dart';
import '../widgets/deleted_item_row.dart';
import '../widgets/safe_delete_confirmation_dialog.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key, this.serviceOverride});

  /// Test seam — production resolves via GetIt.
  final SemyaCapableFamilyTreeService? serviceOverride;

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  bool _isLoading = false;
  bool _hasLoaded = false;
  List<DeletedPerson> _persons = const <DeletedPerson>[];
  List<DeletedPost> _posts = const <DeletedPost>[];
  String? _errorMessage;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
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
      final results = await Future.wait([
        svc.listMyDeletedPersons(),
        svc.listMyDeletedPosts(),
      ]);
      if (!mounted) return;
      setState(() {
        _persons = results[0] as List<DeletedPerson>;
        _posts = results[1] as List<DeletedPost>;
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

  Future<void> _restorePerson(DeletedPerson row) async {
    final svc = _resolveService();
    if (svc == null) return;
    setState(() => _busyId = row.id);
    try {
      await svc.restoreDeletedPerson(row.id);
      if (!mounted) return;
      setState(() {
        _persons = _persons.where((p) => p.id != row.id).toList(growable: false);
        _busyId = null;
      });
      _snack('${row.displayName} восстановлен${_isFemale(row) ? 'а' : ''}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _busyId = null);
      _snack(_describeError(error));
    }
  }

  Future<void> _restorePost(DeletedPost row) async {
    final svc = _resolveService();
    if (svc == null) return;
    setState(() => _busyId = row.id);
    try {
      await svc.restoreDeletedPost(row.id);
      if (!mounted) return;
      setState(() {
        _posts = _posts.where((p) => p.id != row.id).toList(growable: false);
        _busyId = null;
      });
      _snack('Публикация восстановлена');
    } catch (error) {
      if (!mounted) return;
      setState(() => _busyId = null);
      _snack(_describeError(error));
    }
  }

  Future<void> _permanentlyDeletePerson(DeletedPerson row) async {
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
        _persons = _persons.where((p) => p.id != row.id).toList(growable: false);
        _busyId = null;
      });
      _snack('Удалено навсегда');
    } catch (error) {
      if (!mounted) return;
      setState(() => _busyId = null);
      _snack(_describeError(error));
    }
  }

  Future<void> _permanentlyDeletePost(DeletedPost row) async {
    final confirmed = await showSafeDeleteConfirmation(
      context,
      title: 'Удалить публикацию навсегда?',
      body: 'Это нельзя отменить. Публикация удалится без '
          'возможности восстановления.',
      confirmLabel: 'Удалить навсегда',
    );
    if (!confirmed || !mounted) return;
    final svc = _resolveService();
    if (svc == null) return;
    setState(() => _busyId = row.id);
    try {
      await svc.permanentlyDeletePost(row.id);
      if (!mounted) return;
      setState(() {
        _posts = _posts.where((p) => p.id != row.id).toList(growable: false);
        _busyId = null;
      });
      _snack('Удалено навсегда');
    } catch (error) {
      if (!mounted) return;
      setState(() => _busyId = null);
      _snack(_describeError(error));
    }
  }

  bool _isFemale(DeletedPerson row) =>
      row.snapshot['gender'] == 'female';

  String _describeError(Object error) {
    if (error is SemyaError) return error.message;
    return 'Не удалось выполнить действие';
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Корзина'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Родственники'),
            Tab(text: 'Посты'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildPersonsTab(),
          _buildPostsTab(),
        ],
      ),
    );
  }

  Widget _buildPersonsTab() {
    if (_isLoading && !_hasLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) return _buildError();
    if (_persons.isEmpty) return _buildEmpty();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _persons.length,
        separatorBuilder: (_, __) => _rowDivider(context),
        itemBuilder: (_, i) => _buildPersonRow(_persons[i]),
      ),
    );
  }

  Widget _buildPostsTab() {
    if (_isLoading && !_hasLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) return _buildError();
    if (_posts.isEmpty) return _buildEmpty();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _posts.length,
        separatorBuilder: (_, __) => _rowDivider(context),
        itemBuilder: (_, i) => _buildPostRow(_posts[i]),
      ),
    );
  }

  // Hairline вместо непрозрачной Divider() по умолчанию — тот же
  // разделитель, что в «Заблокированных»/«Активных сеансах».
  Widget _rowDivider(BuildContext context) => Divider(
        height: 1,
        thickness: 0.7,
        indent: 72,
        color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6),
      );

  Widget _buildPersonRow(DeletedPerson row) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final image = buildAvatarImageProvider(normalizePhotoUrl(row.photoUrl));
    return DeletedItemRow(
      key: Key('trash-person-${row.id}'),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.16),
        foregroundImage: image,
        child: Text(
          row.displayName.isNotEmpty
              ? row.displayName[0].toUpperCase()
              : '?',
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
      onRestore: () => _restorePerson(row),
      onPurge: () => _permanentlyDeletePerson(row),
      restoreKey: Key('trash-person-restore-${row.id}'),
      purgeKey: Key('trash-person-purge-${row.id}'),
    );
  }

  Widget _buildPostRow(DeletedPost row) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final thumb = buildAvatarImageProvider(
      normalizePhotoUrl(row.firstImageUrl),
    );
    return DeletedItemRow(
      key: Key('trash-post-${row.id}'),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        foregroundImage: thumb,
        child: thumb == null
            ? Icon(
                Icons.article_outlined,
                color: theme.colorScheme.onSurfaceVariant,
              )
            : null,
      ),
      title: row.bodyPreview,
      titleMaxLines: 2,
      isThreeLine: row.bodyPreview.length > 40,
      daysLeft: row.daysUntilHardDelete(now),
      floorPassed: row.isFloorPassed(now),
      busy: _busyId == row.id,
      onRestore: () => _restorePost(row),
      onPurge: () => _permanentlyDeletePost(row),
      restoreKey: Key('trash-post-restore-${row.id}'),
      purgeKey: Key('trash-post-purge-${row.id}'),
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
              'Корзина пуста',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Удалённые элементы будут здесь 30 дней '
              'перед окончательным удалением.',
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
