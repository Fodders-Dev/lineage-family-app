// Phase E2c/E3b: feed card for a «Встреча» (Gathering). Mirrors PostCard's
// visual language (author header, audience chip, body) — no likes /
// comments / media. Phase E3b lights up the RSVP row (Да / Может / Нет)
// with an optimistic update, an optional headcount stepper, and a public
// tally, mirroring the post like/reaction toggle pattern.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/intl.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/gathering_service_interface.dart';
import '../models/gathering.dart';
import '../models/post.dart' show TreeContentScopeType;
import '../theme/app_theme.dart';
import 'feed_media_gallery.dart';
import 'media_lightbox.dart';

class GatheringCard extends StatefulWidget {
  const GatheringCard({
    super.key,
    required this.gathering,
    this.serviceOverride,
    this.currentUserId,
  });

  final Gathering gathering;

  /// Test seams — production resolves these via GetIt.
  final GatheringServiceInterface? serviceOverride;
  final String? currentUserId;

  @override
  State<GatheringCard> createState() => _GatheringCardState();
}

class _GatheringCardState extends State<GatheringCard> {
  late Gathering _gathering = widget.gathering;
  late int _myHeadcount;
  bool _submitting = false;

  GatheringServiceInterface? get _service =>
      widget.serviceOverride ??
      (GetIt.I.isRegistered<GatheringServiceInterface>()
          ? GetIt.I<GatheringServiceInterface>()
          : null);

  String? get _currentUserId =>
      widget.currentUserId ??
      (GetIt.I.isRegistered<AuthServiceInterface>()
          ? GetIt.I<AuthServiceInterface>().currentUserId
          : null);

  @override
  void initState() {
    super.initState();
    _myHeadcount = _gathering.headcountFor(_currentUserId);
  }

  // Optimistic local upsert of my RSVP row (mirrors the post like toggle:
  // mutate now, reconcile/revert when the server answers).
  Gathering _withMyRsvp(
      Gathering g, String myId, String status, int headcount) {
    final next = <Map<String, dynamic>>[
      for (final r in g.rsvps)
        if (r['userId']?.toString() != myId) Map<String, dynamic>.from(r),
      {
        'userId': myId,
        'status': status,
        'headcount': status == 'yes' ? headcount : 0,
        'note': null,
        'respondedAt': null,
      },
    ];
    return g.copyWith(rsvps: next);
  }

