import 'package:flutter/material.dart';

import '../backend/models/semya.dart';

/// Ship FE4 (2026-05-26): header indicator showing семя binding +
/// caller's role в этой семье. Renders compact pill suitable для
/// tree view top toolbar.
///
/// Two visual modes:
///   • Bound tree (semya != null): семя name + role chip
///       e.g. «Семья Ивановых» [Редактор]
///   • Unbound tree (legacy): «Моё дерево» single label, no role chip
///
/// Tap optional — when [onTap] provided, badge becomes interactive
/// (FE2 details screen navigation typically).
class SemyaContextBadge extends StatelessWidget {
  const SemyaContextBadge({
    super.key,
    this.semya,
    this.callerRole,
    this.onTap,
    this.legacyLabel = 'Моё дерево',
  });

  /// `null` означает unbound tree (legacy mode).
  final Semya? semya;

  /// Caller's role в этой семье; null для unbound либо не-member
  /// (treat as owner-equivalent для legacy compat).
  final SemyaRole? callerRole;

  /// Optional tap handler — pushes к SemyaDetailsScreen typically.
  final VoidCallback? onTap;

  /// Label для unbound tree case. Customizable так widget reusable
  /// в other contexts.
  final String legacyLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isBound = semya != null;
    return Material(
      color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        key: const Key('semya-context-badge'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        // Плотность, чанк 16 (05.09.2026): бейдж живёт в компактной
        // тулбар-карточке дерева рядом с фильтр-чипом «Всё дерево» — общая
        // высота карточки была ~54dp. Паддинг ужат 6 → 2 (иконка/шрифт те
        // же — тексты и семантика теста semya_context_badge_test не трогаем).
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isBound
                    ? Icons.family_restroom_rounded
                    : Icons.account_tree_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  isBound ? semya!.name : legacyLabel,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (isBound && callerRole != null) ...[
                const SizedBox(width: 8),
                _RolePill(role: callerRole!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RolePill extends StatelessWidget {
  const _RolePill({required this.role});

  final SemyaRole role;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color background;
    final Color foreground;
    switch (role) {
      case SemyaRole.owner:
        background = theme.colorScheme.primary.withValues(alpha: 0.18);
        foreground = theme.colorScheme.primary;
        break;
      case SemyaRole.editor:
        background = Colors.amber.withValues(alpha: 0.20);
        foreground = Colors.amber.shade900;
        break;
      case SemyaRole.viewer:
      case SemyaRole.unknown:
        background = theme.colorScheme.surfaceContainerHighest;
        foreground = theme.colorScheme.onSurfaceVariant;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        role.displayLabel,
        style: theme.textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
