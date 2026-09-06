// Phase E5b: feed card for an «Опрос» (Poll). Mirrors GatheringCard's
// shell (author header, type badge, photos via FeedMediaGallery) and its
// optimistic-update pattern, swapping the RSVP row for option bars: each
// option is a tappable bar with a percent fill by votes, my pick
// highlighted. Single-choice replaces my vote; multi toggles.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/intl.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/poll_service_interface.dart';
import '../models/poll.dart';
import '../models/post.dart' show TreeContentScopeType;
import '../theme/app_theme.dart';
import '../utils/date_parser.dart';
import 'feed_media_gallery.dart';
import 'media_lightbox.dart';

class PollCard extends StatefulWidget {
  const PollCard({
    super.key,
    required this.poll,
    this.serviceOverride,
    this.currentUserId,
  });

  final Poll poll;

  /// Test seams — production resolves these via GetIt.
  final PollServiceInterface? serviceOverride;
  final String? currentUserId;

  @override
  State<PollCard> createState() => _PollCardState();
}

class _PollCardState extends State<PollCard> {
  late Poll _poll = widget.poll;
  bool _submitting = false;

  PollServiceInterface? get _service =>
      widget.serviceOverride ??
      (GetIt.I.isRegistered<PollServiceInterface>()
          ? GetIt.I<PollServiceInterface>()
          : null);

  String? get _currentUserId =>
      widget.currentUserId ??
      (GetIt.I.isRegistered<AuthServiceInterface>()
          ? GetIt.I<AuthServiceInterface>().currentUserId
          : null);

  // Optimistic local upsert of my vote row (mirrors GatheringCard._respond).
  Poll _withMyVote(Poll p, String myId, List<String> optionIds) {
    final next = <Map<String, dynamic>>[
      for (final r in p.responses)
        if (r['userId']?.toString() != myId) Map<String, dynamic>.from(r),
      {'userId': myId, 'optionIds': optionIds},
    ];
    return p.copyWith(responses: next);
  }

  Future<void> _vote(String optionId) async {
    final service = _service;
    final myId = _currentUserId;
    if (service == null || myId == null || _submitting) return;

    final previous = _poll;
    final current = previous.myVotedOptionIds(myId).toSet();
    final Set<String> next;
    if (previous.allowMultiple) {
      next = {...current};
      if (next.contains(optionId)) {
        next.remove(optionId);
      } else {
        next.add(optionId);
      }
      // No un-vote endpoint — keep at least one choice.
      if (next.isEmpty) return;
    } else {
      next = {optionId};
    }
    final nextIds = next.toList();

    setState(() {
      _poll = _withMyVote(previous, myId, nextIds);
      _submitting = true;
    });
    try {
      final updated = await service.vote(previous.id, nextIds);
      if (!mounted) return;
      setState(() {
        _poll = updated;
        _submitting = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _poll = previous; // revert
        _submitting = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить голос')),
      );
    }
  }

  // Плотность (чанк 24): было padding: EdgeInsets.all(16) на весь
  // контейнер (16dp сверху и снизу впустую) — теперь локальный паддинг
  // на секцию (12 по бокам), как у GatheringCard/PostCard (чанки 24/20).
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return Container(
      key: Key('poll-card-${_poll.id}'),
      margin: EdgeInsets.only(bottom: tokens.space8),
      decoration: BoxDecoration(
        color: tokens.surfaceStrong,
        borderRadius: BorderRadius.circular(tokens.radiusLg),
        border: Border.all(color: tokens.surfaceLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Плотность (чанк 24): вертикаль шапки 4/4 (было бы 8/8, как у
          // GatheringCard) — карточка опроса несёт 3 варианта под собой
          // и должна уложиться в ≤260dp целиком, бюджет плотнее.
          Padding(
            padding: EdgeInsets.fromLTRB(tokens.space12, 4, tokens.space8, 4),
            child: _buildHeader(theme, tokens),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                tokens.space12, 0, tokens.space12, tokens.space4),
            child: Text(
              _poll.question,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.serif(
                color: tokens.ink,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
          ),
          if (_poll.renderableImageUrls.isNotEmpty) _buildPhotos(),
          Padding(
            padding: EdgeInsets.fromLTRB(
                tokens.space12, 0, tokens.space12, tokens.space8),
            child: _buildOptions(theme, tokens),
          ),
        ],
      ),
    );
  }

  // Плотность (чанк 24): шапка ≤56dp — тот же приём, что у GatheringCard:
  // дата публикации и аудитория объединены в одну строку метаданных
  // вместо отдельной строки-даты.
  Widget _buildHeader(ThemeData theme, RodnyaDesignTokens tokens) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildAvatar(theme, tokens),
        SizedBox(width: tokens.space8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _poll.authorName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.sans(
                  color: tokens.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 2),
              DefaultTextStyle.merge(
                style: AppTheme.sans(
                  color: tokens.inkMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.2,
                ),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        DateFormat('d MMMM', 'ru')
                            .format(toLocalForDisplay(_poll.createdAt)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text('·'),
                    const SizedBox(width: 6),
                    Icon(_audienceIcon, size: 13, color: tokens.inkMuted),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        _audienceLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SizedBox(width: tokens.space8),
        _buildTypeBadge(theme, tokens),
      ],
    );
  }

  String get _audienceLabel =>
      _poll.scopeType == TreeContentScopeType.branches ? 'Ветки' : 'Семья';

  IconData get _audienceIcon => _poll.scopeType == TreeContentScopeType.branches
      ? Icons.alt_route
      : Icons.eco_outlined;

  Widget _buildAvatar(ThemeData theme, RodnyaDesignTokens tokens) {
    final photo = _poll.renderableAuthorPhotoUrl;
    return Container(
      width: 40,
      height: 40,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: tokens.accentSoft,
        shape: BoxShape.circle,
        border: Border.all(color: tokens.surfaceLine),
      ),
      child: photo != null && photo.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: photo,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => _buildInitials(theme, tokens),
            )
          : _buildInitials(theme, tokens),
    );
  }

