// Phase B polish C: «Не бойся сломать» reassurance banner (SHARED-TREE-
// PROPOSAL §4: «Не бойся сломать — каждое действие можно отменить.»).
// Shown where the tree is edited; dismissible, and once dismissed it
// stays dismissed (SharedPreferences). Mirrors onboarding_resume_banner's
// Material + tokens treatment.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

class DontFearBreakingBanner extends StatefulWidget {
  const DontFearBreakingBanner({super.key});

  static const String _prefsKey = 'dont_fear_breaking_banner_dismissed_v1';

  @override
  State<DontFearBreakingBanner> createState() => _DontFearBreakingBannerState();
}

class _DontFearBreakingBannerState extends State<DontFearBreakingBanner> {
  bool _resolved = false;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dismissed = prefs.getBool(DontFearBreakingBanner._prefsKey) ?? false;
      if (!mounted) return;
      setState(() {
        _dismissed = dismissed;
        _resolved = true;
      });
    } catch (_) {
      if (mounted) setState(() => _resolved = true);
    }
  }

  Future<void> _dismiss() async {
    setState(() => _dismissed = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(DontFearBreakingBanner._prefsKey, true);
    } catch (_) {
      // Persisting failure is non-fatal — it just shows again next time.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_resolved || _dismissed) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (isDark ? RodnyaDesignTokens.dark : RodnyaDesignTokens.light);

    // Плотность (02.09.2026): одна строка вместо заголовка + подзаголовка —
    // ~40dp вместо ~90 на главном экране продукта; смысл тот же, показ до
    // первого закрытия — тот же.
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
      child: Material(
        key: const Key('dont-fear-breaking-banner'),
        color: tokens.surfaceStrong.withValues(alpha: isDark ? 0.92 : 0.96),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusSm),
          side: BorderSide(
            color: theme.colorScheme.primary.withValues(alpha: 0.45),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 2, 4),
          child: Row(
            children: [
              Icon(
                Icons.shield_outlined,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Не бойся сломать — каждое действие можно отменить.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.ink,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
              ),
              IconButton(
                key: const Key('dont-fear-breaking-banner-dismiss'),
                tooltip: 'Скрыть',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: tokens.inkSecondary,
                ),
                onPressed: _dismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
