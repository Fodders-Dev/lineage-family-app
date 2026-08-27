// «Альбом семьи»: every photo from the family's posts, collected so
// moments don't get lost in the feed scroll. Frontend-only: aggregates
// over the audience scope the home feed already uses (getPosts(treeId:
// null) = union across ALL the viewer's branches — a ready scope, no
// per-branch fan needed), dedups by URL, sorts newest-first. Tap → the
// shared MediaLightbox. Optional «по автору» filter (client-side — posts
// already carry authorName/authorPhotoUrl, no getRelatives call).
//
// v2: grouped into month sections (A2a) + a «N лет назад» memory strip at
// the top for photos from this day in past years (A2b).
//
// Out of scope (separate arcs): «кто на фото» (needs person-tagging,
// Phase D — anchorPersonIds is audience-scope, not subjects), Круг
// (Phase C), backend filters, videos in the album.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../backend/interfaces/post_service_interface.dart';
import '../models/media_upload_progress.dart';
import '../models/post.dart';
import '../providers/tree_provider.dart';
import '../services/gallery_media_picker.dart';
import '../services/posts_cache.dart';
import '../theme/app_theme.dart';
import '../utils/image_decode.dart';
import '../widgets/media_lightbox.dart';

class _AlbumPhoto {
  const _AlbumPhoto({
    required this.url,
    required this.authorId,
    required this.authorName,
    required this.createdAt,
  });

  final String url;
  final String authorId;
  final String authorName;
  final DateTime createdAt;
}

/// A photo plus its position in the full (filtered) album, so a thumb in
/// any month section can open the lightbox at the right global index.
class _IndexedPhoto {
  const _IndexedPhoto({required this.photo, required this.globalIndex});

  final _AlbumPhoto photo;
  final int globalIndex;
}

class _MonthSection {
  _MonthSection({required this.month});

  final DateTime month;
  final List<_IndexedPhoto> items = [];
}

class _MonthHeaderDelegate extends SliverPersistentHeaderDelegate {
  _MonthHeaderDelegate({
    required this.label,
    required this.background,
    required this.textStyle,
  });

  final String label;
  final Color background;
  final TextStyle? textStyle;

  static const double _height = 40;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return Container(
      height: _height,
      color: background,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text(label, style: textStyle),
    );
  }

  @override
  bool shouldRebuild(_MonthHeaderDelegate old) =>
      old.label != label ||
      old.background != background ||
      old.textStyle != textStyle;
}

class FamilyAlbumScreen extends StatefulWidget {
  const FamilyAlbumScreen({
    super.key,
    this.serviceOverride,
    this.cacheOverride,
    this.nowProvider,
    this.mediaPickerOverride,
  });

  /// Test seams — production resolves via GetIt.
  final PostServiceInterface? serviceOverride;
  final PostsCache? cacheOverride;

  /// Injectable «today» for the «N лет назад» memory section (tests).
  final DateTime Function()? nowProvider;

  /// Test seam: подменяемый выбор файлов (в тестах платформенного пикера нет).
  final Future<List<XFile>> Function()? mediaPickerOverride;

  @override
  State<FamilyAlbumScreen> createState() => _FamilyAlbumScreenState();
}

class _FamilyAlbumScreenState extends State<FamilyAlbumScreen> {
  // The home feed caches its aggregate («Все») batch under this key.
  // Reusing it gives the album instant offline-first photos.
  static const String _audienceCacheKey = '__audience__';

  // ±days around today that still counts as «this day» in past years.
  static const int _memoryWindowDays = 3;

  bool _loading = true;
  bool _loadFailed = false;
  bool _uploading = false;
  MediaUploadProgress? _uploadProgress;
  List<_AlbumPhoto> _photos = const [];
  String? _authorFilter; // null = все авторы

