// Phase E2b: «Новая встреча» composer. Reuses the post-composer audience
// widgets (AudiencePicker for circles, cross-branch FilterChips, the
// PersonMultiPickerSheet for branch scope) so the gathering audience model
// (circleId / scopeType / anchorPersonIds / branchIds) matches posts. The
// post-specific extras (presets, public toggle, media) are dropped — a
// gathering has no media and is always within-audience.
//
// Event fields: title (required), startAt date+time (required), optional
// endAt, all-day toggle, place, description.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../backend/interfaces/circle_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/gathering_service_interface.dart';
import '../models/circle.dart';
import '../models/family_person.dart';
import '../models/family_tree.dart';
import '../models/post.dart' show TreeContentScopeType;
import '../providers/tree_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/audience_picker.dart';
import '../widgets/person_multi_picker_sheet.dart';
import '../widgets/profile_redesign.dart' show PillButton;

class CreateGatheringScreen extends StatefulWidget {
  const CreateGatheringScreen({
    super.key,
    this.serviceOverride,
    this.treeServiceOverride,
    this.circleServiceOverride,
    this.treeId,
    this.initialStartAt,
  });

  /// Test seams — production resolves these via GetIt / TreeProvider.
  final GatheringServiceInterface? serviceOverride;
  final FamilyTreeServiceInterface? treeServiceOverride;
  final CircleServiceInterface? circleServiceOverride;
  final String? treeId;
  final DateTime? initialStartAt;

  @override
  State<CreateGatheringScreen> createState() => _CreateGatheringScreenState();
}

class _CreateGatheringScreenState extends State<CreateGatheringScreen> {
  final _titleController = TextEditingController();
  final _placeController = TextEditingController();
  final _descriptionController = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  static const int _maxImages = 5;
  List<XFile> _images = <XFile>[];

  late final GatheringServiceInterface _gatheringService =
      widget.serviceOverride ?? GetIt.I<GatheringServiceInterface>();

  String? _treeId;
  bool _isLoading = false;

  DateTime? _startAt;
  DateTime? _endAt;
  bool _isAllDay = false;

  // Audience (mirrors the post composer's four fields).
  TreeContentScopeType _scopeType = TreeContentScopeType.wholeTree;
  String? _selectedCircleId;
  List<FamilyCircle> _audienceCircles = const [];
  bool _isLoadingCircles = false;
  bool _circlesUnavailable = false;
  List<FamilyTree> _otherUserTrees = const [];
  final Set<String> _additionalBranchIds = <String>{};
  List<FamilyPerson> _availablePeople = const [];
  final Set<String> _selectedBranchPersonIds = <String>{};

  FamilyTreeServiceInterface? get _treeService =>
      widget.treeServiceOverride ??
      (GetIt.I.isRegistered<FamilyTreeServiceInterface>()
          ? GetIt.I<FamilyTreeServiceInterface>()
          : null);

  CircleServiceInterface? get _circleService =>
      widget.circleServiceOverride ??
      (GetIt.I.isRegistered<CircleServiceInterface>()
          ? GetIt.I<CircleServiceInterface>()
          : null);

