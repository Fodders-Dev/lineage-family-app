import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/family_tree.dart';
import '../providers/tree_provider.dart';
import '../theme/app_theme.dart';

/// Phase 6.1: compact branch switcher widget for the top bar.
/// Shows the active branch's name + chevron; tap opens a bottom
/// sheet with every branch the user belongs to plus a "+ Создать
/// ветку" entry. Hidden when the user has no branches yet (a
/// fresh-account state — TreeProvider hasn't loaded anything).
///
/// Plumbing-only: switching just calls TreeProvider.selectTree —
/// existing screens already react to selectedTreeId via their own
/// listeners, so feed/relatives/tree all reload under the new
/// branch with no additional wiring.
class BranchSwitcherChip extends StatelessWidget {
  const BranchSwitcherChip({super.key, this.maxNameWidth});

  /// Max width for the branch-name label. The chip auto-truncates
  /// with an ellipsis when the name doesn't fit. When omitted, the
  /// chip picks a value adaptively from the device width — narrow
  /// (< 400 dp) phones cap at 90 dp so the chip doesn't push the
  /// topbar's icon-button cluster off-screen on Samsung S20 FE-class
  /// devices, wider screens get 180 dp like before.
  final double? maxNameWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final screenWidth = MediaQuery.of(context).size.width;
    final effectiveMaxNameWidth = maxNameWidth ??
        (screenWidth < 400 ? 90.0 : (screenWidth < 600 ? 130.0 : 180.0));
    // User-reported: «если название не вмещается, то может сделаем
    // по цветам? разным деревам разный цвет, чтобы текстом не
    // вставлять, раз не влезает. А текст в веб версии держать».
    // Below 380 dp width we drop the text part and render a tiny
    // color dot derived from the tree id — same identifier-to-color
    // approach as Telegram's avatar tints, so the same branch
    // always gets the same dot.
    final useColorOnly = screenWidth < 380;

