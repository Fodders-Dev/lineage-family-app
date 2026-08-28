import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../models/media_upload_progress.dart';
import '../models/pending_post_publish.dart';
import '../services/post_publish_queue.dart';
import '../theme/app_theme.dart';
import '../utils/russian_plural.dart';

/// Глобальный чип фоновой публикации (шаг 5 bulk-upload): «Опубликовать»
/// отпускает человека с composer'а, а этот чип — единственное окно в судьбу
/// пачки: живой счётчик во время загрузки, «Повторить»/«Убрать» при провале,
/// исчезает без следа, когда всё дошло (пост появляется в ленте сам).
///
/// Живёт в app shell поверх контента: публикацию видно с любого таба.
/// Очереди нет в GetIt (тесты, деградированный старт) — рисует пустоту.
class PostPublishStatusChip extends StatelessWidget {
  const PostPublishStatusChip({super.key});

  @override
  Widget build(BuildContext context) {
    if (!GetIt.I.isRegistered<PostPublishQueue>()) {
      return const SizedBox.shrink();
    }
    final queue = GetIt.I<PostPublishQueue>();
    return AnimatedBuilder(
      animation: queue,
      builder: (context, _) {
        final items = queue.items;
        if (items.isEmpty) {
          return const SizedBox.shrink();
        }
        final failed = items
            .where((item) => item.status == PendingPostPublishStatus.failed)
            .toList(growable: false);
        return failed.isNotEmpty
            ? _buildFailed(context, queue, failed)
            : _buildUploading(context, items);
      },
    );
  }

  Widget _buildUploading(BuildContext context, List<PendingPostPublish> items) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>();
    // Хвост очереди (не более одного активного — enqueue идёт по одному, но
    // человек может успеть поставить второй пост, пока грузится первый).
    final active = items.last;
    final progress = active.progress;
    String label;
    if (progress != null &&
        progress.stage == MediaUploadStage.uploading &&
        progress.total > 1) {
      label = 'Загружено ${progress.completed} из ${progress.total}';
    } else {
      label = 'Публикуем запись…';
    }
    if (items.length > 1) {
      label = '$label · ещё ${items.length - 1}';
    }
    // Кнопок нет — чип чисто информационный, тапы уходят сквозь него:
    // иначе он закрывал compose-бар ленты (mobile) и композер чата (desktop).
    return IgnorePointer(
      child: _chipShell(
        context,
        leading: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: progress?.value,
            color: tokens?.accent ?? theme.colorScheme.primary,
          ),
        ),
        label: label,
      ),
    );
  }

  Widget _buildFailed(
    BuildContext context,
    PostPublishQueue queue,
    List<PendingPostPublish> failed,
  ) {
    final theme = Theme.of(context);
    return _chipShell(
      context,
      leading: Icon(
        Icons.cloud_off_outlined,
        size: 18,
        color: theme.colorScheme.error,
      ),
      // «Повторить»/«Убрать» действуют на ВСЕ упавшие публикации — при
      // нескольких метка обязана говорить про все, а не цитировать первую.
      label: failed.length > 1
          ? 'Не удалось опубликовать: ${failed.length} '
              '${russianPluralForm(failed.length, one: 'запись', few: 'записи', many: 'записей')}.'
          : (failed.first.errorText?.trim().isNotEmpty == true
              ? failed.first.errorText!.trim()
              : 'Не удалось опубликовать запись.'),
      actions: [
        TextButton(
          onPressed: () {
            for (final item in failed) {
              queue.retry(item.localId);
            }
          },
          child: const Text('Повторить'),
        ),
        IconButton(
          onPressed: () {
            for (final item in failed) {
              queue.remove(item.localId);
            }
          },
          visualDensity: VisualDensity.compact,
          tooltip: 'Убрать',
          icon: const Icon(Icons.close, size: 18),
        ),
      ],
    );
  }

  Widget _chipShell(
    BuildContext context, {
    required Widget leading,
    required String label,
    List<Widget> actions = const <Widget>[],
  }) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>();
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        // 88 — выше compose-бара ленты (mobile) и композера чата в
        // master-detail (desktop): failed-чип с кнопками не должен
        // ложиться на управляющие элементы под ним.
        minimum: const EdgeInsets.only(bottom: 88),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Material(
            elevation: 4,
            color: tokens?.surfaceStrong ?? theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(tokens?.radiusLg ?? 20),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  leading,
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  ...actions,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

