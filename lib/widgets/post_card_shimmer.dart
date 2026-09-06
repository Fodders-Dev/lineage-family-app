import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../theme/app_theme.dart';
import 'glass_panel.dart';

/// Loading placeholder that mirrors [PostCard]'s real geometry — same
/// GlassPanel shell, 40dp author avatar, header line, a couple of body
/// lines, a full-bleed 4:5-capped media block, then a 3-button 44dp
/// action row (no divider). Because the skeleton matches where content
/// will land, the swap to real posts reads as a settle rather than a
/// reflow. Shimmer tones are pulled from the warm palette (surface
/// containers) so it stays on-brand instead of a neutral grey card.
///
/// Плотность (чанк 20): numbers below track post_card.dart's
/// _buildPostHeader / content Text / _buildPostImages / _buildPostActions
/// after the density pass — see that file's inline comments for the
/// before/after rationale.
class PostCardShimmer extends StatelessWidget {
  const PostCardShimmer({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final isDark = theme.brightness == Brightness.dark;
    // Resting tone + brighter sweep, both warm-palette derived.
    final baseColor = isDark
        ? theme.colorScheme.surfaceContainerHigh
        : theme.colorScheme.surfaceContainerHighest;
    final highlightColor = isDark
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.surfaceContainerLowest;

    return GlassPanel(
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
      borderRadius: BorderRadius.circular(tokens.radiusMd + 2),
      plain: true,
      child: Shimmer.fromColors(
        baseColor: baseColor,
        highlightColor: highlightColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header — avatar + name/meta lines (mirrors _buildPostHeader).
            // Row height pinned to 48 — that's not the 40dp avatar, it's
            // the Material minimum tap-target the overflow menu's
            // IconButton holds regardless of our own constraints; +4/4
            // padding = 56dp header, matching the real card.
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
              child: SizedBox(
                height: 48,
                child: Row(
                  children: [
                    _block(width: 40, height: 40, shape: BoxShape.circle),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        _ShimmerBar(width: 120, height: 14),
                        SizedBox(height: 6),
                        _ShimmerBar(width: 80, height: 11),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            // Body text lines (mirrors content padding: 12 sides, 4 bottom).
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ShimmerBar(width: double.infinity, height: 14),
                  SizedBox(height: 6),
                  _ShimmerBar(width: 160, height: 14),
                ],
              ),
            ),
            // Media block (mirrors FeedMediaGallery single-tile: full
            // width, 4:5 cap, radius 12, no side inset).
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AspectRatio(
                // Как стартовое состояние настоящей плитки (16:9, пока
                // размер снимка не известен) — переход без прыжка.
                aspectRatio: 16 / 9,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            // 3-button action row (mirrors _buildPostActions: 44dp tap
            // targets, no divider).
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
              child: Row(
                children: const [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: Center(child: _ShimmerBar(width: 56, height: 14)),
                    ),
                  ),
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: Center(child: _ShimmerBar(width: 56, height: 14)),
                    ),
                  ),
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: Center(child: _ShimmerBar(width: 56, height: 14)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _block({
    required double width,
    required double height,
    BoxShape shape = BoxShape.rectangle,
  }) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: shape,
      ),
    );
  }
}

/// A single rounded shimmer bar. The fill colour is irrelevant (Shimmer
/// paints its gradient over the opaque area) — only the shape matters.
class _ShimmerBar extends StatelessWidget {
  const _ShimmerBar({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(height / 2),
      ),
    );
  }
}