    return Consumer<TreeProvider>(
      builder: (context, treeProvider, _) {
        final selectedName = treeProvider.selectedTreeName;
        final selectedId = treeProvider.selectedTreeId;
        final available = treeProvider.availableTrees;
        // Hide when there's nothing to switch to AND no active
        // branch — a fresh user with no trees would just see an
        // empty chip taking up space. The "+ Создать ветку" path
        // is reachable through the regular /trees screen anyway.
        if (selectedId == null && available.isEmpty) {
          return const SizedBox.shrink();
        }
        final label = selectedName?.trim().isNotEmpty == true
            ? selectedName!.trim()
            : 'Выберите ветку';
        final dotColor = _branchDotColor(selectedId);
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => _openSwitcherSheet(
              context,
              treeProvider: treeProvider,
              tokens: tokens,
            ),
            child: Container(
              padding: useColorOnly
                  ? const EdgeInsets.symmetric(horizontal: 8, vertical: 6)
                  : const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: tokens.surfaceStrong.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: tokens.surfaceLine.withValues(alpha: 0.7),
                  width: 0.8,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // On narrow screens use a per-branch coloured dot
                  // instead of the generic tree icon — combined with
                  // hidden text it still tells you which branch you're
                  // on at a glance, derived from a hash of the branch
                  // id so the same branch always gets the same hue.
                  if (useColorOnly)
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: dotColor,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.7),
                          width: 1,
                        ),
                      ),
                    )
                  else
                    Icon(
                      Icons.account_tree_outlined,
                      size: 16,
                      color: tokens.accent,
                    ),
                  if (!useColorOnly) ...[
                    const SizedBox(width: 6),
                    // Flexible so the label shrinks + ellipsizes to the
                    // actual space the chip is given (the topbar can be
                    // tight on narrow phones) rather than overflowing at
                    // its max-name width.
                    Flexible(
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(maxWidth: effectiveMaxNameWidth),
                        child: Text(
                          label,
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: tokens.ink,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                  SizedBox(width: useColorOnly ? 2 : 4),
                  Icon(
                    Icons.expand_more_rounded,
                    size: 18,
                    color: tokens.inkSecondary,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Hash the branch id into a stable colour so the dot mode picks
  /// the same hue for the same branch every time. We avoid pure
  /// reds / yellows that would clash with notification badges, and
  /// stay in saturated mid-tones so the dot stays legible on warm
  /// cream and dark backgrounds alike.
  Color _branchDotColor(String? branchId) {
    if (branchId == null || branchId.isEmpty) {
      return const Color(0xFF3F8E52); // sage fallback
    }
    var hash = 0;
    for (final code in branchId.codeUnits) {
      hash = (hash * 31 + code) & 0xFFFFFFF;
    }
    const palette = <Color>[
      Color(0xFF3F8E52), // sage green
      Color(0xFF4A7DBF), // family blue
      Color(0xFFA15FBF), // heritage purple
      Color(0xFFD7783A), // warm copper
      Color(0xFF2BA1A1), // teal
      Color(0xFF8E6C3F), // coffee
      Color(0xFFC4A030), // honey
      Color(0xFFB85B7C), // dusty rose
    ];
    return palette[hash % palette.length];
  }

  Future<void> _openSwitcherSheet(
    BuildContext context, {
    required TreeProvider treeProvider,
    required RodnyaDesignTokens tokens,
  }) async {
    // Refresh in the background so the sheet reflects any new
    // branches created on another device. Best-effort; the sheet
    // renders immediately with whatever's already loaded.
    treeProvider.refreshAvailableTrees();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => _BranchSwitcherSheet(
        outerContext: context,
        treeProvider: treeProvider,
      ),
    );
  }
}

class _BranchSwitcherSheet extends StatelessWidget {
  const _BranchSwitcherSheet({
    required this.outerContext,
    required this.treeProvider,
  });

  /// The original context the chip lives in. We use this for
  /// navigation pushes after the sheet pops, since the sheet's
  /// own context is gone by the time the push runs.
  final BuildContext outerContext;
  final TreeProvider treeProvider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle pill — same affordance as the rest of
            // the app's bottom sheets.
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: tokens.surfaceLine,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Ветки',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: tokens.ink,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Каждая ветка — отдельная лента, отдельные истории, отдельные родственники.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: tokens.inkSecondary,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            for (final tree in treeProvider.availableTrees) ...[
              _BranchSwitcherTile(
                tree: tree,
                isActive: tree.id == treeProvider.selectedTreeId,
                onTap: () async {
                  await treeProvider.selectTree(
                    tree.id,
                    tree.name,
                    treeKind: tree.kind,
                  );
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 4),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                // Canonical selector URL — same surface as the
                // back-arrow from the tree view. `/trees` now IS
                // that canonical selector (moved off `/tree?selector=1`
                // once `/tree` became its own tab route); this is no
                // longer the old overlay screen that used to live here.
                outerContext.push('/trees');
              },
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('Создать или управлять ветками'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BranchSwitcherTile extends StatelessWidget {
  const _BranchSwitcherTile({
    required this.tree,
    required this.isActive,
    required this.onTap,
  });

  final FamilyTree tree;
  final bool isActive;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    final memberLabel = tree.isFriendsTree ? 'Круг друзей' : 'Семейная ветка';
    return Material(
      color: isActive
          ? tokens.accent.withValues(alpha: 0.12)
          : tokens.surfaceStrong.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => onTap(),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tokens.accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  tree.isFriendsTree
                      ? Icons.diversity_3_rounded
                      : Icons.account_tree_outlined,
                  size: 20,
                  color: tokens.accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tree.name.trim().isEmpty ? 'Без названия' : tree.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: tokens.ink,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      memberLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: tokens.inkSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (isActive)
                Icon(
                  Icons.check_circle_rounded,
                  color: tokens.accent,
                  size: 22,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
