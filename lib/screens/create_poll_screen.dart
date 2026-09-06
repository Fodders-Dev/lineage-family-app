// Phase E5c: «Новый опрос» composer. Reuses the gathering composer's
// audience widgets (AudiencePicker / PersonMultiPickerSheet / cross-branch)
// and image picker; swaps the event fields for a question + a dynamic
// options list (min 2) + a «несколько вариантов» toggle + optional closesAt.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../backend/interfaces/circle_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/poll_service_interface.dart';
import '../models/circle.dart';
import '../models/family_person.dart';
import '../models/family_tree.dart';
import '../models/post.dart' show TreeContentScopeType;
import '../providers/tree_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/audience_picker.dart';
import '../widgets/person_multi_picker_sheet.dart';
import '../widgets/profile_redesign.dart' show PillButton;

class CreatePollScreen extends StatefulWidget {
  const CreatePollScreen({
    super.key,
    this.serviceOverride,
    this.treeServiceOverride,
    this.circleServiceOverride,
    this.treeId,
  });

  /// Test seams — production resolves these via GetIt / TreeProvider.
  final PollServiceInterface? serviceOverride;
  final FamilyTreeServiceInterface? treeServiceOverride;
  final CircleServiceInterface? circleServiceOverride;
  final String? treeId;

  @override
  State<CreatePollScreen> createState() => _CreatePollScreenState();
}

class _CreatePollScreenState extends State<CreatePollScreen> {
  final _questionController = TextEditingController();
  final List<TextEditingController> _optionControllers = [
    TextEditingController(),
    TextEditingController(),
  ];
  final ImagePicker _picker = ImagePicker();

  static const int _maxImages = 5;
  static const int _maxOptions = 10;
  List<XFile> _images = <XFile>[];

  bool _allowMultiple = false;
  DateTime? _closesAt;

  late final PollServiceInterface _pollService =
      widget.serviceOverride ?? GetIt.I<PollServiceInterface>();

  String? _treeId;
  bool _isLoading = false;

  // Audience (mirrors the gathering composer's four fields).
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
    _questionController.dispose();
    for (final c in _optionControllers) {
      c.dispose();
    }
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

  void _addOption() {
    if (_optionControllers.length >= _maxOptions) return;
    setState(() => _optionControllers.add(TextEditingController()));
  }

  void _removeOption(int index) {
    if (_optionControllers.length <= 2) return;
    setState(() {
      _optionControllers.removeAt(index).dispose();
    });
  }

