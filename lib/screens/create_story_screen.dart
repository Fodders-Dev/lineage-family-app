import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../utils/user_facing_error.dart';
import '../widgets/attachment_picker_sheet.dart';
import '../widgets/kruzhok_recorder_screen.dart';
import 'package:provider/provider.dart';

import '../backend/interfaces/circle_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/story_service_interface.dart';
import '../models/audience_preset.dart';
import '../models/circle.dart';
import '../models/family_person.dart';
import '../models/post.dart' show TreeContentScopeType;
import '../models/story.dart';
import '../providers/tree_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/audience_picker.dart';
import '../widgets/glass_panel.dart';
import '../widgets/person_multi_picker_sheet.dart';
import '../widgets/story_visuals.dart';

class CreateStoryScreen extends StatefulWidget {
  const CreateStoryScreen({super.key});

  @override
  State<CreateStoryScreen> createState() => _CreateStoryScreenState();
}

class _CreateStoryScreenState extends State<CreateStoryScreen> {
  final StoryServiceInterface _storyService = GetIt.I<StoryServiceInterface>();
  final CircleServiceInterface? _circleService =
      GetIt.I.isRegistered<CircleServiceInterface>()
          ? GetIt.I<CircleServiceInterface>()
          : null;
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _textController = TextEditingController();

  StoryType _storyType = StoryType.text;
  XFile? _selectedMedia;
  String? _currentTreeId;
  String? _currentTreeName;
  String? _selectedCircleId;
  List<FamilyCircle> _audienceCircles = <FamilyCircle>[];
  AudiencePresetsResponse _audiencePresets = AudiencePresetsResponse.empty;
  String? _selectedPresetKey;
  final Set<String> _selectedBranchPersonIds = <String>{};
  TreeContentScopeType _scopeType = TreeContentScopeType.wholeTree;
  List<FamilyPerson> _availablePeople = <FamilyPerson>[];
  bool _isSubmitting = false;
  bool _isLoadingCircles = false;
  bool _circlesUnavailable = false;

  bool get _needsMedia => _storyType != StoryType.text;
  String get _selectedAudienceLabel => _selectedCircle?.name ?? 'Только свои';
  FamilyCircle? get _selectedCircle {
    final selectedId = _selectedCircleId;
    if (selectedId == null) {
      return null;
    }
    for (final circle in _audienceCircles) {
      if (circle.id == selectedId) {
        return circle;
      }
    }
    return null;
  }

  StoryVisualPalette get _palette => storyPaletteForSeed(
        '${_currentTreeId ?? 'story'}:${_storyType.name}:${_textController.text.trim()}',
      );
  String get _storyText => _textController.text.trim().isEmpty
      ? 'Поделитесь моментом'
      : _textController.text.trim();

  @override
  void initState() {
    super.initState();
    final treeProvider = Provider.of<TreeProvider>(context, listen: false);
    _currentTreeId = treeProvider.selectedTreeId;
    _currentTreeName = treeProvider.selectedTreeName;
    _textController.addListener(_handleDraftChanged);
    _loadAudienceCircles();
  }

  @override
  void dispose() {
    _textController
      ..removeListener(_handleDraftChanged)
      ..dispose();
    super.dispose();
  }

