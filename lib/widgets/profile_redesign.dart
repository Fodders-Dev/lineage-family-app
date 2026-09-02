// Profile Redesign widget toolkit.
//
// Implements the building blocks called out in
// `docs/design_handoff/Profile Redesign.html`:
//   - HeroCard: cover gradient + avatar overlap + name/bio/stats/actions
//   - Section: uppercase label + glass info-card container
//   - InfoRow: 32x32 accent-soft icon + label/value + optional chevron
//   - CompletionMeter: % bar with suggestion chips
//   - PrivacyToggle: 44x26 iOS-style switch
//   - PrivacyScopeRow: «Только я / Семья / Все» 3-button selector
//   - PillButton: primary / outlined / ghost variants
//
// All widgets are theme-aware (light + dark) via `RodnyaDesignTokens`
// and lay out cleanly on phone widths AND desktop / web (max-width
// constraint applied at the screen level, not here).
//
// The new ProfileScreen + RelativeDetailsScreen + ProfileEditSheet
// compose from this kit so visual treatment stays consistent.

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../theme/app_theme.dart';
import '../utils/photo_url.dart';

/// Hero card matching the Profile Redesign spec:
///   - 130px cover (gradient or photo)
///   - 64x64 avatar overlapping the cover bottom by 32px
///   - Name (Lora 22px / 600), location (12px / 600 / muted), bio
///   - Optional stats grid (3 columns)
///   - Optional row of pill-buttons
///   - Optional rel-badge after the name (used on relative cards)
///   - Optional «† Память» badge top-left of cover (deceased relatives)
/// На сколько аватар свисает под обложку. Раньше свес делался через
/// Transform.translate, который двигает только отрисовку и оставлял
/// ~28dp пустого зарезервированного места под каждой шапкой.
const double _kHeroAvatarOverlap = 32;

class ProfileHeroCard extends StatelessWidget {
  const ProfileHeroCard({
    super.key,
    required this.fullName,
    this.firstName,
    this.lastName,
    this.patronymic,
    this.initials,
    this.photoUrl,
    this.coverPhotoUrl,
    this.location,
    this.bio,
    this.stats,
    this.actions,
    this.relBadge,
    this.useWarmAvatar = false,
    this.deceased = false,
    this.deceasedYears,
    this.onTapAvatar,
    this.onTapCover,
    this.onEditPressed,
    this.editLabel = 'Изменить',
    this.editIcon = Icons.edit_outlined,
  });

  /// Full name shown as the headline. The redesign splits this into
  /// «Имя Отчество» on line 1 and «Фамилия» on line 2 — when the
  /// caller passes `firstName/patronymic/lastName` we honour that
  /// split; otherwise we render `fullName` as a single line.
  final String fullName;
  final String? firstName;
  final String? lastName;
  final String? patronymic;

  /// 2-letter initials for the avatar fallback. When null we derive
  /// from `fullName`.
  final String? initials;
  final String? photoUrl;
  final String? coverPhotoUrl;
  final String? location;
  final String? bio;
  final List<ProfileHeroStat>? stats;

  /// Action row (pill buttons). Built by callers using [PillButton].
  final List<Widget>? actions;

  /// Small accent chip rendered below the name (e.g. "Дедушка по
  /// отцу" on relative cards). Pass null to hide.
  final String? relBadge;

  /// Use warm (amber) gradient on the avatar instead of accent.
  /// The redesign uses warm for relatives and accent for the user
  /// themselves.
  final bool useWarmAvatar;

  /// Memorial mode: cover gradient flips to grey ink, edit button
  /// is replaced by a years-of-life badge.
  final bool deceased;
  final String? deceasedYears;

  final VoidCallback? onTapAvatar;
  final VoidCallback? onTapCover;
  final VoidCallback? onEditPressed;
  final String editLabel;
  final IconData editIcon;

