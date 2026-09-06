part of 'chat_screen.dart';

/// C2c: единый реестр «один inline-медиаплеер за раз» — голосовые бабблы
/// и видео-кружки. Старт любого паузит предыдущий активный (как в
/// Telegram: новое голосовое глушит играющий кружок и наоборот). Раньше
/// реестр был только у голосовых (_VoicePlayerWidgetState), а видео его
/// не переиспользовало — два кружка играли разом с зацикленным звуком.
class _InlineMediaPlayback {
  _InlineMediaPlayback._();

  // Ключуем по ВЛАДЕЛЬЦУ (State-инстансу), а НЕ по колбэку: tear-off
  // метода (`_pauseSelf`) при каждом обращении — новый объект, и
  // identical() над ними всегда false → реестр бы не очищался и копил
  // ссылку на уже-disposed-плеер. State-инстанс стабилен, identical
  // работает корректно.
  static Object? _activeOwner;
  static VoidCallback? _activePause;

  /// Сделать [owner] активным плеером, поставив предыдущего на паузу.
  static void activate(Object owner, VoidCallback pauseSelf) {
    final previousPause = _activePause;
    if (previousPause != null && !identical(_activeOwner, owner)) {
      previousPause();
    }
    _activeOwner = owner;
    _activePause = pauseSelf;
  }

  /// Снять регистрацию (complete / pause / dispose), если активны были мы
  /// — чтобы следующий старт не дёргал устаревший колбэк.
  static void resign(Object owner) {
    if (identical(_activeOwner, owner)) {
      _activeOwner = null;
      _activePause = null;
    }
  }
}

class _VoicePlayerWidget extends StatefulWidget {
  const _VoicePlayerWidget({
    this.url,
    this.path,
    required this.isMe,
    this.initialDuration,
    this.waveform = const <double>[],
    this.semanticLabel,
  });

  final String? url;
  final String? path;
  final bool isMe;
  final Duration? initialDuration;
  final List<double> waveform;
  final String? semanticLabel;

  @override
  State<_VoicePlayerWidget> createState() => _VoicePlayerWidgetState();
}

class _VoicePlayerWidgetState extends State<_VoicePlayerWidget> {
  // C1: плеер создаём ЛЕНИВО — только при первом воспроизведении.
  // Раньше initState спавнил AudioPlayer на КАЖДОЕ голосовое в чате
  // (десятки плагин-инстансов на один скролл) и трогал плагин при
  // простом рендере. Теперь рендер бабла бесплатен, плеер появляется
  // по тапу Play.
  AudioPlayer? _player;
  PlayerState _playerState = PlayerState.stopped;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  double _playbackRate = 1.0;

  StreamSubscription? _stateSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _posSub;
  StreamSubscription? _compSub;

  // C2c: one-at-a-time playback теперь в общем реестре
  // [_InlineMediaPlayback] (голос + видео-кружки), не в локальном
  // статике — старт голосового паузит играющий кружок и наоборот.

  @override
  void initState() {
    super.initState();
    _duration = widget.initialDuration ?? Duration.zero;
  }

