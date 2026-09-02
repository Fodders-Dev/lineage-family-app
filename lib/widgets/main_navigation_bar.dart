import 'dart:ui';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class MainNavigationBar extends StatelessWidget {
  const MainNavigationBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.unreadNotificationsStream,
    required this.unreadChatsStream,
    required this.pendingInvitationsCountStream,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final Stream<int> unreadNotificationsStream;
  final Stream<int> unreadChatsStream;
  final Stream<int> pendingInvitationsCountStream;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: unreadNotificationsStream,
      initialData: 0,
      builder: (context, notificationsSnapshot) {
        final unreadNotificationsCount = notificationsSnapshot.data ?? 0;
        return StreamBuilder<int>(
          stream: unreadChatsStream,
          initialData: 0,
          builder: (context, unreadSnapshot) {
            final unreadCount = unreadSnapshot.data ?? 0;
            return StreamBuilder<int>(
              stream: pendingInvitationsCountStream,
              initialData: 0,
              builder: (context, invitationsSnapshot) {
                final pendingInvitationsCount = invitationsSnapshot.data ?? 0;

                final items = <_NavItemData>[
                  _NavItemData(
                    label: 'Лента',
                    outlinedIcon: Icons.home_outlined,
                    filledIcon: Icons.home_rounded,
                    count: unreadNotificationsCount,
                  ),
                  _NavItemData(
                    label: 'Родные',
                    outlinedIcon: Icons.groups_outlined,
                    filledIcon: Icons.groups_rounded,
                    // Приглашения — про людей, поэтому бейдж живёт на
                    // «Родных» (у дерева своя вкладка с августа 2026).
                    count: pendingInvitationsCount,
                  ),
                  // Ядро продукта — в центре бара. Люди приходят строить
                  // семейное дерево; с июня по август у него не было ни
                  // своей вкладки, ни имени в интерфейсе (жило режимом
                  // внутри «Родных»). Календарь уехал на Ленту.
                  const _NavItemData(
                    label: 'Дерево',
                    outlinedIcon: Icons.account_tree_outlined,
                    filledIcon: Icons.account_tree_rounded,
                  ),
                  _NavItemData(
                    label: 'Чаты',
                    outlinedIcon: Icons.chat_bubble_outline_rounded,
                    filledIcon: Icons.chat_bubble_rounded,
                    count: unreadCount,
                  ),
                  const _NavItemData(
                    label: 'Профиль',
                    outlinedIcon: Icons.person_outline_rounded,
                    filledIcon: Icons.person_rounded,
                  ),
                ];

                final theme = Theme.of(context);
                final isDark = theme.brightness == Brightness.dark;
                final tokens = theme.extension<RodnyaDesignTokens>() ??
                    (isDark
                        ? RodnyaDesignTokens.dark
                        : RodnyaDesignTokens.light);

                // Плоская панель у нижнего края (02.09.2026): плавающая
                // пилюля с полями 14dp и двойной тенью занимала 84–100dp на
                // каждой вкладке — Telegram обходится 56 + системный inset.
                return SafeArea(
                  top: false,
                  minimum: EdgeInsets.zero,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Was `>= 340` — too strict; on Samsung Galaxy
                      // S20 / mid-range phones the SafeArea + outer
                      // 14dp padding pulled effective width to ~330dp
                      // and labels disappeared. The five short labels
                      // (Лента / Родные / Дерево / Чаты / Профиль) fit
                      // even at 280dp so we lower the threshold; a 240dp
                      // floor still trips for very narrow tablets in
                      // weird split-screen layouts.
                      final showLabels = constraints.maxWidth >= 280;
                      // Labelled height = AppTheme.bottomNavContentHeight,
                      // чтобы bottomNavInset резервировал ровно панель.
                      final navHeight =
                          showLabels ? AppTheme.bottomNavContentHeight : 48.0;
                      // User-reported: «домик с лентой находятся
                      // правее этой зеленой области». The pill used
                      // `constraints.maxWidth / items.length` for its
                      // slot, but the Row of nav items lives inside a
                      // `Padding(horizontal: 6 or 4)` — so each
                      // NavItem's actual slot was `(maxWidth - 2 *
                      // padding) / items.length`. The pill ended up
                      // 9–10 dp narrower than the item, so the icon
                      // sat off-center to the right of the green
                      // pill. Recompute using the same denominator.
                      final rowPadding = showLabels ? 6.0 : 4.0;
                      final itemSlotWidth =
                          (constraints.maxWidth - 2 * rowPadding) /
                              items.length;
                      const pillInset = 6.0;
                      final pillLeft =
                          rowPadding + itemSlotWidth * currentIndex + pillInset;
                      final pillWidth = itemSlotWidth - 2 * pillInset;

                      // Skip BackdropFilter on web (CPU-bound) AND on
                      // Android (mid-range GPU bound). The bar already
                      // floats above content via box-shadow, and at
                      // ≥0.90 alpha the underlying scroll is barely
                      // perceptible — well worth the frame-time win
                      // on Samsung S20 FE / Galaxy A-series. We keep
                      // the blur on iOS + desktop where the cost is
                      // negligible and the look is nicer.
                      final useBlur = !kIsWeb &&
                          defaultTargetPlatform != TargetPlatform.android;
                      final navFill = tokens.surface.withValues(
                        alpha: useBlur
                            ? (isDark ? 0.58 : 0.64)
                            : (isDark ? 0.90 : 0.94),
                      );
                      final borderColor = tokens.surfaceLine;
                      final navRadius = BorderRadius.zero;

                      Widget navInner = ClipRRect(
                        borderRadius: navRadius,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: DecoratedBox(
                                decoration: BoxDecoration(color: navFill),
                              ),
                            ),
                            Positioned.fill(
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.white.withValues(
                                          alpha: isDark ? 0.08 : 0.32,
                                        ),
                                        Colors.white.withValues(alpha: 0),
                                      ],
                                      stops: const [0, 0.5],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            AnimatedPositioned(
                              duration: const Duration(milliseconds: 320),
                              curve: Curves.easeOutCubic,
                              left: pillLeft,
                              top: 4,
                              bottom: 4,
                              width: pillWidth,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: tokens.accentGradient,
                                  borderRadius: BorderRadius.circular(999),
                                  boxShadow: [
                                    BoxShadow(
                                      color: tokens.accent.withValues(
                                        alpha: isDark ? 0.34 : 0.30,
                                      ),
                                      blurRadius: 22,
                                      spreadRadius: -8,
                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: showLabels ? 6 : 4,
                                vertical: 4,
                              ),
                              child: Row(
                                children: [
                                  for (var index = 0;
                                      index < items.length;
                                      index++)
                                    Expanded(
                                      child: _NavItem(
                                        data: items[index],
                                        selected: currentIndex == index,
                                        showLabel: showLabels,
                                        onTap: () => onTap(index),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Positioned.fill(
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: navRadius,
                                    // Волосяная линия сверху вместо рамки
                                    // вокруг: панель, не карточка.
                                    border: Border(
                                      top: BorderSide(
                                        color: borderColor,
                                        width: 0.6,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );

                      if (useBlur) {
                        navInner = ClipRRect(
                          borderRadius: navRadius,
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                            child: navInner,
                          ),
                        );
                      }

                      // Без внешних теней: панель лежит на краю экрана, а не
                      // парит над контентом.
                      return SizedBox(height: navHeight, child: navInner);
                    },
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _NavItemData {
  const _NavItemData({
    required this.label,
    required this.outlinedIcon,
    required this.filledIcon,
    this.count = 0,
  });

  final String label;
  final IconData outlinedIcon;
  final IconData filledIcon;
  final int count;
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.data,
    required this.selected,
    required this.showLabel,
    required this.onTap,
  });

  final _NavItemData data;
  final bool selected;
  final bool showLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    final iconColor = selected ? tokens.accentInk : scheme.onSurfaceVariant;
    final icon = Icon(
      selected ? data.filledIcon : data.outlinedIcon,
      size: 22,
      color: iconColor,
    );

    final iconWithBadge = data.count <= 0
        ? icon
        : Stack(
            clipBehavior: Clip.none,
            children: [
              icon,
              Positioned(
                top: -4,
                right: -8,
                child: Container(
                  constraints: const BoxConstraints(
                    minWidth: 16,
                    minHeight: 16,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: tokens.warm,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: selected ? tokens.accentInk : tokens.surfaceStrong,
                      width: 1.5,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      data.count > 99 ? '99+' : data.count.toString(),
                      style: AppTheme.sans(
                        color: const Color(0xFF241A0D),
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );

    return Semantics(
      button: true,
      selected: selected,
      label: data.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          // Horizontal stays tight (space4) so "Родные"/"Дерево" fit on
          // Samsung-mid widths. Vertical slimmed to space4/space8 (was
          // 6/10) as part of the bar slimming.
          padding: EdgeInsets.symmetric(
            horizontal: tokens.space4,
            vertical: showLabel ? tokens.space4 : tokens.space8,
          ),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(999)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              iconWithBadge,
              if (showLabel) ...[
                const SizedBox(height: 3),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    data.label,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color:
                          selected ? tokens.accentInk : scheme.onSurfaceVariant,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      letterSpacing: -0.1,
                      fontSize: 10.5,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
