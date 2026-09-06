import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/onboarding_capable_family_tree_service.dart';
import '../backend/models/onboarding_state.dart';
import '../theme/app_theme.dart';

/// Ship Q1 (2026-05-25): home-screen banner showing «resume wizard»
/// CTA для users who tapped «Пропустить» в onboarding welcome step.
/// Renders nothing когда:
///   • backend service не capable (legacy server)
///   • auth service indicates no skipped state
///   • OnboardingState.shouldShowResumeBanner == false
///
/// Tap navigates к /setup чтобы resume wizard — wizard's existing
/// state hydration picks up currentStep, banner re-evaluates после
/// completion via authStateChanges subscription.
class OnboardingResumeBanner extends StatefulWidget {
  const OnboardingResumeBanner({super.key, this.deferUntil});

  /// S-fanout (05.09.2026): без этого поля баннер стреляет своим
  /// `/v1/me/onboarding-state` GET прямо на mount — то есть в том же
  /// кадре, что и весь остальной стартовый fan-out (~10 параллельных
  /// GET на холодном старте). Когда caller (HomeScreen's
  /// StartupScheduler) передаёт [deferUntil], реальный `_resolve()`
  /// откладывается до завершения этого future — HomeScreen ставит его
  /// последним в свою последовательную очередь «второй волны», так что
  /// этот запрос уходит последним, а не в общей пачке. `null` (любое
  /// другое встраивание баннера, включая существующие тесты) сохраняет
  /// прежнее немедленное поведение.
  final Future<void>? deferUntil;

  /// Сброс session-dismiss между тестами (static переживает пересоздание
  /// виджета — этим и ценен в проде, но тестам нужен чистый старт).
  @visibleForTesting
  static void debugResetSessionDismissal() {
    _OnboardingResumeBannerState._sessionDismissed = false;
  }

  @override
  State<OnboardingResumeBanner> createState() => _OnboardingResumeBannerState();
}

class _OnboardingResumeBannerState extends State<OnboardingResumeBanner> {
  /// 2b: «Скрыть» приглушает баннер до конца сессии (static переживает
  /// пересоздание экрана, сбрасывается перезапуском приложения). Состояние
  /// onboarding'а на бэке не трогаем — баннер вернётся в новой сессии,
  /// если мастер так и не завершён.
  static bool _sessionDismissed = false;

  bool _resolved = false;
  OnboardingState? _state;
  StreamSubscription<String?>? _authSubscription;

  @override
  void initState() {
    super.initState();
    final gate = widget.deferUntil;
    if (gate != null) {
      unawaited(gate.then((_) {
        if (mounted) _resolve();
      }));
    } else {
      _resolve();
    }
    if (GetIt.I.isRegistered<AuthServiceInterface>()) {
      // Re-fetch state когда session changes (skip / completion /
      // refresh broadcast'нут authStateChanges).
      _authSubscription =
          GetIt.I<AuthServiceInterface>().authStateChanges.listen((_) {
        if (!mounted) return;
        _resolve();
      });
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<void> _resolve() async {
    if (!GetIt.I.isRegistered<FamilyTreeServiceInterface>()) {
      if (mounted) setState(() => _resolved = true);
      return;
    }
    final service = GetIt.I<FamilyTreeServiceInterface>();
    if (service is! OnboardingCapableFamilyTreeService) {
      if (mounted) setState(() => _resolved = true);
      return;
    }
    try {
      final fetched = await (service as OnboardingCapableFamilyTreeService)
          .getOnboardingState();
      if (!mounted) return;
      setState(() {
        _state = fetched;
        _resolved = true;
      });
    } catch (_) {
      if (mounted) setState(() => _resolved = true);
    }
  }

  void _dismissForSession() {
    setState(() => _sessionDismissed = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_resolved || _sessionDismissed) return const SizedBox.shrink();
    final state = _state;
    if (state == null || !state.shouldShowResumeBanner) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (isDark ? RodnyaDesignTokens.dark : RodnyaDesignTokens.light);

    // Плотность, чанк 17 (05.09.2026): рамка-карточка (border + скругление
    // 20) → лёгкая заливка без обводки, паддинг ужат — та же строка
    // «заголовок 15sp / подпись 13sp», но ближе к ≤56dp. Показ/дисмисс/тап
    // в /setup — без изменений.
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Material(
        color:
            theme.colorScheme.primary.withValues(alpha: isDark ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(tokens.radiusSm),
        child: InkWell(
          key: const Key('onboarding-resume-banner'),
          borderRadius: BorderRadius.circular(tokens.radiusSm),
          onTap: () => context.go('/setup'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            child: Row(
              children: [
                Icon(
                  Icons.account_tree_rounded,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Закончите настройку дерева',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: tokens.ink,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        'Добавьте свою карточку и близких',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: tokens.inkSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                // Закрытие — IconButton с полным ≥44dp тап-таргетом, чтобы
                // старшим не приходилось целиться (2c-ритм).
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  tooltip: 'Скрыть',
                  color: tokens.inkSecondary,
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: _dismissForSession,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
