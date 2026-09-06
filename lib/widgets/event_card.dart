import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/app_event.dart';
import '../theme/app_theme.dart';
import '../utils/relative_details_route.dart';

class EventCard extends StatelessWidget {
  final AppEvent event;
  final double? width;
  final bool compact;

  /// Чанк 26: сайдбар «Родня» на десктоп-раскладке хочет плоские строки
  /// (без карточки-в-карточке внутри своей GlassPanel-обёртки) — тот же
  /// контент, без Material-заливки и обводки. Дефолт `false` сохраняет
  /// прежний вид везде, где EventCard уже используется как отдельная
  /// карточка (горизонтальный рельс, календарь).
  final bool plain;

  /// Tap handler used only for events NOT linked to a person (e.g. a
  /// holiday → show its info). Person-linked events always open the
  /// profile and ignore this.
  final VoidCallback? onTap;

  const EventCard({
    required this.event,
    this.width,
    this.compact = false,
    this.plain = false,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = _tokensFor(theme);
    final canOpenProfile = event.isLinkedToPerson;
    final personName = canOpenProfile ? event.personName.trim() : '';
    final radius = BorderRadius.circular(compact ? 14 : 20);
    final onTapHandler = canOpenProfile
        // P0: событие знает своё дерево — карточка открывается сразу
        // в нём, а не в выбранном.
        ? () => context.push(
              relativeDetailsRoute(
                event.personId,
                treeId: event.treeId,
              ),
            )
        : onTap;
    final content = Padding(
      padding: compact
          ? const EdgeInsets.fromLTRB(8, 8, 14, 8)
          : const EdgeInsets.fromLTRB(12, 11, 12, 12),
      child: compact
          ? _buildCompactBody(context, personName, canOpenProfile)
          : _buildFullBody(context, personName, canOpenProfile),
    );

    return SizedBox(
      width: width ?? (compact ? 220 : 220),
      child: plain
          ? Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: radius,
                onTap: onTapHandler,
                child: content,
              ),
            )
          : Material(
              color: tokens.surfaceStrong,
              shape: RoundedRectangleBorder(
                side: BorderSide(color: tokens.surfaceLine),
                borderRadius: radius,
              ),
              child: InkWell(
                borderRadius: radius,
                onTap: onTapHandler,
                child: content,
              ),
            ),
    );
  }

  Widget _buildCompactBody(
    BuildContext context,
    String personName,
    bool canOpenProfile,
  ) {
    final theme = Theme.of(context);
    final tokens = _tokensFor(theme);
    final accent = _eventAccent(tokens);
    final accentSoft = _eventAccentSoft(tokens);
    final subtitle = personName.isNotEmpty ? personName : event.status;

    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: accentSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _shortMonth(event.date).toUpperCase(),
                style: AppTheme.sans(
                  color: accent,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  height: 1.0,
                ),
              ),
              Text(
                event.date.day.toString(),
                style: AppTheme.sans(
                  color: accent,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                  height: 1.05,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                event.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.sans(
                  color: tokens.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.sans(
                  color: tokens.inkMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFullBody(
    BuildContext context,
    String personName,
    bool canOpenProfile,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tokens = _tokensFor(theme);
    final accent = _eventAccent(tokens);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.85,
                    ),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    event.categoryLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                event.status,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: accent,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                event.icon,
                size: 18,
                color: accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (personName.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      personName,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            if (canOpenProfile) ...[
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 17,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ],
        ),
      ],
    );
  }

  RodnyaDesignTokens _tokensFor(ThemeData theme) {
    return theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
  }

  Color _eventAccent(RodnyaDesignTokens tokens) =>
      _isWarmEvent ? tokens.warm : tokens.accent;

  Color _eventAccentSoft(RodnyaDesignTokens tokens) =>
      _isWarmEvent ? tokens.warmSoft : tokens.accentSoft;

  bool get _isWarmEvent =>
      event.type == AppEventType.birthday ||
      event.type == AppEventType.weddingAnniversary ||
      event.type == AppEventType.customFamilyEvent;

  String _shortMonth(DateTime value) {
    const months = <int, String>{
      1: 'янв',
      2: 'фев',
      3: 'мар',
      4: 'апр',
      5: 'мая',
      6: 'июн',
      7: 'июл',
      8: 'авг',
      9: 'сен',
      10: 'окт',
      11: 'ноя',
      12: 'дек',
    };
    return months[value.month] ?? '';
  }
}
