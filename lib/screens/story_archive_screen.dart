import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/intl.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/story_service_interface.dart';
import '../models/story.dart';
import '../theme/app_theme.dart';
import '../utils/date_parser.dart';
import '../utils/image_decode.dart';
import '../widgets/media_lightbox.dart';

/// Archive of the current user's expired stories — Instagram / Telegram
/// have one and the user explicitly asked for the same. Backend doesn't
/// surface expired entries yet (the `includeArchive=true` query hint we
/// pass is a forward-compat marker), so until the API support lands the
/// page renders an empty state with an explanation. The route shell +
/// fetch wiring + lightbox-on-tap behaviour are already in place so the
/// only follow-up is server-side: have `/v1/stories?includeArchive=true`
/// return rows whose `expiresAt < now`.
class StoryArchiveScreen extends StatefulWidget {
  const StoryArchiveScreen({super.key});

  @override
  State<StoryArchiveScreen> createState() => _StoryArchiveScreenState();
}

class _StoryArchiveScreenState extends State<StoryArchiveScreen> {
  final StoryServiceInterface _storyService = GetIt.I<StoryServiceInterface>();
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();

  bool _loading = true;
  Object? _error;
  List<Story> _archived = const <Story>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final userId = _authService.currentUserId;
    if (userId == null || userId.isEmpty) {
      setState(() {
        _loading = false;
        _archived = const <Story>[];
      });
      return;
    }
    try {
      final all = await _storyService.getStories(
        authorId: userId,
        includeArchive: true,
      );
      // Defense in depth: even if the backend already filters server
      // side, we re-filter here in case a not-yet-expired entry sneaks
      // through. The archive should only show fully expired stories.
      final now = DateTime.now();
      final expired = all.where((s) => s.expiresAt.isBefore(now)).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (!mounted) return;
      setState(() {
        _archived = expired;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _openStory(int index) {
    final items = <MediaLightboxItem>[];
    for (final story in _archived) {
      if (story.type == StoryType.video) {
        items.add(MediaLightboxItem(
          videoUrl: story.mediaUrl,
          thumbnailUrl: story.thumbnailUrl,
          caption: _captionFor(story),
        ));
      } else if (story.type == StoryType.image) {
        items.add(MediaLightboxItem(
          imageUrl: story.mediaUrl,
          caption: _captionFor(story),
        ));
      } else {
        // Text stories — represent in the lightbox as a captioned blank
        // (no media URL); the caption itself is the entire payload.
        items.add(MediaLightboxItem(caption: _captionFor(story)));
      }
    }
    if (items.isEmpty) return;
    MediaLightbox.show(
      context,
      items: items,
      initialIndex: index.clamp(0, items.length - 1),
    );
  }

  String _captionFor(Story story) {
    final date = DateFormat('d MMMM yyyy в HH:mm', 'ru')
        .format(toLocalForDisplay(story.createdAt));
    if (story.type == StoryType.text && (story.text ?? '').trim().isNotEmpty) {
      return '${story.text!.trim()}\n\n$date';
    }
    return date;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return Scaffold(
      backgroundColor: tokens.bgBase,
      appBar: AppBar(
        title: Text(
          'Архив историй',
          style: AppTheme.serif(
            color: tokens.ink,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: tokens.bgBase,
        elevation: 0,
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: _buildBody(tokens),
        ),
      ),
    );
  }

  Widget _buildBody(RodnyaDesignTokens tokens) {
    if (_loading) {
      // Skeleton grid — same shape as the loaded archive (3 cols,
      // 9:16) so the user sees the layout before the data lands
      // instead of a blank circular spinner.
      return GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 9 / 16,
        ),
        itemCount: 6,
        itemBuilder: (_, __) => Container(
          decoration: BoxDecoration(
            color: tokens.surfaceStrong.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      );
    }
    // Плотность: оба состояния были top-anchored ListView с фиксированным
    // паддингом (пустое — ещё и лишний SizedBox(32) сверху, итого 64dp
    // до иконки) — контент прижат к верху, а низ экрана пустует. Центр
    // по реальной высоте вьюпорта; иконка/заголовок уменьшены до размера,
    // принятого в остальных пустых состояниях приложения (48dp/titleLarge).
    if (_error != null) {
      return _scrollSafeCenter(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 48, color: tokens.inkSecondary),
              const SizedBox(height: 10),
              Text(
                'Не удалось загрузить архив. $_error',
                textAlign: TextAlign.center,
                style: AppTheme.sans(color: tokens.inkSecondary, fontSize: 14),
              ),
              const SizedBox(height: 14),
              FilledButton.tonalIcon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    }
    if (_archived.isEmpty) {
      return _scrollSafeCenter(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history_rounded, size: 48, color: tokens.inkSecondary),
              const SizedBox(height: 12),
              Text(
                'Архив пуст',
                textAlign: TextAlign.center,
                style: AppTheme.serif(
                  color: tokens.ink,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Истории, которым больше 24 часов, появятся здесь автоматически. Так вы сможете пересматривать их в любое время.',
                textAlign: TextAlign.center,
                style: AppTheme.sans(
                  color: tokens.inkSecondary,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 9 / 16,
      ),
      itemCount: _archived.length,
      itemBuilder: (context, index) => _ArchivedStoryTile(
          story: _archived[index], onTap: () => _openStory(index)),
    );
  }

  // Центрирует error/empty-контент по реальной высоте вьюпорта вместо
  // фиксированных отступов сверху (см. family_calendar_screen), сохраняя
  // pull-to-refresh — RefreshIndicator требует прокручиваемый потомок.
  Widget _scrollSafeCenter(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _ArchivedStoryTile extends StatelessWidget {
  const _ArchivedStoryTile({required this.story, required this.onTap});

  final Story story;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return Material(
      color: tokens.surfaceStrong,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildPoster(context, tokens),
              Positioned(
                left: 6,
                right: 6,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    DateFormat('d MMM', 'ru')
                        .format(toLocalForDisplay(story.createdAt)),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              if (story.type == StoryType.video)
                const Positioned(
                  top: 8,
                  right: 8,
                  child: Icon(
                    Icons.play_circle_filled_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPoster(BuildContext context, RodnyaDesignTokens tokens) {
    final url = story.thumbnailUrl ?? story.mediaUrl;
    if (story.type == StoryType.text || (url ?? '').isEmpty) {
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [tokens.accentSoft, tokens.accent.withValues(alpha: 0.32)],
          ),
        ),
        padding: const EdgeInsets.all(8),
        alignment: Alignment.center,
        child: Text(
          (story.text ?? '').trim().isEmpty ? 'История' : story.text!.trim(),
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: AppTheme.sans(
            color: tokens.ink,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            height: 1.25,
          ),
        ),
      );
    }
    return CachedNetworkImage(
      imageUrl: url!,
      fit: BoxFit.cover,
      // M2: плитка архива — не шире половины экрана (грид-превью).
      memCacheWidth: decodeCacheWidth(
        context,
        MediaQuery.of(context).size.width / 2,
      ),
      placeholder: (_, __) => ColoredBox(
        color: tokens.surfaceStrong,
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      errorWidget: (_, __, ___) => ColoredBox(
        color: tokens.surfaceStrong,
        child: Icon(
          Icons.broken_image_outlined,
          color: tokens.inkSecondary,
        ),
      ),
    );
  }
}