  Widget _buildInitials(ThemeData theme, RodnyaDesignTokens tokens) {
    final name = _poll.authorName.trim();
    final initial = name.isEmpty ? 'Р' : String.fromCharCode(name.runes.first);
    return Center(
      child: Text(
        initial.toUpperCase(),
        style: theme.textTheme.titleSmall?.copyWith(
          color: tokens.accent,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildTypeBadge(ThemeData theme, RodnyaDesignTokens tokens) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: tokens.accentSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bar_chart_rounded, size: 14, color: tokens.accent),
          const SizedBox(width: 4),
          Text(
            'Опрос',
            style: theme.textTheme.labelSmall?.copyWith(
              color: tokens.accent,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotos() {
    final images = _poll.renderableImageUrls;
    return FeedMediaGallery(
      imageUrls: images,
      caption: _poll.question,
      captionPrefix: 'Фото опроса',
      // Плотность (чанк 24): контейнер больше не паддит всё целиком —
      // дефолтный инсет галереи (space12 бока+низ) не задваивается.
      onTap: (index) {
        MediaLightbox.show(
          context,
          items: [
            for (final url in images) MediaLightboxItem(imageUrl: url),
          ],
          initialIndex: index,
        );
      },
    );
  }

  // Плотность (чанк 24): «N голосов · до …» одной строкой 13sp — было
  // bodySmall (без явного размера) и без даты закрытия вовсе (closesAt
  // нигде не отображался, хотя модель его несёт).
  Widget _buildOptions(ThemeData theme, RodnyaDesignTokens tokens) {
    final total = _poll.totalVoters;
    final myVotes = _poll.myVotedOptionIds(_currentUserId).toSet();
    final closesAt = _poll.closesAt;
    final options = _poll.options;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Плотность (чанк 24): зазор МЕЖДУ строками (4dp), а не паддинг
        // «снизу у каждой» (было tokens.space8 на КАЖДЫЙ вариант,
        // включая последний, — лишние 8dp перед строкой голосов). Три
        // варианта по 44dp держат бюджет ≤260dp карточки.
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) SizedBox(height: tokens.space4),
          _buildOptionBar(theme, tokens, options[i], myVotes, total),
        ],
        SizedBox(height: tokens.space4),
        Text(
          key: const Key('poll-vote-count'),
          '$total ${_votesWord(total)}'
          '${_poll.allowMultiple ? ' · можно несколько' : ''}'
          '${closesAt != null ? ' · до ${DateFormat('d MMMM', 'ru').format(closesAt)}' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTheme.sans(
            color: tokens.inkMuted,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildOptionBar(
    ThemeData theme,
    RodnyaDesignTokens tokens,
    PollOption option,
    Set<String> myVotes,
    int total,
  ) {
    final votes = _poll.votesFor(option.id);
    final fraction = total == 0 ? 0.0 : votes / total;
    final percent = (fraction * 100).round();
    final selected = myVotes.contains(option.id);
    final radius = BorderRadius.circular(tokens.radiusSm);

    // Плотность (чанк 24): зазор между строками теперь ставит вызывающий
    // _buildOptions (SizedBox между элементами) — эта функция больше не
    // несёт собственный нижний отступ (см. комментарий там).
    return InkWell(
      key: Key('poll-option-${option.id}'),
      borderRadius: radius,
      onTap: _submitting ? null : () => _vote(option.id),
      child: SizedBox(
        height: 44,
        child: Stack(
          children: [
              // Track.
              Container(
                decoration: BoxDecoration(
                  color: tokens.surface,
                  borderRadius: radius,
                  border: Border.all(
                    color: selected ? tokens.accent : tokens.surfaceLine,
                    width: selected ? 1.4 : 1,
                  ),
                ),
              ),
              // Percent fill.
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: fraction.clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: selected
                          ? tokens.accent.withValues(alpha: 0.22)
                          : tokens.accentSoft,
                      borderRadius: radius,
                    ),
                  ),
                ),
              ),
              // Label + percent.
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Icon(
                        selected
                            ? (_poll.allowMultiple
                                ? Icons.check_box_rounded
                                : Icons.radio_button_checked)
                            : (_poll.allowMultiple
                                ? Icons.check_box_outline_blank_rounded
                                : Icons.radio_button_unchecked),
                        size: 18,
                        color: selected ? tokens.accent : tokens.inkMuted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          option.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          // Плотность (чанк 24): 16sp явно (было bodyMedium
                          // без гарантии ≥16sp) — вариант ответа это контент.
                          style: AppTheme.sans(
                            color: tokens.ink,
                            fontSize: 16,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$percent%',
                        // Плотность (чанк 24): 14sp явно (было labelMedium
                        // ≈12sp).
                        style: AppTheme.sans(
                          color: tokens.inkMuted,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
  }

  String _votesWord(int count) {
    final mod10 = count % 10;
    final mod100 = count % 100;
    if (mod10 == 1 && mod100 != 11) return 'голос';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return 'голоса';
    }
    return 'голосов';
  }
}
