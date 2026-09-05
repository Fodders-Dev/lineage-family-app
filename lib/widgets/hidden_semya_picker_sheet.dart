// Ship FE7b (2026-05-26): семя picker sheet для settings tile «Скрытые
// родственники» (FE7 polish). User selects which семя's hidden list к
// open. После tap pushes SemyaDetailsScreen(scrollToHidden: true).
//
// Surfaced только когда user belongs к 2+ семей; single-семя case
// skips picker и navigates directly из settings.

import 'package:flutter/material.dart';

import '../backend/models/semya.dart';
import '../screens/semya_details_screen.dart';

Future<void> showHiddenSemyaPickerSheet(
  BuildContext context, {
  required List<Semya> semyi,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _HiddenSemyaPickerSheet(semyi: semyi),
  );
}

class _HiddenSemyaPickerSheet extends StatelessWidget {
  const _HiddenSemyaPickerSheet({required this.semyi});

  final List<Semya> semyi;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(
                'В какой семье?',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                'Скрытые родственники — отдельный список '
                'для каждой семьи. Выберите семью.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            ...semyi.map(
              (s) => ListTile(
                key: Key('hidden-semya-picker-${s.id}'),
                visualDensity: const VisualDensity(vertical: -1),
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: const Icon(Icons.family_restroom_rounded),
                title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context, rootNavigator: true).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SemyaDetailsScreen(
                        semyaId: s.id,
                        scrollToHidden: true,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
