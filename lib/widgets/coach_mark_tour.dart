// E (Week 7 §6): first-launch coach-mark tour. Custom overlay — NO
// package. A dimmed full-screen scrim with a spotlight hole punched over
// the current target (anchored via a GlobalKey on a real widget) plus a
// speech-bubble card that steps through 3-4 hotspots. Dismissible
// («Пропустить»); persists «shown» so it never repeats.
//
// Gating + persistence helpers live here (SharedPreferences, ..._v1 key)
// so the host screen just asks `shouldShow()` and calls `markShown()`.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

/// One step: the copy plus an optional [key] on the real widget to
/// spotlight. `key: null` — шаг без анкера: скрим без дырки и карточка
/// по центру. Нужен для того, что живёт ВНЕ экрана-хозяина (нижний бар
/// принадлежит шеллу), но объяснить это новичку всё равно надо.
class CoachMarkTarget {
  const CoachMarkTarget({
    this.key,
    required this.title,
    required this.body,
  });

  final GlobalKey? key;
  final String title;
  final String body;
}

/// Full-screen coach-mark overlay. Render it ABOVE the screen body (e.g.
/// in a Stack) when [CoachMarkTour.shouldShow] resolved true. Calls
/// [onDismiss] on skip or after the last step — the host persists + hides.
class CoachMarkTour extends StatefulWidget {
  const CoachMarkTour({
    super.key,
    required this.targets,
    required this.onDismiss,
  });

  final List<CoachMarkTarget> targets;
  final VoidCallback onDismiss;

  static const String _prefsKey = 'coach_marks_home_tour_shown_v1';

  /// True the first time only — once [markShown] has run it returns false.
  static Future<bool> shouldShow() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return !(prefs.getBool(_prefsKey) ?? false);
    } catch (_) {
      // Prefs unavailable → don't nag with a tour we can't remember
      // dismissing.
      return false;
    }
  }

  /// Persist that the tour has been seen (skip or completion) so it
  /// never shows again.
  static Future<void> markShown() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, true);
    } catch (_) {
      // Non-fatal — worst case it shows once more next launch.
    }
  }

  @override
  State<CoachMarkTour> createState() => _CoachMarkTourState();
}

class _CoachMarkTourState extends State<CoachMarkTour> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // F4: _resolveRect на ПЕРВОМ build идёт до layout — анкеры ещё без
    // размеров, и первый кадр рисовался с центрированным бубблом без
    // спотлайта (в проде это маскировали случайные rebuilds). Один
    // пост-фреймовый rebuild — и первый же видимый кадр целится точно.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _next() {
    if (_index >= widget.targets.length - 1) {
      widget.onDismiss();
      return;
    }
    setState(() => _index += 1);
  }

  Rect? _resolveRect(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final Rect globalRect;
    try {
      // findRenderObject throws if the element is inactive (e.g. a
      // GlobalKey mid-reparent, or a recycled ListView child) — treat
      // any such case as "no rect" → the bubble centres for that frame.
      final box = ctx.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return null;
      final topLeft = box.localToGlobal(Offset.zero);
      globalRect = topLeft & box.size;
    } catch (_) {
      return null;
    }
    // F4: оверлей тура живёт в Stack ПОД топбаром, а спотлайт-дырка и
    // буббл позиционируются в ЛОКАЛЬНЫХ координатах оверлея. Раньше
    // rect оставался глобальным — дырка «указывала мимо» блока на
    // высоту топбара (на wide-вёрстке web особенно заметно).
    // Переводим глобальный rect в систему координат оверлея; если сам
    // оверлей ещё не лэйаучен — честный fallback на глобальный rect.
    try {
      final overlayBox = context.findRenderObject();
      if (overlayBox is RenderBox &&
          overlayBox.attached &&
          overlayBox.hasSize) {
        return globalRect.shift(-overlayBox.localToGlobal(Offset.zero));
      }
    } catch (_) {
      // Падать нельзя — лучше глобальный rect, чем пустой кадр.
    }
    return globalRect;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final target = widget.targets[_index];
    final targetKey = target.key;
    final rect = targetKey == null ? null : _resolveRect(targetKey);
    final isLast = _index == widget.targets.length - 1;

    return Positioned.fill(
      child: Material(
        type: MaterialType.transparency,
        // F4: позиционируем буббл от размера ОВЕРЛЕЯ, не экрана — оверлей
        // живёт под топбаром, и экранная высота давала сдвиг.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final overlayHeight = constraints.maxHeight;
            // Bubble sits below the spotlight when the target is in the
            // top half, above it otherwise — so it never runs off-screen.
            final below =
                rect == null || rect.center.dy < overlayHeight / 2;
            return Stack(
              key: const Key('coach-mark-tour'),
              children: [
                // Dim + spotlight. Tapping the scrim advances (or
                // finishes).
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _next,
                    child: CustomPaint(
                      painter: _SpotlightPainter(rect: rect),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  top: below
                      ? (rect == null
                          ? overlayHeight * 0.5
                          : rect.bottom + 14)
                      : null,
                  bottom: below ? null : (overlayHeight - rect.top + 14),
                  child: _CoachBubble(
                    key: const Key('coach-mark-bubble'),
                    tokens: tokens,
                    title: target.title,
                    body: target.body,
                    stepLabel: '${_index + 1} / ${widget.targets.length}',
                    isLast: isLast,
                    onNext: _next,
                    onSkip: widget.onDismiss,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter({required this.rect});

  final Rect? rect;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.62);
    if (rect == null) {
      canvas.drawRect(Offset.zero & size, dim);
      return;
    }
    // Punch a rounded hole over the target via even-odd fill.
    final hole = RRect.fromRectAndRadius(
      rect!.inflate(8),
      const Radius.circular(16),
    );
    final path = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(hole)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, dim);

    // Soft ring around the spotlight.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.85);
    canvas.drawRRect(hole, ring);
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) => old.rect != rect;
}

class _CoachBubble extends StatelessWidget {
  const _CoachBubble({
    super.key,
    required this.tokens,
    required this.title,
    required this.body,
    required this.stepLabel,
    required this.isLast,
    required this.onNext,
    required this.onSkip,
  });

  final RodnyaDesignTokens tokens;
  final String title;
  final String body;
  final String stepLabel;
  final bool isLast;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: tokens.surfaceStrong,
      elevation: 8,
      borderRadius: BorderRadius.circular(tokens.radiusMd),
      child: Padding(
        padding: EdgeInsets.all(tokens.space16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              stepLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                color: tokens.inkMuted,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
            SizedBox(height: tokens.space8),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: tokens.ink,
              ),
            ),
            SizedBox(height: tokens.space4),
            Text(
              body,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tokens.inkSecondary,
                height: 1.35,
              ),
            ),
            SizedBox(height: tokens.space12),
            Row(
              children: [
                TextButton(
                  key: const Key('coach-mark-skip'),
                  onPressed: onSkip,
                  child: const Text('Пропустить'),
                ),
                const Spacer(),
                FilledButton(
                  key: const Key('coach-mark-next'),
                  onPressed: onNext,
                  child: Text(isLast ? 'Понятно' : 'Далее'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
