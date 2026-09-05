import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../services/custom_api_notification_service.dart';
import '../theme/app_theme.dart';

/// N2: ненавязчивый dismissible CTA «Включить уведомления».
///
/// Чинит оба перекоса iOS/web-бага:
///  • «у одних нет уведомлений» — теперь явный CTA вместо тихого «всё
///    включено»;
///  • «у других постоянно вылезает запрос» — запрос ТОЛЬКО по тапу
///    (жест, иначе iOS молча игнорирует) и один раз: после grant/deny/
///    закрытия флаг в prefs гасит баннер навсегда.
///
/// Показывается, когда сервис говорит [shouldShowPermissionCta]
/// (web && permission==default && pref-enabled && не закрыт) ИЛИ это
/// iOS вне PWA — тогда вместо запроса подсказываем «добавьте на Домой».
///
/// Плотность, чанк 17 (05.09.2026): карточка с рамкой + заголовок 20sp +
/// три строки текста + полноширинная кнопка занимала ~150dp над шапкой
/// ЛЮБОЙ вкладки на свежей установке — больше, чем сэкономил весь чанк 16
/// по дереву. Теперь одна строка (иконка + текст + кнопка + крестик),
/// без рамки-карточки. Показ/дисмисс/обработчики — без изменений.
class NotificationPermissionBanner extends StatefulWidget {
  const NotificationPermissionBanner({super.key});

  @override
  State<NotificationPermissionBanner> createState() =>
      _NotificationPermissionBannerState();
}

class _NotificationPermissionBannerState
    extends State<NotificationPermissionBanner> {
  bool _busy = false;

  CustomApiNotificationService? get _service =>
      GetIt.I.isRegistered<CustomApiNotificationService>()
          ? GetIt.I<CustomApiNotificationService>()
          : null;

  Future<void> _enable() async {
    final service = _service;
    if (service == null || _busy) return;
    setState(() => _busy = true);
    try {
      // Тап = user-gesture → реальный requestPermission(prompt:true) и
      // подписка на push при grant.
      await service.setNotificationsEnabled(
        true,
        promptForBrowserPermission: true,
      );
    } catch (_) {
      // CTA — best-effort: ошибку проглатываем, баннер всё равно гасим
      // (повторно дёргать запрос смысла нет).
    } finally {
      // grant / deny — в обоих случаях больше не показываем.
      await service.dismissNotificationCta();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _dismiss() async {
    final service = _service;
    if (service == null) return;
    await service.dismissNotificationCta();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    if (service == null || !service.shouldShowPermissionCta) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (isDark ? RodnyaDesignTokens.dark : RodnyaDesignTokens.light);

    // N3: на iOS вне PWA — инструкция вместо кнопки запроса.
    final iosAddToHome = service.iosNeedsStandaloneForPush;
    // Заголовок + подпись вместо одной длинной фразы: рядом с кнопкой и
    // крестиком на 360–412dp строка вмещает ~30 символов, и «…чтобы не
    // пропустить сообщ…» резалось многоточием даже в две строки.
    final title = iosAddToHome
        ? 'Добавьте «Родню» на экран «Домой»'
        : 'Включите уведомления';
    final subtitle = iosAddToHome
        ? 'Так на iPhone приходят уведомления'
        : 'Звонки и сообщения родных';

    // Баннер показывается и на Android (разрешение не выдано) — в мобильном
    // шелле он верхний элемент без инсета, как AppUpdateBanner (FX-A): без
    // SafeArea текст уходил под статус-бар. Под AppBar/SafeArea — no-op.
    return SafeArea(
      top: true,
      bottom: false,
      left: false,
      right: false,
      child: Container(
        key: const Key('notification-permission-banner'),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.surfaceLine)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
        child: Row(
          children: [
            Icon(
              Icons.notifications_active_outlined,
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
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: tokens.ink,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 13,
                      color: tokens.inkSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (!iosAddToHome) ...[
              const SizedBox(width: 8),
              TextButton(
                key: const Key('notification-permission-enable'),
                onPressed: _busy ? null : _enable,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Включить'),
              ),
            ],
            // ≥44dp тап-цель для закрытия (2c-ритм для 50+).
            IconButton(
              key: const Key('notification-permission-dismiss'),
              icon: const Icon(Icons.close_rounded, size: 18),
              tooltip: 'Скрыть',
              color: tokens.inkSecondary,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              padding: EdgeInsets.zero,
              onPressed: _dismiss,
            ),
          ],
        ),
      ),
    );
  }
}