  Future<void> _pickClosesAt() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _closesAt ?? DateTime.now().add(const Duration(days: 7)),
      firstDate: DateTime.now(),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    setState(() => _closesAt = DateTime(date.year, date.month, date.day));
  }

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
    final question = _questionController.text.trim();
    if (question.isEmpty) {
      _showMessage('Укажите вопрос опроса');
      return;
    }
    final options = _optionControllers
        .map((c) => c.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    if (options.length < 2) {
      _showMessage('Нужно минимум два варианта ответа');
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
      await _pollService.createPoll(
        treeId: treeId,
        question: question,
        options: options,
        allowMultiple: _allowMultiple,
        closesAt: _closesAt,
        images: _images,
        scopeType: _scopeType,
        anchorPersonIds: _selectedBranchPersonIds.toList(),
        circleId: _selectedCircleId,
        branchIds: branchIdsForRequest,
      );
      if (mounted) {
        _showMessage('Опрос создан');
        context.pop(true);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showMessage('Не удалось создать опрос. Попробуйте ещё раз.');
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

    // Плотность (чанк 24): заголовок только в AppBar, без action-кнопки
    // «Создать» там — было единственным способом отправить форму без
    // явного CTA. Главное действие — CTA 52dp внизу формы (см.
    // CreateGatheringScreen, тот же приём).
    return Scaffold(
      appBar: AppBar(title: const Text('Новый опрос')),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            tokens.space12,
            12,
            tokens.space12,
            12 + MediaQuery.of(context).viewPadding.bottom,
          ),
          children: [
            _FieldLabel(label: 'Вопрос'),
            const SizedBox(height: 4),
            _FormField(
              key: const Key('poll-question-field'),
              controller: _questionController,
              hint: 'Например, когда собираемся?',
              textCapitalization: TextCapitalization.sentences,
              minLines: 1,
              maxLines: 3,
            ),
            const SizedBox(height: 14),
            _buildOptionsSection(theme, tokens),
            const SizedBox(height: 10),
            SwitchListTile.adaptive(
              key: const Key('poll-multiple-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Можно выбрать несколько'),
              value: _allowMultiple,
              onChanged: (value) => setState(() => _allowMultiple = value),
            ),
            const SizedBox(height: 4),
            _buildClosesAtRow(tokens),
            const SizedBox(height: 14),
            _buildMediaSection(theme, tokens),
            const SizedBox(height: 14),
            _buildAudienceSection(theme, tokens),
            const SizedBox(height: 14),
            PillButton(
              key: const Key('poll-submit'),
              label: _isLoading ? 'Создаём…' : 'Создать опрос',
              icon: Icons.bar_chart_rounded,
              expanded: true,
              height: 52,
              onPressed: _isLoading ? null : _create,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClosesAtRow(RodnyaDesignTokens tokens) {
    if (_closesAt == null) {
      return InkWell(
        key: const Key('poll-closes-add'),
        borderRadius: BorderRadius.circular(14),
        onTap: _pickClosesAt,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.schedule_outlined, size: 18, color: tokens.accent),
              const SizedBox(width: 6),
              Text(
                'Закрыть опрос по дате',
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
        _FieldLabel(label: 'Закрыть опрос'),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: _DateTimeChip(
                key: const Key('poll-closes-tile'),
                icon: Icons.schedule_outlined,
                label: DateFormat('d MMMM y', 'ru').format(_closesAt!),
                onTap: _pickClosesAt,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              key: const Key('poll-closes-clear'),
              tooltip: 'Убрать срок',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              onPressed: () => setState(() => _closesAt = null),
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ],
    );
  }

  // Плотность (чанк 24): строки-варианты 50dp (было TextField с
  // isDense:true + плавающим лейблом — высота «плавала» в районе
  // 56–60dp), «+ добавить вариант» — явная тач-цель 44dp.
  Widget _buildOptionsSection(ThemeData theme, RodnyaDesignTokens tokens) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: 'Варианты ответа'),
        const SizedBox(height: 6),
        for (var i = 0; i < _optionControllers.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.space8),
            child: Row(
              children: [
                Expanded(
                  child: _FormField(
                    key: Key('poll-option-$i'),
                    controller: _optionControllers[i],
                    hint: 'Вариант ${i + 1}',
                    textCapitalization: TextCapitalization.sentences,
                  ),
                ),
                IconButton(
                  key: Key('poll-remove-option-$i'),
                  tooltip: 'Удалить вариант',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  onPressed: _optionControllers.length <= 2
                      ? null
                      : () => _removeOption(i),
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                ),
              ],
            ),
          ),
        if (_optionControllers.length < _maxOptions)
          InkWell(
            key: const Key('poll-add-option'),
            borderRadius: BorderRadius.circular(14),
            onTap: _addOption,
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
                    'Добавить вариант',
                    style: AppTheme.sans(
                      color: tokens.accent,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
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
              key: const Key('poll-add-photo'),
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
            key: Key('poll-remove-photo-$index'),
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
        const _SectionHeader(title: 'Кого спрашиваем?'),
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
      key: const Key('poll-branch-tile'),
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
        _FieldLabel(label: 'Спросить также в'),
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

// Плотность (чанк 24): те же приёмы, что у CreateGatheringScreen —
// подпись 13sp uppercase над полем 50dp вместо плавающего
// Material-лейбла, заголовок секции 15sp uppercase без своей карточки.

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

/// 50dp text field — hint-only (no floating Material label; that lives
/// above as [_FieldLabel]) so the field height stays fixed regardless of
/// focus/fill state, matching the reference forms (чанки 18/21).
class _FormField extends StatelessWidget {
  const _FormField({
    super.key,
    required this.controller,
    this.hint,
    this.textCapitalization = TextCapitalization.none,
    this.minLines = 1,
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final String? hint;
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

/// One 50dp tappable date/time chip.
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
