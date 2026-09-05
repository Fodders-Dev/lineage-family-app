import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../services/app_update_service.dart';
import '../theme/app_theme.dart';

/// U2: UI самообновления sideload-сборок.
///   • [AppUpdateBanner] — ненавязчивый баннер «Доступно обновление»
///     (необязательное обновление, дисмисс на сессию).
///   • [AppUpdateGate] — оборачивает приложение и при несовместимой
///     старой версии (mandatory) показывает блокирующий экран.
/// Мандаторный блок-экран — крупно/контрастно, там нет альтернативы.
/// [AppUpdateBanner] с чанка 17 плотности — одна тонкая строка (тап-цели
/// кнопки/крестика всё равно ≥44dp), а не карточка с полноширинными
/// кнопками: это ненавязчивый баннер над КАЖДОЙ вкладкой, ему нельзя
/// конкурировать с контентом за первый экран.

class AppUpdateMonitor extends StatefulWidget {
  const AppUpdateMonitor({
    super.key,
    required this.child,
    this.pollInterval = const Duration(minutes: 1),
  });

  final Widget child;
  final Duration pollInterval;

  @override
  State<AppUpdateMonitor> createState() => _AppUpdateMonitorState();
}

class _AppUpdateMonitorState extends State<AppUpdateMonitor>
    with WidgetsBindingObserver {
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _checkForUpdate();
    });
    _restartTimer();
  }

  @override
  void didUpdateWidget(AppUpdateMonitor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pollInterval != widget.pollInterval) {
      _restartTimer();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkForUpdate(force: true);
      _restartTimer();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _pollTimer = null;
    super.dispose();
  }

  void _restartTimer() {
    _pollTimer?.cancel();
    final interval = widget.pollInterval;
    if (interval <= Duration.zero) {
      _pollTimer = null;
      return;
    }
    _pollTimer = Timer.periodic(interval, (_) => _checkForUpdate());
  }

  void _checkForUpdate({bool force = false}) {
    if (!GetIt.I.isRegistered<AppUpdateService>()) {
      return;
    }
    unawaited(GetIt.I<AppUpdateService>().checkForUpdate(force: force));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

RodnyaDesignTokens _tokensOf(BuildContext context) {
  final theme = Theme.of(context);
  return theme.extension<RodnyaDesignTokens>() ??
      (theme.brightness == Brightness.dark
          ? RodnyaDesignTokens.dark
          : RodnyaDesignTokens.light);
}

class AppUpdateBanner extends StatelessWidget {
  const AppUpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    if (!GetIt.I.isRegistered<AppUpdateService>()) {
      return const SizedBox.shrink();
    }
    final service = GetIt.I<AppUpdateService>();
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final state = service.state;
        final latest = state.latest;
        if (state.availability != AppUpdateAvailability.optional ||
            latest == null ||
            service.isOptionalDismissed) {
          return const SizedBox.shrink();
        }

        final theme = Theme.of(context);
        final tokens = _tokensOf(context);
        final download = service.downloadProgress;
        final isBusy = download.isBusy;
        final isFailed = download.stage == AppUpdateDownloadStage.failed;

        // Плотность, чанк 17 (05.09.2026): карточка с рамкой + заголовок +
        // абзац notes + две полноширинные кнопки (~130dp) → одна тонкая
        // строка (заголовок + подпись ≤2 строк, действие и крестик справа).
        // Показ/скачивание/дисмисс — без изменений, крестик = «Позже»
        // (тот же dismissOptionalForSession, что раньше был текстовой
        // кнопкой под текстом).
        String? subtitle;
        Color subtitleColor = tokens.inkSecondary;
        if (isBusy) {
          final fraction = download.fraction;
          final percent = fraction == null ? null : (fraction * 100).round();
          subtitle = percent == null
              ? 'Скачиваем обновление…'
              : 'Скачиваем обновление… $percent%';
        } else if (isFailed && download.error != null) {
          subtitle = download.error;
          subtitleColor = theme.colorScheme.error;
        } else {
          subtitle = latest.notes;
        }

        // FX-A: баннер — самый верхний видимый элемент шелла (под ним
        // навигейшн-скрин со своим AppBar), поэтому без верхнего инсета он
        // налезал на статус-бар. Обновление доступно только онлайн, значит
        // OfflineIndicator выше скрыт → SafeArea(top) здесь даёт ровно
        // нужный отступ без двойного инсета.
        return SafeArea(
          top: true,
          bottom: false,
          left: false,
          right: false,
          child: Container(
            key: const Key('app-update-banner'),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: tokens.surfaceLine)),
            ),
            padding: const EdgeInsets.fromLTRB(14, 2, 6, 2),
            child: Row(
              children: [
                Icon(
                  Icons.system_update_rounded,
                  size: 20,
                  color: isFailed
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Доступно обновление',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: tokens.ink,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 1),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 13,
                            color: subtitleColor,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (isBusy)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else ...[
                  TextButton(
                    key: const Key('app-update-install-button'),
                    onPressed: service.downloadAndInstall,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: Text(isFailed ? 'Повторить' : 'Обновить'),
                  ),
                  IconButton(
                    key: const Key('app-update-later-button'),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: 'Позже',
                    color: tokens.inkSecondary,
                    constraints:
                        const BoxConstraints(minWidth: 44, minHeight: 44),
                    padding: EdgeInsets.zero,
                    onPressed: service.dismissOptionalForSession,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Оборачивает приложение: при mandatory-обновлении показывает
/// блокирующий экран поверх [child], иначе отдаёт [child] как есть.
class AppUpdateGate extends StatelessWidget {
  const AppUpdateGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!GetIt.I.isRegistered<AppUpdateService>()) {
      return child;
    }
    final service = GetIt.I<AppUpdateService>();
    return AnimatedBuilder(
      animation: service,
      child: child,
      builder: (context, child) {
        final state = service.state;
        final latest = state.latest;
        if (state.availability != AppUpdateAvailability.mandatory ||
            latest == null) {
          return child!;
        }
        return _MandatoryUpdateScreen(service: service, latest: latest);
      },
    );
  }
}

class _MandatoryUpdateScreen extends StatelessWidget {
  const _MandatoryUpdateScreen({required this.service, required this.latest});

  final AppUpdateService service;
  final AppLatestVersion latest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = _tokensOf(context);
    return Material(
      key: const Key('app-update-mandatory-screen'),
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.system_update_rounded,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Нужно обновить приложение',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: tokens.ink,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Эта версия больше не поддерживается. Чтобы продолжить '
                    'пользоваться «Роднёй», установите свежую версию.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: tokens.inkSecondary,
                      height: 1.45,
                    ),
                  ),
                  if (latest.notes != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      latest.notes!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: tokens.inkSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  _AppUpdateActions(
                    service: service,
                    download: service.downloadProgress,
                    showLater: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Общий блок действий «Обновить» / «Позже» + прогресс/ошибка
/// скачивания. Кнопки ≥48dp.
class _AppUpdateActions extends StatelessWidget {
  const _AppUpdateActions({
    required this.service,
    required this.download,
    required this.showLater,
  });

  final AppUpdateService service;
  final AppUpdateDownloadProgress download;
  final bool showLater;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = _tokensOf(context);

    if (download.isBusy) {
      final fraction = download.fraction;
      final percent = fraction == null ? null : (fraction * 100).round();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              key: const Key('app-update-progress'),
              minHeight: 8,
              // null (неизвестная длина) → неопределённый индикатор.
              value: fraction,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            percent == null
                ? 'Скачиваем обновление…'
                : 'Скачиваем обновление… $percent%',
            style: theme.textTheme.bodySmall?.copyWith(
              color: tokens.inkSecondary,
            ),
          ),
        ],
      );
    }

    final isFailed = download.stage == AppUpdateDownloadStage.failed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isFailed && download.error != null) ...[
          Text(
            download.error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
        ],
        SizedBox(
          height: 48,
          child: FilledButton.icon(
            key: const Key('app-update-install-button'),
            onPressed: service.downloadAndInstall,
            icon: const Icon(Icons.download_rounded),
            label: Text(isFailed ? 'Повторить' : 'Обновить'),
          ),
        ),
        if (showLater) ...[
          const SizedBox(height: 6),
          SizedBox(
            height: 44,
            child: TextButton(
              key: const Key('app-update-later-button'),
              onPressed: service.dismissOptionalForSession,
              child: const Text('Позже'),
            ),
          ),
        ],
      ],
    );
  }
}