  void _handleDraftChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openMediaPicker() async {
    // Big-app pattern: launch a colored-icon picker grid that lets the
    // user choose between gallery (photo), camera (snap now), gallery
    // video, and "snap video now" via the in-app camera plugin —
    // bypasses image_picker's medium-quality default which the user
    // reported as a visible drop on iPhone.
    final choice = await showAttachmentPickerSheet(
      context,
      title: 'ДОБАВИТЬ МЕДИА',
      actions: [
        const AttachmentPickerAction(
          id: 'photo_gallery',
          icon: Icons.photo_library_rounded,
          label: 'Галерея',
          color: Color(0xFFE05A8B),
        ),
        const AttachmentPickerAction(
          id: 'photo_camera',
          icon: Icons.photo_camera_rounded,
          label: 'Снять фото',
          color: Color(0xFF3D8DFF),
        ),
        const AttachmentPickerAction(
          id: 'video_gallery',
          icon: Icons.video_library_rounded,
          label: 'Видео',
          color: Color(0xFFE85A40),
        ),
        // Native camera capture (mobile only — web's <input type=file>
        // can't drive a live preview loop).
        if (!kIsWeb)
          const AttachmentPickerAction(
            id: 'video_camera',
            icon: Icons.video_call_rounded,
            label: 'Снять видео',
            color: Color(0xFF7B5BD6),
          ),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'photo_camera':
        await _takeStoryPhoto();
        return;
      case 'video_gallery':
        await _pickVideo();
        return;
      case 'video_camera':
        await _recordStoryVideo();
        return;
      case 'photo_gallery':
      default:
        await _pickImage();
        return;
    }
  }

  // iPhone захватывает фото в 4032×3024 @ HEIC. Прежние ограничения
  // imageQuality: 85 + maxWidth: 1440 урезали до 1440×1080 @ 85% JPEG —
  // при показе на 9:19.5 фуллскрине это видно как "качество упало"
  // (пользователь так и описал). 1920 ширина = Full HD, 95% — практически
  // визуально-без-потери JPEG. Stories публикуются один раз, размер на
  // диске через серверную обработку всё равно будет нормализован.
  static const int _photoQuality = 95;
  static const double _photoMaxWidth = 1920;

  Future<void> _takeStoryPhoto() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: _photoQuality,
        maxWidth: _photoMaxWidth,
      );
      if (picked == null || !mounted) return;
      setState(() {
        _storyType = StoryType.image;
        _selectedMedia = picked;
      });
    } catch (error) {
      _showError(humanizeError(error, fallback: 'Не удалось сделать фото.'));
    }
  }

  Future<void> _pickImage() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: _photoQuality,
        maxWidth: _photoMaxWidth,
      );
      if (picked == null || !mounted) {
        return;
      }
      setState(() {
        _storyType = StoryType.image;
        _selectedMedia = picked;
      });
    } catch (error) {
      _showError(
          humanizeError(error, fallback: 'Не удалось выбрать изображение.'));
    }
  }

  /// Native-camera-plugin capture path. Bypasses image_picker's
  /// medium-quality default (the source of "качество съемки на айфоне
  /// упало" that the user reported). The recorder writes the file
  /// with a `story_video_*` prefix so any future per-source detection
  /// can branch on it.
  Future<void> _recordStoryVideo() async {
    try {
      final picked = await KruzhokRecorderScreen.showStory(context);
      if (picked == null || !mounted) return;
      setState(() {
        _storyType = StoryType.video;
        _selectedMedia = picked;
      });
    } catch (error) {
      _showError(humanizeError(error, fallback: 'Не удалось записать видео.'));
    }
  }

  Future<void> _pickVideo() async {
    try {
      final picked = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 2),
      );
      if (picked == null || !mounted) {
        return;
      }
      setState(() {
        _storyType = StoryType.video;
        _selectedMedia = picked;
      });
    } catch (error) {
      _showError(humanizeError(error, fallback: 'Не удалось выбрать видео.'));
    }
  }

  Future<void> _submitStory() async {
    final text = _textController.text.trim();
    if (_currentTreeId == null || _currentTreeId!.isEmpty) {
      _showError(
        'Сначала выберите дерево, для которого хотите опубликовать историю.',
      );
      return;
    }
    if (_storyType == StoryType.text && text.isEmpty) {
      _showError('Для текстовой истории нужен хотя бы короткий текст.');
      return;
    }
    if (_needsMedia && _selectedMedia == null) {
      _showError('Добавьте файл для истории.');
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      // When a preset / manual person-list is active we hand
      // anchorPersonIds + scopeType=branches to the server. Without
      // that the API ignores the audience narrowing and the story
      // shows up to the whole tree.
      await _storyService.createStory(
        treeId: _currentTreeId!,
        type: _storyType,
        text: text.isEmpty ? null : text,
        media: _selectedMedia,
        circleId: _selectedBranchPersonIds.isEmpty ? _selectedCircleId : null,
        scopeType: _scopeType,
        anchorPersonIds: _selectedBranchPersonIds.toList(growable: false),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('История опубликована на 24 часа')),
      );
      context.pop(true);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showError(
          humanizeError(error, fallback: 'Не удалось опубликовать историю.'));
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  void _setStoryType(StoryType type) {
    setState(() {
      _storyType = type;
      if (type == StoryType.text) {
        _selectedMedia = null;
      } else if (_selectedMedia != null) {
        final isImageStory = type == StoryType.image;
        final mimeType = _selectedMedia?.mimeType ?? '';
        final isImageFile = mimeType.startsWith('image/');
        if (isImageStory != isImageFile) {
          _selectedMedia = null;
        }
      }
    });
  }

  Future<void> _loadAudienceCircles() async {
    final treeId = _currentTreeId;
    final circleService = _circleService;
    if (treeId == null || circleService == null) {
      return;
    }

    setState(() {
      _isLoadingCircles = true;
    });

    try {
      final circles = await circleService.getCircles(treeId);
      AudiencePresetsResponse presets = AudiencePresetsResponse.empty;
      try {
        presets = await circleService.getAudiencePresets(treeId);
      } catch (_) {
        // Older backend without /audience-presets — picker just won't
        // surface smart tiles, no error toast for the user.
      }
      // Tree people for the manual picker. Best-effort — failure
      // here just hides the "Выбрать людей" affordance.
      List<FamilyPerson> people = const <FamilyPerson>[];
      try {
        final familyTreeService = GetIt.I<FamilyTreeServiceInterface>();
        people = await familyTreeService.getRelatives(treeId);
      } catch (_) {
        // ignored
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _audienceCircles = circles;
        _audiencePresets = presets;
        _availablePeople = people;
        _selectedCircleId = _resolveSelectedCircleId(circles);
        _circlesUnavailable = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _circlesUnavailable = true;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingCircles = false;
        });
      }
    }
  }

  AudiencePreset? get _activeStoryPreset {
    final key = _selectedPresetKey;
    if (key == null) return null;
    for (final p in _audiencePresets.presets) {
      if (p.key == key) return p;
    }
    return null;
  }

  Widget _buildStoryPresetTilesRow(ThemeData theme) {
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _audiencePresets.presets.map((preset) {
        final selected = _selectedPresetKey == preset.key;
        return InkWell(
          borderRadius: BorderRadius.circular(tokens.radiusMd),
          onTap: () => _applyStoryPreset(preset),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            constraints: const BoxConstraints(minWidth: 140),
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 10,
            ),
            decoration: BoxDecoration(
              color: selected ? tokens.accentSoft : tokens.surfaceStrong,
              borderRadius: BorderRadius.circular(tokens.radiusMd),
              border: Border.all(
                color: selected ? tokens.accent : tokens.surfaceLine,
                width: selected ? 1.4 : 0.8,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  preset.key == 'core_family'
                      ? Icons.diversity_3_outlined
                      : Icons.groups_2_outlined,
                  color: selected ? tokens.accent : tokens.inkSecondary,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      preset.label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: tokens.ink,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${preset.personIds.length} чел.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: tokens.inkSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildStoryBranchPickerSummary(ThemeData theme) {
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final selectedCount = _selectedBranchPersonIds.length;
    final selectedPeople = _availablePeople
        .where((p) => _selectedBranchPersonIds.contains(p.id))
        .take(3)
        .toList();
    return InkWell(
      onTap: _openStoryBranchMultiPicker,
      borderRadius: BorderRadius.circular(tokens.radiusMd),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        decoration: BoxDecoration(
          color: selectedCount > 0
              ? tokens.accentSoft
              : tokens.surfaceStrong.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(tokens.radiusMd),
          border: Border.all(
            color: selectedCount > 0 ? tokens.accent : tokens.surfaceLine,
            width: selectedCount > 0 ? 1.2 : 0.7,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.alt_route_outlined,
              color: selectedCount > 0 ? tokens.accent : tokens.inkSecondary,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    selectedCount > 0
                        ? 'Выбрано: $selectedCount чел.'
                        : 'Выбрать людей вручную',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: tokens.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    selectedCount == 0
                        ? 'Поиск по имени · доступно ${_availablePeople.length}'
                        : selectedPeople.map((p) => p.displayName).join(', ') +
                            (selectedCount > selectedPeople.length
                                ? ' и ещё ${selectedCount - selectedPeople.length}'
                                : ''),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: tokens.inkSecondary,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded, color: tokens.inkSecondary),
          ],
        ),
      ),
    );
  }

  void _applyStoryPreset(AudiencePreset preset) {
    setState(() {
      if (_selectedPresetKey == preset.key) {
        // Toggle off — back to "Всё дерево" / circle default.
        _selectedPresetKey = null;
        _selectedBranchPersonIds.clear();
        _scopeType = TreeContentScopeType.wholeTree;
        return;
      }
      _selectedPresetKey = preset.key;
      _selectedCircleId = null;
      _scopeType = TreeContentScopeType.branches;
      _selectedBranchPersonIds
        ..clear()
        ..addAll(preset.personIds);
    });
  }

  Future<void> _openStoryBranchMultiPicker() async {
    final result = await PersonMultiPickerSheet.show(
      context,
      people: _availablePeople,
      initialSelection: Set<String>.from(_selectedBranchPersonIds),
      title: 'Выбрать людей',
    );
    if (result == null || !mounted) return;
    setState(() {
      _selectedPresetKey = null;
      _selectedCircleId = null;
      _selectedBranchPersonIds
        ..clear()
        ..addAll(result);
      _scopeType = _selectedBranchPersonIds.isEmpty
          ? TreeContentScopeType.wholeTree
          : TreeContentScopeType.branches;
    });
  }

  String? _resolveSelectedCircleId(List<FamilyCircle> circles) {
    final selectedId = _selectedCircleId;
    if (selectedId != null &&
        circles.any((circle) => circle.id == selectedId)) {
      return selectedId;
    }
    for (final circle in circles) {
      if (circle.isAllTree) {
        return circle.id;
      }
    }
    return circles.isEmpty ? null : circles.first.id;
  }

  void _showError(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('История'),
        actions: [
          TextButton(
            onPressed: _isSubmitting ? null : _submitStory,
            child: _isSubmitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Поделиться'),
          ),
        ],
      ),
      body: _currentTreeId == null
          ? _buildMissingTreeState()
          : LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 960;
                final preview = _buildStoryCanvas();
                final controls = _buildControls();

                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1180),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              _buildMetaPill(
                                icon: Icons.account_tree_outlined,
                                label:
                                    _currentTreeName?.trim().isNotEmpty == true
                                        ? _currentTreeName!
                                        : 'Текущее дерево',
                              ),
                              _buildMetaPill(
                                icon: Icons.schedule_outlined,
                                label: '24 часа',
                              ),
                              _buildMetaPill(
                                icon: Icons.group_work_outlined,
                                label: _selectedAudienceLabel,
                              ),
                              _buildMetaPill(
                                icon: _storyType == StoryType.text
                                    ? Icons.notes_outlined
                                    : (_storyType == StoryType.image
                                        ? Icons.image_outlined
                                        : Icons.videocam_outlined),
                                label: _storyTypeLabel(_storyType),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          if (isWide)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(flex: 7, child: preview),
                                const SizedBox(width: 16),
                                Expanded(flex: 4, child: controls),
                              ],
                            )
                          else ...[
                            preview,
                            const SizedBox(height: 16),
                            controls,
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _buildStoryCanvas() {
    return GlassPanel(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Превью',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 12),
          StoryPosterCardFrame(
            palette: _palette,
            child: Stack(
              children: [
                Positioned.fill(child: _buildCanvasContent()),
                Align(
                  alignment: Alignment.topLeft,
                  child: StoryMediaBadge(
                    icon: _storyType == StoryType.video
                        ? Icons.videocam_rounded
                        : _storyType == StoryType.image
                            ? Icons.image_rounded
                            : Icons.text_fields_rounded,
                    label: _storyTypeLabel(_storyType),
                    emphasized: true,
                  ),
                ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      StoryMediaBadge(
                        icon: Icons.schedule_outlined,
                        label: '24 часа',
                      ),
                      StoryMediaBadge(
                        icon: Icons.remove_red_eye_outlined,
                        label: _selectedAudienceLabel,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvasContent() {
    if (_storyType == StoryType.image) {
      if (_selectedMedia == null) {
        return _StoryCanvasPlaceholder(
          icon: Icons.add_photo_alternate_outlined,
          title: 'Добавьте фото',
          subtitle: 'История будет выглядеть как poster.',
        );
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          _PickedStoryImagePreview(image: _selectedMedia!),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.08),
                  Colors.black.withValues(alpha: 0.42),
                ],
              ),
            ),
          ),
          if (_textController.text.trim().isNotEmpty)
            Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: StoryPosterText(
                  primaryText: _storyText,
                  maxLines: 5,
                ),
              ),
            ),
        ],
      );
    }

    if (_storyType == StoryType.video) {
      if (_selectedMedia == null) {
        return _StoryCanvasPlaceholder(
          icon: Icons.videocam_outlined,
          title: 'Добавьте видео',
          subtitle: 'Короткий ролик до двух минут.',
        );
      }

      return Stack(
        fit: StackFit.expand,
        children: [
          StoryPosterBackground(
            palette: _palette,
            dimmed: true,
          ),
          Center(
            child: Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.18),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                color: Colors.white,
                size: 48,
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: StoryPosterText(
                primaryText: _textController.text.trim().isEmpty
                    ? _selectedMedia!.name
                    : _storyText,
                secondaryText:
                    _textController.text.trim().isEmpty ? 'Видео' : 'Видео',
                maxLines: 4,
              ),
            ),
          ),
        ],
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        StoryPosterBackground(
          palette: _palette,
        ),
        Padding(
          padding: const EdgeInsets.all(18),
          child: Align(
            alignment: Alignment.center,
            child: StoryPosterText(
              primaryText: _storyText,
              centered: true,
              maxLines: 8,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildControls() {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Аудитория',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              if (_audiencePresets.presets.isNotEmpty) ...[
                _buildStoryPresetTilesRow(theme),
                const SizedBox(height: 12),
              ],
              AudiencePicker(
                circles: _audienceCircles,
                selectedCircleId:
                    _activeStoryPreset == null ? _selectedCircleId : null,
                onChanged: (circleId) {
                  setState(() {
                    // Picking a circle clears any active preset /
                    // manual-people selection so the three paths
                    // stay mutually exclusive.
                    _selectedPresetKey = null;
                    _selectedBranchPersonIds.clear();
                    _scopeType = TreeContentScopeType.wholeTree;
                    _selectedCircleId = circleId;
                  });
                },
                isLoading: _isLoadingCircles,
                isUnavailable: _circlesUnavailable,
                onRetry: _loadAudienceCircles,
              ),
              if (_availablePeople.isNotEmpty) ...[
                const SizedBox(height: 12),
                _buildStoryBranchPickerSummary(theme),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        GlassPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Формат',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _buildTypeChip(
                    icon: Icons.text_fields_rounded,
                    label: 'Текст',
                    value: StoryType.text,
                  ),
                  _buildTypeChip(
                    icon: Icons.image_rounded,
                    label: 'Фото',
                    value: StoryType.image,
                  ),
                  _buildTypeChip(
                    icon: Icons.videocam_rounded,
                    label: 'Видео',
                    value: StoryType.video,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        GlassPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _storyType == StoryType.text ? 'Текст' : 'Подпись',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLowest
                      .withValues(alpha: 0.88),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: TextField(
                  controller: _textController,
                  minLines: 3,
                  maxLines: 6,
                  decoration: InputDecoration(
                    hintText: _storyType == StoryType.text
                        ? 'Короткий момент'
                        : 'Подпись',
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.all(18),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        GlassPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Медиа',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _openMediaPicker,
                    icon: const Icon(Icons.add_photo_alternate_rounded),
                    label: Text(
                        _selectedMedia == null ? 'Добавить медиа' : 'Заменить'),
                  ),
                  if (_selectedMedia != null)
                    OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          _selectedMedia = null;
                          if (_storyType != StoryType.text) {
                            _storyType = StoryType.text;
                          }
                        });
                      },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Убрать'),
                    ),
                ],
              ),
              if (_selectedMedia != null) ...[
                const SizedBox(height: 12),
                Text(
                  _selectedMedia!.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTypeChip({
    required IconData icon,
    required String label,
    required StoryType value,
  }) {
    final theme = Theme.of(context);
    final isSelected = _storyType == value;

    return ChoiceChip(
      selected: isSelected,
      onSelected: (_) => _setStoryType(value),
      avatar: Icon(
        icon,
        size: 18,
        color: isSelected
            ? theme.colorScheme.onPrimaryContainer
            : theme.colorScheme.onSurfaceVariant,
      ),
      label: Text(label),
      labelStyle: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      backgroundColor:
          theme.colorScheme.surfaceContainerLowest.withValues(alpha: 0.88),
      selectedColor: theme.colorScheme.primaryContainer.withValues(alpha: 0.9),
      side: BorderSide(
        color: isSelected
            ? theme.colorScheme.primary.withValues(alpha: 0.18)
            : theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    );
  }

  Widget _buildMetaPill({
    required IconData icon,
    required String label,
  }) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _storyTypeLabel(StoryType type) {
    switch (type) {
      case StoryType.text:
        return 'Текст';
      case StoryType.image:
        return 'Фото';
      case StoryType.video:
        return 'Видео';
    }
  }

  Widget _buildMissingTreeState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: GlassPanel(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.account_tree_outlined,
                  size: 56,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Сначала выберите дерево',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Нужен активный контекст.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => context.go('/trees'),
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Выбрать дерево'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StoryCanvasPlaceholder extends StatelessWidget {
  const _StoryCanvasPlaceholder({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 40),
            const SizedBox(height: 14),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.86),
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _PickedStoryImagePreview extends StatelessWidget {
  const _PickedStoryImagePreview({required this.image});

  final XFile image;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: image.readAsBytes(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const ColoredBox(
            color: Color(0x11000000),
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        return Image.memory(
          snapshot.data!,
          fit: BoxFit.cover,
          // Composer-side preview of the image the user picked for
          // their story. Confirms the upload to a screen-reader user.
          semanticLabel: 'Изображение истории',
          errorBuilder: (_, __, ___) => const ColoredBox(
            color: Color(0x11000000),
            child: Center(child: Icon(Icons.broken_image_outlined)),
          ),
        );
      },
    );
  }
}
