import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/battery_optimization_advisor.dart';
import '../theme/app_theme.dart';

/// Dismissible advisory card shown once on Xiaomi/Honor/Huawei/Oppo
/// /OnePlus/Vivo devices that ship aggressive battery savers. These
/// vendors silently kill background services (including the push
/// listener) until the user explicitly whitelists the app in
/// Autostart + battery exception lists. Without that the user just
/// stops getting notifications and incoming-call rings, and they
/// have no way to know why.
///
/// Renders nothing on devices that don't need the warning, on web,
/// or after the user has dismissed it once.
class BatteryOptimizationCard extends StatefulWidget {
  const BatteryOptimizationCard({super.key});

  @override
  State<BatteryOptimizationCard> createState() =>
      _BatteryOptimizationCardState();
}

class _BatteryOptimizationCardState extends State<BatteryOptimizationCard> {
  bool _shouldShow = false;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    _resolveVisibility();
  }

  Future<void> _resolveVisibility() async {
    if (!GetIt.I.isRegistered<BatteryOptimizationAdvisor>()) {
      if (mounted) {
        setState(() {
          _resolved = true;
          _shouldShow = false;
        });
      }
      return;
    }
    final advisor = GetIt.I<BatteryOptimizationAdvisor>();
    final visible = await advisor.shouldShowOnboardingTip();
    if (!mounted) return;
    setState(() {
      _resolved = true;
      _shouldShow = visible;
    });
  }

  Future<void> _dismiss() async {
    if (GetIt.I.isRegistered<BatteryOptimizationAdvisor>()) {
      await GetIt.I<BatteryOptimizationAdvisor>().markOnboardingTipShown();
    }
    if (!mounted) return;
    setState(() => _shouldShow = false);
  }

  Future<void> _openSettings() async {
    // 1) Standard battery-exemption prompt (best-effort; some vendor ROMs
    //    don't expose it — the steps below still help there).
    try {
      final batteryStatus = await Permission.ignoreBatteryOptimizations.status;
      if (!batteryStatus.isGranted) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    } catch (_) {
      // Ignore: the autostart deep-link / app-settings fallback still run.
    }

    // 2) Deep-link straight into the OEM autostart / "protected apps"
    //    whitelist — the actual switch that lets a killed app wake up on a
    //    push/call. This screen is NOT reachable from the general app
    //    settings on Huawei/Xiaomi/Oppo/Vivo, so it's the important step.
    var openedAutostart = false;
    if (GetIt.I.isRegistered<BatteryOptimizationAdvisor>()) {
      try {
        openedAutostart =
            await GetIt.I<BatteryOptimizationAdvisor>().openAutostartSettings();
      } catch (_) {
        openedAutostart = false;
      }
    }

    // 3) Fallback: if we couldn't open the vendor autostart screen (unknown
    //    vendor, firmware drift, missing permission), open the general app
    //    settings so the user always lands on *some* useful screen.
    if (!openedAutostart) {
      // Прямого перехода нет (современные Huawei/HarmonyOS блокируют
      // deep-link, неизвестный вендор) — человек попадёт в общие настройки
      // приложения и без подсказки не найдёт нужный пункт. Названия меню
      // по вендорам раньше жили в тексте плашки на всех телефонах; теперь
      // их видят только те, кому они реально нужны — здесь.
      if (!mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Включите автозапуск вручную'),
          content: const Text(
            'Сейчас откроются настройки приложения. Найдите там пункт '
            '«Запуск приложений» (Huawei, Honor) или «Автозапуск» '
            '(Xiaomi) и включите «Родню», а батарею поставьте '
            '«Без ограничений».',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Открыть настройки'),
            ),
          ],
        ),
      );
      if (proceed == true) {
        await openAppSettings();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_resolved || !_shouldShow) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (isDark ? RodnyaDesignTokens.dark : RodnyaDesignTokens.light);

    // Плотность, чанк 17 (05.09.2026): рамка-карточка + заголовок + 4-строчный
    // абзац с точными названиями вендорских меню + полноширинная кнопка
    // (~150dp) → одна-две строки. Точные названия пунктов меню
    // (Huawei/Honor «Запуск приложений», Xiaomi «Автозапуск») по-прежнему
    // важны — их не выбросили, а перенесли из текста плашки в комментарий:
    // кнопка «Настроить» ведёт на нужный экран настроек напрямую, так что
    // навигация по названиям меню тут не нужна вовсе. Показ/дисмисс/
    // обработчик кнопки — без изменений.
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Material(
        color: tokens.warm.withValues(alpha: isDark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(tokens.radiusSm),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              Icon(
                Icons.battery_alert_rounded,
                size: 20,
                color: tokens.warm,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Разрешите автозапуск «Родне»',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: tokens.ink,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      'Иначе звонки и сообщения не дойдут, пока приложение закрыто.',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 13,
                        color: tokens.inkSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              TextButton(
                onPressed: _openSettings,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: const Text('Настроить'),
              ),
              // ≥44dp тап-таргет закрытия (2c-ритм).
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: 'Скрыть',
                color: tokens.inkSecondary,
                constraints: const BoxConstraints(
                  minWidth: 44,
                  minHeight: 44,
                ),
                padding: EdgeInsets.zero,
                onPressed: _dismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