  DateTime get _now => widget.nowProvider?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// Загрузка пачки фото прямо из альбома.
  ///
  /// Альбом — производная от постов (агрегат по `imageUrls`), поэтому «плюс»
  /// здесь публикует обычный пост без подписи, и фото сразу попадают в свой
  /// месяц. Отдельная модель на бэкенде не нужна.
  Future<void> _pickAndUpload() async {
    if (_uploading) {
      return;
    }
    final service = _service();
    if (service == null) {
      _showMessage('Сервис недоступен. Попробуйте позже.');
      return;
    }
    final treeId = Provider.of<TreeProvider>(context, listen: false).selectedTreeId;
    if (treeId == null || treeId.isEmpty) {
      _showMessage('Сначала выберите дерево.');
      return;
    }

    List<XFile> picked;
    try {
      picked = widget.mediaPickerOverride != null
          ? await widget.mediaPickerOverride!()
          : await const GalleryMediaPicker().pickMultiple();
    } catch (error) {
      debugPrint('Album picker failed: $error');
      _showMessage('Не удалось открыть галерею.');
      return;
    }
    if (picked.isEmpty || !mounted) {
      return;
    }

    final trimmed = picked.length > kMaxPostMedia;
    final files = trimmed ? picked.take(kMaxPostMedia).toList() : picked;
    if (trimmed) {
      _showMessage(
        'Можно добавить до $kMaxPostMedia фото за раз — лишние не поместились.',
      );
    }

    setState(() {
      _uploading = true;
      _uploadProgress = null;
    });
    try {
      await service.createPost(
        treeId: treeId,
        // Подпись пустая: человек пришёл выложить фото, а не писать текст.
        // Бэкенд разрешает пост без текста, когда есть медиа.
        content: '',
        images: files,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() => _uploadProgress = progress);
        },
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _uploading = false;
        _uploadProgress = null;
      });
      _showMessage(
        files.length == 1
            ? 'Фото добавлено в альбом.'
            : '${files.length} фото добавлены в альбом.',
      );
      await _load();
    } catch (error) {
      debugPrint('Album upload failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _uploading = false;
        _uploadProgress = null;
      });
      _showMessage('Не удалось загрузить фото. Попробуйте ещё раз.');
    }
  }

  void _showMessage(String text) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Подпись на кнопке во время загрузки: «Загружено 3 из 8».
  String get _fabLabel {
    if (!_uploading) {
      return 'Добавить фото';
    }
    final progress = _uploadProgress;
    if (progress == null || progress.total <= 1) {
      return 'Загружаем…';
    }
    switch (progress.stage) {
      case MediaUploadStage.preparing:
        return 'Готовим ${progress.total} фото';
      case MediaUploadStage.uploading:
        return 'Загружено ${progress.completed} из ${progress.total}';
      case MediaUploadStage.publishing:
        return 'Сохраняем…';
    }
  }

  PostServiceInterface? _service() {
    if (widget.serviceOverride != null) return widget.serviceOverride;
    if (GetIt.I.isRegistered<PostServiceInterface>()) {
      return GetIt.I<PostServiceInterface>();
    }
    return null;
  }

  PostsCache? _cache() {
    if (widget.cacheOverride != null) return widget.cacheOverride;
    if (GetIt.I.isRegistered<PostsCache>()) return GetIt.I<PostsCache>();
    return null;
  }

  Future<void> _load() async {
    // Offline-first: hydrate from the audience cache before the network.
    final cache = _cache();
    if (cache != null) {
      try {
        final cached = await cache.read(_audienceCacheKey);
        if (cached.isNotEmpty && mounted) {
          setState(() => _photos = _collect(cached));
        }
      } catch (_) {
        // Cache miss is non-fatal.
      }
    }

    final svc = _service();
    if (svc == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      // treeId: null = audience aggregate across ALL the viewer's
      // branches (same scope the home feed uses in «Все» mode).
      final posts = await svc.getPosts(treeId: null);
      if (!mounted) return;
      setState(() {
        _photos = _collect(posts);
        _loading = false;
        _loadFailed = false;
      });
    } catch (_) {
      // Offline-first: a network failure is only an error if we have
      // nothing cached to show. With cached photos we keep them (CP-4).
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = _photos.isEmpty;
        });
      }
    }
  }

  Future<void> _retry() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    await _load();
  }

  /// Flatten posts → photos, newest-first, deduped by URL. Videos are
  /// skipped (album v1 is photos; posts store videos in imageUrls too).
  List<_AlbumPhoto> _collect(List<Post> posts) {
    final sorted = [...posts]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final out = <_AlbumPhoto>[];
    final seen = <String>{};
    for (final post in sorted) {
      for (final url in post.renderableImageUrls) {
        if (_isVideoUrl(url)) continue;
        if (!seen.add(url)) continue;
        out.add(_AlbumPhoto(
          url: url,
          authorId: post.authorId,
          authorName: post.authorName,
          createdAt: post.createdAt,
        ));
      }
    }
    return out;
  }

  bool _isVideoUrl(String url) {
    final lower = url.toLowerCase();
    final q = lower.indexOf('?');
    final path = q >= 0 ? lower.substring(0, q) : lower;
    return path.endsWith('.mp4') ||
        path.endsWith('.mov') ||
        path.endsWith('.webm') ||
        path.endsWith('.m4v') ||
        path.endsWith('.avi');
  }

  /// Distinct authors (id → display name), in first-seen order — drives
  /// the «по автору» filter chips.
  Map<String, String> get _authors {
    final map = <String, String>{};
    for (final p in _photos) {
      map.putIfAbsent(p.authorId, () => p.authorName);
    }
    return map;
  }

  List<_AlbumPhoto> get _visiblePhotos => _authorFilter == null
      ? _photos
      : _photos.where((p) => p.authorId == _authorFilter).toList();

  void _openLightbox(int index) {
    final photos = _visiblePhotos;
    if (photos.isEmpty) return;
    MediaLightbox.show(
      context,
      items: [
        for (final p in photos) MediaLightboxItem(imageUrl: p.url),
      ],
      initialIndex: index.clamp(0, photos.length - 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final visible = _visiblePhotos;
    return Scaffold(
      appBar: AppBar(title: const Text('Альбом семьи')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploading ? null : _pickAndUpload,
        icon: _uploading
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: _uploadProgress?.value,
                  color: tokens.accentInk,
                ),
              )
            : const Icon(Icons.add_photo_alternate_outlined),
        label: Text(_fabLabel),
      ),
      body: _loading && _photos.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildAuthorFilter(theme, tokens),
                Expanded(
                  child: _loadFailed && _photos.isEmpty
                      ? _buildError(theme, tokens)
                      : visible.isEmpty
                          ? (_authorFilter != null
                              ? _buildFilterEmpty(theme, tokens)
                              : _buildEmpty(theme, tokens))
                          : _buildSections(theme, tokens, visible),
                ),
              ],
            ),
    );
  }

  Widget _buildAuthorFilter(ThemeData theme, RodnyaDesignTokens tokens) {
    final authors = _authors;
    // Pointless when everything is from one author (or empty).
    if (authors.length < 2) return const SizedBox.shrink();
    final entries = authors.entries.toList();
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: tokens.space12, vertical: 6),
        itemCount: entries.length + 1,
        separatorBuilder: (_, __) => SizedBox(width: tokens.space8),
        itemBuilder: (context, index) {
          if (index == 0) {
            return ChoiceChip(
              key: const Key('album-author-all'),
              label: const Text('Все'),
              selected: _authorFilter == null,
              onSelected: (_) => setState(() => _authorFilter = null),
            );
          }
          final entry = entries[index - 1];
          return ChoiceChip(
            label: Text(entry.value),
            selected: _authorFilter == entry.key,
            onSelected: (_) => setState(() => _authorFilter = entry.key),
          );
        },
      ),
    );
  }

  // ── «N лет назад» — memories resurfacing ──

  /// Photos from past years whose date falls within ±[_memoryWindowDays]
  /// of today (handling the Dec↔Jan wrap). Keeps the input order
  /// (newest-first), so the strip leads with the most recent memory.
  List<_AlbumPhoto> _memoriesFor(List<_AlbumPhoto> photos) {
    final now = _now;
    return photos.where((p) => _isOnThisDay(p.createdAt, now)).toList();
  }

  bool _isOnThisDay(DateTime created, DateTime now) {
    if (created.year >= now.year) return false; // only past years
    final today = DateTime(now.year, now.month, now.day);
    for (final year in [now.year - 1, now.year, now.year + 1]) {
      final anchor = DateTime(year, created.month, created.day);
      if (anchor.difference(today).inDays.abs() <= _memoryWindowDays) {
        return true;
      }
    }
    return false;
  }

  /// «Год назад» / «3 года назад» / «5 лет назад» (RU plural rules). When
  /// the strip spans several past years, a neutral header is used instead.
  String _memoryHeader(List<_AlbumPhoto> memories) {
    final nowYear = _now.year;
    final yearsAgo = memories.map((m) => nowYear - m.createdAt.year).toSet();
    if (yearsAgo.length != 1) return 'В этот день раньше';
    final years = yearsAgo.first;
    if (years == 1) return 'Год назад';
    final mod10 = years % 10;
    final mod100 = years % 100;
    final word = (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14))
        ? 'года'
        : 'лет';
    return '$years $word назад';
  }

  void _openMemoryLightbox(List<_AlbumPhoto> memories, int index) {
    if (memories.isEmpty) return;
    MediaLightbox.show(
      context,
      items: [for (final p in memories) MediaLightboxItem(imageUrl: p.url)],
      initialIndex: index.clamp(0, memories.length - 1),
    );
  }

  Widget _buildMemoryStrip(
    ThemeData theme,
    RodnyaDesignTokens tokens,
    List<_AlbumPhoto> memories,
  ) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.space12,
        tokens.space12,
        0,
        tokens.space4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(right: tokens.space12),
            child: Row(
              children: [
                Icon(Icons.auto_awesome_outlined, size: 18, color: tokens.warm),
                SizedBox(width: tokens.space8),
                Text(
                  _memoryHeader(memories),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontFamily: 'Lora',
                    fontWeight: FontWeight.w700,
                    color: tokens.warm,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.space8),
          SizedBox(
            height: 104,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 12),
              itemCount: memories.length,
              separatorBuilder: (_, __) => SizedBox(width: tokens.space8),
              itemBuilder: (_, i) => ClipRRect(
                borderRadius: BorderRadius.circular(tokens.radiusSm),
                child: SizedBox(
                  width: 104,
                  height: 104,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CachedNetworkImage(
                        imageUrl: memories[i].url,
                        fit: BoxFit.cover,
                        // M2: декод под фиксированный 104dp-тайл.
                        memCacheWidth: decodeCacheWidth(context, 104),
                        placeholder: (_, __) => Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                        ),
                        errorWidget: (_, __, ___) => Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: Key('album-memory-$i'),
                          onTap: () => _openMemoryLightbox(memories, i),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Group [photos] (already newest-first) into month buckets — because
  /// the list is date-sorted, every month's photos are contiguous, so a
  /// single pass yields newest-month-first sections without a map. Each
  /// thumb keeps its global index so the lightbox still pages the whole
  /// album in chronology.
  List<_MonthSection> _groupByMonth(List<_AlbumPhoto> photos) {
    final sections = <_MonthSection>[];
    for (var i = 0; i < photos.length; i++) {
      final photo = photos[i];
      final month = DateTime(photo.createdAt.year, photo.createdAt.month);
      if (sections.isEmpty || sections.last.month != month) {
        sections.add(_MonthSection(month: month));
      }
      sections.last.items.add(_IndexedPhoto(photo: photo, globalIndex: i));
    }
    return sections;
  }

  String _monthLabel(DateTime month) {
    // Standalone (nominative) month name: «Июнь 2026», not «июня».
    final raw = DateFormat('LLLL yyyy', 'ru').format(month);
    return raw.isEmpty ? raw : raw[0].toUpperCase() + raw.substring(1);
  }

  Widget _buildSections(
    ThemeData theme,
    RodnyaDesignTokens tokens,
    List<_AlbumPhoto> photos,
  ) {
    final sections = _groupByMonth(photos);
    final memories = _memoriesFor(photos);
    // Full-screen route (pushed on the root navigator like post/search) →
    // no bottom nav, so we only clear the device safe-area inset.
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    return CustomScrollView(
      slivers: [
        if (memories.isNotEmpty)
          SliverToBoxAdapter(
            child: _buildMemoryStrip(theme, tokens, memories),
          ),
        for (final section in sections) ...[
          SliverPersistentHeader(
            pinned: true,
            delegate: _MonthHeaderDelegate(
              label: _monthLabel(section.month),
              background: tokens.bgBase,
              textStyle: theme.textTheme.titleSmall?.copyWith(
                fontFamily: 'Lora',
                fontWeight: FontWeight.w700,
                color: tokens.ink,
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              tokens.space12,
              tokens.space8,
              tokens.space12,
              tokens.space16,
            ),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: tokens.space8,
                mainAxisSpacing: tokens.space8,
              ),
              delegate: SliverChildBuilderDelegate(
                (_, i) {
                  final indexed = section.items[i];
                  return _buildThumb(
                    theme,
                    tokens,
                    indexed.photo,
                    indexed.globalIndex,
                  );
                },
                childCount: section.items.length,
              ),
            ),
          ),
        ],
        SliverToBoxAdapter(child: SizedBox(height: bottomInset)),
      ],
    );
  }

  Widget _buildThumb(
    ThemeData theme,
    RodnyaDesignTokens tokens,
    _AlbumPhoto photo,
    int globalIndex,
  ) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(tokens.radiusSm),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            imageUrl: photo.url,
            fit: BoxFit.cover,
            // M2: грид 3 колонки во всю ширину → тайл ≈ треть экрана.
            memCacheWidth: decodeCacheWidth(
              context,
              MediaQuery.of(context).size.width / 3,
            ),
            placeholder: (_, __) => Container(
              color: theme.colorScheme.surfaceContainerHighest,
            ),
            errorWidget: (_, __, ___) => Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Icon(
                Icons.broken_image_outlined,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          // Transparent ink layer over the image → tap ripple feedback.
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: Key('album-thumb-$globalIndex'),
              onTap: () => _openLightbox(globalIndex),
            ),
          ),
        ],
      ),
    );
  }

  /// Network load failed and there's nothing cached to fall back on —
  /// honest error + retry (CP-4), instead of a silently empty grid.
  Widget _buildError(ThemeData theme, RodnyaDesignTokens tokens) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            SizedBox(height: tokens.space12),
            Text(
              'Не удалось загрузить альбом',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontFamily: 'Lora',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: tokens.space8),
            Text(
              'Проверьте соединение и попробуйте ещё раз.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: tokens.space16),
            FilledButton.tonal(
              key: const Key('album-retry'),
              onPressed: _retry,
              child: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }

  /// Shown when a per-author filter is active but matches no photos —
  /// honest copy + a one-tap escape back to all photos. (Reachable when
  /// the filtered author's photos drop out on a refresh while the filter
  /// is still set.)
  Widget _buildFilterEmpty(ThemeData theme, RodnyaDesignTokens tokens) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            SizedBox(height: tokens.space12),
            Text(
              'У этого автора пока нет фото',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontFamily: 'Lora',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: tokens.space8),
            FilledButton.tonal(
              key: const Key('album-show-all'),
              onPressed: () => setState(() => _authorFilter = null),
              child: const Text('Показать все'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(ThemeData theme, RodnyaDesignTokens tokens) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            SizedBox(height: tokens.space12),
            Text(
              'Пока нет фотографий',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontFamily: 'Lora',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: tokens.space8),
            Text(
              'Поделись первым моментом в ленте — фото соберутся здесь.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