  Future<void> _respond(String status) async {
    final service = _service;
    final myId = _currentUserId;
    if (service == null || myId == null || _submitting) return;

    final previous = _gathering;
    final headcount = status == 'yes' ? _myHeadcount : 0;
    setState(() {
      _gathering = _withMyRsvp(previous, myId, status, headcount);
      _submitting = true;
    });
    try {
      final updated =
          await service.setRsvp(previous.id, status, headcount: headcount);
      if (!mounted) return;
      setState(() {
        _gathering = updated;
        _myHeadcount = updated.headcountFor(myId);
        _submitting = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _gathering = previous; // revert
        _myHeadcount = previous.headcountFor(myId);
        _submitting = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить ответ')),
      );
    }
  }

  void _changeHeadcount(int delta) {
    final next = (_myHeadcount + delta).clamp(0, 99);
    if (next == _myHeadcount) return;
    setState(() => _myHeadcount = next);
    _respond('yes'); // persist the new headcount
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    // Плотность (чанк 24): было padding: EdgeInsets.all(16) на весь
    // контейнер — 16dp сверху и снизу впустую поверх содержимого секций.
    // Теперь паддинг локальный на каждую секцию (12 по бокам, вертикаль
    // под конкретный бюджет), как в PostCard (чанк 20).
    return Container(
      key: Key('gathering-card-${_gathering.id}'),
      margin: EdgeInsets.only(bottom: tokens.space8),
      decoration: BoxDecoration(
        color: tokens.surfaceStrong,
        borderRadius: BorderRadius.circular(tokens.radiusLg),
        border: Border.all(color: tokens.surfaceLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(tokens.space12, 8, tokens.space8, 8),
            child: _buildHeader(theme, tokens),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                tokens.space12, 0, tokens.space12, tokens.space8),
            child: _buildBody(theme, tokens),
          ),
          if (_gathering.renderableImageUrls.isNotEmpty) _buildPhotos(tokens),
          Padding(
            padding: EdgeInsets.fromLTRB(
                tokens.space12, 0, tokens.space12, tokens.space12),
            child: _buildRsvp(theme, tokens),
          ),
        ],
      ),
    );
  }

  // Плотность (чанк 24): шапка ≤56dp — аватар 40 + 8/8 вертикали. Время
  // публикации и аудитория объединены в одну строку метаданных (было:
  // отдельная строка даты + отдельный чип аудитории после «когда·где» —
  // тот чип стоил ~38dp сам по себе). Тот же приём, что у PostCard
  // (чанк 20): Flexible + «·»-разделитель гарантируют одну строку даже
  // на длинных лейблах / крупном системном шрифте.
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
                _gathering.authorName,
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
                        _formatPosted(_gathering.createdAt),
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

  // Короткие ярлыки для строки метаданных шапки (было: отдельный чип
  // «Вся семья» / «Отдельные ветки» после «когда·где»).
  String get _audienceLabel =>
      _gathering.scopeType == TreeContentScopeType.branches
          ? 'Ветки'
          : 'Семья';

  IconData get _audienceIcon =>
      _gathering.scopeType == TreeContentScopeType.branches
          ? Icons.alt_route
          : Icons.eco_outlined;

  Widget _buildAvatar(ThemeData theme, RodnyaDesignTokens tokens) {
    final photo = _gathering.renderableAuthorPhotoUrl;
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
    final name = _gathering.authorName.trim();
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
          Icon(Icons.event_outlined, size: 14, color: tokens.accent),
          const SizedBox(width: 4),
          Text(
            'Встреча',
            style: theme.textTheme.labelSmall?.copyWith(
              color: tokens.accent,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  // Плотность (чанк 24): заголовок 18sp (было titleLarge ≈22) + «когда·где»
  // объединены в одну строку с иконками 18dp (было: две отдельные строки
  // schedule/place + отдельный чип аудитории — три строки контента вместо
  // одной). Аудитория переехала в шапку (см. _buildHeader).
  Widget _buildBody(ThemeData theme, RodnyaDesignTokens tokens) {
    final description = _gathering.description?.trim() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _gathering.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppTheme.serif(
            color: tokens.ink,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        SizedBox(height: tokens.space8),
        _buildWhenWhere(tokens),
        if (description.isNotEmpty) ...[
          SizedBox(height: tokens.space8),
          Text(
            description,
            style: AppTheme.sans(
              color: tokens.ink,
              fontSize: 16,
              fontWeight: FontWeight.w500,
              height: 1.3,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildWhenWhere(RodnyaDesignTokens tokens) {
    final place = _gathering.place?.trim() ?? '';
    final textStyle = AppTheme.sans(
      color: tokens.ink,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    );
    return Row(
      children: [
        Icon(Icons.schedule_outlined, size: 18, color: tokens.accent),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            _formatWhen(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle,
          ),
        ),
        if (place.isNotEmpty) ...[
          const SizedBox(width: 8),
          Text('·', style: textStyle.copyWith(color: tokens.inkMuted)),
          const SizedBox(width: 8),
          Icon(Icons.place_outlined, size: 18, color: tokens.accent),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              place,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textStyle,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPhotos(RodnyaDesignTokens tokens) {
    final images = _gathering.renderableImageUrls;
    return FeedMediaGallery(
      imageUrls: images,
      caption: _gathering.title,
      captionPrefix: 'Фото встречи',
      // Плотность (чанк 24): контейнер больше не паддит контент целиком
      // (было EdgeInsets.all(16)) — дефолтный инсет галереи (space12
      // бока+низ) теперь и есть единственный инсет, без двойного счёта.
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

  // ── RSVP (Phase E3b) ──
  //
  // Плотность (чанк 24): было — 3 кнопки статуса + отдельная строка
  // «Пойдут: N · Может: N · Нет: N» под ними (~20dp сама по себе).
  // Счётчики переехали внутрь кнопок («Пойду 4», как «Тепло 3» у
  // PostCard, чанк 20) — так «действия одной строкой 44dp, счётчики
  // внутри» из спеки чанка 24 не тянет за собой отдельную строку-дубль.
  // «Кто идёт» теперь виден как ряд аватаров-инициалов над кнопками
  // (только когда есть хоть один «да» — до первого ответа ряд пуст и
  // не занимает места).
  Widget _buildRsvp(ThemeData theme, RodnyaDesignTokens tokens) {
    final myStatus = _gathering.myRsvpStatus(_currentUserId);
    final participants = _buildParticipants(tokens);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (participants != null) ...[
          participants,
          SizedBox(height: tokens.space8),
        ],
        SizedBox(
          height: 44,
          child: Row(
            children: [
              Expanded(
                child: _buildRsvpButton(
                  tokens,
                  'yes',
                  'Пойду',
                  myStatus,
                  _gathering.goingCount,
                ),
              ),
              SizedBox(width: tokens.space8),
              Expanded(
                child: _buildRsvpButton(
                  tokens,
                  'maybe',
                  'Может',
                  myStatus,
                  _gathering.maybeCount,
                ),
              ),
              SizedBox(width: tokens.space8),
              Expanded(
                child: _buildRsvpButton(
                  tokens,
                  'no',
                  'Не пойду',
                  myStatus,
                  _gathering.notGoingCount,
                ),
              ),
            ],
          ),
        ),
        if (myStatus == 'yes') ...[
          SizedBox(height: tokens.space8),
          _buildHeadcountStepper(theme, tokens),
        ],
      ],
    );
  }

  /// Ряд аватаров-инициалов (28dp) для тех, кто ответил «Пойду», + «+N»
  /// на остальных (включая headcount — людей, которых ведут с собой).
  /// Модель не несёт имя/фото участника (только userId в rsvps) — берём
  /// первый символ userId как инициал, тот же приём, что и у
  /// _buildInitials для автора, просто применённый к чужим id.
  Widget? _buildParticipants(RodnyaDesignTokens tokens) {
    final going =
        _gathering.rsvps.where((r) => r['status']?.toString() == 'yes');
    if (going.isEmpty) return null;
    const maxAvatars = 4;
    final shown = going.take(maxAvatars).toList();
    final remaining = _gathering.goingCount - shown.length;
    return SizedBox(
      key: const Key('gathering-participants'),
      height: 28,
      child: Row(
        children: [
          for (final r in shown) ...[
            _ParticipantBubble(
              tokens: tokens,
              seed: r['userId']?.toString() ?? '',
            ),
            const SizedBox(width: 4),
          ],
          if (remaining > 0) _ParticipantBubble(tokens: tokens, label: '+$remaining'),
        ],
      ),
    );
  }

  Widget _buildRsvpButton(
    RodnyaDesignTokens tokens,
    String status,
    String label,
    String? myStatus,
    int count,
  ) {
    final selected = myStatus == status;
    final fg = selected ? tokens.accentInk : tokens.ink;
    return Material(
      color: selected ? tokens.accent : tokens.surface,
      borderRadius: BorderRadius.circular(tokens.radiusSm),
      child: InkWell(
        key: Key('gathering-rsvp-$status'),
        borderRadius: BorderRadius.circular(tokens.radiusSm),
        onTap: _submitting ? null : () => _respond(status),
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(tokens.radiusSm),
            border: Border.all(
              color: selected ? tokens.accent : tokens.surfaceLine,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.sans(
                    color: fg,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 4),
                Text(
                  '$count',
                  style: AppTheme.sans(
                    color: fg,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeadcountStepper(ThemeData theme, RodnyaDesignTokens tokens) {
    return Row(
      children: [
        Expanded(
          child: Text(
            _myHeadcount == 0
                ? 'Приду один'
                : '+$_myHeadcount ${_peopleWord(_myHeadcount)} со мной',
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.ink),
          ),
        ),
        // ≥44dp тач-цель без VisualDensity.compact (density-правило
        // чанка 24) — фиксированные constraints вместо density-сжатия.
        IconButton(
          key: const Key('gathering-headcount-dec'),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          onPressed: _submitting || _myHeadcount == 0
              ? null
              : () => _changeHeadcount(-1),
          icon: const Icon(Icons.remove_circle_outline, size: 20),
        ),
        Text('$_myHeadcount', style: theme.textTheme.titleSmall),
        IconButton(
          key: const Key('gathering-headcount-inc'),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          onPressed: _submitting ? null : () => _changeHeadcount(1),
          icon: const Icon(Icons.add_circle_outline, size: 20),
        ),
      ],
    );
  }

  String _peopleWord(int count) {
    final mod10 = count % 10;
    final mod100 = count % 100;
    if (mod10 == 1 && mod100 != 11) return 'человек';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return 'человека';
    }
    return 'человек';
  }

  String _formatWhen() {
    final pattern = _gathering.isAllDay ? 'd MMMM y' : 'd MMMM y, HH:mm';
    final start = DateFormat(pattern, 'ru').format(_gathering.startAt);
    final end = _gathering.endAt;
    if (end == null) return start;
    final sameDay = end.year == _gathering.startAt.year &&
        end.month == _gathering.startAt.month &&
        end.day == _gathering.startAt.day;
    final endLabel = _gathering.isAllDay
        ? DateFormat('d MMMM y', 'ru').format(end)
        : sameDay
            ? DateFormat('HH:mm', 'ru').format(end)
            : DateFormat('d MMMM y, HH:mm', 'ru').format(end);
    return '$start — $endLabel';
  }

  String _formatPosted(DateTime createdAt) {
    return DateFormat('d MMMM', 'ru').format(createdAt);
  }
}

/// One 28dp avatar bubble in the participants row — an initial letter
/// (from a userId seed, since rsvps carry no name/photo) or an explicit
/// overflow label («+N»).
class _ParticipantBubble extends StatelessWidget {
  const _ParticipantBubble({required this.tokens, this.seed, this.label});

  final RodnyaDesignTokens tokens;
  final String? seed;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final text = label ??
        (seed != null && seed!.isNotEmpty
            ? String.fromCharCode(seed!.runes.first).toUpperCase()
            : '?');
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tokens.accentSoft,
        shape: BoxShape.circle,
        border: Border.all(color: tokens.surfaceLine),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: AppTheme.sans(
          color: tokens.accent,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
