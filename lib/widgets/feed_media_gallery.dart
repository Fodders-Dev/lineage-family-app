// Shared feed media gallery — extracted from post_card.dart so posts and
// gatherings render photos identically (single 16:9 tile, multi-photo
// carousel with page-dots, video tiles, on-brand shimmer placeholder,
// broken-image fallback, video-extension sniffing). Behaviour is a
// verbatim move; the caller owns the tap action (e.g. MediaLightbox.show)
// via [onTap] so each surface can wire its own lightbox affordances.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:carousel_slider/carousel_slider.dart';
import 'package:flutter/material.dart' hide CarouselController;
import 'package:shimmer/shimmer.dart';

import '../theme/app_theme.dart';
import '../utils/image_decode.dart';

/// True when [url] points at a video by extension (query string ignored).
bool isFeedVideoUrl(String url) {
  final lower = url.toLowerCase();
  final qIndex = lower.indexOf('?');
  final pathOnly = qIndex >= 0 ? lower.substring(0, qIndex) : lower;
  return pathOnly.endsWith('.mp4') ||
      pathOnly.endsWith('.mov') ||
      pathOnly.endsWith('.webm') ||
      pathOnly.endsWith('.m4v') ||
      pathOnly.endsWith('.avi');
}

class FeedMediaGallery extends StatelessWidget {
  const FeedMediaGallery({
    super.key,
    required this.imageUrls,
    required this.onTap,
    this.caption,
    this.captionPrefix = 'Фото',
    this.padding,
  });

  /// Renderable media URLs (photos + videos). Empty → renders nothing.
  final List<String> imageUrls;

  /// Tapped tile index — the caller opens the lightbox (so each surface
  /// can attach its own actions like like/comment/share).
  final void Function(int index) onTap;

  /// Optional a11y caption text (e.g. the post body).
  final String? caption;

  /// a11y label prefix; combined with [caption] as `prefix: caption`.
  final String captionPrefix;

  /// Outer padding around the gallery. Defaults to the post inset
  /// (space12 sides + bottom); surfaces that already pad their content
  /// (e.g. the gathering card) pass [EdgeInsets.zero].
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    if (imageUrls.isEmpty) return const SizedBox.shrink();
    final tokens = _tokensFor(context);
    // Плотность (чанк 20): скругление 12 (было tokens.radiusMd = 20) —
    // единый радиус для одиночного тайла и карусели, без рамки-в-рамке.
    final borderRadius = BorderRadius.circular(12);
    final pad = padding ??
        EdgeInsets.fromLTRB(
          tokens.space12,
          0,
          tokens.space12,
          tokens.space12,
        );

    if (imageUrls.length == 1) {
      return Padding(
        padding: pad,
        child: AspectRatio(
          // Плотность (чанк 20): не выше 4:5 (портретный кап) — было
          // жёсткое 16:9, которое сильно обрезало вертикальные фото.
          aspectRatio: 4 / 5,
          child: ClipRRect(
            borderRadius: borderRadius,
            // MouseRegion gives a "click" cursor on web/desktop; we keep
            // GestureDetector (vs InkWell) because an ink ripple on a
            // full-bleed photo looks like a glitch.
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onTap(0),
                child: _tileFor(context, imageUrls.first),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: pad,
      child: _MediaImageCarousel(
        images: imageUrls,
        borderRadius: borderRadius,
        tileFor: (url) => _tileFor(context, url),
        onTapImage: onTap,
      ),
    );
  }

  Widget _tileFor(BuildContext context, String url) {
    if (isFeedVideoUrl(url)) {
      return _MediaVideoTile(url: url);
    }
    final trimmed = caption?.trim() ?? '';
    return Semantics(
      label: trimmed.isEmpty ? captionPrefix : '$captionPrefix: $trimmed',
      image: true,
      excludeSemantics: true,
      child: CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        // M2: декод под ширину экрана (слот фида не шире) — без этого
        // оригиналы 3-4К с телефонов декодятся целиком (jank/OOM на A50).
        memCacheWidth: decodeCacheWidthForScreen(context),
        placeholder: (_, __) => const FeedMediaPlaceholder(),
        errorWidget: (_, __, ___) => const FeedMediaFallback(),
      ),
    );
  }

  static RodnyaDesignTokens _tokensFor(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
  }
}

/// On-brand shimmer fill shown while a feed image resolves (matches the
/// feed skeleton language rather than a stray Material spinner).
class FeedMediaPlaceholder extends StatelessWidget {
  const FeedMediaPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Shimmer.fromColors(
      baseColor: isDark
          ? theme.colorScheme.surfaceContainerHigh
          : theme.colorScheme.surfaceContainerHighest,
      highlightColor: isDark
          ? theme.colorScheme.surfaceContainerHighest
          : theme.colorScheme.surfaceContainerLowest,
      child: Container(color: Colors.white),
    );
  }
}

/// Broken-image fallback tile — also used for "image URL not renderable".
class FeedMediaFallback extends StatelessWidget {
  const FeedMediaFallback({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
      child: Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A video tile — a poster-coloured surface with a play badge. Tapping
/// (handled by the parent gallery) opens MediaLightbox which streams the
/// real video.
class _MediaVideoTile extends StatelessWidget {
  const _MediaVideoTile({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF332B45), Color(0xFF181522)],
            ),
          ),
        ),
        Center(
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.32),
                  blurRadius: 16,
                  spreadRadius: -2,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: 36,
            ),
          ),
        ),
        const Positioned(
          top: 12,
          right: 12,
          child: _VideoBadge(),
        ),
      ],
    );
  }
}

class _VideoBadge extends StatelessWidget {
  const _VideoBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam_rounded, color: Colors.white, size: 14),
          SizedBox(width: 4),
          Text(
            'Видео',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Multi-photo carousel with a page-dots indicator (UX-audit 3.4). Owns
/// its own page index so the surrounding card doesn't rebuild on swipe.
class _MediaImageCarousel extends StatefulWidget {
  const _MediaImageCarousel({
    required this.images,
    required this.borderRadius,
    required this.tileFor,
    required this.onTapImage,
  });

  final List<String> images;
  final BorderRadius borderRadius;
  final Widget Function(String url) tileFor;
  final void Function(int index) onTapImage;

  @override
  State<_MediaImageCarousel> createState() => _MediaImageCarouselState();
}

class _MediaImageCarouselState extends State<_MediaImageCarousel> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.bottomCenter,
      children: [
        CarouselSlider.builder(
          itemCount: widget.images.length,
          itemBuilder: (context, index, _) {
            return ClipRRect(
              borderRadius: widget.borderRadius,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onTapImage(index),
                  child: SizedBox(
                    width: MediaQuery.of(context).size.width,
                    child: widget.tileFor(widget.images[index]),
                  ),
                ),
              ),
            );
          },
          options: CarouselOptions(
            aspectRatio: 16 / 9,
            viewportFraction: 1,
            enableInfiniteScroll: false,
            autoPlay: false,
            enlargeCenterPage: false,
            onPageChanged: (index, _) {
              if (mounted) setState(() => _index = index);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            // Kept as 'post-carousel-dots' so the existing post_card test
            // hook still resolves; the same gallery now backs gatherings.
            key: const Key('post-carousel-dots'),
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.images.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: i == _index ? 18 : 6,
                  height: 6,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color: i == _index
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(3),
                    boxShadow: const [
                      BoxShadow(color: Color(0x55000000), blurRadius: 4),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
