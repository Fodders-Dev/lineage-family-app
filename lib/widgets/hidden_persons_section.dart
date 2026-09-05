// Ship FE7 (2026-05-26): hidden-persons management section для FE2
// семя details screen. Lists caller's personally-hidden persons +
// per-row «Показать снова» action.
//
// Privacy invariant (per SHARED-TREE-PROPOSAL §3.3): hide affects
// ТОЛЬКО caller's view. Other семя members continue seeing person.
// Cross-семя: twin person в другой семе НЕ auto-hidden — каждая
// семья имеет собственный hide list per member.
//
// Resolves person names via service.getPersonById(treeId, personId)
// — этот endpoint НЕ filters per hideFilterPersonIds (per backend
// tree-routes design), поэтому caller может resolve names даже
// для собственноскрытых persons.

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/semya_capable_family_tree_service.dart';
import '../backend/models/semya.dart';
import '../models/family_person.dart';
import '../utils/photo_url.dart';

class HiddenPersonsSection extends StatefulWidget {
  const HiddenPersonsSection({
    super.key,
    required this.semyaId,
    required this.treeId,
    this.serviceOverride,
    this.familyServiceOverride,
  });

  final String semyaId;
  final String treeId;

  /// Test seam — semya operations.
  final SemyaCapableFamilyTreeService? serviceOverride;

  /// Test seam — name resolution via family-tree service. Production
  /// uses GetIt-resolved FamilyTreeServiceInterface.getPersonById.
  final FamilyTreeServiceInterface? familyServiceOverride;

  @override
  State<HiddenPersonsSection> createState() => _HiddenPersonsSectionState();
}

class _HiddenPersonsSectionState extends State<HiddenPersonsSection> {
  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _errorMessage;
  List<_HiddenPersonRow> _rows = const <_HiddenPersonRow>[];
  String? _unhidingPersonId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  SemyaCapableFamilyTreeService? _resolveSemyaService() {
    if (widget.serviceOverride != null) return widget.serviceOverride;
    if (!GetIt.I.isRegistered<FamilyTreeServiceInterface>()) return null;
    final service = GetIt.I<FamilyTreeServiceInterface>();
    if (service is SemyaCapableFamilyTreeService) {
      return service as SemyaCapableFamilyTreeService;
    }
    return null;
  }

  FamilyTreeServiceInterface? _resolveFamilyService() {
    if (widget.familyServiceOverride != null) {
      return widget.familyServiceOverride;
    }
    if (!GetIt.I.isRegistered<FamilyTreeServiceInterface>()) return null;
    return GetIt.I<FamilyTreeServiceInterface>();
  }

  Future<void> _load() async {
    final semyaSvc = _resolveSemyaService();
    final familySvc = _resolveFamilyService();
    if (semyaSvc == null || familySvc == null) {
      setState(() {
        _hasLoaded = true;
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final ids = await semyaSvc.listHiddenPersonIds(semyaId: widget.semyaId);
      if (ids.isEmpty) {
        if (!mounted) return;
        setState(() {
          _rows = const <_HiddenPersonRow>[];
          _isLoading = false;
          _hasLoaded = true;
        });
        return;
      }
      // Resolve names в parallel. getPersonById НЕ filtered по hide
      // list (backend filters только tree-routes GET persons), так
      // hidden persons resolve normally.
      final results = await Future.wait(
        ids.map((id) => _safeFetchPerson(familySvc, widget.treeId, id)),
      );
      final rows = <_HiddenPersonRow>[];
      for (var i = 0; i < ids.length; i++) {
        final id = ids[i];
        final person = results[i];
        rows.add(_HiddenPersonRow(id: id, person: person));
      }
      if (!mounted) return;
      setState(() {
        _rows = rows;
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

  Future<FamilyPerson?> _safeFetchPerson(
    FamilyTreeServiceInterface service,
    String treeId,
    String personId,
  ) async {
    try {
      return await service.getPersonById(treeId, personId);
    } catch (_) {
      // Name resolution best-effort. Если person удалён либо
      // network blip — fall back на «Скрытый родственник».
      return null;
    }
  }

  Future<void> _unhide(_HiddenPersonRow row) async {
    final service = _resolveSemyaService();
    if (service == null) return;
    setState(() {
      _unhidingPersonId = row.id;
    });
    try {
      await service.updateHideFilter(
        semyaId: widget.semyaId,
        removePersonIds: [row.id],
      );
      if (!mounted) return;
      setState(() {
        _rows = _rows.where((r) => r.id != row.id).toList(growable: false);
        _unhidingPersonId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Снова видно')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _unhidingPersonId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_describeError(error))),
      );
    }
  }

  String _describeError(Object error) {
    if (error is SemyaError) return error.message;
    return 'Не удалось загрузить скрытых';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
          child: Row(
            children: [
              Icon(
                Icons.visibility_off_outlined,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                'Скрытые от меня',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        _buildBody(context),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading && !_hasLoaded) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }
    if (_errorMessage != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _errorMessage!,
                key: const Key('hidden-persons-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            TextButton.icon(
              key: const Key('hidden-persons-retry'),
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Повторить'),
            ),
          ],
        ),
      );
    }
    if (_rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: Text(
          'Никого не скрыто. Чтобы скрыть родственника от себя, '
          'нажмите на его карточку в дереве и выберите «Скрыть от меня».',
          key: Key('hidden-persons-empty'),
        ),
      );
    }
    return Column(
      children: _rows.map(_buildRow).toList(growable: false),
    );
  }

  Widget _buildRow(_HiddenPersonRow row) {
    final theme = Theme.of(context);
    final name = row.person?.name.trim().isNotEmpty == true
        ? row.person!.name
        : 'Скрытый родственник';
    final photo = normalizePhotoUrl(row.person?.photoUrl);
    final image = buildAvatarImageProvider(photo);
    final unhiding = _unhidingPersonId == row.id;
    return ListTile(
      key: Key('hidden-person-row-${row.id}'),
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.16),
        foregroundImage: image,
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: TextButton.icon(
        key: Key('hidden-person-unhide-${row.id}'),
        onPressed: unhiding ? null : () => _unhide(row),
        icon: unhiding
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.visibility_outlined, size: 18),
        label: const Text('Показывать'),
      ),
    );
  }
}

class _HiddenPersonRow {
  const _HiddenPersonRow({required this.id, required this.person});

  final String id;
  final FamilyPerson? person;
}
