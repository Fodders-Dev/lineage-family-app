import 'package:flutter/material.dart';

import '../models/family_person.dart';
import '../models/family_relation.dart';

/// Ship 2026-05-26 (UX audit Screen 4.1): guided CTA для empty-либо-
/// only-self tree state. Closes «mama-fear» surface — replaced blank
/// canvas (либо canvas с single tiny self card lost в empty space) с
/// relation-first action buttons.
///
/// 4 primary CTAs:
///   • Мама — parent + female pre-fill
///   • Папа — parent + male pre-fill
///   • Ребёнок — child
///   • Партнёр — spouse
///
/// Plus secondary «Другой родственник» — opens generic add form.
///
/// Caller (tree_view_screen_sections) detects empty-либо-only-self
/// state и renders this widget instead of canvas. Each CTA tap calls
/// [onAddRelative] с the chosen [RelationType] и pre-filled [Gender]
/// (когда applicable). Caller dispatches к
/// `/relatives/add/{treeId}` с extras — AddRelativeScreen reads
/// relationType + prefilledGender + optional contextPersonId.
///
/// Audit spec: «For 0-1 person trees, show a guided empty canvas:
/// «Добавьте маму, папу, детей или партнёра», with relation-based
/// buttons near the current person.»
class EmptyTreeGuidedCta extends StatelessWidget {
  const EmptyTreeGuidedCta({
    super.key,
    required this.onAddRelative,
    required this.onAddOther,
    this.hasSelfPerson = false,
    this.viewerMode = false,
    this.onDismiss,
  });

  /// Invoked when one of the 4 primary CTAs tapped.
  /// Receives the [RelationType] + optional [Gender] hint.
  final void Function(RelationType relation, Gender? gender) onAddRelative;

  /// Invoked when «Другой родственник» secondary action tapped.
  /// Opens generic add-form без relation hint.
  final VoidCallback onAddOther;

  /// True когда tree уже has caller's self-person (только he/her alone).
  /// Affects header copy: «Добавь близких к своей карточке» (self exists)
  /// vs «Начни своё семейное дерево» (truly empty).
  final bool hasSelfPerson;

  /// Ship FE4 (2026-05-26): viewer-role gating. When `true`, no CTAs
  /// render — caller cannot mutate tree. Shows informational copy
  /// instead («Когда владелец добавит родственников, они появятся
  /// здесь»). Server-side gating enforces; UI just hides surfaces
  /// чтобы viewer не тыкал в кнопки которые отвалятся с 403.
  final bool viewerMode;

  /// A-CTA: закрыть гид (×). Когда задан — в правом верхнем углу
  /// появляется крестик; вызывающий запоминает dismiss на сессию и
  /// показывает обычный канвас. null → крестика нет.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    if (viewerMode) {
      return _ViewerEmptyState();
    }
    final theme = Theme.of(context);
    // SingleChildScrollView allows the column to fit on small surfaces
    // (test viewports often 600px tall; production phones similar).
    // Pure Center+Column overflows when keyboard либо other chrome
    // shrinks the viewport. Scrollable центрирует контент via Align.
    final Widget content = SingleChildScrollView(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.account_tree_rounded,
                  size: 52,
                  color: theme.colorScheme.primary.withValues(alpha: 0.85),
                ),
                const SizedBox(height: 14),
                Text(
                  hasSelfPerson
                      ? 'Добавь близких'
                      : 'Начни своё семейное дерево',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  hasSelfPerson
                      ? 'Сохрани историю семьи — добавь родителей, '
                          'детей или партнёра.'
                      : 'Добавь родственников, чтобы сохранить '
                          'историю семьи.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                // Четыре CTA — раньше кнопки во всю ширину столбиком (52dp
                // каждая + отступы ≈ 240dp), теперь один ряд плиток (как
                // «Спросить историю» на карточке человека, чанк 7): те же
                // подписи и ключи, ≈80dp вместо ≈240dp.
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _GuidedCtaTile(
                          key: const Key('empty-tree-cta-mama'),
                          icon: Icons.face_3_outlined,
                          label: 'Добавить маму',
                          onPressed: () => onAddRelative(
                            RelationType.parent,
                            Gender.female,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _GuidedCtaTile(
                          key: const Key('empty-tree-cta-papa'),
                          icon: Icons.face_outlined,
                          label: 'Добавить папу',
                          onPressed: () => onAddRelative(
                            RelationType.parent,
                            Gender.male,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _GuidedCtaTile(
                          key: const Key('empty-tree-cta-child'),
                          icon: Icons.child_care_outlined,
                          label: 'Добавить ребёнка',
                          onPressed: () =>
                              onAddRelative(RelationType.child, null),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _GuidedCtaTile(
                          key: const Key('empty-tree-cta-partner'),
                          icon: Icons.favorite_outline_rounded,
                          label: 'Добавить партнёра',
                          onPressed: () =>
                              onAddRelative(RelationType.spouse, null),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  key: const Key('empty-tree-cta-other'),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('Другой родственник'),
                  onPressed: onAddOther,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final dismiss = onDismiss;
    if (dismiss == null) {
      return content;
    }
    // A-CTA: крестик в правом верхнем углу — закрыть гид (≥44dp).
    return Stack(
      children: [
        content,
        Positioned(
          top: 4,
          right: 4,
          child: IconButton(
            key: const Key('empty-tree-cta-dismiss'),
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: 'Скрыть',
            color: theme.colorScheme.onSurfaceVariant,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            onPressed: dismiss,
          ),
        ),
      ],
    );
  }
}

/// Компактная плитка ряда CTA (иконка сверху, подпись в 2 строки снизу) —
/// тот же язык, что и у ряда действий карточки человека (профиль,
/// «Спросить историю» и др.), только локальная копия: этот файл не имеет
/// доступа к приватному классу профиля (другая library-часть).
class _GuidedCtaTile extends StatelessWidget {
  const _GuidedCtaTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: theme.colorScheme.primary),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ship FE4 (2026-05-26): viewer-role empty state. Replaces guided
/// CTAs с информационным сообщением — viewer не имеет права mutating
/// tree, так предлагать «Добавить маму» misleading. Server-side gates
/// reject mutations independently; UI просто скрывает affordances.
class _ViewerEmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.account_tree_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 10),
            Text(
              'Здесь пока никого нет',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Когда владелец семьи добавит родственников, '
              'они появятся здесь.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