  @override
  void initState() {
    super.initState();
    _startAt = widget.initialStartAt;
    _treeId = widget.treeId;
    if (_treeId == null) {
      try {
        _treeId =
            Provider.of<TreeProvider>(context, listen: false).selectedTreeId;
      } catch (_) {
        _treeId = null;
      }
    }
    _loadAudienceCircles();
    _loadBranchCandidates();
    _loadOtherUserTrees();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _placeController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _loadAudienceCircles() async {
    final treeId = _treeId;
    final circleService = _circleService;
    if (treeId == null || circleService == null) return;
    setState(() => _isLoadingCircles = true);
    try {
      final circles = await circleService.getCircles(treeId);
      if (!mounted) return;
      setState(() {
        _audienceCircles = circles;
        _selectedCircleId = _resolveSelectedCircleId(circles);
        _circlesUnavailable = false;
      });
    } catch (_) {
      if (mounted) setState(() => _circlesUnavailable = true);
    } finally {
      if (mounted) setState(() => _isLoadingCircles = false);
    }
  }

  String? _resolveSelectedCircleId(List<FamilyCircle> circles) {
    final current = _selectedCircleId;
    if (current != null && circles.any((c) => c.id == current)) return current;
    for (final circle in circles) {
      if (circle.isAllTree) return circle.id;
    }
    return circles.isEmpty ? null : circles.first.id;
  }

  Future<void> _loadBranchCandidates() async {
    final treeId = _treeId;
    final treeService = _treeService;
    if (treeId == null || treeService == null) return;
    try {
      final people = await treeService.getRelatives(treeId);
      if (!mounted) return;
      final sorted = List<FamilyPerson>.from(people)
        ..sort((a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
      setState(() => _availablePeople = sorted);
    } catch (_) {
      // Best-effort — the branch picker just stays empty.
    }
  }

  Future<void> _loadOtherUserTrees() async {
    final treeId = _treeId;
    final treeService = _treeService;
    if (treeId == null || treeService == null) return;
    try {
      final trees = await treeService.getUserTrees();
      if (!mounted) return;
      setState(() {
        _otherUserTrees =
            trees.where((t) => t.id != treeId).toList(growable: false);
      });
    } catch (_) {
      // Best-effort — cross-branch section stays hidden.
    }
  }

  // Плотность (чанк 24): «дата/время события — одна строка из двух
  // полей» — было два последовательных пикера за один тап (сперва
  // дата, потом время) на ОДНОМ ListTile. Разделены на независимые
  // дата-поле и время-поле бок о бок, как того требует спека; каждое
  // трогает только свою часть DateTime, вторая сохраняется.
  Future<void> _pickStartDate() async {
    final base = _startAt ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    setState(() {
      _startAt = DateTime(date.year, date.month, date.day, base.hour, base.minute);
    });
  }

  Future<void> _pickStartTime() async {
    final base = _startAt ?? DateTime.now();
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null || !mounted) return;
    setState(() {
      _startAt =
          DateTime(base.year, base.month, base.day, time.hour, time.minute);
    });
  }

  Future<void> _pickEndDate() async {
    final base = _endAt ?? _startAt ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    setState(() {
      _endAt = DateTime(date.year, date.month, date.day, base.hour, base.minute);
    });
  }

  Future<void> _pickEndTime() async {
    final base = _endAt ?? _startAt ?? DateTime.now();
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null || !mounted) return;
    setState(() {
      _endAt =
          DateTime(base.year, base.month, base.day, time.hour, time.minute);
    });
  }

  String _formatDate(DateTime value) => DateFormat('d MMMM y', 'ru').format(value);
  String _formatTime(DateTime value) => DateFormat('HH:mm', 'ru').format(value);

  Future<void> _pickImages() async {
    try {
      final picked = await _picker.pickMultiImage(
        imageQuality: 80,
        maxWidth: 1080,
      );
      if (picked.isEmpty || !mounted) return;
      final willTrim = _images.length + picked.length > _maxImages;
      setState(() {
        _images = <XFile>[..._images, ...picked].take(_maxImages).toList();
      });
      if (willTrim) _showMessage('Можно прикрепить не более $_maxImages фото.');
    } catch (_) {
      if (mounted) _showMessage('Не удалось выбрать фото.');
    }
  }

  void _removeImage(int index) {
    setState(() {
      _images = <XFile>[..._images]..removeAt(index);
    });
  }

  Future<void> _create() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      _showMessage('Укажите название встречи');
      return;
    }
    if (_startAt == null) {
      _showMessage('Укажите дату и время встречи');
      return;
    }
    final treeId = _treeId;
    if (treeId == null) {
      _showMessage('Сначала выберите дерево на главной');
      return;
    }
    if (_scopeType == TreeContentScopeType.branches &&
        _selectedBranchPersonIds.isEmpty) {
      _showMessage('Выберите хотя бы одну ветку');
      return;
    }

