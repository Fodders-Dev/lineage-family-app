import 'package:flutter/material.dart';

import '../models/family_person.dart';
import '../theme/app_theme.dart';
import '../utils/photo_url.dart';

/// Ship Q4 (2026-05-26): bottom sheet с actions для tapped tree person.
/// Закрывает Critical #4 из UX audit 2026-05-25: «Details/edit/delete
/// path for a person is not discoverable from the main card».
///
/// Существующий inline person sheet оставлен intact для edit-mode
/// multi-action workflows. Modal sheet pops on non-edit tap чтобы
/// surfaceить пять action paths очевидным образом:
///   • Открыть профиль
///   • Редактировать
///   • Добавить родственника
///   • Связать с существующим (если еще не linked к real user)
///   • Удалить (с consequence copy)
///
/// Сall through `showTreePersonActionSheet` helper — handles modal
/// lifecycle + safety check `mounted` после await.
Future<void> showTreePersonActionSheet(
  BuildContext context, {
  required FamilyPerson person,
  required VoidCallback onOpenProfile,
  required VoidCallback onEdit,
  required VoidCallback onAddRelative,
  required VoidCallback onConnect,
  required VoidCallback onDelete,
  bool viewerMode = false,
  VoidCallback? onToggleHide,
  bool isHidden = false,
  VoidCallback? onAddSecondParent,
  VoidCallback? onAskStory,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => TreePersonActionSheet(
      person: person,
      viewerMode: viewerMode,
      isHidden: isHidden,
      onAddSecondParent: onAddSecondParent == null
          ? null
          : () {
              Navigator.of(sheetContext).pop();
              onAddSecondParent();
            },
      onOpenProfile: () {
        Navigator.of(sheetContext).pop();
        onOpenProfile();
      },
      onEdit: () {
        Navigator.of(sheetContext).pop();
        onEdit();
      },
      onAddRelative: () {
        Navigator.of(sheetContext).pop();
        onAddRelative();
      },
      onConnect: () {
        Navigator.of(sheetContext).pop();
        onConnect();
      },
      onDelete: () {
        Navigator.of(sheetContext).pop();
        onDelete();
      },
      onAskStory: onAskStory == null
          ? null
          : () {
              Navigator.of(sheetContext).pop();
              onAskStory();
            },
      onToggleHide: onToggleHide == null
          ? null
          : () {
              Navigator.of(sheetContext).pop();
              onToggleHide();
            },
    ),
  );
}

class TreePersonActionSheet extends StatelessWidget {
  const TreePersonActionSheet({
    super.key,
    required this.person,
    required this.onOpenProfile,
    required this.onEdit,
    required this.onAddRelative,
    required this.onConnect,
    required this.onDelete,
    this.viewerMode = false,
    this.onToggleHide,
    this.isHidden = false,
    this.onAddSecondParent,
    this.onAskStory,
  });

  final FamilyPerson person;
  final VoidCallback onOpenProfile;
  final VoidCallback onEdit;
  final VoidCallback onAddRelative;
  final VoidCallback onConnect;
  final VoidCallback onDelete;

  /// B3 (FR3): явный путь добавить ВТОРОГО родителя ребёнку с одним
  /// родителем. Не null только когда у узла ровно один родитель — тогда
  /// в шите появляется «Добавить второго родителя» (ведёт в add-флоу с
  /// предвыбранным недостающим полом). null → пункта нет.
  final VoidCallback? onAddSecondParent;

  /// Ship FE4 (2026-05-26): viewer-role gating. When `true`, only
  /// «Открыть профиль» tile renders — editorial actions (edit / add /
  /// connect / delete) hidden. Mutation rejection is enforced server-
  /// side regardless (defense-in-depth); hiding UI спasает viewer от
  /// «доступно, но не работает» confusion.
  final bool viewerMode;

  /// Ship FE7 (2026-05-26): hide-filter toggle callback. When non-null,
  /// «Скрыть от меня» либо «Показывать снова» tile renders (label
  /// flips based on [isHidden]). Hide is per-user — не affects other
  /// семя members' view. Null когда tree unbound либо seller decides
  /// не expose hide feature (e.g., public tree).
  final VoidCallback? onToggleHide;

  /// Ship FE7 (2026-05-26): current hide state из caller's filter.
  /// Used к flip toggle tile copy + icon (visibility_off → visibility).
  final bool isHidden;

