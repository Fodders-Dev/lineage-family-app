import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../services/app_status_service.dart';

/// Плотность, чанк 17 (05.09.2026): плавающая карточка со скруглением 18
/// и рамкой → полоса во всю ширину с нижним hairline, как у остальных
/// глобальных плашек шелла (баннер обновления, уведомлений). Условия
/// показа/ретрая/логина/дисмисса — без изменений.
class OfflineIndicator extends StatelessWidget {
  const OfflineIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final appStatusService = GetIt.I<AppStatusService>();
    return AnimatedBuilder(
      animation: appStatusService,
      builder: (context, _) {
        final issue = appStatusService.issue;
        final showBanner = appStatusService.hasVisibleStatus;
        if (!showBanner) {
          return const SizedBox.shrink();
        }

        late final IconData icon;
        late final Color foregroundColor;
        late final Color backgroundColor;
        late final String message;
        final showLoginAction =
            issue?.type == AppStatusIssueType.sessionExpired;
        final showRetryAction = !showLoginAction &&
            (appStatusService.isOffline || issue?.retryable == true);

        if (showLoginAction) {
          icon = Icons.lock_clock_outlined;
          foregroundColor = const Color(0xFF7A2600);
          backgroundColor = const Color(0xFFFFE2D4);
          message = issue?.message ?? 'Сессия истекла.';
        } else if (appStatusService.isOffline) {
          icon = Icons.cloud_off_outlined;
          foregroundColor = const Color(0xFF6A4A12);
          backgroundColor = const Color(0xFFFFF0CC);
          message = 'Нет сети. Показываем последние данные.';
        } else {
          icon = Icons.error_outline;
          foregroundColor = const Color(0xFF7A2600);
          backgroundColor = const Color(0xFFFFE7D9);
          message = issue?.message ?? 'Не удалось обновить данные.';
        }

        return Material(
          color: Colors.transparent,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: backgroundColor,
              border: Border(
                bottom: BorderSide(
                  color: foregroundColor.withValues(alpha: 0.18),
                ),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(14, 2, 6, 2),
            child: Row(
              children: [
                Icon(icon, color: foregroundColor, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foregroundColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                if (showRetryAction)
                  TextButton(
                    onPressed: appStatusService.requestRetry,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      foregroundColor: foregroundColor,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: const Text('Повторить'),
                  ),
                if (showLoginAction)
                  TextButton(
                    onPressed: () {
                      appStatusService.clearSessionIssue();
                      context.go('/login');
                    },
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      foregroundColor: foregroundColor,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: const Text('Войти'),
                  )
                else if (!appStatusService.isOffline)
                  IconButton(
                    tooltip: 'Скрыть',
                    onPressed: appStatusService.clearIssue,
                    icon: const Icon(Icons.close, size: 18),
                    color: foregroundColor,
                    constraints:
                        const BoxConstraints(minWidth: 44, minHeight: 44),
                    padding: EdgeInsets.zero,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
