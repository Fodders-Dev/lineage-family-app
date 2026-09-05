// Ship Q4a frontend (2026-05-28, Ship 31b): shared row widget для
// soft-deleted items. Extracted из TrashScreen (Ship 31) так per-семя
// SemyaDeletedPersonsScreen reuses identical layout — avatar/thumbnail
// + name/preview + «Удалится через N дней» + restore/purge actions с
// 3h floor visualization (purge disabled + tooltip пока floor не пройден).
//
// Caller builds `leading` (CircleAvatar для persons, thumbnail для
// posts) и passes display fields + action callbacks. Row key передаётся
// через super.key.

import 'package:flutter/material.dart';

class DeletedItemRow extends StatelessWidget {
  const DeletedItemRow({
    super.key,
    required this.leading,
    required this.title,
    required this.daysLeft,
    required this.floorPassed,
    required this.busy,
    required this.onRestore,
    required this.onPurge,
    required this.restoreKey,
    required this.purgeKey,
    this.titleMaxLines = 1,
    this.isThreeLine = false,
  });

  final Widget leading;
  final String title;
  final int daysLeft;

  /// True когда earliestHardDelete passed — purge button enabled.
  final bool floorPassed;

  /// In-flight restore/purge — replaces actions с spinner.
  final bool busy;

  final VoidCallback onRestore;
  final VoidCallback onPurge;
  final Key restoreKey;
  final Key purgeKey;
  final int titleMaxLines;
  final bool isThreeLine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      // Плотность −1 без dense: default two-line ListTile ≈72dp — выше
      // планки 56–64dp для строки с аватаром (см. чанк 9b, settings).
      visualDensity: const VisualDensity(vertical: -1),
      leading: leading,
      title: Text(
        title,
        maxLines: titleMaxLines,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        'Удалится через $daysLeft ${deletedDaysLabel(daysLeft)}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      isThreeLine: isThreeLine,
      trailing: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: restoreKey,
                  tooltip: 'Восстановить',
                  icon: Icon(
                    Icons.restore_rounded,
                    color: theme.colorScheme.primary,
                  ),
                  onPressed: onRestore,
                ),
                IconButton(
                  key: purgeKey,
                  tooltip: floorPassed
                      ? 'Удалить навсегда'
                      : 'Подождите немного перед окончательным удалением',
                  icon: Icon(
                    Icons.delete_forever_outlined,
                    color: floorPassed
                        ? theme.colorScheme.error
                        : theme.disabledColor,
                  ),
                  onPressed: floorPassed ? onPurge : null,
                ),
              ],
            ),
    );
  }
}

/// Russian pluralization для «день/дня/дней». Shared между TrashScreen
/// + SemyaDeletedPersonsScreen.
String deletedDaysLabel(int n) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return 'день';
  if ([2, 3, 4].contains(mod10) && ![12, 13, 14].contains(mod100)) {
    return 'дня';
  }
  return 'дней';
}