  /// UX-аудит 2026-07-04 P1: «Спросить историю» прямо с канваса —
  /// north-star фича (сохранение семейной памяти) была закопана в
  /// профиль на 2-3 тапа без аффорданса. Доступна всем ролям: share
  /// вопроса прав не требует, запись ответа гейтится ниже по флоу
  /// (article-permission на экране деталей).
  final VoidCallback? onAskStory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (isDark ? RodnyaDesignTokens.dark : RodnyaDesignTokens.light);
    final lifeDates = _formatLifeDates(person);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header: avatar + full name + life dates. Audit explicitly
            // recommends person preview ПЕРЕД actions так что user видит
            // exactly которую карточку трогает.
            Row(
              children: [
                _PersonAvatar(
                  photoUrl: person.photoUrl,
                  fallbackInitial:
                      person.name.isNotEmpty ? person.name[0] : '?',
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        person.name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (lifeDates.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          lifeDates,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: tokens.inkSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              height: 0.6,
              color: tokens.surfaceLine.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 4),
            _ActionTile(
              key: const Key('tree-action-open-profile'),
              icon: Icons.account_circle_outlined,
              label: 'Открыть профиль',
              onTap: onOpenProfile,
            ),
            if (onAskStory != null)
              _ActionTile(
                key: const Key('tree-action-ask-story'),
                icon: Icons.auto_stories_outlined,
                label: 'Спросить историю',
                onTap: onAskStory!,
              ),
            // Ship FE7 (2026-05-26): hide-filter toggle. Tile renders
            // когда callback provided (tree bound к семя + caller
            // is member). Hide is per-user — другие members видят
            // person как обычно.
            if (onToggleHide != null)
              _ActionTile(
                key: const Key('tree-action-toggle-hide'),
                icon: isHidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                label: isHidden ? 'Показывать снова' : 'Скрыть от меня',
                onTap: onToggleHide!,
              ),
            // Ship FE4 (2026-05-26): editorial actions gated by
            // viewerMode. Viewer role → mutation tiles hidden;
            // only «Открыть профиль» surfaces. Server-side gating
            // separately enforces, мы здесь только cleanup UX
            // surface to avoid «доступно, но 403» confusion.
            if (!viewerMode) ...[
              _ActionTile(
                key: const Key('tree-action-edit'),
                icon: Icons.edit_outlined,
                label: 'Редактировать',
                onTap: onEdit,
              ),
              _ActionTile(
                key: const Key('tree-action-add-relative'),
                icon: Icons.person_add_alt_outlined,
                label: 'Добавить родственника',
                onTap: onAddRelative,
              ),
              // B3 (FR3): контекстный пункт — виден только когда у узла
              // ровно один родитель, делает добавление второго очевидным.
              if (onAddSecondParent != null)
                _ActionTile(
                  key: const Key('tree-action-add-second-parent'),
                  icon: Icons.family_restroom_rounded,
                  label: 'Добавить второго родителя',
                  onTap: onAddSecondParent!,
                ),
              _ActionTile(
                key: const Key('tree-action-connect'),
                icon: Icons.link_rounded,
                label: 'Связать с существующим',
                onTap: onConnect,
              ),
              _ActionTile(
                key: const Key('tree-action-delete'),
                icon: Icons.delete_outline_rounded,
                label: 'Удалить',
                isDestructive: true,
                onTap: onDelete,
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatLifeDates(FamilyPerson person) {
    final birth = person.birthDate?.year;
    final death = person.deathDate?.year;
    if (birth == null && death == null) return '';
    if (birth != null && death != null) return '$birth – $death';
    if (birth != null) return person.isAlive ? 'Род. $birth' : '$birth – ?';
    return '? – $death';
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        isDestructive ? theme.colorScheme.error : theme.colorScheme.onSurface;
    // Telegram-style dense context-menu row (~44dp — touch-target floor),
    // не Material-дефолт ListTile (56dp). Лист может нести до 7 пунктов
    // разом (профиль/история/скрыть/редактировать/родитель/связать/
    // удалить) — на дефолтной высоте это почти пол-экрана только под меню.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
          child: Row(
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: color,
                    fontWeight:
                        isDestructive ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PersonAvatar extends StatelessWidget {
  const _PersonAvatar({
    required this.photoUrl,
    required this.fallbackInitial,
    required this.color,
  });

  final String? photoUrl;
  final String fallbackInitial;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final normalized = normalizePhotoUrl(photoUrl);
    final placeholder = CircleAvatar(
      radius: 26,
      backgroundColor: color.withValues(alpha: 0.15),
      child: Text(
        fallbackInitial.toUpperCase(),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 18,
        ),
      ),
    );
    final image = buildAvatarImageProvider(normalized);
    if (image == null) return placeholder;
    return CircleAvatar(
      radius: 26,
      backgroundColor: color.withValues(alpha: 0.15),
      foregroundImage: image,
      child: Text(
        fallbackInitial.toUpperCase(),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 18,
        ),
      ),
    );
  }
}