    setState(() => _isLoading = true);
    try {
      final branchIdsForRequest = _additionalBranchIds.isEmpty
          ? null
          : <String>{treeId, ..._additionalBranchIds}.toList();
      final description = _descriptionController.text.trim();
      final place = _placeController.text.trim();
      await _gatheringService.createGathering(
        treeId: treeId,
        title: title,
        description: description.isEmpty ? null : description,
        startAt: _startAt!,
        endAt: _endAt,
        isAllDay: _isAllDay,
        place: place.isEmpty ? null : place,
        images: _images,
        scopeType: _scopeType,
        anchorPersonIds: _selectedBranchPersonIds.toList(),
        circleId: _selectedCircleId,
        branchIds: branchIdsForRequest,
      );
      if (mounted) {
        _showMessage('Встреча создана');
        context.pop(true);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showMessage('Не удалось создать встречу. Попробуйте ещё раз.');
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    // Плотность (чанк 24): заголовок только в AppBar, без hero и без
    // action-кнопки «Создать» там (было: TextButton в actions — единственный
    // способ отправить форму, экран без явного CTA). Главное действие —
    // CTA 52dp внизу формы, как в CompleteProfileScreen (чанк 21) /
    // AuthScreen (чанк 18).
    return Scaffold(
      appBar: AppBar(title: const Text('Новая встреча')),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            tokens.space12,
            4,
            tokens.space12,
            12 + MediaQuery.of(context).viewPadding.bottom,
          ),
          children: [
            _FieldLabel(label: 'Название встречи'),
            const SizedBox(height: 4),
            _FormField(
              key: const Key('gathering-title-field'),
              controller: _titleController,
              hint: 'Например, шашлыки на даче',
              textCapitalization: TextCapitalization.sentences,
            ),
            // Плотность (чанк 24): межсекционные зазоры 10 (не 14) —
            // «Кого зовём?» тянет AudiencePicker (виджет вне области этого
            // чанка), который сам по себе держит ~106dp даже без кругов;
            // 10 вместо 14 на каждом стыке — необходимый компромисс ради
            // «CTA формы ≤800dp на пустой форме» (жёсткий DoD чанка 24).
            const SizedBox(height: 10),
            _buildDateTimeSection(theme, tokens),
            const SizedBox(height: 10),
            _FieldLabel(label: 'Место (необязательно)'),
            const SizedBox(height: 4),
            _FormField(
              key: const Key('gathering-place-field'),
              controller: _placeController,
              hint: 'Где встречаемся',
              icon: Icons.place_outlined,
            ),
            const SizedBox(height: 10),
            _FieldLabel(label: 'Описание (необязательно)'),
            const SizedBox(height: 4),
            _FormField(
              key: const Key('gathering-description-field'),
              controller: _descriptionController,
              // Короткая подсказка — длинная («…что взять с собой»)
              // переносилась на несколько строк под fallback-шрифтом
              // тестового harness'а шире Manrope и раздувала пустое поле
              // до высоты как у maxLines, «съедая» эффект minLines.
              hint: 'Детали для гостей',
              textCapitalization: TextCapitalization.sentences,
              minLines: 2,
              maxLines: 8,
            ),
            const SizedBox(height: 10),
            _buildMediaSection(theme, tokens),
            const SizedBox(height: 8),
            _buildAudienceSection(theme, tokens),
            const SizedBox(height: 8),
            PillButton(
              key: const Key('gathering-submit'),
              label: _isLoading ? 'Создаём…' : 'Создать встречу',
              icon: Icons.event_available_outlined,
              expanded: true,
              height: 52,
              onPressed: _isLoading ? null : _create,
            ),
          ],
        ),
      ),
    );
  }

  // Плотность (чанк 24): «дата/время события — одна строка из двух
  // полей» — было два ListTile (Material-стандарт ~56–72dp каждый, с
  // leading-иконкой + title + subtitle) на дату и на время внутри
  // одного тапа. Теперь дата и время — соседние поля 50dp в одной
  // строке (независимые пикеры), «Конец» — компактная affordance-строка
  // 44dp, пока не задан, и такая же строка из двух полей + крестик,
  // когда задан.
  Widget _buildDateTimeSection(ThemeData theme, RodnyaDesignTokens tokens) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: 'Когда'),
        const SizedBox(height: 6),
        // Плотность (чанк 24): SwitchListTile держит ~56dp даже с
        // contentPadding:zero (Material ListTile добавляет свой
        // вертикальный inset независимо) — голый Row с адаптивным
        // Switch укладывается в тач-цель Switch (≥44dp) без лишнего.
        Row(
          children: [
            Expanded(
              child: Text(
                'Весь день',
                style: AppTheme.sans(
                  color: tokens.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Switch.adaptive(
              key: const Key('gathering-allday-switch'),
              value: _isAllDay,
              onChanged: (value) => setState(() => _isAllDay = value),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _FieldLabel(label: 'Начало'),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              flex: _isAllDay ? 1 : 3,
              child: _DateTimeChip(
                key: const Key('gathering-start-date'),
                icon: Icons.event_outlined,
                label: _startAt == null ? 'Дата' : _formatDate(_startAt!),
                onTap: _pickStartDate,
              ),
            ),
            if (!_isAllDay) ...[
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _DateTimeChip(
                  key: const Key('gathering-start-time'),
                  icon: Icons.schedule_outlined,
                  label: _startAt == null ? 'Время' : _formatTime(_startAt!),
                  onTap: _pickStartTime,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 10),
        _buildEndRow(tokens),
      ],
    );
  }

  Widget _buildEndRow(RodnyaDesignTokens tokens) {
    if (_endAt == null) {
      return InkWell(
        key: const Key('gathering-end-add'),
        borderRadius: BorderRadius.circular(14),
        onTap: _pickEndDate,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 18, color: tokens.accent),
              const SizedBox(width: 6),
              Text(
                'Указать окончание',
                style: AppTheme.sans(
                  color: tokens.accent,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(label: 'Конец'),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              flex: _isAllDay ? 1 : 3,
              child: _DateTimeChip(
                key: const Key('gathering-end-date'),
                icon: Icons.event_available_outlined,
                label: _formatDate(_endAt!),
                onTap: _pickEndDate,
              ),
            ),
            if (!_isAllDay) ...[
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _DateTimeChip(
                  key: const Key('gathering-end-time'),
                  icon: Icons.schedule_outlined,
                  label: _formatTime(_endAt!),
                  onTap: _pickEndTime,
                ),
              ),
            ],
            const SizedBox(width: 4),
            IconButton(
              key: const Key('gathering-end-clear'),
              tooltip: 'Убрать окончание',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              onPressed: () => setState(() => _endAt = null),
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMediaSection(ThemeData theme, RodnyaDesignTokens tokens) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: _SectionHeader(title: 'Фото (необязательно)')),
            TextButton.icon(
              key: const Key('gathering-add-photo'),
              onPressed: _images.length >= _maxImages ? null : _pickImages,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: Text(
                _images.isEmpty ? 'Добавить' : '${_images.length}/$_maxImages',
              ),
            ),
          ],
        ),
        if (_images.isNotEmpty) ...[
          SizedBox(height: tokens.space8),
          SizedBox(
            height: 96,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _images.length,
              separatorBuilder: (_, __) => SizedBox(width: tokens.space8),
              itemBuilder: (_, i) => _buildImageThumb(theme, tokens, i),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildImageThumb(
    ThemeData theme,
    RodnyaDesignTokens tokens,
    int index,
  ) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(tokens.radiusSm),
          child: SizedBox(
            width: 96,
            height: 96,
            child: FutureBuilder<Uint8List>(
              future: _images[index].readAsBytes(),
              builder: (_, snapshot) {
                if (snapshot.hasData) {
                  return Image.memory(snapshot.data!, fit: BoxFit.cover);
                }
                return Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                );
              },
            ),
          ),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: GestureDetector(
            key: Key('gathering-remove-photo-$index'),
            onTap: () => _removeImage(index),
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(2),
              child: const Icon(Icons.close, color: Colors.white, size: 16),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAudienceSection(ThemeData theme, RodnyaDesignTokens tokens) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: 'Кого зовём?'),
        SizedBox(height: tokens.space8),
        AudiencePicker(
          circles: _audienceCircles,
          selectedCircleId: _selectedCircleId,
          onChanged: (circleId) {
            setState(() {
              _selectedCircleId = circleId;
              _selectedBranchPersonIds.clear();
              _scopeType = TreeContentScopeType.wholeTree;
            });
          },
          isLoading: _isLoadingCircles,
          isUnavailable: _circlesUnavailable,
          onRetry: _loadAudienceCircles,
        ),
        if (_availablePeople.isNotEmpty) ...[
          SizedBox(height: tokens.space12),
          _buildBranchPickerTile(theme, tokens),
        ],
        if (_otherUserTrees.isNotEmpty) ...[
          SizedBox(height: tokens.space12),
          _buildCrossBranchSection(theme, tokens),
        ],
      ],
    );
  }

  Widget _buildBranchPickerTile(ThemeData theme, RodnyaDesignTokens tokens) {
    final count = _selectedBranchPersonIds.length;
    return ListTile(
      key: const Key('gathering-branch-tile'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.alt_route_outlined),
      title: Text(count == 0 ? 'Отдельные ветки' : 'Выбрано: $count'),
      subtitle: const Text('Сузить до выбранных людей и их веток'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final result = await PersonMultiPickerSheet.show(
          context,
          people: _availablePeople,
          initialSelection: Set<String>.from(_selectedBranchPersonIds),
          title: 'Отдельные ветки',
        );
        if (result == null || !mounted) return;
        setState(() {
          _selectedCircleId = null;
          _selectedBranchPersonIds
            ..clear()
            ..addAll(result);
          _scopeType = _selectedBranchPersonIds.isEmpty
              ? TreeContentScopeType.wholeTree
              : TreeContentScopeType.branches;
        });
      },
    );
  }

  Widget _buildCrossBranchSection(ThemeData theme, RodnyaDesignTokens tokens) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(label: 'Позвать также в'),
        SizedBox(height: tokens.space8),
        Wrap(
          spacing: tokens.space8,
          runSpacing: tokens.space8,
          children: _otherUserTrees.map((tree) {
            final selected = _additionalBranchIds.contains(tree.id);
            return FilterChip(
              label: Text(tree.name),
              selected: selected,
              onSelected: (next) {
                setState(() {
                  if (next) {
                    _additionalBranchIds.add(tree.id);
                  } else {
                    _additionalBranchIds.remove(tree.id);
                  }
                });
              },
            );
          }).toList(),
        ),
      ],
    );
  }
}

