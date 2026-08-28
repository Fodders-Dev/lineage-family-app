import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../widgets/attachment_picker_sheet.dart';
import '../widgets/kruzhok_recorder_screen.dart';
import 'package:provider/provider.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/circle_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/post_service_interface.dart';
import '../models/audience_preset.dart';
import '../models/circle.dart';
import '../models/family_person.dart';
import '../models/family_tree.dart';
import '../models/post.dart';
import '../providers/tree_provider.dart';
import '../services/app_status_service.dart';
import '../services/local_storage_service.dart';
import '../theme/app_theme.dart';
import '../utils/user_facing_error.dart';
import '../widgets/audience_picker.dart';
import '../widgets/glass_panel.dart';
import '../models/media_upload_progress.dart';
import '../services/gallery_media_picker.dart';
import '../services/post_publish_queue.dart';
import '../widgets/person_multi_picker_sheet.dart';

class CreatePostScreen extends StatefulWidget {
  const CreatePostScreen({super.key, this.initialAction});

  /// Optional CTA passed in via `?action=` from the home-screen
  /// teaser icons. `'photo'` auto-opens the gallery picker on mount,
  /// `'video'` auto-opens the video picker. Anything else is a no-op
  /// (user gets the regular composer).
  final String? initialAction;

  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen> {
  final _contentController = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final FamilyTreeServiceInterface _familyTreeService =
      GetIt.I<FamilyTreeServiceInterface>();
  final PostServiceInterface _postService = GetIt.I<PostServiceInterface>();
  final CircleServiceInterface? _circleService =
      GetIt.I.isRegistered<CircleServiceInterface>()
          ? GetIt.I<CircleServiceInterface>()
          : null;
  final LocalStorageService _localStorageService =
      GetIt.I<LocalStorageService>();
  final AppStatusService _appStatusService = GetIt.I<AppStatusService>();

  bool _isPublic = false;
  bool _isLoading = false;

  /// Прогресс загрузки медиа во время публикации (шаг 3 плана массовой
  /// загрузки): 30 фото едут не мгновенно, и замерший спиннер читается как
  /// «приложение зависло». Null — пока публикация не идёт.
  MediaUploadProgress? _uploadProgress;

  /// Подпись рядом со спиннером публикации: «Загружено 18 из 30».
  /// Для одного файла счётчик не нужен — он не несёт информации.
  String? get _uploadProgressLabel {
    final progress = _uploadProgress;
    if (progress == null || progress.total <= 1) {
      return null;
    }
    switch (progress.stage) {
      case MediaUploadStage.preparing:
        return 'Готовим ${progress.total} фото';
      case MediaUploadStage.uploading:
        return 'Загружено ${progress.completed} из ${progress.total}';
      case MediaUploadStage.publishing:
        return 'Публикуем…';
    }
  }
  bool _isLoadingCircles = false;
  bool _isLoadingPeople = false;
  bool _circlesUnavailable = false;
  bool _branchCandidatesUnavailable = false;
  // Phase 3.4 multi-branch posts: list of the user's OTHER trees
  // (excluding the primary one driving this composer) that the
  // post can be cross-posted to. The primary tree is always
  // implicit — `_additionalBranchIds` only tracks the extras.
  // When empty, the post is single-branch (legacy behavior).
  List<FamilyTree> _otherUserTrees = <FamilyTree>[];
  final Set<String> _additionalBranchIds = <String>{};
  // Mixed photos + videos. The Post model still stores everything as
  // imageUrls (server-side blob, no schema change needed), but locally
  // we track the kind so the preview tile can render a video poster
  // with a play overlay instead of trying to decode an image header
  // out of an .mp4.
  List<_PostMedia> _selectedMedia = <_PostMedia>[];
  List<FamilyCircle> _audienceCircles = <FamilyCircle>[];
  AudiencePresetsResponse _audiencePresets = AudiencePresetsResponse.empty;
  /// `'core_family'` / `'close'` while one of the smart-tile presets
  /// is active. Cleared the moment the user picks any non-preset
  /// option (a regular circle / their own custom branch list).
  String? _selectedPresetKey;
  List<FamilyPerson> _availablePeople = <FamilyPerson>[];
  final Set<String> _selectedBranchPersonIds = <String>{};
  TreeContentScopeType _scopeType = TreeContentScopeType.wholeTree;
  String? _selectedCircleId;
  String? _currentTreeId;
  FamilyTree? _currentTreeMeta;

  bool get _isFriendsTree => _currentTreeMeta?.isFriendsTree == true;

  /// Live audience footprint based on the currently-selected branches.
  /// Counts the union of `memberIds` across the primary branch
  /// (`_currentTreeMeta`) and every branch the user toggled on in the
  /// "Опубликовать также в" strip. The author is included — the
  /// "увидят X человек" copy is read as "audience size" and pretending
  /// the author isn't part of the audience confuses the count when
  /// the user opens their own post a moment later.
  ///
  /// Returns `null` until the primary tree metadata loaded; the badge
  /// stays hidden until then so we don't flash a misleading "0 человек".
  _AudienceSummary? get _audienceSummary {
    if (_currentTreeMeta == null) return null;
    final viewers = <String>{..._currentTreeMeta!.memberIds};
    var branches = 1;
    for (final tree in _otherUserTrees) {
      if (_additionalBranchIds.contains(tree.id)) {
        viewers.addAll(tree.memberIds);
        branches += 1;
      }
    }
    return _AudienceSummary(viewers: viewers.length, branches: branches);
  }

  String get _selectedAudienceLabel {
    final activePreset = _activePreset;
    if (activePreset != null) {
      return activePreset.label;
    }
    final selectedCircle = _selectedCircle;
    if (_scopeType == TreeContentScopeType.branches &&
        _selectedBranchPersonIds.isNotEmpty) {
      return _isFriendsTree
          ? '${_selectedBranchPersonIds.length} круг(а)'
          : '${_selectedBranchPersonIds.length} ветк(и)';
    }
    if (selectedCircle != null) {
      return selectedCircle.name;
    }
    return _isFriendsTree ? 'Весь круг' : 'Всё дерево';
  }

  AudiencePreset? get _activePreset {
    final key = _selectedPresetKey;
    if (key == null) return null;
    for (final p in _audiencePresets.presets) {
      if (p.key == key) return p;
    }
    return null;
  }

  String get _selectedAudienceDetail {
    final selectedCircle = _selectedCircle;
    final parts = <String>[];
    if (_scopeType == TreeContentScopeType.branches &&
        _selectedBranchPersonIds.isNotEmpty) {
      parts.add(
        _isFriendsTree
            ? 'выбранные люди и их круги'
            : 'выбранные люди и их ветки',
      );
    } else if (selectedCircle != null) {
      parts.add(_memberLabel(selectedCircle.memberCount));
      if ((selectedCircle.description ?? '').trim().isNotEmpty) {
        parts.add(selectedCircle.description!.trim());
      } else if (selectedCircle.isAllTree) {
        parts.add(_isFriendsTree ? 'весь круг' : 'вся семья');
      } else if (selectedCircle.isAuto) {
        parts.add('автоматический круг по ветке');
      }
    } else {
      parts.add(_isFriendsTree ? 'внутри текущего круга' : 'внутри дерева');
    }
    if (_isPublic) {
      parts.add('публично по ссылке');
    }
    return parts.join(' · ');
  }

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

  @override
  void initState() {
    super.initState();
    // Q1: the publish button enables only when there's something to post,
    // so rebuild the topbar as the text field gains/loses content. Media
    // changes already flow through setState.
    _contentController.addListener(_handleComposerChanged);
    _currentTreeId = Provider.of<TreeProvider>(
      context,
      listen: false,
    ).selectedTreeId;
    _loadCurrentTreeMeta();
    _loadAudienceCircles();
    _loadBranchCandidates();
    _loadOtherUserTrees();
    // Honor the action hint coming from the home teaser icons. The
    // post-frame callback gives the navigator a chance to settle so
    // the picker sheet appears on top of the actually-mounted
    // composer instead of fighting with the page transition.
    final action = widget.initialAction;
    if (action == 'photo' || action == 'video') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (action == 'photo') {
          _pickImages();
        } else {
          _pickVideoFromGallery();
        }
      });
    }
  }

  /// Rebuilds the composer when the text content changes so the publish
  /// button's enabled state (Q1) tracks the field live.
  void _handleComposerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadCurrentTreeMeta() async {
    final treeId = _currentTreeId;
    if (treeId == null) {
      return;
    }
    final treeMeta = await _localStorageService.getTree(treeId);
    if (!mounted) {
      return;
    }
    setState(() {
      _currentTreeMeta = treeMeta;
    });
  }

  // Phase 3.4: load the user's OTHER branches (legacy: trees) so
  // the composer can offer "Опубликовать также в:" toggles for
  // multi-branch posts. Best-effort — when the call fails the
  // section just stays hidden and the user posts to the primary
  // branch only (legacy behavior).
  Future<void> _loadOtherUserTrees() async {
    final treeId = _currentTreeId;
    if (treeId == null) return;
    try {
      final trees = await _familyTreeService.getUserTrees();
      if (!mounted) return;
      setState(() {
        _otherUserTrees = trees
            .where((tree) => tree.id != treeId)
            .toList(growable: false);
      });
    } catch (_) {
      // Silent: multi-branch is opt-in. If we can't load the list,
      // hide the section rather than blocking the composer.
    }
  }

  Future<void> _loadBranchCandidates() async {
    if (_currentTreeId == null) {
      return;
    }

    setState(() {
      _isLoadingPeople = true;
    });

    try {
      final people = await _familyTreeService.getRelatives(_currentTreeId!);
      final sortedPeople = List<FamilyPerson>.from(people)
        ..sort(
          (left, right) => left.displayName.toLowerCase().compareTo(
                right.displayName.toLowerCase(),
              ),
        );
      if (!mounted) {
        return;
      }
      setState(() {
        _availablePeople = sortedPeople;
        _branchCandidatesUnavailable = false;
      });
    } catch (error) {
      _appStatusService.reportError(
        error,
        fallbackMessage: 'Не удалось загрузить список веток для публикации.',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _branchCandidatesUnavailable = true;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingPeople = false;
        });
      }
    }
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
      // Audience presets are best-effort — the older backend simply
      // doesn't have the endpoint and returns 404, which the service
      // turns into the empty response. Wrap in a separate try so a
      // presets failure doesn't blank out the regular circles list.
      AudiencePresetsResponse presets = AudiencePresetsResponse.empty;
      try {
        presets = await circleService.getAudiencePresets(treeId);
      } catch (_) {
        // ignore — picker just won't show smart tiles
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _audienceCircles = circles;
        _audiencePresets = presets;
        _selectedCircleId = _resolveSelectedCircleId(circles);
        _circlesUnavailable = false;
      });
    } catch (error) {
      _appStatusService.reportError(
        error,
        fallbackMessage: 'Не удалось загрузить круги для публикации.',
      );
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

  Future<void> _openMediaPicker() async {
    // Big-app pattern: a colored-icon picker sheet rather than jumping
    // straight into the OS gallery. Now also surfaces video — user
    // complained "а видео нельзя что-ли?" — and the camera tile splits
    // photo / video so the user can record without scrolling out of
    // the app.
    final choice = await showAttachmentPickerSheet(
      context,
      title: 'ДОБАВИТЬ МЕДИА',
      actions: const [
        AttachmentPickerAction(
          id: 'gallery',
          icon: Icons.photo_library_rounded,
          label: 'Галерея',
          color: Color(0xFFE05A8B),
        ),
        AttachmentPickerAction(
          id: 'camera',
          icon: Icons.photo_camera_rounded,
          label: 'Снять фото',
          color: Color(0xFF3D8DFF),
        ),
        AttachmentPickerAction(
          id: 'video',
          icon: Icons.videocam_rounded,
          label: 'Видео',
          color: Color(0xFFE85A40),
        ),
        AttachmentPickerAction(
          id: 'video_camera',
          icon: Icons.video_call_rounded,
          label: 'Снять видео',
          color: Color(0xFF7B5BD6),
        ),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'camera':
        await _takePhoto();
        break;
      case 'video':
        await _pickVideoFromGallery();
        break;
      case 'video_camera':
        await _recordVideo();
        break;
      case 'gallery':
      default:
        await _pickImages();
        break;
    }
  }

  Future<void> _takePhoto() async {
    try {
      final shot = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 80,
        maxWidth: 1080,
      );
      if (shot == null || !mounted) return;
      _appendMedia(_PostMedia(file: shot, isVideo: false));
    } catch (e) {
      debugPrint('Ошибка камеры: $e');
      if (mounted) _showMessage('Не удалось сделать фото.');
    }
  }

  Future<void> _pickImages() async {
    try {
      final picked = await const GalleryMediaPicker().pickMultiple();
      if (picked.isEmpty || !mounted) {
        return;
      }
      final mapped = picked
          .map((file) => _PostMedia(file: file, isVideo: _looksLikeVideo(file)))
          .toList();
      _appendMediaBatch(mapped);
    } catch (e) {
      debugPrint('Ошибка выбора медиа: $e');
      if (mounted) {
        _showMessage('Не удалось выбрать медиа.');
      }
    }
  }

  Future<void> _pickVideoFromGallery() async {
    try {
      final clip = await _picker.pickVideo(source: ImageSource.gallery);
      if (clip == null || !mounted) return;
      _appendMedia(_PostMedia(file: clip, isVideo: true));
    } catch (e) {
      debugPrint('Ошибка выбора видео: $e');
      if (mounted) _showMessage('Не удалось выбрать видео.');
    }
  }

  Future<void> _recordVideo() async {
    try {
      // On native (iOS / Android) we use the in-app camera-plugin
      // recorder to bypass image_picker's medium-quality default
      // (the source of "качество съёмки на айфоне упало" the user
      // reported earlier — same issue stories had until commit
      // 365efb5). Web stays on image_picker because <input
      // type=file capture> can't drive a live preview loop.
      final XFile? clip;
      if (kIsWeb) {
        clip = await _picker.pickVideo(source: ImageSource.camera);
      } else {
        clip = await KruzhokRecorderScreen.showPost(context);
      }
      if (clip == null || !mounted) return;
      _appendMedia(_PostMedia(file: clip, isVideo: true));
    } catch (e) {
      debugPrint('Ошибка записи видео: $e');
      if (mounted) _showMessage('Не удалось записать видео.');
    }
  }

  /// Push one media item, respecting [kMaxPostMedia].
  void _appendMedia(_PostMedia media) {
    if (_selectedMedia.length >= kMaxPostMedia) {
      _showMessage('Можно прикрепить не более $kMaxPostMedia файлов.');
      return;
    }
    setState(() {
      _selectedMedia = <_PostMedia>[..._selectedMedia, media];
    });
  }

  /// Push a batch (gallery multi-pick), capping at [kMaxPostMedia] with a
  /// snackbar notice if it had to trim.
  void _appendMediaBatch(List<_PostMedia> batch) {
    final willBeTrimmed = _selectedMedia.length + batch.length > kMaxPostMedia;
    setState(() {
      final next = <_PostMedia>[..._selectedMedia, ...batch];
      _selectedMedia = next.take(kMaxPostMedia).toList();
    });
    if (willBeTrimmed && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Можно добавить до $kMaxPostMedia фото за один пост — '
            'лишние не поместились.',
          ),
        ),
      );
    }
  }

  /// pickMultipleMedia returns XFile but doesn't tell us which entries
  /// are video — sniff via mime then file extension as a fallback.
  bool _looksLikeVideo(XFile file) {
    final mime = file.mimeType?.toLowerCase();
    if (mime != null && mime.startsWith('video/')) return true;
    final name = file.name.toLowerCase();
    return name.endsWith('.mp4') ||
        name.endsWith('.mov') ||
        name.endsWith('.webm') ||
        name.endsWith('.m4v') ||
        name.endsWith('.avi');
  }

  Future<void> _createPost() async {
    final content = _contentController.text.trim();
    if (content.isEmpty && _selectedMedia.isEmpty) {
      _showMessage('Добавьте текст или хотя бы один файл.');
      return;
    }
    if (_scopeType == TreeContentScopeType.branches &&
        _selectedBranchPersonIds.isEmpty) {
      _showMessage(
        _isFriendsTree
            ? 'Выберите хотя бы один круг для публикации.'
            : 'Выберите хотя бы одну ветку для публикации.',
      );
      return;
    }

    if (_currentTreeId == null) return;

    // Phase 3.4: when the user picked one or more "Опубликовать
    // также в" chips, the post fans out to the primary tree
    // PLUS those branches. When nothing's picked, send `null`
    // so the backend keeps the legacy single-branch default.
    final List<String>? branchIdsForRequest = _additionalBranchIds.isEmpty
        ? null
        : <String>{_currentTreeId!, ..._additionalBranchIds}.toList();

    // Шаг 5 bulk-upload: очередь публикации есть → «Опубликовать» отпускает
    // человека сразу. Пачка грузится в фоне (чип в shell показывает ход),
    // упавшая публикация переживает офлайн и kill приложения и уходит сама.
    // Рефреш ленты придёт через PostsRefreshCoordinator после ACK сервера,
    // поэтому pop без сигнала «обнови сейчас».
    if (GetIt.I.isRegistered<PostPublishQueue>()) {
      try {
        await GetIt.I<PostPublishQueue>().enqueue(
          treeId: _currentTreeId!,
          content: content,
          files: _selectedMedia.map((m) => m.file).toList(),
          isPublic: _isPublic,
          scopeType: _scopeType,
          anchorPersonIds: _selectedBranchPersonIds.toList(),
          circleId: _selectedCircleId,
          branchIds: branchIdsForRequest,
        );
      } catch (error) {
        _appStatusService.reportError(
          error,
          fallbackMessage: 'Не удалось опубликовать запись.',
        );
        _showMessage('Не удалось опубликовать запись. Попробуйте ещё раз.');
        return;
      }
      if (mounted) {
        context.pop();
      }
      return;
    }

    // Очереди нет (тестовый или деградированный контекст) — публикуем на
    // месте, как раньше: блокирующий прогресс на кнопке.
    setState(() {
      _isLoading = true;
      _uploadProgress = null;
    });

    try {
      await _postService.createPost(
        treeId: _currentTreeId!,
        content: content,
        // The Post model still surfaces everything as imageUrls — the
        // video items go through the same upload pipe (storage service
        // already handles video MIME) and post_card.dart sniffs the
        // URL extension at render time to pick the right tile.
        images: _selectedMedia.map((m) => m.file).toList(),
        isPublic: _isPublic,
        scopeType: _scopeType,
        anchorPersonIds: _selectedBranchPersonIds.toList(),
        circleId: _selectedCircleId,
        branchIds: branchIdsForRequest,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() => _uploadProgress = progress);
        },
      );

      if (mounted) {
        _showMessage('Запись опубликована.');
        context.pop(true); // Return true to signal refresh
      }
    } catch (error) {
      _appStatusService.reportError(
        error,
        fallbackMessage: 'Не удалось опубликовать запись.',
      );
      if (mounted) {
        setState(() {
          _isLoading = false;
          _uploadProgress = null;
        });
        _showMessage(
          describeUserFacingError(
            authService: _authService,
            error: error,
            fallbackMessage: _appStatusService.isOffline
                ? 'Нет соединения. Проверьте интернет и отправьте запись ещё раз.'
                : 'Не удалось опубликовать запись. Попробуйте ещё раз.',
          ),
        );
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isWideLayout = width >= 900;
    final composeTheme = Theme.of(context).copyWith(
      splashFactory: InkRipple.splashFactory,
    );

    final composeTokens = composeTheme.extension<RodnyaDesignTokens>() ??
        (composeTheme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return Theme(
      data: composeTheme,
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: Size.fromHeight(AppTheme.topbarHeight(context)),
          child: _buildComposeTopbar(
            theme: composeTheme,
            tokens: composeTokens,
          ),
        ),
        body: _currentTreeId == null
            ? _buildMissingTreeState()
            : SafeArea(
                child: Stack(
                  children: [
                    Positioned.fill(
                      // Align to topCenter (not Center) so the
                      // composer card anchors to the top of the
                      // viewport. Center vertically-centred a short
                      // SingleChildScrollView, which on desktop pushed
                      // the editor card halfway down the screen.
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: isWideLayout ? 1180 : 680,
                          ),
                          child: SingleChildScrollView(
                            padding: EdgeInsets.fromLTRB(
                              isWideLayout ? 24 : 14,
                              isWideLayout ? 18 : 12,
                              isWideLayout ? 24 : 14,
                              116,
                            ),
                            child: isWideLayout
                                ? Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        flex: 3,
                                        child: _buildEditorCard(compact: false),
                                      ),
                                      const SizedBox(width: 16),
                                      SizedBox(
                                        width: 370,
                                        child: _buildAudiencePanel(),
                                      ),
                                    ],
                                  )
                                : _buildEditorCard(compact: true),
                          ),
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: _buildComposeToolDock(compact: !isWideLayout),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildComposeToolDock({required bool compact}) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 12 : 24,
        0,
        compact ? 12 : 24,
        compact ? 12 : 18,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: GlassPanel(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          borderRadius: BorderRadius.circular(tokens.radiusLg),
          color: tokens.surfaceStrong.withValues(alpha: 0.94),
          borderColor: tokens.surfaceLine,
          child: Row(
            children: [
              _buildToolButton(
                icon: Icons.add_photo_alternate_outlined,
                label: _selectedMedia.isEmpty
                    ? 'Медиа'
                    : '${_selectedMedia.length}/$kMaxPostMedia',
                active: _selectedMedia.isNotEmpty,
                onPressed: _openMediaPicker,
              ),
              _buildToolButton(
                icon: Icons.group_work_outlined,
                label: 'Кому',
                active: _selectedCircleId != null,
                onPressed: _showAudienceSheet,
              ),
              _buildToolButton(
                icon: Icons.alt_route_outlined,
                label: _isFriendsTree ? 'Круги' : 'Ветки',
                active: _scopeType == TreeContentScopeType.branches,
                onPressed: () {
                  setState(() {
                    _scopeType = TreeContentScopeType.branches;
                  });
                  _showAudienceSheet();
                },
              ),
              _buildToolButton(
                icon: _isPublic ? Icons.public : Icons.lock_outline,
                label: _isPublic ? 'Публично' : 'Внутри',
                active: _isPublic,
                onPressed: () {
                  setState(() {
                    _isPublic = !_isPublic;
                  });
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolButton({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onPressed,
  }) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final foreground = active ? tokens.accentStrong : tokens.inkSecondary;

    return Expanded(
      child: Material(
        color: active ? tokens.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(tokens.radiusSm),
        child: InkWell(
          borderRadius: BorderRadius.circular(tokens.radiusSm),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: foreground, size: 21),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPresetTilesRow(
    ThemeData theme,
    RodnyaDesignTokens tokens,
    StateSetter? sheetSetState,
  ) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _audiencePresets.presets.map((preset) {
        final selected = _selectedPresetKey == preset.key;
        final memberCount = preset.personIds.length;
        return InkWell(
          borderRadius: BorderRadius.circular(tokens.radiusMd),
          onTap: () => _applyAudiencePreset(preset, sheetSetState),
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
                      '$memberCount ${_memberLabel(memberCount).split(' ').last}',
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

  void _applyAudiencePreset(
    AudiencePreset preset,
    StateSetter? sheetSetState,
  ) {
    _updateAudienceState(() {
      if (_selectedPresetKey == preset.key) {
        // Tapping an already-selected preset clears it (back to "Всё
        // дерево" or whatever circle was selected before).
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
    }, sheetSetState);
  }

  Future<void> _showAudienceSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, sheetSetState) {
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(sheetContext).size.height * 0.86,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 22),
                  child: _buildAudiencePanelContent(
                    sheetSetState: sheetSetState,
                    inSheet: true,
                    onDone: () => Navigator.of(sheetContext).pop(),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _updateAudienceState(VoidCallback update, [StateSetter? sheetSetState]) {
    if (!mounted) {
      return;
    }
    setState(update);
    sheetSetState?.call(() {});
  }

  Widget _buildAudiencePanel() {
    return GlassPanel(
      padding: const EdgeInsets.all(16),
      child: _buildAudiencePanelContent(inSheet: false),
    );
  }

  Widget _buildAudiencePanelContent({
    required bool inSheet,
    StateSetter? sheetSetState,
    VoidCallback? onDone,
  }) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Кто увидит пост?',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w900,
            color: tokens.ink,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Выбор аудитории сохраняется вместе с постом. При необходимости круг можно поменять перед публикацией.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: tokens.inkSecondary,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 14),
        if (_audiencePresets.presets.isNotEmpty) ...[
          // Smart-tile row above the regular picker. Single tap takes
          // care of "Мoя семья" / "Близкие" — the 80% case the user
          // described as "тонна выбора" in the flat list.
          _buildPresetTilesRow(theme, tokens, sheetSetState),
          const SizedBox(height: 16),
        ],
        AudiencePicker(
          circles: _audienceCircles,
          selectedCircleId: _activePreset == null ? _selectedCircleId : null,
          onChanged: (circleId) {
            _updateAudienceState(() {
              // Picking a regular circle clears any active preset —
              // they're mutually exclusive selections.
              _selectedPresetKey = null;
              _selectedCircleId = circleId;
              _selectedBranchPersonIds.clear();
              if (_scopeType == TreeContentScopeType.branches &&
                  _selectedBranchPersonIds.isEmpty) {
                _scopeType = TreeContentScopeType.wholeTree;
              }
            }, sheetSetState);
          },
          isLoading: _isLoadingCircles,
          isUnavailable: _circlesUnavailable,
          isFriendsTree: _isFriendsTree,
          onRetry: _loadAudienceCircles,
        ),
        const SizedBox(height: 16),
        _buildBranchAudienceSection(sheetSetState: sheetSetState),
        const SizedBox(height: 16),
        _buildCrossBranchSection(theme, tokens, sheetSetState),
        _buildAudienceSummaryBadge(theme, tokens),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('По публичной ссылке'),
          subtitle: Text(
            _isPublic
                ? 'Пост можно будет открыть по ссылке.'
                : 'Пост останется внутри выбранной аудитории.',
          ),
          value: _isPublic,
          onChanged: (value) {
            _updateAudienceState(() {
              _isPublic = value;
            }, sheetSetState);
          },
        ),
        if (inSheet) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onDone,
              child: const Text('Готово'),
            ),
          ),
        ],
      ],
    );
  }

  // Phase 3.4 cross-branch composer section. Renders an empty
  // SizedBox when the user has 0 other trees; otherwise shows a
  // "Опубликовать также в:" row with one FilterChip per other
  // branch. Toggles add/remove the branch id from the set the
  // post will fan out to. The primary branch is always included
  // server-side, so the chips here are pure additions.
  Widget _buildCrossBranchSection(
    ThemeData theme,
    RodnyaDesignTokens tokens,
    StateSetter? sheetSetState,
  ) {
    if (_otherUserTrees.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Опубликовать также в:',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: tokens.ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Один пост увидят сразу несколько ваших веток. Реакции и комментарии останутся общими.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: tokens.inkSecondary,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _otherUserTrees.map((tree) {
              final selected = _additionalBranchIds.contains(tree.id);
              return FilterChip(
                label: Text(tree.name),
                selected: selected,
                onSelected: (next) {
                  _updateAudienceState(() {
                    if (next) {
                      _additionalBranchIds.add(tree.id);
                    } else {
                      _additionalBranchIds.remove(tree.id);
                    }
                  }, sheetSetState);
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  /// "Этот пост увидят: X человек • N ветке/веток" — live audience
  /// preview that reacts whenever the user toggles a cross-branch
  /// chip or switches the primary branch. Closes the loop on the
  /// audience model: until this badge existed, the author had to
  /// guess how many people the fan-out reached. The number is the
  /// union of branch.memberIds across selected branches (NOT the
  /// circle/branch-anchored audience narrowing — that's harder to
  /// compute correctly client-side and worth a follow-up if users
  /// ask). Author is included — the badge reads as "audience size",
  /// and pretending the author isn't in their own audience
  /// confuses the count when they open their own post seconds later.
  Widget _buildAudienceSummaryBadge(
    ThemeData theme,
    RodnyaDesignTokens tokens,
  ) {
    final summary = _audienceSummary;
    if (summary == null) return const SizedBox.shrink();
    final viewerLabel = _pluralizeViewers(summary.viewers);
    final branchLabel = _pluralizeBranches(summary.branches);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tokens.accentSoft.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: tokens.accent.withValues(alpha: 0.32),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.visibility_outlined,
            size: 18,
            color: tokens.accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tokens.ink,
                  height: 1.3,
                ),
                children: [
                  const TextSpan(text: 'Этот пост увидят '),
                  TextSpan(
                    text: viewerLabel,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: tokens.accent,
                    ),
                  ),
                  TextSpan(text: ' в $branchLabel.'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _pluralizeViewers(int count) {
    final mod10 = count % 10;
    final mod100 = count % 100;
    if (mod10 == 1 && mod100 != 11) return '$count человек';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return '$count человека';
    }
    return '$count человек';
  }

  static String _pluralizeBranches(int count) {
    final mod10 = count % 10;
    final mod100 = count % 100;
    if (mod10 == 1 && mod100 != 11) return '$count ветке';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return '$count ветках';
    }
    return '$count ветках';
  }

  Widget _buildBranchAudienceSection({StateSetter? sheetSetState}) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _isFriendsTree ? 'Отдельные круги' : 'Отдельные ветки',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: tokens.ink,
                ),
              ),
            ),
            if (_selectedBranchPersonIds.isNotEmpty)
              TextButton(
                onPressed: () {
                  _updateAudienceState(() {
                    _selectedBranchPersonIds.clear();
                    _scopeType = TreeContentScopeType.wholeTree;
                  }, sheetSetState);
                },
                child: const Text('Сбросить'),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _isFriendsTree
              ? 'Можно сузить видимость до выбранных людей и их кругов.'
              : 'Можно сузить видимость до выбранных людей и их веток.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: tokens.inkSecondary,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 10),
        if (_isLoadingPeople)
          _buildScopeState(
            icon: Icons.sync,
            title: 'Подбираем ветки',
            message:
                'Проверяем, какие люди доступны для выборочной публикации.',
            showProgress: true,
          )
        else if (_branchCandidatesUnavailable)
          _buildScopeState(
            icon: _appStatusService.isOffline
                ? Icons.cloud_off_outlined
                : Icons.error_outline,
            title: _appStatusService.isOffline
                ? 'Нет соединения'
                : 'Ветки сейчас недоступны',
            message: _appStatusService.isOffline
                ? 'Список веток вернётся, когда интернет снова появится.'
                : 'Не удалось обновить список веток. Попробуйте ещё раз.',
            actions: [
              OutlinedButton.icon(
                onPressed: _loadBranchCandidates,
                icon: const Icon(Icons.refresh),
                label: const Text('Повторить'),
              ),
            ],
          )
        else if (_availablePeople.isEmpty)
          _buildScopeState(
            icon: Icons.alt_route,
            title: _isFriendsTree ? 'Кругов пока нет' : 'Веток пока нет',
            message: _isFriendsTree
                ? 'Сначала добавьте людей в круг.'
                : 'Сначала добавьте людей и связи в дерево.',
          )
        else
          // Compact summary instead of an N-chip Wrap. The flat
          // FilterChip list didn't scale past ~30 people and would
          // become a wall on a 200-person tree (user feedback).
          // Tapping the card opens a fullscreen multi-picker with
          // search + virtualized list — that scales linearly.
          _buildBranchPickerSummary(theme, tokens, sheetSetState),
      ],
    );
  }

  Widget _buildBranchPickerSummary(
    ThemeData theme,
    RodnyaDesignTokens tokens,
    StateSetter? sheetSetState,
  ) {
    final selectedCount = _selectedBranchPersonIds.length;
    final selectedPeople = _availablePeople
        .where((p) => _selectedBranchPersonIds.contains(p.id))
        .take(3)
        .toList();
    return InkWell(
      onTap: () => _openBranchMultiPicker(sheetSetState),
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
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: selectedCount > 0
                    ? tokens.accent.withValues(alpha: 0.18)
                    : tokens.surface,
                borderRadius: BorderRadius.circular(tokens.radiusSm),
              ),
              child: Icon(
                Icons.alt_route_outlined,
                color: selectedCount > 0 ? tokens.accent : tokens.inkSecondary,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    selectedCount > 0
                        ? 'Выбрано ${_memberLabel(selectedCount)}'
                        : 'Выбрать людей',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: tokens.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    selectedCount == 0
                        ? 'Поиск по имени · доступно ${_memberLabel(_availablePeople.length)}'
                        : selectedPeople
                                .map((p) => p.displayName)
                                .join(', ') +
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
            const SizedBox(width: 10),
            Icon(
              Icons.chevron_right_rounded,
              color: tokens.inkSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openBranchMultiPicker(StateSetter? sheetSetState) async {
    final result = await PersonMultiPickerSheet.show(
      context,
      people: _availablePeople,
      initialSelection: Set<String>.from(_selectedBranchPersonIds),
      title: _isFriendsTree ? 'Отдельные круги' : 'Отдельные ветки',
    );
    if (result == null || !mounted) return;
    _updateAudienceState(() {
      // Picking a custom person set always clears the active preset
      // and circle so the three selection paths stay mutually
      // exclusive.
      _selectedPresetKey = null;
      _selectedCircleId = null;
      _selectedBranchPersonIds
        ..clear()
        ..addAll(result);
      if (_selectedBranchPersonIds.isEmpty) {
        _scopeType = TreeContentScopeType.wholeTree;
      } else {
        _scopeType = TreeContentScopeType.branches;
      }
    }, sheetSetState);
  }

  String _memberLabel(int count) {
    final mod10 = count % 10;
    final mod100 = count % 100;
    final suffix = mod10 == 1 && mod100 != 11
        ? 'человек'
        : mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)
            ? 'человека'
            : 'человек';
    return '$count $suffix';
  }

  Widget _buildEditorCard({required bool compact}) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return GlassPanel(
      padding: EdgeInsets.all(compact ? 16 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildAuthorRow(compact: compact),
          const SizedBox(height: 14),
          // Q6: the compact (mobile) editor shows just the audience summary
          // + «Изменить»; the wide layout already has the full audience
          // panel in the side column, so the summary would be redundant.
          if (compact) ...[
            _buildAudienceSummaryRow(),
            const SizedBox(height: 18),
          ],
          // Reference compose textarea is transparent — no border, no bg, just
          // text inside the outer card. Drop the inner DecoratedBox so the
          // input reads like the jsx prototype (placeholder font 17px, fluid
          // line-height 1.45, accent cursor).
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 4 : 6,
              vertical: compact ? 4 : 6,
            ),
            child: TextField(
              controller: _contentController,
              decoration: InputDecoration(
                hintText: 'О чём хотите рассказать родне?',
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                isCollapsed: true,
                hintStyle: AppTheme.sans(
                  color: tokens.inkMuted,
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                  height: 1.45,
                ),
              ),
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              maxLines: compact ? 9 : 12,
              minLines: compact ? 7 : 10,
              cursorColor: tokens.accent,
              style: AppTheme.sans(
                color: tokens.ink,
                fontSize: 17,
                fontWeight: FontWeight.w500,
                height: 1.45,
              ),
            ),
          ),
          // Visible media slot. Was previously rendered only when the
          // user had attached something, which made the "Фото"/"Медиа"
          // toolbar button feel disconnected — user said: "не
          // интуитивно понятно где фото то прикладывается". The empty
          // hint card reserves the space and re-opens the picker on
          // tap, so the user can see ahead of time where media will
          // land.
          const SizedBox(height: 16),
          if (_selectedMedia.isEmpty)
            _buildMediaEmptyHint()
          else
            _buildMediaPreviews(),
        ],
      ),
    );
  }

  Widget _buildAuthorRow({required bool compact}) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return Row(
      children: [
        _buildAuthorAvatar(),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _authorName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: tokens.ink,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _selectedAudienceDetail,
                maxLines: compact ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tokens.inkSecondary,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: _showAudienceSheet,
          icon: const Icon(Icons.expand_more, size: 18),
          label: Text(_selectedAudienceLabel),
        ),
      ],
    );
  }

  Widget _buildAuthorAvatar() {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final photoUrl = _authService.currentUserPhotoUrl?.trim();

    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: tokens.accentSoft,
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        border: Border.all(color: tokens.surfaceLine),
      ),
      clipBehavior: Clip.antiAlias,
      child: photoUrl != null && photoUrl.isNotEmpty
          ? Image.network(
              photoUrl,
              fit: BoxFit.cover,
              // Author avatar — the post card's name row already
              // identifies who's posting, so the image itself is
              // decorative for a screen-reader user.
              excludeFromSemantics: true,
              errorBuilder: (_, __, ___) => _buildAuthorInitials(tokens),
            )
          : _buildAuthorInitials(tokens),
    );
  }

  Widget _buildAuthorInitials(RodnyaDesignTokens tokens) {
    return Center(
      child: Text(
        _authorInitials,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: tokens.accentStrong,
              fontWeight: FontWeight.w900,
            ),
      ),
    );
  }

  String get _authorName {
    final displayName = _authService.currentUserDisplayName?.trim();
    if (displayName != null && displayName.isNotEmpty) {
      return displayName;
    }
    final email = _authService.currentUserEmail?.trim();
    if (email != null && email.isNotEmpty) {
      return email.split('@').first;
    }
    return 'Родня';
  }

  String get _authorInitials {
    final words =
        _authorName.split(RegExp(r'\s+')).where((word) => word.isNotEmpty);
    final initials = words
        .take(2)
        .map((word) => String.fromCharCode(word.runes.first).toUpperCase())
        .join();
    return initials.isEmpty ? 'Р' : initials;
  }

  /// Q6: a compact audience summary shown by default. Rather than laying
  /// out the whole circle/branch taxonomy as a chip strip up front (which
  /// read as noisy and pushed people to overthink reach), we show the
  /// current audience — defaulting to «Всё дерево» — with an «Изменить»
  /// action that opens the full picker sheet. The taxonomy still lives
  /// behind that one tap.
  Widget _buildAudienceSummaryRow() {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    final circle = _selectedCircle;
    final inBranches = _scopeType == TreeContentScopeType.branches;
    final icon = inBranches
        ? Icons.alt_route_outlined
        : (circle != null ? _circleIcon(circle) : Icons.groups_outlined);
    final accent = (!inBranches && circle != null)
        ? _circleAccent(circle, tokens)
        : tokens.accent;

    return Material(
      color: tokens.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: const Key('compose-audience-summary'),
        borderRadius: BorderRadius.circular(14),
        onTap: _showAudienceSheet,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: tokens.surfaceLine),
          ),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 17, color: accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Кто увидит',
                      style: AppTheme.sans(
                        color: tokens.inkMuted,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                    Text(
                      _selectedAudienceLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.sans(
                        color: tokens.ink,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (_isLoadingCircles)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.colorScheme.primary,
                  ),
                )
              else ...[
                Text(
                  'Изменить',
                  style: AppTheme.sans(
                    color: tokens.accent,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.expand_more_rounded,
                    size: 18, color: tokens.accent),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData _circleIcon(FamilyCircle circle) {
    switch (circle.kind) {
      case FamilyCircleKind.allTree:
        return Icons.account_tree_outlined;
      case FamilyCircleKind.favorites:
        return Icons.favorite_border;
      case FamilyCircleKind.descendantsOf:
      case FamilyCircleKind.ancestorsOf:
        return Icons.alt_route_outlined;
      case FamilyCircleKind.pair:
        return Icons.people_outline;
      case FamilyCircleKind.custom:
        return Icons.group_work_outlined;
    }
  }

  Color _circleAccent(FamilyCircle circle, RodnyaDesignTokens tokens) {
    switch (circle.kind) {
      case FamilyCircleKind.favorites:
        return tokens.warm;
      case FamilyCircleKind.descendantsOf:
      case FamilyCircleKind.ancestorsOf:
      case FamilyCircleKind.pair:
        return tokens.accentStrong;
      case FamilyCircleKind.allTree:
      case FamilyCircleKind.custom:
        return tokens.accent;
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
                  'Сначала выберите дерево, чтобы было понятно, кому показывать публикацию.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => context.go('/tree?selector=1'),
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

  Widget _buildScopeState({
    required IconData icon,
    required String title,
    required String message,
    bool showProgress = false,
    List<Widget> actions = const <Widget>[],
  }) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (showProgress)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }

  Widget _buildMediaEmptyHint() {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return InkWell(
      onTap: _openMediaPicker,
      borderRadius: BorderRadius.circular(tokens.radiusMd),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
        decoration: BoxDecoration(
          color: tokens.surfaceStrong.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(tokens.radiusMd),
          border: Border.all(
            color: tokens.surfaceLine,
            style: BorderStyle.solid,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: tokens.accentSoft,
                borderRadius: BorderRadius.circular(tokens.radiusSm),
              ),
              child: Icon(
                Icons.add_photo_alternate_outlined,
                color: tokens.accent,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Добавить фото или видео',
                    style: AppTheme.sans(
                      color: tokens.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Можно прикрепить до $kMaxPostMedia файлов',
                    style: AppTheme.sans(
                      color: tokens.inkSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: tokens.inkSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMediaPreviews() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _selectedMedia.length,
      itemBuilder: (context, index) {
        final media = _selectedMedia[index];
        return Stack(
          alignment: Alignment.topRight,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox.expand(
                child: _PickedMediaPreview(media: media),
              ),
            ),
            IconButton(
              tooltip: 'Удалить вложение',
              icon: const Icon(Icons.cancel, color: Colors.black54),
              iconSize: 20,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              style: IconButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.7),
              ),
              onPressed: () {
                setState(() {
                  _selectedMedia.removeAt(index);
                });
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildComposeTopbar({
    required ThemeData theme,
    required RodnyaDesignTokens tokens,
  }) {
    // Q1: nothing to publish until there's text or at least one media item.
    final hasContent = _contentController.text.trim().isNotEmpty ||
        _selectedMedia.isNotEmpty;
    final canPublish = !_isLoading && _currentTreeId != null && hasContent;
    // Same Android perf bypass as other topbars.
    final useBlur = defaultTargetPlatform != TargetPlatform.android;
    final body = Container(
      decoration: BoxDecoration(
        color: tokens.surface.withValues(
          alpha: theme.brightness == Brightness.dark
              ? (useBlur ? 0.74 : 0.96)
              : (useBlur ? 0.78 : 0.97),
        ),
        border: Border(
          bottom: BorderSide(
            color: tokens.surfaceLine.withValues(alpha: 0.5),
            width: 0.6,
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: AppTheme.topbarContentHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
            child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.arrow_back_rounded, color: tokens.ink),
              tooltip: 'Назад',
              onPressed: () {
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              },
            ),
            const SizedBox(width: 4),
            Text(
              'Новый пост',
              style: AppTheme.serif(
                color: tokens.ink,
                fontSize: 22,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.22,
              ),
            ),
            const Spacer(),
            Material(
              color: canPublish ? tokens.accent : tokens.surfaceLine,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: canPublish ? _createPost : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 9,
                  ),
                  child: _isLoading
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                // Детерминированный бар, когда файлов
                                // несколько и хоть один уже долетел; иначе
                                // честнее крутилка, чем застывший 0%.
                                value: _uploadProgress?.value,
                                color: tokens.accentInk,
                              ),
                            ),
                            if (_uploadProgressLabel != null) ...[
                              const SizedBox(width: 8),
                              Text(
                                _uploadProgressLabel!,
                                style: AppTheme.sans(
                                  color: tokens.accentInk,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ],
                        )
                      : Text(
                          'Опубликовать',
                          style: AppTheme.sans(
                            color: canPublish
                                ? tokens.accentInk
                                : tokens.inkMuted,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
          ),
        ),
      ),
    );
    if (!useBlur) return body;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: body,
      ),
    );
  }
}

/// Local media item attached to a draft post — XFile + a video flag.
/// Lives outside Post (which is the server-shaped model) because the
/// preview widget needs to know whether to even attempt to decode the
/// bytes as an image.
class _PostMedia {
  const _PostMedia({required this.file, required this.isVideo});

  final XFile file;
  final bool isVideo;
}

/// Audience preview computed from the composer's selected branches.
/// Carries the union member count and the branch count so the
/// pluralization helpers can render the right grammar.
class _AudienceSummary {
  const _AudienceSummary({required this.viewers, required this.branches});

  final int viewers;
  final int branches;
}

class _PickedMediaPreview extends StatelessWidget {
  const _PickedMediaPreview({required this.media});

  final _PostMedia media;

  @override
  Widget build(BuildContext context) {
    if (media.isVideo) {
      return _VideoTilePoster(file: media.file);
    }
    return FutureBuilder<Uint8List>(
      future: media.file.readAsBytes(),
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
          // Composer-side preview of an image the user just attached
          // to their post — confirms the attach worked.
          semanticLabel: 'Прикреплённое изображение',
          errorBuilder: (_, __, ___) => const ColoredBox(
            color: Color(0x11000000),
            child: Center(child: Icon(Icons.broken_image_outlined)),
          ),
        );
      },
    );
  }
}

/// Composer-side video poster. We don't pull a real frame here because
/// that would mean importing video_thumbnail just for the draft state —
/// the published post does it server-side / via the lightbox. A dark
/// gradient + filename + play overlay is enough to confirm "this is the
/// video I just attached" before publishing.
class _VideoTilePoster extends StatelessWidget {
  const _VideoTilePoster({required this.file});

  final XFile file;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF332B45), Color(0xFF181522)],
            ),
          ),
        ),
        Center(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
            ),
            padding: const EdgeInsets.all(10),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: 32,
            ),
          ),
        ),
        Positioned(
          left: 6,
          right: 6,
          bottom: 6,
          child: Text(
            file.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              shadows: [Shadow(color: Colors.black45, blurRadius: 4)],
            ),
          ),
        ),
      ],
    );
  }
}