  String get _initials {
    if (initials != null && initials!.trim().isNotEmpty) return initials!;
    final source = fullName.trim();
    if (source.isEmpty) return '?';
    final parts = source.split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts[1].substring(0, 1))
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    final coverGradient = deceased
        ? const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF5B6863), Color(0xFF3D4845)],
          )
        : LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [tokens.accent, tokens.warm],
          );

    final avatarGradient = useWarmAvatar
        ? LinearGradient(
            begin: const Alignment(-0.5, -0.5),
            end: const Alignment(0.5, 0.5),
            colors: [tokens.warm, _darken(tokens.warm, 0.15)],
          )
        : LinearGradient(
            begin: const Alignment(-0.5, -0.5),
            end: const Alignment(0.5, 0.5),
            colors: [tokens.accent, tokens.accentStrong],
          );

    final cover = SizedBox(
      height: 88,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (coverPhotoUrl != null && coverPhotoUrl!.trim().isNotEmpty)
            ClipRect(
              child: CachedNetworkImage(
                imageUrl: normalizePhotoUrl(coverPhotoUrl!) ?? coverPhotoUrl!,
                fit: BoxFit.cover,
                placeholder: (_, __) =>
                    DecoratedBox(decoration: BoxDecoration(gradient: coverGradient)),
                errorWidget: (_, __, ___) =>
                    DecoratedBox(decoration: BoxDecoration(gradient: coverGradient)),
              ),
            )
          else
            DecoratedBox(decoration: BoxDecoration(gradient: coverGradient)),
          if (deceased)
            const Positioned(
              top: 10,
              left: 10,
              child: _MemorialBadge(),
            ),
          if (!deceased)
            Positioned(
              top: 10,
              right: 10,
              child: _CoverButton(
                onTap: onTapCover,
                label: 'обложка',
                icon: Icons.photo_camera_outlined,
              ),
            ),
        ],
      ),
    );

    final avatar = GestureDetector(
      onTap: onTapAvatar,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: photoUrl == null || photoUrl!.trim().isEmpty
              ? avatarGradient
              : null,
          border: Border.all(color: tokens.bgBase, width: 3),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 18,
              spreadRadius: -6,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipOval(
          child: photoUrl != null && photoUrl!.trim().isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: normalizePhotoUrl(photoUrl!) ?? photoUrl!,
                  fit: BoxFit.cover,
                  placeholder: (_, __) =>
                      DecoratedBox(decoration: BoxDecoration(gradient: avatarGradient)),
                  errorWidget: (_, __, ___) => Center(
                    child: Text(
                      _initials,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                )
              : Center(
                  child: Text(
                    _initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
        ),
      ),
    );

    Widget? trailing;
    if (deceased && deceasedYears != null && deceasedYears!.trim().isNotEmpty) {
      trailing = Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: tokens.bgTintSage,
          borderRadius: BorderRadius.circular(999),
        ),
        alignment: Alignment.center,
        child: Text(
          '† $deceasedYears',
          style: AppTheme.sans(
            color: tokens.inkMuted,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
      );
    } else if (onEditPressed != null) {
      trailing = _EditPill(
        label: editLabel,
        icon: editIcon,
        onPressed: onEditPressed!,
        accent: tokens.accent,
      );
    }

    // Имя в одну строку (перенос — только если не влезает): принудительный
    // '\n' перед фамилией делал двухстрочную шапку каждому.
    final nameStyle = AppTheme.serif(
      color: tokens.ink,
      fontSize: 20,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.3,
      height: 1.15,
    );
    final nameParts = <String>[
      if (firstName != null && firstName!.trim().isNotEmpty) firstName!.trim(),
      if (patronymic != null && patronymic!.trim().isNotEmpty)
        patronymic!.trim(),
      if (lastName != null && lastName!.trim().isNotEmpty) lastName!.trim(),
    ];
    final nameWidget = Text(
      nameParts.isNotEmpty ? nameParts.join(' ') : fullName,
      style: nameStyle,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: tokens.surfaceStrong,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tokens.surfaceLine),
        boxShadow: [
          BoxShadow(
            offset: const Offset(0, 2),
            blurRadius: 12,
            spreadRadius: -6,
            color: Colors.black.withValues(alpha: 0.14),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Аватар свисает под обложку настоящим overflow'ом Stack'а —
            // ниже резервируем ровно свес + зазор, а не «минус 36 / минус 28»
            // поверх полноразмерной колонки.
            Stack(
              clipBehavior: Clip.none,
              children: [
                cover,
                Positioned(
                  left: 16,
                  bottom: -_kHeroAvatarOverlap,
                  child: avatar,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                16,
                _kHeroAvatarOverlap + 8,
                16,
                12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (location != null &&
                                location!.trim().isNotEmpty) ...[
                              Row(
                                children: [
                                  Icon(Icons.place_outlined,
                                      size: 13, color: tokens.inkMuted),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      location!.trim(),
                                      style: AppTheme.sans(
                                        color: tokens.inkMuted,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 0,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                            ],
                            nameWidget,
                          ],
                        ),
                      ),
                      if (trailing != null) ...[
                        const SizedBox(width: 8),
                        trailing,
                      ],
                    ],
                  ),
                  if (relBadge != null && relBadge!.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _RelBadge(label: relBadge!),
                  ],
                  if (bio != null && bio!.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      bio!.trim(),
                      style: AppTheme.sans(
                        color: tokens.inkSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                        height: 1.35,
                      ),
                    ),
                  ],
                  if (stats != null && stats!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _StatsRow(stats: stats!),
                  ],
                  if (actions != null && actions!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: actions!,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Single stat cell shown in the hero card. The redesign uses 3
/// columns (posts / родных / дерева) but the widget supports any
/// non-empty list — the host controls semantics.
class ProfileHeroStat {
  const ProfileHeroStat({required this.value, required this.label});
  final String value;
  final String label;
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.stats});
  final List<ProfileHeroStat> stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return Row(
      children: [
        for (var i = 0; i < stats.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: tokens.bgTintWarm,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    stats[i].value,
                    style: AppTheme.serif(
                      color: tokens.ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    stats[i].label,
                    style: AppTheme.sans(
                      color: tokens.inkMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _CoverButton extends StatelessWidget {
  const _CoverButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: Colors.white),
              const SizedBox(width: 5),
              Text(
                label,
                style: AppTheme.sans(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditPill extends StatelessWidget {
  const _EditPill({
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.accent,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: accent,
      borderRadius: BorderRadius.circular(999),
      elevation: 4,
      shadowColor: accent.withValues(alpha: 0.45),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: SizedBox(
            height: 34,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: Colors.white),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: AppTheme.sans(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MemorialBadge extends StatelessWidget {
  const _MemorialBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
      ),
      child: Text(
        '† Память',
        style: AppTheme.sans(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _RelBadge extends StatelessWidget {
  const _RelBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: tokens.accentSoft,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tokens.accent.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: AppTheme.sans(
          color: tokens.accent,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// Pill-shaped action button used in the hero action row and on
/// relative-card actions. Three variants: primary (filled accent),
/// outlined (accent border), ghost (no background, muted text).
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.variant = PillButtonVariant.primary,
    this.expanded = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final PillButtonVariant variant;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    final isPrimary = variant == PillButtonVariant.primary;
    final isOutlined = variant == PillButtonVariant.outlined;
    // Disabled state: dim primary fill, mute outlined / ghost ink so
    // the user can tell at a glance that an action is parked
    // (loading, pre-condition not met, etc.). PillButton callers pass
    // `onPressed: null` to flag this.
    final isDisabled = onPressed == null;

    final fg = isPrimary
        ? Colors.white
        : (isOutlined ? tokens.accent : tokens.inkMuted);
    final bg = isPrimary ? tokens.accent : Colors.transparent;
    final border = isOutlined
        ? Border.all(color: tokens.accent.withValues(alpha: 0.32), width: 1.5)
        : null;
    final disabledOpacity = isDisabled ? 0.45 : 1.0;

    Widget content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: SizedBox(
        height: 36,
        child: Row(
          mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 6),
            Text(
              label,
              style: AppTheme.sans(
                color: fg,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ),
    );

    return Opacity(
      opacity: disabledOpacity,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        elevation: isPrimary && !isDisabled ? 4 : 0,
        shadowColor:
            isPrimary && !isDisabled ? tokens.accent.withValues(alpha: 0.45) : null,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onPressed,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: border,
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}

enum PillButtonVariant { primary, outlined, ghost }

/// Section wrapper: uppercase label above an info-card container.
/// The container holds a vertical list of [InfoRow]s (or any other
/// children — a relative-card kinship section, for example, uses
/// it for free-form content).
class ProfileSection extends StatelessWidget {
  const ProfileSection({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    required this.children,
    this.cardColor,
    this.borderColor,
  });

  final String title;
  final String? subtitle;
  final Widget? action;
  final List<Widget> children;
  final Color? cardColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.toUpperCase(),
                        style: AppTheme.sans(
                          color: tokens.inkMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.9,
                        ),
                      ),
                      if (subtitle != null && subtitle!.trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            subtitle!,
                            style: AppTheme.sans(
                              color: tokens.inkMuted,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (action != null) action!,
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: cardColor ?? tokens.surfaceStrong,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: borderColor ?? tokens.surfaceLine),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Column(children: children),
            ),
          ),
        ],
      ),
    );
  }
}

/// Single info-row inside a [ProfileSection]. 32x32 icon (accent or
/// warm tint) + label/value column + optional chevron. Tap-handler
/// makes the row pressable for opening the edit sheet.
class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.warm = false,
    this.onTap,
    this.trailing,
    this.isFirst = false,
    this.isLast = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool warm;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool isFirst;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final iconBg = warm ? tokens.warmSoft : tokens.accentSoft;
    final iconFg = warm ? tokens.warm : tokens.accent;

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 17, color: iconFg),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppTheme.sans(
                    color: tokens.inkMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: AppTheme.sans(
                    color: tokens.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
          if (onTap != null && trailing == null)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 6),
              child: Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: tokens.inkMuted,
              ),
            ),
        ],
      ),
    );

    final wrapped = onTap == null
        ? content
        : InkWell(
            onTap: onTap,
            child: content,
          );

    return Container(
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(
                  color: tokens.surfaceLine.withValues(alpha: 0.7),
                  width: 0.7,
                ),
              ),
      ),
      child: wrapped,
    );
  }
}

/// Privacy toggle row (iOS-style 44x26 switch + label/sub).
class PrivacyToggleRow extends StatelessWidget {
  const PrivacyToggleRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.isLast = false,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(
                  color: tokens.surfaceLine.withValues(alpha: 0.7),
                  width: 0.7,
                ),
              ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: value ? tokens.accentSoft : tokens.surfaceLine,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 17,
              color: value ? tokens.accent : tokens.inkMuted,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppTheme.sans(
                    color: tokens.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
                if (subtitle != null && subtitle!.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: AppTheme.sans(
                        color: tokens.inkMuted,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _IosToggle(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _IosToggle extends StatelessWidget {
  const _IosToggle({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 44,
        height: 26,
        decoration: BoxDecoration(
          color: value ? tokens.accent : tokens.surfaceLine,
          borderRadius: BorderRadius.circular(999),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 200),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 20,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Privacy scope: 3 mutually-exclusive buttons («Только я / Семья /
/// Все»). Active button gets accent-soft fill + accent border.
class PrivacyScopeRow extends StatelessWidget {
  const PrivacyScopeRow({
    super.key,
    required this.value,
    required this.onChanged,
    this.options = const [
      ProfileScopeOption(id: 'private', label: 'Только я'),
      ProfileScopeOption(id: 'family', label: 'Семья'),
      ProfileScopeOption(id: 'public', label: 'Все'),
    ],
  });

  final String value;
  final ValueChanged<String> onChanged;
  final List<ProfileScopeOption> options;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return Row(
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(options[i].id),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 44,
                decoration: BoxDecoration(
                  color: options[i].id == value
                      ? tokens.accentSoft
                      : tokens.bgTintWarm,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: options[i].id == value
                        ? tokens.accent
                        : tokens.surfaceLine,
                    width: 1.5,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  options[i].label,
                  style: AppTheme.sans(
                    color: options[i].id == value
                        ? tokens.accent
                        : tokens.inkMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class ProfileScopeOption {
  const ProfileScopeOption({required this.id, required this.label});
  final String id;
  final String label;
}

/// Profile completion meter: bar + percentage + suggestion chips.
/// Suggestions are tappable and open the edit sheet at a target step.
class ProfileCompletionMeterCard extends StatelessWidget {
  const ProfileCompletionMeterCard({
    super.key,
    required this.percent,
    this.suggestions = const [],
    this.label = 'Заполненность профиля',
  });

  /// 0..100. Anything outside is clamped.
  final double percent;
  final String label;

  /// Suggestion chips below the bar. Each tap fires the chip's
  /// `onTap` (host opens edit sheet at the right step).
  final List<ProfileCompletionChipData> suggestions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final clamped = percent.clamp(0.0, 100.0);
    // Заполненный профиль подсказок не требует — плитке нечего показывать.
    if (clamped >= 100 && suggestions.isEmpty) {
      return const SizedBox.shrink();
    }
    // Плотность (02.09.2026): поля 14/12 → 12/8, чипы — одной прокручиваемой
    // строкой вместо Wrap на 2–3 ряда: плитка ~90 → ~70dp и не растёт с
    // числом подсказок.
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: tokens.surfaceStrong,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tokens.surfaceLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: AppTheme.sans(
                    color: tokens.inkMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ),
              Text(
                '${clamped.round()}%',
                style: AppTheme.sans(
                  color: tokens.accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LayoutBuilder(builder: (ctx, c) {
              return Stack(
                children: [
                  Container(
                    height: 6,
                    color: tokens.bgTintSage,
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeOutCubic,
                    height: 6,
                    width: c.maxWidth * (clamped / 100),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [tokens.accent, tokens.warm],
                      ),
                    ),
                  ),
                ],
              );
            }),
          ),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
              children: suggestions
                  .map(
                    (s) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: GestureDetector(
                      onTap: s.onTap,
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: tokens.accentSoft,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: tokens.accent.withValues(alpha: 0.32),
                          ),
                        ),
                        child: Text(
                          '+ ${s.label}',
                          style: AppTheme.sans(
                            color: tokens.accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0,
                          ),
                        ),
                      ),
                    ),
                    ),
                  )
                  .toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class ProfileCompletionChipData {
  const ProfileCompletionChipData({required this.label, this.onTap});
  final String label;
  final VoidCallback? onTap;
}

Color _darken(Color color, double amount) {
  assert(amount >= 0 && amount <= 1);
  final hsl = HSLColor.fromColor(color);
  return hsl.withLightness((hsl.lightness - amount).clamp(0.0, 1.0)).toColor();
}