// Плотность (чанк 24): те же приёмы, что у AuthScreen (чанк 18) /
// CompleteProfileScreen (чанк 21) — подпись 13sp uppercase над полем
// 50dp вместо плавающего Material-лейбла (который тянет поле к
// ~58–64dp), заголовок секции 15sp uppercase без собственной карточки.

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        RodnyaDesignTokens.light;
    return Text(
      title.toUpperCase(),
      style: AppTheme.sans(
        color: tokens.ink,
        fontSize: 15,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
        height: 1.15,
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        RodnyaDesignTokens.light;
    return Text(
      label.toUpperCase(),
      style: AppTheme.sans(
        color: tokens.inkMuted,
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
        height: 1.2,
      ),
    );
  }
}

/// 50dp text field — hint-only (no floating Material label, that lives
/// above as [_FieldLabel]) so the field height stays fixed regardless of
/// focus/fill state, matching the reference forms (чанки 18/21).
class _FormField extends StatelessWidget {
  const _FormField({
    super.key,
    required this.controller,
    this.hint,
    this.icon,
    this.textCapitalization = TextCapitalization.none,
    this.minLines = 1,
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final String? hint;
  final IconData? icon;
  final TextCapitalization textCapitalization;
  final int minLines;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        RodnyaDesignTokens.light;
    return TextField(
      controller: controller,
      textCapitalization: textCapitalization,
      minLines: minLines,
      maxLines: maxLines,
      style: AppTheme.sans(
        color: tokens.ink,
        fontSize: AppTheme.formInputFontSize,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: icon == null ? null : Icon(icon, size: 18, color: tokens.accent),
        hintStyle: AppTheme.sans(
          color: tokens.inkMuted,
          fontSize: AppTheme.formInputFontSize,
          fontWeight: FontWeight.w500,
          letterSpacing: 0,
        ),
        filled: true,
        fillColor: tokens.bgTintWarm,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: tokens.surfaceLine),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: tokens.surfaceLine),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: tokens.accent, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }
}

/// One 50dp tappable date/time chip — used side by side (date+time) in
/// a single row, per the density spec («дата/время события — одна
/// строка из двух полей»).
class _DateTimeChip extends StatelessWidget {
  const _DateTimeChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        RodnyaDesignTokens.light;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: tokens.bgTintWarm,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: tokens.surfaceLine),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: tokens.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.sans(
                  color: tokens.ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