  /// C1: создать плеер и подписки один раз — на первом Play.
  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) {
      return existing;
    }
    final player = AudioPlayer();
    _player = player;
    _stateSub = player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playerState = s);
    });
    _durationSub = player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _posSub = player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _compSub = player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playerState = PlayerState.stopped;
          _position = Duration.zero;
        });
      }
      // Clear the global pointer if we were the active one — keeps
      // a stale callback from being invoked by the next bubble.
      _InlineMediaPlayback.resign(this);
    });
    return player;
  }

  void _pauseSelf() {
    if (mounted && _playerState == PlayerState.playing) {
      unawaited(_player?.pause());
    }
  }

  @override
  void dispose() {
    _InlineMediaPlayback.resign(this);
    _stateSub?.cancel();
    _durationSub?.cancel();
    _posSub?.cancel();
    _compSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    try {
      // C2c: паузим любой другой играющий inline-медиаплеер (голос или
      // видео-кружок) перед стартом — иначе две дорожки звучат разом.
      _InlineMediaPlayback.activate(this, _pauseSelf);

      final player = _ensurePlayer();
      if (widget.url != null) {
        await player.play(UrlSource(widget.url!));
      } else if (widget.path != null) {
        await player.play(DeviceFileSource(widget.path!));
      }
      await player.setPlaybackRate(_playbackRate);
    } catch (e) {
      debugPrint('Error playing audio: $e');
    }
  }

  Future<void> _pause() async {
    await _player?.pause();
  }

  Future<void> _cyclePlaybackRate() async {
    const rates = <double>[1.0, 1.5, 2.0];
    final currentIndex = rates.indexOf(_playbackRate);
    final nextRate = rates[(currentIndex + 1) % rates.length];
    setState(() => _playbackRate = nextRate);
    try {
      // Если плеер ещё не создан — скорость применится при первом Play.
      await _player?.setPlaybackRate(nextRate);
    } catch (e) {
      debugPrint('Error changing audio speed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isPlaying = _playerState == PlayerState.playing;
    // Theme-aligned palette: outgoing bubble uses onPrimary against the
    // accent gradient; incoming uses primary (accent) on the surface
    // bubble. Replaces the previous hardcoded white / blue.shade700,
    // which clashed with the warm cream brand.
    final Color color = widget.isMe ? scheme.onPrimary : scheme.primary;
    final totalDuration = _duration > Duration.zero
        ? _duration
        : (widget.initialDuration ?? Duration.zero);
    final progressFraction = totalDuration.inMilliseconds > 0
        ? (_position.inMilliseconds / totalDuration.inMilliseconds)
            .clamp(0.0, 1.0)
            .toDouble()
        : 0.0;
    final progressLabel = totalDuration > Duration.zero
        ? '${_formatDuration(_position)} / ${_formatDuration(totalDuration)}'
        : _formatDuration(_position);

    final waveform =
        widget.waveform.isNotEmpty ? widget.waveform : _fallbackVoiceWaveform;

    return Semantics(
      label: widget.semanticLabel ?? 'Голосовое сообщение',
      button: true,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: widget.isMe
              ? scheme.onPrimary.withValues(alpha: 0.14)
              : scheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: isPlaying
                  ? 'Пауза голосового сообщения'
                  : 'Воспроизвести голосовое сообщение',
              onPressed: isPlaying ? _pause : _play,
              icon: Icon(isPlaying
                  ? Icons.pause_circle_filled
                  : Icons.play_circle_filled),
              color: color,
              iconSize: 32,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 168,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.semanticLabel ?? 'Голосовое сообщение',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: color,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _cyclePlaybackRate,
                        style: TextButton.styleFrom(
                          foregroundColor: color,
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          minimumSize: const Size(38, 24),
                          padding: EdgeInsets.zero,
                        ),
                        child: Text(
                          '${_playbackRate.toStringAsFixed(_playbackRate == 1.0 ? 0 : 1)}x',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  _VoiceWaveformScrubber(
                    waveform: waveform,
                    progress: progressFraction,
                    isPlaying: isPlaying,
                    activeColor: color,
                    inactiveColor: color.withValues(alpha: 0.28),
                    onSeekFraction: totalDuration.inMilliseconds <= 0
                        ? null
                        : (fraction) {
                            // Сик имеет смысл только когда плеер уже создан
                            // (после первого Play); иначе игнорируем.
                            _player?.seek(
                              Duration(
                                milliseconds:
                                    (totalDuration.inMilliseconds * fraction)
                                        .round(),
                              ),
                            );
                          },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      progressLabel,
                      style: TextStyle(color: color, fontSize: 10),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final min = d.inMinutes;
    final sec = d.inSeconds % 60;
    return '$min:${sec.toString().padLeft(2, '0')}';
  }
}

const List<double> _fallbackVoiceWaveform = <double>[
  0.18,
  0.42,
  0.28,
  0.66,
  0.38,
  0.74,
  0.46,
  0.31,
  0.58,
  0.82,
  0.35,
  0.52,
  0.24,
  0.68,
  0.44,
  0.29,
  0.61,
  0.76,
  0.33,
  0.49,
  0.22,
  0.57,
  0.39,
  0.71,
  0.27,
  0.46,
  0.63,
  0.36,
  0.54,
  0.25,
  0.69,
  0.41,
];

/// Tappable / draggable waveform with live progress.
///
/// Telegram-style behaviour:
/// * Tap anywhere on the strip → immediate seek to that point.
/// * Horizontal drag → visual scrub follows the finger in real time
///   but the audio seek only fires on drag end. Committing on every
///   `onHorizontalDragUpdate` (the previous behaviour) caused
///   audible glitching on each frame and made the wave fight the
///   live-position listener.
/// * While playing, the bars under the playback head get a subtle
///   sin-wave breathing pulse — same "alive" feel TG has.
class _VoiceWaveformScrubber extends StatefulWidget {
  const _VoiceWaveformScrubber({
    required this.waveform,
    required this.progress,
    required this.isPlaying,
    required this.activeColor,
    required this.inactiveColor,
    required this.onSeekFraction,
  });

  final List<double> waveform;
  final double progress;
  final bool isPlaying;
  final Color activeColor;
  final Color inactiveColor;
  final ValueChanged<double>? onSeekFraction;

  @override
  State<_VoiceWaveformScrubber> createState() => _VoiceWaveformScrubberState();
}

class _VoiceWaveformScrubberState extends State<_VoiceWaveformScrubber>
    with SingleTickerProviderStateMixin {
  double? _dragFraction;
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _VoiceWaveformScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      _syncPulse();
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  /// Pulse runs only while `isPlaying`. Skipping under flutter_test's
  /// binding so widget tests' pumpAndSettle doesn't hang on the
  /// repeating controller.
  void _syncPulse() {
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    final inTest = bindingName.contains('TestWidgetsFlutterBinding');
    if (widget.isPlaying && !inTest) {
      if (!_pulseCtrl.isAnimating) {
        _pulseCtrl.repeat();
      }
    } else {
      _pulseCtrl.stop();
      _pulseCtrl.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveWaveform =
        widget.waveform.isEmpty ? _fallbackVoiceWaveform : widget.waveform;
    return SizedBox(
      height: 34,
      child: LayoutBuilder(
        builder: (context, constraints) {
          double? localToFraction(Offset localPosition) {
            if (constraints.maxWidth <= 0) return null;
            return (localPosition.dx / constraints.maxWidth)
                .clamp(0.0, 1.0)
                .toDouble();
          }

          void commit(double fraction) {
            final cb = widget.onSeekFraction;
            if (cb != null) cb(fraction);
          }

          // Effective progress: while user is dragging, follow the
          // finger; otherwise mirror the player's position.
          final visualProgress =
              (_dragFraction ?? widget.progress).clamp(0.0, 1.0).toDouble();

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) {
              final f = localToFraction(details.localPosition);
              if (f != null) commit(f);
            },
            onHorizontalDragStart: (details) {
              setState(() {
                _dragFraction = localToFraction(details.localPosition);
              });
            },
            onHorizontalDragUpdate: (details) {
              setState(() {
                _dragFraction = localToFraction(details.localPosition);
              });
            },
            onHorizontalDragEnd: (_) {
              final f = _dragFraction;
              setState(() => _dragFraction = null);
              if (f != null) commit(f);
            },
            onHorizontalDragCancel: () {
              setState(() => _dragFraction = null);
            },
            child: AnimatedBuilder(
              animation: _pulseCtrl,
              builder: (context, _) {
                return CustomPaint(
                  painter: _VoiceWaveformPainter(
                    waveform: effectiveWaveform,
                    progress: visualProgress,
                    activeColor: widget.activeColor,
                    inactiveColor: widget.inactiveColor,
                    pulsePhase: widget.isPlaying ? _pulseCtrl.value : 0,
                    isPlaying: widget.isPlaying,
                  ),
                  child: const SizedBox.expand(),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _VoiceWaveformPainter extends CustomPainter {
  const _VoiceWaveformPainter({
    required this.waveform,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
    this.pulsePhase = 0,
    this.isPlaying = false,
  });

  final List<double> waveform;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  /// 0..1 — current phase of the breathing pulse animation. Only used
  /// when [isPlaying] is true to give bars near the playback head a
  /// subtle "alive" feel; off otherwise.
  final double pulsePhase;
  final bool isPlaying;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || waveform.isEmpty) {
      return;
    }

    final gap = waveform.length > 48 ? 1.5 : 2.0;
    final barWidth =
        ((size.width - gap * (waveform.length - 1)) / waveform.length)
            .clamp(2.0, 5.0)
            .toDouble();
    final totalWidth = waveform.length * barWidth + (waveform.length - 1) * gap;
    final startX = (size.width - totalWidth).clamp(0.0, size.width) / 2;
    final centerY = size.height / 2;
    final radius = Radius.circular(barWidth / 2);

    final activePaint = Paint()..color = activeColor;
    final inactivePaint = Paint()..color = inactiveColor;

    for (var index = 0; index < waveform.length; index++) {
      final value = waveform[index].clamp(0.0, 1.0).toDouble();
      final sampleProgress = (index + 0.5) / waveform.length;
      // Pulse: only bars within ±2 of the playback head get the
      // breathing scale; further bars stay flat. We compute distance
      // in *bar indices* and apply a falloff.
      double scale = 1.0;
      if (isPlaying && progress > 0) {
        final headIndex = progress * waveform.length;
        final distance = (index - headIndex).abs();
        if (distance < 3.0) {
          // Phased sin so each bar peaks slightly after its neighbour
          // → the pulse "rolls" along the head.
          final localPhase = (pulsePhase + index * 0.08) % 1.0;
          final wave = math.sin(localPhase * 2 * math.pi);
          // Closer = bigger amplitude. 1.0 amplitude at distance 0,
          // 0 at distance 3+.
          final intensity = (1.0 - distance / 3.0).clamp(0.0, 1.0);
          scale = 1.0 + 0.18 * intensity * wave;
        }
      }
      final barHeight = (size.height * (0.18 + value * 0.78) * scale)
          .clamp(4.0, size.height)
          .toDouble();
      final x = startX + index * (barWidth + gap);
      final rect = Rect.fromLTWH(
        x,
        centerY - barHeight / 2,
        barWidth,
        barHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, radius),
        sampleProgress <= progress ? activePaint : inactivePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VoiceWaveformPainter oldDelegate) {
    return oldDelegate.waveform != waveform ||
        oldDelegate.progress != progress ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor ||
        oldDelegate.pulsePhase != pulsePhase ||
        oldDelegate.isPlaying != isPlaying;
  }
}

class _RemoteMediaGrid extends StatelessWidget {
  const _RemoteMediaGrid({
    required this.attachments,
    this.onOpenAttachment,
  });

  final List<ChatAttachment> attachments;
  final void Function(
          List<ChatAttachment> attachments, ChatAttachment attachment)?
      onOpenAttachment;

  // Telegram-style smart photo grid:
  //   1 photo  → full 220x220 with adaptive aspect.
  //   2 photos → side-by-side 50/50, single tall row.
  //   3 photos → first big-left + two stacked right.
  //   4 photos → 2x2 grid.
  //   5+ photos → 2x2 grid with the last tile carrying a "+N" overlay so
  //               the user knows there's more behind the tap.
  // Total grid width is locked at 220 — same as the previous single-tile
  // variant — so bubble width stays predictable.
  static const double _gridWidth = 220;
  static const double _gap = 4;
  static const double _radius = 14;

  void _open(int index) {
    final callback = onOpenAttachment;
    if (callback == null || index < 0 || index >= attachments.length) return;
    callback(attachments, attachments[index]);
  }

  Widget _tile(int index, {Widget? overlay}) {
    Widget tile = _RemoteMediaTile(
      attachment: attachments[index],
      onTap: onOpenAttachment == null ? null : () => _open(index),
    );
    if (overlay != null) {
      tile = Stack(fit: StackFit.expand, children: [tile, overlay]);
    }
    return ClipRRect(borderRadius: BorderRadius.circular(_radius), child: tile);
  }

  Widget _moreOverlay(int extraCount) {
    return IgnorePointer(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.42),
        child: Center(
          child: Text(
            '+$extraCount',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = attachments.length;
    if (count == 1) {
      return SizedBox(width: _gridWidth, height: 220, child: _tile(0));
    }
    if (count == 2) {
      return SizedBox(
        width: _gridWidth,
        height: 130,
        child: Row(
          children: [
            Expanded(child: _tile(0)),
            const SizedBox(width: _gap),
            Expanded(child: _tile(1)),
          ],
        ),
      );
    }
    if (count == 3) {
      return SizedBox(
        width: _gridWidth,
        height: 158,
        child: Row(
          children: [
            Expanded(flex: 3, child: _tile(0)),
            const SizedBox(width: _gap),
            Expanded(
              flex: 2,
              child: Column(
                children: [
                  Expanded(child: _tile(1)),
                  const SizedBox(height: _gap),
                  Expanded(child: _tile(2)),
                ],
              ),
            ),
          ],
        ),
      );
    }
    // 4+ photos: 2x2 grid; last tile gets a +N overlay when count > 4.
    final extra = count - 4;
    return SizedBox(
      width: _gridWidth,
      height: 220,
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: _tile(0)),
                const SizedBox(width: _gap),
                Expanded(child: _tile(1)),
              ],
            ),
          ),
          const SizedBox(height: _gap),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _tile(2)),
                const SizedBox(width: _gap),
                Expanded(
                  child: _tile(
                    3,
                    overlay: extra > 0 ? _moreOverlay(extra) : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LocalMediaGrid extends StatelessWidget {
  const _LocalMediaGrid({
    required this.files,
    this.statuses,
    this.onOpenAttachment,
  });

  final List<XFile> files;

  /// Пофайловые статусы загрузки (UX-аудит P1): совпадают по индексам
  /// с [files]; null → без оверлеев (превью в композере и т.п.).
  final List<ChatAttachmentUploadStatus>? statuses;
  final void Function(List<XFile> files, XFile file)? onOpenAttachment;

  // Mirror of _RemoteMediaGrid for not-yet-uploaded local files. Same
  //1/2/3/4+ smart layouts so the optimistic preview matches the final
  // remote rendering.
  static const double _gridWidth = 220;
  static const double _gap = 4;
  static const double _radius = 14;

  void _open(int index) {
    final callback = onOpenAttachment;
    if (callback == null || index < 0 || index >= files.length) return;
    callback(files, files[index]);
  }

  Widget _tile(int index, {Widget? overlay}) {
    Widget tile = _LocalMediaTile(
      file: files[index],
      onTap: onOpenAttachment == null ? null : () => _open(index),
    );
    final uploadOverlay = _uploadOverlayFor(index);
    if (uploadOverlay != null) {
      tile = Stack(fit: StackFit.expand, children: [tile, uploadOverlay]);
    }
    if (overlay != null) {
      tile = Stack(fit: StackFit.expand, children: [tile, overlay]);
    }
    return ClipRRect(borderRadius: BorderRadius.circular(_radius), child: tile);
  }

  /// Оверлей состояния загрузки: queued — притемнение, uploading —
  /// притемнение + спиннер, done — чисто, failed — иконка ошибки.
  Widget? _uploadOverlayFor(int index) {
    final list = statuses;
    if (list == null || index >= list.length) {
      return null;
    }
    final status = list[index];
    Widget? content;
    switch (status) {
      case ChatAttachmentUploadStatus.done:
        return null;
      case ChatAttachmentUploadStatus.queued:
        content = null;
        break;
      case ChatAttachmentUploadStatus.uploading:
        content = const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            key: Key('attachment-uploading-spinner'),
            strokeWidth: 2.5,
            color: Colors.white,
          ),
        );
        break;
      case ChatAttachmentUploadStatus.failed:
        content = const Icon(
          Icons.error_outline_rounded,
          key: Key('attachment-failed-icon'),
          color: Colors.white,
          size: 28,
        );
        break;
    }
    return IgnorePointer(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: ColoredBox(
          key: ValueKey(status),
          color: Colors.black.withValues(
            alpha: status == ChatAttachmentUploadStatus.queued ? 0.25 : 0.35,
          ),
          child: content == null ? null : Center(child: content),
        ),
      ),
    );
  }

  Widget _moreOverlay(int extraCount) {
    return IgnorePointer(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.42),
        child: Center(
          child: Text(
            '+$extraCount',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = files.length;
    if (count == 1) {
      return SizedBox(width: _gridWidth, height: 220, child: _tile(0));
    }
    if (count == 2) {
      return SizedBox(
        width: _gridWidth,
        height: 130,
        child: Row(
          children: [
            Expanded(child: _tile(0)),
            const SizedBox(width: _gap),
            Expanded(child: _tile(1)),
          ],
        ),
      );
    }
    if (count == 3) {
      return SizedBox(
        width: _gridWidth,
        height: 158,
        child: Row(
          children: [
            Expanded(flex: 3, child: _tile(0)),
            const SizedBox(width: _gap),
            Expanded(
              flex: 2,
              child: Column(
                children: [
                  Expanded(child: _tile(1)),
                  const SizedBox(height: _gap),
                  Expanded(child: _tile(2)),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final extra = count - 4;
    return SizedBox(
      width: _gridWidth,
      height: 220,
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: _tile(0)),
                const SizedBox(width: _gap),
                Expanded(child: _tile(1)),
              ],
            ),
          ),
          const SizedBox(height: _gap),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _tile(2)),
                const SizedBox(width: _gap),
                Expanded(
                  child: _tile(
                    3,
                    overlay: extra > 0 ? _moreOverlay(extra) : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Truncation threshold for long chat messages. Above this character
/// count we collapse the body to the first ~600 chars and surface a
/// "Показать ещё" affordance — same trick TG and WhatsApp use to
/// keep the bubble compact, the scroll snappy, and the painted
/// TextSpan tree shallow even on a 5 000+ char dump (e.g. pasted
/// log file). On tap the bubble expands to the full text inline.
const int _kLongMessageCollapseAt = 600;

final RegExp _chatMessageUrlPattern = RegExp(
  r'((?:https?://|www\.)[^\s<>()]+|(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(?:/[^\s<>()]*)?)',
  caseSensitive: false,
);

class _ChatMessageUrlMatch {
  const _ChatMessageUrlMatch({
    required this.start,
    required this.end,
    required this.text,
  });

  final int start;
  final int end;
  final String text;
}

class _HighlightedMessageText extends StatefulWidget {
  const _HighlightedMessageText({
    required this.text,
    required this.query,
    required this.color,
  });

  final String text;
  final String query;
  final Color color;

  @override
  State<_HighlightedMessageText> createState() =>
      _HighlightedMessageTextState();
}

class _HighlightedMessageTextState extends State<_HighlightedMessageText> {
  final List<TapGestureRecognizer> _linkRecognizers = <TapGestureRecognizer>[];
  bool _expanded = false;

  bool get _isLong => widget.text.length > _kLongMessageCollapseAt;

  String get _renderedText {
    if (_expanded || !_isLong) return widget.text;
    // Trim to a safe character count, then back off to the nearest
    // whitespace so we don't slice through a word mid-letter.
    final hardCap = widget.text.substring(0, _kLongMessageCollapseAt);
    final lastWhitespace = hardCap.lastIndexOf(RegExp(r'\s'));
    final softCap = lastWhitespace > _kLongMessageCollapseAt - 80
        ? hardCap.substring(0, lastWhitespace)
        : hardCap;
    return '$softCap…';
  }

  @override
  void dispose() {
    _disposeLinkRecognizers();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _HighlightedMessageText oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When the user types into the search bar we want any long
    // message that contains a hit to expand automatically — otherwise
    // a match buried past the truncation point is invisible.
    final query = widget.query.trim();
    if (!_expanded && query.isNotEmpty && _isLong) {
      final hit = widget.text.toLowerCase().indexOf(query.toLowerCase());
      if (hit >= _kLongMessageCollapseAt) {
        _expanded = true;
      }
    }
  }

  void _disposeLinkRecognizers() {
    for (final recognizer in _linkRecognizers) {
      recognizer.dispose();
    }
    _linkRecognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeLinkRecognizers();
    final normalizedQuery = widget.query.trim();
    final body = _renderedText;
    final color = widget.color;

    final textWidget = _buildTextWidget(
      context: context,
      body: body,
      normalizedQuery: normalizedQuery,
      color: color,
    );

    if (!_isLong) return textWidget;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        textWidget,
        const SizedBox(height: 4),
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              _expanded ? 'Свернуть' : 'Показать ещё',
              style: TextStyle(
                color: color.withValues(alpha: 0.85),
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.underline,
                decorationColor: color.withValues(alpha: 0.45),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTextWidget({
    required BuildContext context,
    required String body,
    required String normalizedQuery,
    required Color color,
  }) {
    final urlMatches = _findUrlMatches(body);
    if (normalizedQuery.isEmpty && urlMatches.isEmpty) {
      return Text(
        body,
        // M3 (50+): 16/1.3 — раньше 14.5 по веб-референсу, но на
        // 720×1560 старшим читать тяжело; 16 — минимум для сообщений.
        // Плотность (чанк 22): 1.35 → 1.3 (спека), 16sp не трогаем.
        style: TextStyle(
          color: color,
          fontSize: 16,
          height: 1.3,
        ),
      );
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textBrightness = ThemeData.estimateBrightnessForColor(color);
    final linkColor = textBrightness == Brightness.dark
        ? scheme.primary
        : scheme.primaryContainer;
    final baseStyle = TextStyle(
      color: color,
      fontSize: 16,
      height: 1.3,
    );
    final linkStyle = baseStyle.copyWith(
      color: linkColor,
      fontWeight: FontWeight.w800,
      decoration: TextDecoration.underline,
      decorationColor: linkColor.withValues(alpha: 0.7),
    );
    final spans = <TextSpan>[];
    var currentIndex = 0;

    for (final match in urlMatches) {
      if (match.start < currentIndex) {
        continue;
      }
      if (match.start > currentIndex) {
        _appendHighlightedSpans(
          spans: spans,
          text: body.substring(currentIndex, match.start),
          query: normalizedQuery,
          style: baseStyle,
        );
      }

      final recognizer = TapGestureRecognizer()
        ..onTap = () => unawaited(_openMessageUrl(match.text));
      _linkRecognizers.add(recognizer);
      _appendHighlightedSpans(
        spans: spans,
        text: match.text,
        query: normalizedQuery,
        style: linkStyle,
        recognizer: recognizer,
      );
      currentIndex = match.end;
    }

    if (currentIndex < body.length) {
      _appendHighlightedSpans(
        spans: spans,
        text: body.substring(currentIndex),
        query: normalizedQuery,
        style: baseStyle,
      );
    }

    return RichText(
      text: TextSpan(children: spans),
    );
  }

  List<_ChatMessageUrlMatch> _findUrlMatches(String text) {
    final matches = <_ChatMessageUrlMatch>[];
    for (final match in _chatMessageUrlPattern.allMatches(text)) {
      final raw = match.group(0);
      if (raw == null || raw.trim().isEmpty) {
        continue;
      }
      final trimmed = _trimTrailingUrlPunctuation(raw);
      if (trimmed.isEmpty) {
        continue;
      }
      matches.add(
        _ChatMessageUrlMatch(
          start: match.start,
          end: match.start + trimmed.length,
          text: trimmed,
        ),
      );
    }
    return matches;
  }

  String _trimTrailingUrlPunctuation(String value) {
    var end = value.length;
    while (end > 0) {
      final char = value[end - 1];
      if (char == '.' ||
          char == ',' ||
          char == '!' ||
          char == '?' ||
          char == ';' ||
          char == ':' ||
          char == ')' ||
          char == ']' ||
          char == '}' ||
          char == '"' ||
          char == '\'' ||
          char == '»') {
        end -= 1;
        continue;
      }
      break;
    }
    return value.substring(0, end);
  }

  void _appendHighlightedSpans({
    required List<TextSpan> spans,
    required String text,
    required String query,
    required TextStyle style,
    GestureRecognizer? recognizer,
  }) {
    if (text.isEmpty) {
      return;
    }
    if (query.isEmpty) {
      spans.add(
        TextSpan(
          text: text,
          style: style,
          recognizer: recognizer,
        ),
      );
      return;
    }

    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    var currentIndex = 0;
    while (currentIndex < text.length) {
      final nextMatch = lowerText.indexOf(lowerQuery, currentIndex);
      if (nextMatch == -1) {
        spans.add(
          TextSpan(
            text: text.substring(currentIndex),
            style: style,
            recognizer: recognizer,
          ),
        );
        break;
      }
      if (nextMatch > currentIndex) {
        spans.add(
          TextSpan(
            text: text.substring(currentIndex, nextMatch),
            style: style,
            recognizer: recognizer,
          ),
        );
      }
      final matchEnd = nextMatch + query.length;
      spans.add(
        TextSpan(
          text: text.substring(nextMatch, matchEnd),
          style: style.copyWith(
            backgroundColor: Colors.amber.withValues(alpha: 0.55),
            fontWeight: FontWeight.w800,
          ),
          recognizer: recognizer,
        ),
      );
      currentIndex = matchEnd;
    }
  }

  Future<void> _openMessageUrl(String rawUrl) async {
    final uri = _normalizeMessageUrl(rawUrl);
    if (uri == null) {
      return;
    }

    final internalRoute = _internalRouteFor(uri);
    if (internalRoute != null) {
      if (!mounted) {
        return;
      }
      GoRouter.of(context).go(internalRoute);
      return;
    }

    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        await launchUrl(uri);
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть ссылку.')),
      );
    }
  }

  Uri? _normalizeMessageUrl(String rawUrl) {
    var value = rawUrl.trim();
    if (value.isEmpty) {
      return null;
    }
    if (value.startsWith('www.')) {
      value = 'https://$value';
    } else if (!value.contains('://')) {
      value = 'https://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.trim().isEmpty) {
      return null;
    }
    return uri;
  }

  String? _internalRouteFor(Uri uri) {
    final host = uri.host.toLowerCase();
    final isRodnyaHost =
        host == 'rodnya-tree.ru' || host == 'www.rodnya-tree.ru';
    if (!isRodnyaHost) {
      return null;
    }

    final fragment = uri.fragment.trim();
    if (fragment.startsWith('/')) {
      return fragment;
    }

    final path = uri.path.trim().isEmpty ? '/' : uri.path.trim();
    final route = uri.hasQuery ? '$path?${uri.query}' : path;
    return route == '/' ? null : route;
  }
}

class _LocalImagePreview extends StatelessWidget {
  const _LocalImagePreview({required this.file});

  final XFile file;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: file.readAsBytes(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const ColoredBox(
            color: Color(0x11000000),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }

        return Image.memory(
          snapshot.data!,
          fit: BoxFit.cover,
          // Composer-side preview of an image the USER just picked from
          // their gallery. They know what it is, but a screen reader
          // user benefits from confirmation that the attach succeeded.
          semanticLabel: 'Прикреплённое изображение',
          errorBuilder: (_, __, ___) => const ColoredBox(
            color: Color(0x11000000),
            child: Center(child: Icon(Icons.broken_image_outlined)),
          ),
        );
      },
    );
  }
}

class _AttachmentImage extends StatelessWidget {
  const _AttachmentImage({
    required this.url,
    required this.fit,
    this.placeholder,
    this.errorWidget,
  });

  final String? url;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;

  @override
  Widget build(BuildContext context) {
    final normalizedUrl = UrlUtils.normalizeImageUrl(url);
    final fallback = errorWidget ?? const SizedBox.shrink();
    if (!UrlUtils.isRenderableNetworkImageUrl(normalizedUrl)) {
      return fallback;
    }

    return Semantics(
      // a11y: TalkBack/VoiceOver previously announced just "Image"
      // which is useless. "Изображение в сообщении" tells the user
      // what kind of media they're focused on. Future improvement:
      // surface alt-text from the attachment metadata when the
      // backend supports it.
      label: 'Изображение в сообщении',
      image: true,
      excludeSemantics: true,
      child: CachedNetworkImage(
        imageUrl: normalizedUrl!,
        fit: fit,
        placeholder: placeholder == null ? null : (_, __) => placeholder!,
        errorWidget: (_, __, ___) => fallback,
      ),
    );
  }
}

class _LocalMediaTile extends StatelessWidget {
  const _LocalMediaTile({
    required this.file,
    this.onTap,
  });

  final XFile file;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final kind = _attachmentKindFromXFile(file);
    if (_isVideoNoteFileName(file.name)) {
      return _VideoNoteTile(
        durationLabel: _durationFromAttachmentName(file.name) == null
            ? null
            : _formatAttachmentDuration(
                _durationFromAttachmentName(file.name)!),
        label: 'Кружок',
        onTap: onTap,
        videoSource: file.path,
        isRemoteSource: false,
      );
    }
    if (kind == _ChatAttachmentKind.image) {
      return InkWell(
        onTap: onTap,
        child: _LocalImagePreview(file: file),
      );
    }
    if (kind == _ChatAttachmentKind.audio) {
      return const _AttachmentPlaceholder(
        icon: Icons.mic_none_outlined,
        label: 'Голосовое сообщение',
      );
    }

    return InkWell(
      onTap: onTap,
      child: _AttachmentPlaceholder(
        icon: kind == _ChatAttachmentKind.video
            ? Icons.videocam_outlined
            : Icons.insert_drive_file_outlined,
        label: kind == _ChatAttachmentKind.video
            ? 'Видео'
            : _displayName(file.name),
      ),
    );
  }
}

class _RemoteMediaTile extends StatelessWidget {
  const _RemoteMediaTile({
    required this.attachment,
    this.onTap,
  });

  final ChatAttachment attachment;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final kind = attachment.type == ChatAttachmentType.file
        ? _attachmentKindFromName(attachment.fileName, attachment.url)
        : _chatAttachmentKindFromType(attachment.type);
    if (attachment.isVideoNote) {
      return _VideoNoteTile(
        previewUrl: attachment.thumbnailUrl,
        durationLabel: attachment.durationMs == null
            ? null
            : _formatAttachmentDuration(
                Duration(milliseconds: attachment.durationMs!),
              ),
        label: 'Кружок',
        onTap: onTap,
        videoSource: attachment.url,
        isRemoteSource: true,
      );
    }
    if (kind == _ChatAttachmentKind.image) {
      return InkWell(
        onTap: onTap,
        child: _AttachmentImage(
          url: attachment.thumbnailUrl ?? attachment.url,
          fit: BoxFit.cover,
          placeholder: const _AttachmentPlaceholder(
            icon: Icons.image_outlined,
            label: 'Фото',
          ),
          errorWidget: const _AttachmentPlaceholder(
            icon: Icons.broken_image_outlined,
            label: 'Файл',
          ),
        ),
      );
    }
    if (kind == _ChatAttachmentKind.audio) {
      return const _AttachmentPlaceholder(
        icon: Icons.mic_none_outlined,
        label: 'Голосовое сообщение',
      );
    }

    return InkWell(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (kind == _ChatAttachmentKind.video &&
              attachment.thumbnailUrl != null &&
              attachment.thumbnailUrl!.isNotEmpty)
            _AttachmentImage(
              url: attachment.thumbnailUrl,
              fit: BoxFit.cover,
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(
                alpha: kind == _ChatAttachmentKind.video ? 0.28 : 0.08,
              ),
            ),
            child: _AttachmentPlaceholder(
              icon: kind == _ChatAttachmentKind.video
                  ? Icons.play_circle_outline_rounded
                  : Icons.insert_drive_file_outlined,
              label: kind == _ChatAttachmentKind.video
                  ? 'Видео'
                  : _displayName(attachment.fileName ?? attachment.url),
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoNoteTile extends StatefulWidget {
  const _VideoNoteTile({
    required this.label,
    this.previewUrl,
    this.durationLabel,
    this.onTap,
    this.videoSource,
    this.isRemoteSource = false,
  });

  // Telegram chat круглые видео сидят на ~200px iOS / 180dp Android.
  // 168 — комфортная середина для плотности нашего бабла.
  static const double _diameter = 168;

  final String label;
  final String? previewUrl;
  final String? durationLabel;
  final VoidCallback? onTap;

  /// C2: источник видео (remote URL либо локальный путь) для inline-
  /// проигрывания кружка прямо в бабле. Когда задан — тап играет на месте
  /// (как Telegram), без перехода в просмотрщик. Когда null — поведение
  /// прежнее: тап зовёт [onTap].
  final String? videoSource;
  final bool isRemoteSource;

  @override
  State<_VideoNoteTile> createState() => _VideoNoteTileState();
}

class _VideoNoteTileState extends State<_VideoNoteTile> {
  bool _playing = false;

  bool get _canPlayInline =>
      widget.videoSource != null && widget.videoSource!.trim().isNotEmpty;

  void _handleTap() {
    if (_canPlayInline) {
      setState(() => _playing = true);
    } else {
      widget.onTap?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    // C2: после тапа кружок играет на месте — переиспользуем
    // _VideoNotePlayer (V3: авто-плей, tap = play/pause, кольцо прогресса +
    // перемотка, мьют вторичной кнопкой), сжатый до размера бабла.
    // Просмотрщик не открываем.
    if (_playing && _canPlayInline) {
      return Semantics(
        label: widget.label,
        child: SizedBox(
          width: _VideoNoteTile._diameter,
          height: _VideoNoteTile._diameter,
          child: _VideoNotePlayer(
            key: const Key('video-note-inline-player'),
            source: widget.videoSource!,
            isRemoteSource: widget.isRemoteSource,
            posterUrl: widget.previewUrl,
            diameter: _VideoNoteTile._diameter,
          ),
        ),
      );
    }
    return Semantics(
      label: widget.label,
      button: true,
      // SizedBox обязателен: Stack(fit: StackFit.expand) внутри Wrap
      // получает unbounded constraints и валит layout с null-check'ом.
      // Раньше это рушило весь чат в момент когда в сообщении появлялся
      // кружок. Размер впихнут в сам тайл, чтобы новые callers не
      // забыли обернуть.
      child: SizedBox(
        width: _VideoNoteTile._diameter,
        height: _VideoNoteTile._diameter,
        child: ClipOval(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _handleTap,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (widget.previewUrl != null &&
                      widget.previewUrl!.trim().isNotEmpty)
                    _AttachmentImage(
                      url: widget.previewUrl,
                      fit: BoxFit.cover,
                    ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.black.withValues(alpha: 0.18),
                          Colors.black.withValues(alpha: 0.42),
                        ],
                      ),
                    ),
                  ),
                  Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.42),
                        shape: BoxShape.circle,
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                  if (widget.durationLabel != null &&
                      widget.durationLabel!.isNotEmpty)
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.58),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: Text(
                            widget.durationLabel!,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AttachmentPlaceholder extends StatelessWidget {
  const _AttachmentPlaceholder({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0x11000000),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReactionGroup {
  const _ReactionGroup({
    required this.emoji,
    required this.count,
    required this.isMine,
  });

  final String emoji;
  final int count;
  final bool isMine;
}

class _ReactionPill extends StatelessWidget {
  const _ReactionPill({
    required this.reaction,
    required this.isMe,
    this.onTap,
  });

  final _ReactionGroup reaction;
  final bool isMe;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textColor =
        isMe ? scheme.onPrimary.withValues(alpha: 0.95) : scheme.onSurface;
    final selectedColor = isMe
        ? Colors.white.withValues(alpha: 0.22)
        : scheme.primary.withValues(alpha: 0.18);
    final defaultColor = isMe
        ? Colors.white.withValues(alpha: 0.12)
        : scheme.surface.withValues(alpha: 0.78);
    final borderColor = reaction.isMine
        ? (isMe
            ? Colors.white.withValues(alpha: 0.5)
            : scheme.primary.withValues(alpha: 0.32))
        : (isMe
            ? Colors.white.withValues(alpha: 0.18)
            : scheme.outlineVariant.withValues(alpha: 0.6));

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: reaction.isMine ? selectedColor : defaultColor,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: borderColor, width: 0.7),
        ),
        child: Text(
          '${reaction.emoji} ${reaction.count}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: textColor,
            fontWeight: reaction.isMine ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

enum _MessageAction {
  react,
  reply,
  forward,
  select,
  pin,
  edit,
  copy,
  openDirect,
  report,
  block,
  retry,
  delete
}

class _ContextMenuActionItem<T> {
  const _ContextMenuActionItem({
    required this.label,
    required this.icon,
    required this.value,
    this.isDestructive = false,
  });

  final String label;
  final IconData icon;
  final T value;
  final bool isDestructive;
}

class _MessageSheetSelection {
  const _MessageSheetSelection({
    required this.action,
    this.emoji,
  });

  final _MessageAction action;
  final String? emoji;
}

class _SafetyReasonChoice {
  const _SafetyReasonChoice({
    required this.reason,
    required this.label,
  });

  final String reason;
  final String label;
}

class _SafetyActionDraft {
  const _SafetyActionDraft({
    required this.reason,
    required this.details,
  });

  final String reason;
  final String details;
}

class _ForwardBatchDraft {
  const _ForwardBatchDraft({
    required this.items,
  });

  final List<_ForwardDraft> items;
}

class _SelectedMessageEntry {
  _SelectedMessageEntry.remote({
    required ChatMessage message,
    required this.displayName,
  })  : remoteMessageId = message.id,
        outgoingLocalId = null,
        senderId = message.senderId,
        text = message.text,
        timestamp = message.timestamp,
        attachments = message.attachments;

  _SelectedMessageEntry.outgoing({
    required _OutgoingMessage message,
    required this.displayName,
    required List<ChatAttachment> normalizedAttachments,
  })  : remoteMessageId = null,
        outgoingLocalId = message.localId,
        senderId = message.senderId,
        text = message.text,
        timestamp = message.timestamp,
        attachments = normalizedAttachments;

  final String? remoteMessageId;
  final String? outgoingLocalId;
  final String senderId;
  final String displayName;
  final String text;
  final DateTime timestamp;
  final List<ChatAttachment> attachments;

  bool canDelete(String currentUserId) {
    if (remoteMessageId != null) {
      return senderId == currentUserId;
    }
    return true;
  }
}

class _AttachmentPreviewItem {
  const _AttachmentPreviewItem.remote({
    required this.id,
    required this.kind,
    required this.source,
    required this.displayName,
    this.thumbnailUrl,
    this.senderLabel,
    this.timestamp,
    this.caption,
    this.isVideoNote = false,
  })  : file = null,
        isRemote = true;

  const _AttachmentPreviewItem.local({
    required this.id,
    required this.kind,
    required this.file,
    required this.displayName,
    this.senderLabel,
    this.timestamp,
    this.caption,
    this.isVideoNote = false,
  })  : source = null,
        thumbnailUrl = null,
        isRemote = false;

  final String id;
  final _ChatAttachmentKind kind;
  final String? source;
  final String? thumbnailUrl;
  final XFile? file;
  final String displayName;
  final bool isRemote;
  final String? senderLabel;
  final DateTime? timestamp;
  final String? caption;

  /// True when this video item should render as a Telegram-style
  /// circular video note (auto-play, loop, tap-mute, no controls)
  /// instead of a regular video file player.
  final bool isVideoNote;

  bool get isVisual =>
      kind == _ChatAttachmentKind.image || kind == _ChatAttachmentKind.video;

  String? get trimmedCaption {
    final value = caption?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }
}

class _DesktopMessageContextMenu<T> extends StatelessWidget {
  const _DesktopMessageContextMenu({
    required this.actions,
    required this.onActionSelected,
    this.reactions = const <String>[],
    this.onReactionSelected,
  });

  final List<_ContextMenuActionItem<T>> actions;
  final List<String> reactions;
  final ValueChanged<T> onActionSelected;
  final ValueChanged<String>? onReactionSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final backgroundColor = isDark ? const Color(0xFF1F1F22) : Colors.white;
    final reactionBarColor =
        isDark ? const Color(0xFF2A2A2F) : const Color(0xFFF4F5F8);
    final shadowColor = Colors.black.withValues(alpha: isDark ? 0.34 : 0.16);

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reactions.isNotEmpty && onReactionSelected != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: reactionBarColor,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: shadowColor,
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: reactions
                      .map(
                        (emoji) => InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () => onReactionSelected?.call(emoji),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            child: Text(
                              emoji,
                              style: const TextStyle(fontSize: 26, height: 1),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            if (reactions.isNotEmpty && onReactionSelected != null)
              const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: shadowColor,
                    blurRadius: 30,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var index = 0; index < actions.length; index++) ...[
                      _DesktopMessageContextMenuTile<T>(
                        item: actions[index],
                        onTap: () => onActionSelected(actions[index].value),
                      ),
                      if (index != actions.length - 1)
                        Divider(
                          height: 1,
                          indent: 54,
                          endIndent: 16,
                          color: theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.32),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopMessageContextMenuTile<T> extends StatelessWidget {
  const _DesktopMessageContextMenuTile({
    required this.item,
    required this.onTap,
  });

  final _ContextMenuActionItem<T> item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foregroundColor = item.isDestructive
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              child: Icon(
                item.icon,
                size: 21,
                color: foregroundColor,
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                item.label,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: foregroundColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentViewerDialog extends StatefulWidget {
  const _AttachmentViewerDialog({
    required this.items,
    required this.initialIndex,
    required this.onOpenExternally,
    required this.onDownload,
  });

  final List<_AttachmentPreviewItem> items;
  final int initialIndex;
  final Future<void> Function(_AttachmentPreviewItem item) onOpenExternally;
  final Future<void> Function(_AttachmentPreviewItem item) onDownload;

  @override
  State<_AttachmentViewerDialog> createState() =>
      _AttachmentViewerDialogState();
}

class _AttachmentViewerDialogState extends State<_AttachmentViewerDialog> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.items.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _goToPage(int index) async {
    if (index < 0 || index >= widget.items.length || index == _currentIndex) {
      return;
    }
    await _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _goToPrevious() {
    unawaited(_goToPage(_currentIndex - 1));
  }

  void _goToNext() {
    unawaited(_goToPage(_currentIndex + 1));
  }

  @override
  Widget build(BuildContext context) {
    final currentItem = widget.items[_currentIndex];
    final metadataLabel = <String>[
      if (currentItem.senderLabel != null &&
          currentItem.senderLabel!.isNotEmpty)
        currentItem.senderLabel!,
      if (currentItem.timestamp != null)
        DateFormat('dd.MM.yyyy H:mm', 'ru')
            .format(toLocalForDisplay(currentItem.timestamp!)),
    ].join(' • ');

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): _goToPrevious,
        const SingleActivator(LogicalKeyboardKey.arrowRight): _goToNext,
      },
      child: Dialog.fullscreen(
        backgroundColor: Colors.black.withValues(alpha: 0.92),
        child: Focus(
          autofocus: true,
          child: SafeArea(
            child: Stack(
              children: [
                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            tooltip: 'Закрыть',
                            icon: const Icon(Icons.close, color: Colors.white),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  currentItem.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (metadataLabel.isNotEmpty)
                                  Text(
                                    metadataLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.72),
                                      fontSize: 12,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Text(
                            '${_currentIndex + 1} / ${widget.items.length}',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.82),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: currentItem.isRemote
                                ? 'Открыть оригинал'
                                : 'Открыть файл',
                            onPressed: () =>
                                widget.onOpenExternally(currentItem),
                            icon: const Icon(
                              Icons.open_in_new,
                              color: Colors.white,
                            ),
                          ),
                          IconButton(
                            tooltip: supportsChatAttachmentDownload
                                ? 'Скачать'
                                : 'Открыть',
                            onPressed: () => widget.onDownload(currentItem),
                            icon: Icon(
                              supportsChatAttachmentDownload
                                  ? Icons.download_rounded
                                  : Icons.file_download_outlined,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: PageView.builder(
                        controller: _pageController,
                        itemCount: widget.items.length,
                        onPageChanged: (index) {
                          setState(() {
                            _currentIndex = index;
                          });
                        },
                        itemBuilder: (context, index) {
                          return _AttachmentViewerPage(
                              item: widget.items[index]);
                        },
                      ),
                    ),
                    if (currentItem.trimmedCaption != null ||
                        metadataLabel.isNotEmpty)
                      _AttachmentViewerDetails(
                        item: currentItem,
                        metadataLabel: metadataLabel,
                      ),
                    if (widget.items.length > 1)
                      _AttachmentViewerThumbnailStrip(
                        items: widget.items,
                        currentIndex: _currentIndex,
                        onSelect: _goToPage,
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Text(
                        'Esc закрыть • ← → листать',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.48),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                if (widget.items.length > 1 && _currentIndex > 0)
                  Positioned(
                    left: 20,
                    top: 0,
                    bottom: 92,
                    child: Center(
                      child: IconButton.filledTonal(
                        tooltip: 'Предыдущее вложение',
                        onPressed: _goToPrevious,
                        icon: const Icon(Icons.chevron_left_rounded),
                      ),
                    ),
                  ),
                if (widget.items.length > 1 &&
                    _currentIndex < widget.items.length - 1)
                  Positioned(
                    right: 20,
                    top: 0,
                    bottom: 92,
                    child: Center(
                      child: IconButton.filledTonal(
                        tooltip: 'Следующее вложение',
                        onPressed: _goToNext,
                        icon: const Icon(Icons.chevron_right_rounded),
                      ),
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

class _AttachmentViewerPage extends StatelessWidget {
  const _AttachmentViewerPage({required this.item});

  final _AttachmentPreviewItem item;

  @override
  Widget build(BuildContext context) {
    Widget content;
    switch (item.kind) {
      case _ChatAttachmentKind.image:
        // Wrapped in _SwipeDownDismissibleImage so vertical drag from
        // an un-zoomed image follows the finger + dismisses the
        // viewer past a threshold (TG / iOS Photos pattern). When the
        // image is zoomed > 1.0 the InteractiveViewer wins all pan
        // gestures so users can still look around inside zoom.
        content = _SwipeDownDismissibleImage(
          builder: (context, transformController) => item.isRemote
              ? InteractiveViewer(
                  transformationController: transformController,
                  minScale: 0.8,
                  maxScale: 4,
                  child: _AttachmentImage(
                    url: item.source,
                    fit: BoxFit.contain,
                    placeholder: const Center(
                      child: CircularProgressIndicator(),
                    ),
                    errorWidget: _AttachmentViewerPlaceholder(item: item),
                  ),
                )
              : FutureBuilder<Uint8List>(
                  future: item.file!.readAsBytes(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return InteractiveViewer(
                      transformationController: transformController,
                      minScale: 0.8,
                      maxScale: 4,
                      child: Image.memory(
                        snapshot.data!,
                        fit: BoxFit.contain,
                        semanticLabel: 'Изображение в просмотрщике',
                      ),
                    );
                  },
                ),
        );
        break;
      case _ChatAttachmentKind.video:
        final source = item.isRemote ? item.source! : item.file?.path;
        if (source == null || source.trim().isEmpty) {
          content = _AttachmentViewerPlaceholder(item: item);
        } else if (item.isVideoNote) {
          // Кружочки рисуем как у TG: круглый плеер, авто-плей, tap =
          // play/pause, кольцо прогресса по окружности + перемотка по нему,
          // мьют вторичной кнопкой (V3).
          content = _VideoNotePlayer(
            source: source,
            isRemoteSource: item.isRemote,
            posterUrl: item.thumbnailUrl,
          );
        } else {
          content = _AttachmentVideoPlayer(
            source: source,
            isRemoteSource: item.isRemote,
            posterUrl: item.thumbnailUrl,
          );
        }
        break;
      case _ChatAttachmentKind.audio:
      case _ChatAttachmentKind.other:
        content = _AttachmentViewerPlaceholder(item: item);
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      child: Center(child: content),
    );
  }
}

class _AttachmentViewerDetails extends StatelessWidget {
  const _AttachmentViewerDetails({
    required this.item,
    required this.metadataLabel,
  });

  final _AttachmentPreviewItem item;
  final String metadataLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (metadataLabel.isNotEmpty)
                Text(
                  metadataLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (metadataLabel.isNotEmpty && item.trimmedCaption != null)
                const SizedBox(height: 6),
              if (item.trimmedCaption != null)
                Text(
                  item.trimmedCaption!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    height: 1.35,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttachmentViewerThumbnailStrip extends StatelessWidget {
  const _AttachmentViewerThumbnailStrip({
    required this.items,
    required this.currentIndex,
    required this.onSelect,
  });

  final List<_AttachmentPreviewItem> items;
  final int currentIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 78,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        scrollDirection: Axis.horizontal,
        itemBuilder: (context, index) => _AttachmentViewerThumbnail(
          item: items[index],
          isSelected: index == currentIndex,
          onTap: () => onSelect(index),
        ),
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemCount: items.length,
      ),
    );
  }
}

class _AttachmentViewerThumbnail extends StatelessWidget {
  const _AttachmentViewerThumbnail({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  final _AttachmentPreviewItem item;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final borderColor =
        isSelected ? Colors.white : Colors.white.withValues(alpha: 0.18);

    return Semantics(
      button: true,
      label: 'Перейти к вложению',
      selected: isSelected,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 64,
          height: 64,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor, width: isSelected ? 2 : 1),
            color: Colors.white.withValues(alpha: 0.08),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _AttachmentViewerThumbnailPreview(item: item),
              if (item.kind == _ChatAttachmentKind.video)
                Align(
                  alignment: Alignment.center,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.48),
                      shape: BoxShape.circle,
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
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

class _AttachmentViewerThumbnailPreview extends StatelessWidget {
  const _AttachmentViewerThumbnailPreview({required this.item});

  final _AttachmentPreviewItem item;

  @override
  Widget build(BuildContext context) {
    if (item.kind == _ChatAttachmentKind.image && item.isRemote) {
      return _AttachmentImage(
        url: item.thumbnailUrl ?? item.source,
        fit: BoxFit.cover,
        placeholder: const Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        errorWidget: _AttachmentViewerThumbnailFallback(
          item: item,
        ),
      );
    }

    if (item.kind == _ChatAttachmentKind.image && item.file != null) {
      return FutureBuilder<Uint8List>(
        future: item.file!.readAsBytes(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          return Image.memory(
            snapshot.data!,
            fit: BoxFit.cover,
            semanticLabel: 'Прикреплённое изображение',
          );
        },
      );
    }

    if (item.kind == _ChatAttachmentKind.video &&
        item.thumbnailUrl != null &&
        item.thumbnailUrl!.isNotEmpty) {
      return _AttachmentImage(
        url: item.thumbnailUrl,
        fit: BoxFit.cover,
        placeholder: const Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        errorWidget: _AttachmentViewerThumbnailFallback(
          item: item,
        ),
      );
    }

    return _AttachmentViewerThumbnailFallback(item: item);
  }
}

class _AttachmentViewerThumbnailFallback extends StatelessWidget {
  const _AttachmentViewerThumbnailFallback({required this.item});

  final _AttachmentPreviewItem item;

  @override
  Widget build(BuildContext context) {
    late final IconData icon;
    switch (item.kind) {
      case _ChatAttachmentKind.image:
        icon = Icons.image_outlined;
        break;
      case _ChatAttachmentKind.video:
        icon = Icons.videocam_outlined;
        break;
      case _ChatAttachmentKind.audio:
        icon = Icons.mic_none_outlined;
        break;
      case _ChatAttachmentKind.other:
        icon = Icons.insert_drive_file_outlined;
        break;
    }
    return ColoredBox(
      color: Colors.white.withValues(alpha: 0.06),
      child: Center(
        child: Icon(
          icon,
          color: Colors.white.withValues(alpha: 0.82),
        ),
      ),
    );
  }
}

class _AttachmentViewerPlaceholder extends StatelessWidget {
  const _AttachmentViewerPlaceholder({required this.item});

  final _AttachmentPreviewItem item;

  @override
  Widget build(BuildContext context) {
    final icon = item.kind == _ChatAttachmentKind.video
        ? Icons.videocam_outlined
        : Icons.insert_drive_file_outlined;
    final label = item.kind == _ChatAttachmentKind.video ? 'Видео' : 'Файл';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: Colors.white),
            const SizedBox(height: 12),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.displayName,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.78),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentVideoPlayer extends StatefulWidget {
  const _AttachmentVideoPlayer({
    required this.source,
    required this.isRemoteSource,
    this.posterUrl,
  });

  final String source;
  final bool isRemoteSource;
  final String? posterUrl;

  @override
  State<_AttachmentVideoPlayer> createState() => _AttachmentVideoPlayerState();
}

class _AttachmentVideoPlayerState extends State<_AttachmentVideoPlayer> {
  VideoPlayerController? _controller;
  Future<void>? _initializeFuture;
  bool _isMuted = false;
  bool _seeking = false;
  // Position the user is currently dragging the seek bar to. We commit
  // to the controller on drag-end so the playback head doesn't fight
  // the live position updates while the thumb is in motion.
  Duration _scrubPosition = Duration.zero;
  bool _showControls = true;
  Timer? _hideControlsTimer;

  @override
  void initState() {
    super.initState();
    final uri = _videoSourceUri(widget.source);
    final controller = widget.isRemoteSource
        ? VideoPlayerController.networkUrl(uri)
        : VideoPlayerController.contentUri(uri);
    _controller = controller;
    // Listener pulls live position / playing state into setState so the
    // seek bar + time labels actually follow playback. Was missing
    // before — that's why the slider looked frozen.
    controller.addListener(_handleControllerUpdate);
    _initializeFuture = controller.initialize().then((_) {
      if (!mounted) return;
      // Don't auto-loop video files — TG / WA stop at end-of-file and
      // wait for user to scrub or restart.
      controller.setLooping(false);
    });
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _controller?.removeListener(_handleControllerUpdate);
    _controller?.dispose();
    super.dispose();
  }

  void _handleControllerUpdate() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null) return;
    HapticFeedback.lightImpact();
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      // If we're at the end of the file, restart from 0.
      final pos = controller.value.position;
      final dur = controller.value.duration;
      if (dur > Duration.zero &&
          pos >= dur - const Duration(milliseconds: 250)) {
        await controller.seekTo(Duration.zero);
      }
      await controller.play();
      _scheduleControlsHide();
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleMute() async {
    final controller = _controller;
    if (controller == null) return;
    HapticFeedback.lightImpact();
    final next = !_isMuted;
    await controller.setVolume(next ? 0 : 1);
    if (!mounted) return;
    setState(() => _isMuted = next);
  }

  void _scheduleControlsHide() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      final controller = _controller;
      if (controller == null) return;
      // Don't auto-hide while paused — controls only fade out during
      // active playback so the user can still tap to resume.
      if (controller.value.isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControlsVisibility() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      _scheduleControlsHide();
    } else {
      _hideControlsTimer?.cancel();
    }
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:$mm:$ss';
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<void>(
      future: _initializeFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Stack(
            alignment: Alignment.center,
            children: [
              if (widget.posterUrl != null && widget.posterUrl!.isNotEmpty)
                _AttachmentImage(
                  url: widget.posterUrl,
                  fit: BoxFit.contain,
                ),
              const CircularProgressIndicator(color: Colors.white),
            ],
          );
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Не удалось загрузить видео',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.78)),
              ),
            ),
          );
        }
        final duration = controller.value.duration;
        final position = _seeking ? _scrubPosition : controller.value.position;
        final maxMs =
            duration.inMilliseconds <= 0 ? 1 : duration.inMilliseconds;
        final scrubMs = position.inMilliseconds.clamp(0, maxMs).toDouble();
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 720),
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio == 0
                  ? 16 / 9
                  : controller.value.aspectRatio,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: ColoredBox(
                  color: Colors.black,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Tap on the canvas toggles controls visibility,
                      // play/pause stays on the dedicated button so we
                      // don't fight gesture intent.
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _toggleControlsVisibility,
                        child: VideoPlayer(controller),
                      ),
                      AnimatedOpacity(
                        opacity: _showControls ? 1 : 0,
                        duration: const Duration(milliseconds: 220),
                        child: IgnorePointer(
                          ignoring: !_showControls,
                          child: _buildControlsOverlay(
                            controller: controller,
                            position: position,
                            duration: duration,
                            scrubMs: scrubMs,
                            maxMs: maxMs.toDouble(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildControlsOverlay({
    required VideoPlayerController controller,
    required Duration position,
    required Duration duration,
    required double scrubMs,
    required double maxMs,
  }) {
    return Stack(
      children: [
        // Soft gradient at top + bottom so white controls stay legible
        // over bright video content. Same look as TG / iOS player.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.42),
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.55),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
        ),
        // Center play / pause — big, hit-testable.
        Center(
          child: Material(
            color: Colors.black.withValues(alpha: 0.42),
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: Semantics(
              button: true,
              label: controller.value.isPlaying
                  ? 'Поставить на паузу'
                  : 'Воспроизвести',
              child: InkWell(
                onTap: _togglePlayback,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Icon(
                    controller.value.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ),
            ),
          ),
        ),
        // Bottom strip: time labels + seek bar + mute toggle.
        Positioned(
          left: 8,
          right: 8,
          bottom: 4,
          child: Row(
            children: [
              const SizedBox(width: 8),
              Text(
                _formatDuration(position),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.32),
                    thumbColor: Colors.white,
                    overlayColor: Colors.white.withValues(alpha: 0.12),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 7,
                    ),
                  ),
                  child: Slider(
                    value: scrubMs,
                    max: maxMs,
                    onChangeStart: (_) {
                      setState(() => _seeking = true);
                    },
                    onChanged: (value) {
                      setState(() {
                        _scrubPosition = Duration(milliseconds: value.round());
                      });
                    },
                    onChangeEnd: (value) async {
                      await controller.seekTo(
                        Duration(milliseconds: value.round()),
                      );
                      if (mounted) setState(() => _seeking = false);
                    },
                  ),
                ),
              ),
              Text(
                _formatDuration(duration),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.78),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: _toggleMute,
                tooltip: _isMuted ? 'Включить звук' : 'Выключить звук',
                icon: Icon(
                  _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Uri _videoSourceUri(String value) {
    final parsed = Uri.tryParse(value);
    if (parsed != null && parsed.hasScheme) {
      return parsed;
    }
    return Uri.file(value);
  }
}

/// Telegram-style circular video-note (кружок) player. Auto-plays on open
/// with sound on (V3): tap = play/pause (no force-loop), a progress ring
/// runs round the circle, drag along the ring seeks, and mute is a small
/// secondary speaker control. Save is available from the dialog header
/// (download icon at top-right).
class _VideoNotePlayer extends StatefulWidget {
  const _VideoNotePlayer({
    super.key,
    required this.source,
    required this.isRemoteSource,
    this.posterUrl,
    this.diameter = 320,
  });

  final String source;
  final bool isRemoteSource;
  final String? posterUrl;

  /// C2: диаметр круга. 320 — полноэкранный просмотрщик; ~168 — inline в
  /// бабле (играем кружок на месте, как в Telegram).
  final double diameter;

  @override
  State<_VideoNotePlayer> createState() => _VideoNotePlayerState();
}

class _VideoNotePlayerState extends State<_VideoNotePlayer> {
  VideoPlayerController? _controller;
  Future<void>? _initializeFuture;
  bool _isMuted = false;
  // V3 (ревью FR7): идёт перемотка по кольцу — на это время ведём позицию
  // от пальца, а тап не должен трактоваться как play/pause.
  bool _isScrubbing = false;

  @override
  void initState() {
    super.initState();
    final controller = _createController();
    _controller = controller;
    _initializeFuture = _startPlayback(controller);
  }

  VideoPlayerController _createController() {
    final uri = _videoSourceUri(widget.source);
    final controller = widget.isRemoteSource
        ? VideoPlayerController.networkUrl(uri)
        : VideoPlayerController.contentUri(uri);
    controller.addListener(_handleUpdate);
    return controller;
  }

  Future<void> _startPlayback(VideoPlayerController controller) {
    // FR3: ошибка initialize() (битый файл / недоступный URL / кодек)
    // долетит до FutureBuilder.snapshot.hasError → error-UI вместо
    // вечного спиннера. .then не выполнится, activate/play пропускаются.
    return controller.initialize().then((_) async {
      if (!mounted) return;
      // V3 (ревью FR5): НЕ форсим луп — кружок играет один раз, тап =
      // play/pause (как в Telegram). Звук включён, мьют — вторичным контролом.
      await controller.setVolume(1);
      // C2c: один inline-плеер за раз — паузим другой кружок/голосовое.
      _InlineMediaPlayback.activate(this, _pauseSelf);
      await controller.play();
    });
  }

  Future<void> _retry() async {
    final old = _controller;
    old?.removeListener(_handleUpdate);
    unawaited(old?.dispose());
    final controller = _createController();
    setState(() {
      _controller = controller;
      _initializeFuture = _startPlayback(controller);
    });
  }

  /// C2c: пауза этого кружка по требованию реестра one-at-a-time.
  /// mounted-гард + null'нутый после dispose контроллер — защита от
  /// вызова на уже-disposed-плеере (pause() на нём кидает в debug/profile).
  void _pauseSelf() {
    if (!mounted) {
      return;
    }
    final controller = _controller;
    if (controller != null &&
        controller.value.isInitialized &&
        controller.value.isPlaying) {
      unawaited(controller.pause());
    }
  }

  @override
  void dispose() {
    // FR2: кружок ушёл с экрана / размонтирован → снимаем регистрацию в
    // реестре и диспоузим контроллер, что останавливает зацикленное
    // видео. Слушателя снимаем ПЕРЕД dispose, чтобы pause/teardown не
    // дёрнул setState в фазе билда (краш «setState during build»).
    _InlineMediaPlayback.resign(this);
    final controller = _controller;
    _controller = null;
    controller?.removeListener(_handleUpdate);
    controller?.dispose();
    super.dispose();
  }

  void _handleUpdate() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _toggleMute() async {
    final controller = _controller;
    if (controller == null) return;
    HapticFeedback.lightImpact();
    final next = !_isMuted;
    await controller.setVolume(next ? 0 : 1);
    if (!mounted) return;
    setState(() => _isMuted = next);
  }

  /// V3 (ревью FR5): основной тап = play/pause (как в Telegram). По концу
  /// (без лупа) тап перезапускает с начала. Старт игры заявляет себя в
  /// one-at-a-time реестре, чтобы заглушить другой играющий кружок/голос.
  Future<void> _togglePlayPause() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final value = controller.value;
    HapticFeedback.selectionClick();
    if (value.isPlaying) {
      await controller.pause();
      return;
    }
    if (value.duration > Duration.zero && value.position >= value.duration) {
      await controller.seekTo(Duration.zero);
    }
    _InlineMediaPlayback.activate(this, _pauseSelf);
    await controller.play();
  }

  /// V3 (ревью FR7): доля длительности из точки касания — угол вокруг центра
  /// кружка (0 — наверху/12 часов, по часовой стрелке).
  double _seekFractionFromLocal(Offset local) {
    final radius = widget.diameter / 2;
    final dx = local.dx - radius;
    final dy = local.dy - radius;
    var angle = math.atan2(dx, -dy);
    if (angle < 0) angle += 2 * math.pi;
    return (angle / (2 * math.pi)).clamp(0.0, 1.0);
  }

  /// FR6 (ревью C3c): касание попало в полосу КОЛЬЦА (наружные ~40% радиуса).
  /// Только такой drag захватывается под перемотку; центр оставляем скроллу
  /// ленты / свайпу PageView.
  bool _isOnSeekRing(Offset local) {
    final radius = widget.diameter / 2;
    if (radius <= 0) return false;
    final dx = local.dx - radius;
    final dy = local.dy - radius;
    final distance = math.sqrt(dx * dx + dy * dy);
    return distance >= radius * 0.6 && distance <= radius * 1.15;
  }

  void _seekToLocal(Offset local) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final duration = controller.value.duration;
    if (duration <= Duration.zero) return;
    final fraction = _seekFractionFromLocal(local);
    unawaited(controller.seekTo(duration * fraction));
  }

  void _onSeekStart(DragStartDetails details) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    _isScrubbing = true;
    _seekToLocal(details.localPosition);
  }

  void _onSeekUpdate(DragUpdateDetails details) {
    if (!_isScrubbing) return;
    _seekToLocal(details.localPosition);
  }

  void _onSeekEnd(DragEndDetails details) {
    _isScrubbing = false;
  }

  /// FR6: доля проигранного (0..1) для кольца прогресса.
  double _playbackFraction(VideoPlayerController controller) {
    final total = controller.value.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (controller.value.position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  /// FR3: круг-плейсхолдер при сбое инициализации видео. Тап — повтор
  /// загрузки (а не мёртвый чёрный круг). Постер, если есть, остаётся
  /// фоном.
  Widget _buildErrorCircle(BuildContext context) {
    return Center(
      child: GestureDetector(
        key: const Key('video-note-error'),
        behavior: HitTestBehavior.opaque,
        onTap: _retry,
        child: ClipOval(
          child: Container(
            width: widget.diameter,
            height: widget.diameter,
            color: Colors.black,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (widget.posterUrl != null && widget.posterUrl!.isNotEmpty)
                  Opacity(
                    opacity: 0.4,
                    child: _AttachmentImage(
                      url: widget.posterUrl,
                      fit: BoxFit.cover,
                    ),
                  ),
                const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.refresh_rounded, color: Colors.white, size: 32),
                    SizedBox(height: 4),
                    Text(
                      'Не удалось\nзагрузить',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<void>(
      future: _initializeFuture,
      builder: (context, snapshot) {
        // FR3: сбой инициализации — показываем affordance ошибки с
        // повтором, а не чёрный круг / вечный спиннер без onTap.
        if (snapshot.hasError) {
          return _buildErrorCircle(context);
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return Center(
            child: ClipOval(
              child: Container(
                width: widget.diameter,
                height: widget.diameter,
                color: Colors.black,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (widget.posterUrl != null &&
                        widget.posterUrl!.isNotEmpty)
                      _AttachmentImage(
                        url: widget.posterUrl,
                        fit: BoxFit.cover,
                      ),
                    const CircularProgressIndicator(color: Colors.white),
                  ],
                ),
              ),
            ),
          );
        }
        // Кружочек — фиксированный квадрат-в-круг. Клипуем в Oval
        // независимо от исходного aspect ratio: video note по
        // протоколу TG всегда квадратный, но даже если бэкенд отдаст
        // 16:9, мы аккуратно центрируем + кропаем.
        final progress = _playbackFraction(controller);
        final isPlaying = controller.value.isPlaying;
        return Center(
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            // FR5: тап — play/pause. FR6 (ревью C3c): перемотку ведёт
            // кастомный pan-recognizer, который заявляет жест в арене ТОЛЬКО
            // для drag'а ПО кольцу (старт у края). Drag из центра/мимо кольца
            // не захватывается → уступает вертикальному скроллу ленты чата и
            // горизонтальному свайпу PageView-просмотрщика.
            gestures: <Type, GestureRecognizerFactory>{
              TapGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                () => TapGestureRecognizer(),
                (recognizer) => recognizer.onTap = _togglePlayPause,
              ),
              _RingPanGestureRecognizer: GestureRecognizerFactoryWithHandlers<
                  _RingPanGestureRecognizer>(
                () => _RingPanGestureRecognizer(isOnRing: _isOnSeekRing),
                (recognizer) => recognizer
                  ..onStart = _onSeekStart
                  ..onUpdate = _onSeekUpdate
                  ..onEnd = _onSeekEnd,
              ),
            },
            child: SizedBox(
              width: widget.diameter,
              height: widget.diameter,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ClipOval(
                    child: SizedBox(
                      width: widget.diameter,
                      height: widget.diameter,
                      child: FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: controller.value.size.width <= 0
                              ? 320
                              : controller.value.size.width,
                          height: controller.value.size.height <= 0
                              ? 320
                              : controller.value.size.height,
                          child: VideoPlayer(controller),
                        ),
                      ),
                    ),
                  ),
                  // FR6: кольцо прогресса по окружности кружка.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _VideoNoteProgressRingPainter(
                          progress: progress,
                          color: Colors.white,
                          trackColor: Colors.white.withValues(alpha: 0.28),
                        ),
                      ),
                    ),
                  ),
                  // FR5: центральный индикатор play, когда на паузе.
                  if (!isPlaying)
                    IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.32),
                          shape: BoxShape.circle,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            color: Colors.white,
                            size: 34,
                          ),
                        ),
                      ),
                    ),
                  // FR5: мьют — вторичный мелкий контрол (динамик) в углу.
                  Positioned(
                    right: widget.diameter * 0.10,
                    bottom: widget.diameter * 0.10,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _toggleMute,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isMuted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Uri _videoSourceUri(String value) {
    final parsed = Uri.tryParse(value);
    if (parsed != null && parsed.hasScheme) {
      return parsed;
    }
    return Uri.file(value);
  }
}

/// V3 (ревью FR6): кольцо прогресса по окружности видео-кружка. Дуга от
/// 12 часов по часовой стрелке, синхронна controller.position (репейнт на
/// каждом тике слушателя плеера).
class _VideoNoteProgressRingPainter extends CustomPainter {
  _VideoNoteProgressRingPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
  });

  static const double stroke = 3;

  final double progress;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - stroke) / 2;
    if (radius <= 0) return;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = trackColor
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, track);

    final clamped = progress.clamp(0.0, 1.0);
    if (clamped <= 0) return;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = color
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      clamped * 2 * math.pi,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(covariant _VideoNoteProgressRingPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.color != color ||
        oldDelegate.trackColor != trackColor;
  }
}

/// FR6 (ревью C3c): pan-recognizer перемотки кружка, который ВХОДИТ в арену
/// жестов только если касание началось в полосе кольца ([isOnRing]). Иначе
/// указатель ему не выдаётся — и жест достаётся родителю (вертикальный скролл
/// ленты чата / горизонтальный свайп PageView-просмотрщика), а не крадётся.
class _RingPanGestureRecognizer extends PanGestureRecognizer {
  _RingPanGestureRecognizer({required this.isOnRing});

  final bool Function(Offset localPosition) isOnRing;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    // Не на кольце — не претендуем на жест: указатель не трекается, жест
    // достаётся родителю (скролл ленты / свайп PageView), а не крадётся.
    if (isOnRing(event.localPosition)) {
      super.addAllowedPointer(event);
    }
  }
}

/// Wraps an image in an InteractiveViewer-friendly swipe-down-to-
/// dismiss gesture (TG / iOS Photos pattern).
///
/// Behaviour:
/// * Tracks scale via a [TransformationController]; we dismiss only
///   when the image is at scale 1 (i.e. not zoomed). If the user is
///   zoomed in we let InteractiveViewer keep all pan gestures so they
///   can still look around inside the zoom.
/// * On vertical pan: image follows the finger (Transform.translate)
///   and the surrounding dialog fades proportionally to the drag
///   distance. Past 110dp dismiss-threshold, releasing pops the
///   viewer; below threshold, releasing snaps back.
/// * Builder pattern lets the caller construct the actual image
///   widget (including the InteractiveViewer) so the controller is
///   shared between us (scale-detection) and the viewer
///   (pinch-zoom).
class _SwipeDownDismissibleImage extends StatefulWidget {
  const _SwipeDownDismissibleImage({required this.builder});

  /// Caller builds the InteractiveViewer-wrapped image and binds the
  /// shared `transformationController` so we can read the scale.
  final Widget Function(
    BuildContext context,
    TransformationController controller,
  ) builder;

  @override
  State<_SwipeDownDismissibleImage> createState() =>
      _SwipeDownDismissibleImageState();
}

class _SwipeDownDismissibleImageState extends State<_SwipeDownDismissibleImage>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  late final AnimationController _snap;
  Offset _dragOffset = Offset.zero;
  bool _isAtRestingScale = true;

  // Past this many vertical pixels the release dismisses; under that
  // we snap back.
  static const double _dismissThreshold = 110;

  @override
  void initState() {
    super.initState();
    _snap = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _transform.addListener(_handleTransformChange);
  }

  @override
  void dispose() {
    _transform.removeListener(_handleTransformChange);
    _transform.dispose();
    _snap.dispose();
    super.dispose();
  }

  void _handleTransformChange() {
    final scale = _transform.value.getMaxScaleOnAxis();
    final atRest = (scale - 1.0).abs() < 0.01;
    if (atRest != _isAtRestingScale) {
      setState(() => _isAtRestingScale = atRest);
    }
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (!_isAtRestingScale) return;
    setState(() {
      _dragOffset += Offset(0, details.delta.dy);
      // Don't let the user drag the image up forever — TG just
      // anchors at zero on upward drags.
      if (_dragOffset.dy < 0) {
        _dragOffset = Offset(_dragOffset.dx, _dragOffset.dy * 0.4);
      }
    });
  }

  Future<void> _handleDragEnd(DragEndDetails details) async {
    final velocity = details.velocity.pixelsPerSecond.dy;
    final passedThreshold =
        _dragOffset.dy > _dismissThreshold || velocity > 700;
    if (passedThreshold && mounted) {
      Navigator.of(context).maybePop();
      return;
    }
    // Snap back to origin via animation.
    final from = _dragOffset;
    _snap.value = 0;
    final tween = Tween<Offset>(begin: from, end: Offset.zero)
        .chain(CurveTween(curve: Curves.easeOutCubic))
        .animate(_snap);
    void listener() {
      if (!mounted) return;
      setState(() => _dragOffset = tween.value);
    }

    tween.addListener(listener);
    await _snap.forward();
    tween.removeListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    final dyAbs = _dragOffset.dy.abs();
    // Background opacity falls from 1.0 → 0.55 over the threshold so
    // the "letting go past here will dismiss" point is visible.
    final dragProgress = (dyAbs / _dismissThreshold).clamp(0.0, 1.0);
    final backgroundOpacity = 1.0 - 0.45 * dragProgress;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Black layer that fades as the image translates. The dialog
        // already has its own black 92% backdrop; we layer a fading
        // black-out so the user sees the dimming as a confirmation
        // signal that release will dismiss.
        IgnorePointer(
          child: Container(
            color: Colors.black.withValues(
              alpha: 0.92 * backgroundOpacity,
            ),
          ),
        ),
        GestureDetector(
          // We only care about VERTICAL pan — letting horizontal
          // gestures fall through means the parent PageView still
          // handles swipe-between-pages.
          behavior: HitTestBehavior.translucent,
          onVerticalDragUpdate: _isAtRestingScale ? _handleDragUpdate : null,
          onVerticalDragEnd: _isAtRestingScale ? _handleDragEnd : null,
          child: Transform.translate(
            offset: _dragOffset,
            child: widget.builder(context, _transform),
          ),
        ),
      ],
    );
  }
}

/// Small green presence dot rendered in the bottom-right corner of
/// the chat-AppBar avatar when the peer is online. Pulses gently
/// (1.4s cycle, 0.85 → 1.0 scale + 0.6 → 1.0 opacity on a halo) so
/// the indicator reads as a live signal rather than a static
/// notification badge. Skipped under flutter_test's binding so
/// pumpAndSettle in widget tests doesn't hang on the repeating
/// controller.
class _OnlinePulseDot extends StatefulWidget {
  const _OnlinePulseDot({
    required this.color,
    required this.surfaceColor,
  });

  final Color color;
  final Color surfaceColor;

  @override
  State<_OnlinePulseDot> createState() => _OnlinePulseDotState();
}

class _OnlinePulseDotState extends State<_OnlinePulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    final inTest = bindingName.contains('TestWidgetsFlutterBinding');
    if (!inTest) _ctrl.repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        // Halo expands + fades over the cycle; core dot stays solid.
        final haloScale = 1.0 + 0.7 * t;
        final haloOpacity = (1.0 - t) * 0.55;
        return SizedBox(
          width: 14,
          height: 14,
          child: Stack(
            alignment: Alignment.center,
            children: [
              IgnorePointer(
                child: Opacity(
                  opacity: haloOpacity,
                  child: Transform.scale(
                    scale: haloScale,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: widget.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.surfaceColor,
                    width: 1.6,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Animated three-dot typing indicator. Each dot fades + scales in a
/// 1.2s loop with 200ms phase offset so the row reads as a live
/// "..." pulse — same pattern Telegram / iMessage use under the
/// peer's name when they're composing. Lives in the chat AppBar
/// subtitle row, sized to fit a 12px text line.
class _TypingDots extends StatefulWidget {
  const _TypingDots({required this.color});
  final Color color;

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 14,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < 3; i++)
                _Dot(
                  color: widget.color,
                  // Phase each dot 1/6 of the cycle apart so the
                  // sequence reads left-to-right.
                  phase: (_ctrl.value - i / 6) % 1.0,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.phase});
  final Color color;
  final double phase;

  @override
  Widget build(BuildContext context) {
    // Sine-driven opacity + scale so each dot eases up and back down
    // smoothly. Range 0.35 → 1.0 on opacity keeps the dot always
    // visible (the row never goes blank), 0.7 → 1.0 on scale gives a
    // subtle "breathing" feel without jumping.
    final eased = 0.5 + 0.5 * math.sin(phase * 2 * math.pi);
    final opacity = (0.35 + 0.65 * eased).clamp(0.0, 1.0);
    final scale = (0.7 + 0.3 * eased).clamp(0.0, 2.0);
    return Opacity(
      opacity: opacity,
      child: Transform.scale(
        scale: scale,
        child: Container(
          width: 4,
          height: 4,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

/// Telegram-style read receipt that animates as the message walks the
/// status ladder: pending (no tick — handled in caller) → sent (single
/// ✓) → delivered (✓✓ faded) → read (✓✓ blue). [AnimatedSwitcher]
/// cross-fades + scales whenever the state actually changes; identical
/// repaints (same status) keep the existing icon mounted.
class _ReadReceiptTick extends StatelessWidget {
  const _ReadReceiptTick({
    required this.isRead,
    required this.isDelivered,
    required this.readColor,
    required this.dimColor,
  });

  final bool isRead;
  final bool isDelivered;
  final Color readColor;
  final Color dimColor;

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final Color color;
    final String stateKey;
    if (isRead) {
      icon = Icons.done_all;
      color = readColor;
      stateKey = 'read';
    } else if (isDelivered) {
      icon = Icons.done_all;
      color = dimColor;
      stateKey = 'delivered';
    } else {
      icon = Icons.done;
      color = dimColor;
      stateKey = 'sent';
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        // Scale-in from 0.6 + fade so the upgrade from ✓ → ✓✓ /
        // delivered → read reads as a deliberate beat. We set
        // AlignmentGeometry.center so the icon doesn't slide.
        return ScaleTransition(
          scale: Tween<double>(begin: 0.6, end: 1.0).animate(animation),
          child: FadeTransition(opacity: animation, child: child),
        );
      },
      child: Icon(
        icon,
        key: ValueKey<String>('read-receipt-$stateKey'),
        size: 14,
        color: color,
      ),
    );
  }
}

/// Telegram-style "long-press → context menu" route: backdrop blur
/// grows from 0 to 14, dim grows from 0 to 32% black, the action card
/// slides up 25% + fades in. Used for both incoming and outgoing
/// message-action sheets so the touch interaction reads as premium
/// instead of "yet another bottom sheet".
///
/// API mirrors [showModalBottomSheet] — pass a builder, dismiss via
/// `Navigator.of(context).pop(value)` from inside, await the future.
/// `padding` controls the gap from the bottom edge so the card lifts
/// above the system safe-area / bottom nav.
Future<T?> showBlurredActionsSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Закрыть',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (context, animation, secondary) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              elevation: 18,
              shadowColor: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(24),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 540),
                child: builder(context),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, secondary, child) {
      // We control three things: backdrop blur sigma, dim alpha, and
      // the card's slide-up + fade. AnimatedBuilder rebuilds the blur
      // every frame; the card itself nests cheap transitions.
      final eased = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return AnimatedBuilder(
        animation: eased,
        builder: (context, _) {
          final t = eased.value;
          return Stack(
            children: [
              // Backdrop blur grows / shrinks with the route — same
              // pattern Telegram / iMessage use to draw attention to
              // the floating action card.
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: true,
                  child: BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: 14 * t,
                      sigmaY: 14 * t,
                    ),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.32 * t),
                    ),
                  ),
                ),
              ),
              FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.20),
                    end: Offset.zero,
                  ).animate(eased),
                  child: child,
                ),
              ),
            ],
          );
        },
      );
    },
  );
}

/// Composer-bar slot with smooth show / hide. Wraps a reply / edit /
/// forward bar in [AnimatedSize] (row-height grow) + [AnimatedSwitcher]
/// (cross-fade + slide-down for the bar itself). When [show] flips on
/// the bar slides down 8dp + fades in over 220ms; when it flips off
/// the bar fades out and the row collapses to 0 height.
///
/// Pass `child: null` when the bar should be hidden so the slot has
/// nothing to render — same shape Flutter's `AnimatedSwitcher` expects
/// for the "empty" branch. The 8dp bottom gap is part of the slot
/// itself so the gap collapses with the bar (no leftover whitespace).
class _AnimatedComposerSlot extends StatelessWidget {
  const _AnimatedComposerSlot({required this.show, required this.child});

  final bool show;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final slide = Tween<Offset>(
            begin: const Offset(0, -0.18),
            end: Offset.zero,
          ).animate(animation);
          return ClipRect(
            child: SlideTransition(
              position: slide,
              child: FadeTransition(opacity: animation, child: child),
            ),
          );
        },
        child: show && child != null
            ? Padding(
                key: const ValueKey('composer-slot-shown'),
                padding: const EdgeInsets.only(bottom: 8),
                child: child,
              )
            : const SizedBox.shrink(key: ValueKey('composer-slot-hidden')),
      ),
    );
  }
}
