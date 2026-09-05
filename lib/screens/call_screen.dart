import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:collection/collection.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:get_it/get_it.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';

import '../utils/user_facing_error.dart';
import '../backend/interfaces/chat_service_interface.dart';
import '../models/call_invite.dart';
import '../models/call_media_mode.dart';
import '../models/call_state.dart';
import '../models/chat_details.dart';
import '../services/audio_route_service.dart';
import '../services/call_coordinator_service.dart';
import '../services/call_pip_service.dart';
import '../utils/photo_url.dart';
import '../widgets/call_connection_quality_badge.dart';
import '../widgets/call_device_picker_sheet.dart';
import '../widgets/glass_panel.dart';
import '../widgets/in_call_chat_sheet.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.initialCall,
    required this.title,
    required this.coordinator,
    this.photoUrl,
    this.pipService = const MethodChannelCallPipService(),
    this.chatService,
  });

  final CallInvite initialCall;
  final String title;
  final String? photoUrl;
  final CallCoordinatorService coordinator;
  final CallPipService pipService;
  final ChatServiceInterface? chatService;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  CallInvite? _call;
  // Тracks last-observed value of `coordinator.microphonePublishFailed`
  // чтобы snackbar показывался ровно на false → true transition (а не
  // каждый notifyListeners во время failure). Reset на dispose.
  bool _lastMicrophonePublishFailed = false;
  // Камерное зеркало: transition-tracking для cameraPublishFailed
  // (S20 FE 2026-07-04 — publish камеры падал молча, юзер видел
  // перечёркнутую иконку без единого объяснения).
  bool _lastCameraPublishFailed = false;
  // Дебаунс «Завершить»: второй тап во время exit-анимации снимал бы
  // нижележащий роут вторым maybePop.
  bool _isFinishingCall = false;
  // Дисмисс запрашиваем один раз: повторные notify-микротаски не должны
  // дёргать navigator после того, как закрытие уже пошло.
  bool _dismissRequested = false;
  // Видел ли листенер СВОЙ звонок в координаторе — гейт для дисмисса
  // по id-mismatch (см. _handleCoordinatorChanged).
  bool _coordinatorTrackedOurCall = false;
  // Экран открылся сразу на терминальном состоянии (гонка stale-PIP):
  // координатор молчит (bare return без notify), pop-по-null не
  // сработает — закрываемся сами после короткой паузы.
  Timer? _terminalAutoCloseTimer;
  // Incoming-call ringer: periodic system click + heavy haptic while
  // the call is ringing and we're the callee. Was missing entirely —
  // user reported "звонки в тишину идут".
  Timer? _ringerTimer;
  AudioPlayer? _ringerPlayer;
  bool _ringerActive = false;
  // Active-video-call chrome auto-hide: header + status panel fade
  // out after 3s of inactivity so the remote video gets the whole
  // canvas. Tap brings them back. User said the always-on header
  // was annoying ("шапка торчит — нахуя?").
  bool _videoChromeVisible = true;
  Timer? _videoChromeHideTimer;
  // Таймер длительности звонка: тикает раз в секунду пока звонок
  // active, база — coordinator.activeSince (латчится один раз на
  // звонок). Skip'ается в flutter_test binding'е (см. _startRinger).
  Timer? _durationTicker;
  // Collapsible action row: lets the user fold the bottom mic / audio /
  // camera / chat / device controls down to just the end-call button so
  // the video stage gets more breathing room. Same affordance the user
  // asked for on the latest device-test pass: "Кнопки нижние при
  // звонках хотелось бы тоже сворачивать иметь возможность."
  bool _actionsCollapsed = false;
  // Draggable + swappable PIP (picture-in-picture) for local video.
  // `_pipOffset` is the top-left position of the PIP within the
  // viewport — null until first frame so we can default-position it
  // bottom-right (computed in build from MediaQuery). `_pipShowsLocal`
  // tracks which feed sits in the small tile vs the full stage —
  // tapping the PIP swaps them.
  Offset? _pipOffset;
  Offset? _pipDragStartOffset;
  Offset _pipDragAccumulated = Offset.zero;
  bool _pipShowsLocal = true;
  Map<String, ChatParticipantSummary> _callParticipantsById =
      const <String, ChatParticipantSummary>{};
  String? _participantDetailsChatId;
  bool _isNudgingGroupParticipants = false;
  bool _isAddingParticipant = false;
  static const double _pipWidth = 120;
  static const double _pipHeight = 180;
  // Drag-vs-tap disambiguation threshold для PIP gesture. Был 6.0 —
  // на slow swipe чувствовался «stuck» (Bug 4 audit 2026-05-22:
  // Артёма «окошки не двигаются»). 3.0 dp ≈ 4 physical px на 400ppi
  // displays: comfortably выше touchscreen jitter (1-2 px) и
  // intentional drag intent covers это в <50ms. Apple HIG suggests
  // 3.5pt minimum для drag detection — мы matched. Material
  // kTouchSlop default = 18.0 (намного больше) — мы intentionally
  // sub-system slop потому что `dragStartBehavior: DragStartBehavior.down`
  // уже bypassed system slop ↓ в GestureDetector.
  static const double _pipDragCommitThresholdDp = 3.0;

  String? get _currentUserId => widget.coordinator.currentUserId;
  CallInvite get _resolvedCall => _call ?? widget.initialCall;
  bool get _isIncoming =>
      _currentUserId != null && _resolvedCall.isIncomingFor(_currentUserId!);
  // GP1/GP5: an ACTIVE call I'm viewing but have no session in yet → «Войти»
  // for a late member to «залететь в группу». We DON'T gate on
  // participantIds.contains(uid): the server `/join` is chat-membership-gated
  // (requireCallJoinAccess — any member of the call's chat may join, and a
  // non-invited joiner is added to the roster server-side in joinActiveCall),
  // so the old client check was STRICTER than the server and hid «Войти» from
  // chat members who weren't on the original invite list. Optimistic-show +
  // server validation (a join failure surfaces a retriable snackbar). The
  // initiator is excluded via isOutgoingFor.
  bool get _canJoinActive {
    final uid = _currentUserId;
    return uid != null &&
        _resolvedCall.state == CallState.active &&
        _resolvedCall.session == null &&
        !_resolvedCall.isOutgoingFor(uid);
  }

  bool get _isVideoCall => _resolvedCall.mediaMode == CallMediaMode.video;
  AudioRouteService get _audioRouteService =>
      widget.coordinator.audioRouteService;
  ChatServiceInterface? get _chatService =>
      widget.chatService ??
      (GetIt.I.isRegistered<ChatServiceInterface>()
          ? GetIt.I<ChatServiceInterface>()
          : null);

  @override
  void initState() {
    super.initState();
    _call = widget.coordinator.currentCall?.id == widget.initialCall.id
        ? widget.coordinator.currentCall
        : widget.initialCall;
    widget.coordinator.setCallScreenVisible(
      widget.initialCall.id,
      isVisible: true,
    );
    widget.coordinator.addListener(_handleCoordinatorChanged);
    unawaited(widget.coordinator.activateCall(_resolvedCall));
    unawaited(_loadCallParticipantSummaries());
    _syncRinger();
    _syncDurationTicker();
    if (widget.coordinator.currentCall?.id == _resolvedCall.id) {
      _coordinatorTrackedOurCall = true;
    }
    // Stuck-path №3 (скаут 2026-07-04): терминальный initialCall при
    // молчащем координаторе — activateCall упрётся в bare return без
    // notify, экран завис бы статично. Пауза, чтобы юзер увидел исход.
    if (_resolvedCall.state.isTerminal &&
        widget.coordinator.currentCall == null) {
      _terminalAutoCloseTimer = Timer(const Duration(milliseconds: 1200), () {
        if (!mounted) {
          return;
        }
        if (_resolvedCall.state.isTerminal &&
            widget.coordinator.currentCall == null) {
          _dismissCallScreen();
        }
      });
    }
  }

  @override
  void dispose() {
    widget.coordinator.removeListener(_handleCoordinatorChanged);
    widget.coordinator.setCallScreenVisible(
      widget.initialCall.id,
      isVisible: false,
    );
    _stopRinger();
    _videoChromeHideTimer?.cancel();
    _durationTicker?.cancel();
    _terminalAutoCloseTimer?.cancel();
    super.dispose();
  }

  /// Держит секундный тикер длительности ровно пока звонок active.
  /// В flutter_test binding'е periodic-таймер не заводим — pumpAndSettle
  /// иначе никогда не settle'ится (конвенция файла, см. _startRinger).
  void _syncDurationTicker() {
    final shouldTick = _resolvedCall.state == CallState.active &&
        widget.coordinator.activeSince != null;
    if (shouldTick && _durationTicker == null) {
      final bindingName = WidgetsBinding.instance.runtimeType.toString();
      if (bindingName.contains('TestWidgetsFlutterBinding')) {
        return;
      }
      _durationTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        // Хром спрятан (видеозвонок, авто-hide) — статус невидим,
        // секундная перерисовка впустую; догоним при показе хрома.
        if (_isVideoCall && !_videoChromeVisible) return;
        setState(() {});
      });
    } else if (!shouldTick) {
      _durationTicker?.cancel();
      _durationTicker = null;
    }
  }

  void _scheduleVideoChromeHide() {
    _videoChromeHideTimer?.cancel();
    if (_resolvedCall.state != CallState.active || !_isVideoCall) return;
    _videoChromeHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _videoChromeVisible = false);
    });
  }

  void _toggleVideoChromeVisibility() {
    setState(() => _videoChromeVisible = !_videoChromeVisible);
    if (_videoChromeVisible) _scheduleVideoChromeHide();
  }

  /// Start the ringer loop when the call is ringing — incoming gets
  /// the loud `ringtone.wav` arpeggio with haptic pulses, outgoing
  /// gets the classic `ringback.wav` (gudok) without vibration. Stop
  /// on any non-ringing state.
  void _syncRinger() {
    if (!mounted) return;
    final isRinging = _resolvedCall.state == CallState.ringing;
    if (isRinging && !_ringerActive) {
      _startRinger(incoming: _isIncoming);
    } else if (!isRinging && _ringerActive) {
      _stopRinger();
    }
  }

  void _startRinger({required bool incoming}) {
    // Skip ringer in flutter_test's binding so widget tests don't
    // hang on the periodic Timer / pumpAndSettle. Detected via
    // binding-name comparison so we don't import flutter_test from
    // production code.
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    if (bindingName.contains('TestWidgetsFlutterBinding')) return;
    _ringerActive = true;
    final player = _ringerPlayer ??= AudioPlayer();

    // Bundled WAVs: ringtone.wav (~2.8s arpeggio) for incoming,
    // ringback.wav (~4s 1s-on / 3s-off RBT pattern) for outgoing.
    // Both loop seamlessly via ReleaseMode.loop. The asset path
    // omits `assets/` because audioplayers' AssetSource resolves
    // against the asset bundle root.
    final asset = incoming ? 'audio/ringtone.wav' : 'audio/ringback.wav';
    unawaited(() async {
      try {
        // Critical: route through the telephony usage type so
        // Android plays the audio on the **ringtone stream** (or
        // VoIP stream for ringback). Without this, audioplayers
        // defaults to `usageType: media` which is silenced when the
        // device is on Vibrate-only or DND, *and* gets ducked when
        // any media is playing — that's why the user reported
        // «никакого аудио нет». On iOS, set the playAndRecord
        // category with default-to-speaker so the ringer comes out
        // of the loudspeaker even mid-call.
        await player.setAudioContext(
          AudioContext(
            android: AudioContextAndroid(
              isSpeakerphoneOn: true,
              audioMode: incoming
                  ? AndroidAudioMode.ringtone
                  : AndroidAudioMode.inCommunication,
              stayAwake: true,
              contentType: AndroidContentType.music,
              usageType: incoming
                  ? AndroidUsageType.notificationRingtone
                  : AndroidUsageType.voiceCommunicationSignalling,
              audioFocus: AndroidAudioFocus.gainTransientMayDuck,
            ),
            iOS: AudioContextIOS(
              category: AVAudioSessionCategory.playAndRecord,
              options: const {
                AVAudioSessionOptions.defaultToSpeaker,
                AVAudioSessionOptions.allowBluetooth,
              },
            ),
          ),
        );
        await player.setReleaseMode(ReleaseMode.loop);
        // Lower volume for the gudok — it's a confirmation tone, not
        // a wake-the-house alert. Incoming stays loud.
        await player.setVolume(incoming ? 1.0 : 0.55);
        await player.play(AssetSource(asset));
      } catch (error) {
        debugPrint('[call] ringer audio failed: $error');
      }
    }());

    if (incoming) {
      // Haptic pulses ride alongside the audio — works on silent
      // mode and gives mid-range Samsung devices the «double-tap»
      // rhythm that's easier to feel than a single buzz.
      void pulse() {
        if (!_ringerActive || !mounted) return;
        HapticFeedback.vibrate();
        Timer(const Duration(milliseconds: 700), () {
          if (!_ringerActive || !mounted) return;
          HapticFeedback.heavyImpact();
        });
      }

      pulse();
      _ringerTimer = Timer.periodic(
        const Duration(milliseconds: 1400),
        (_) => pulse(),
      );
    }
  }

  void _stopRinger() {
    _ringerActive = false;
    _ringerTimer?.cancel();
    _ringerTimer = null;
    final player = _ringerPlayer;
    _ringerPlayer = null;
    // audioplayers выставляет AudioManager.MODE_RINGTONE под входящий рингер
    // (AndroidAudioMode.ringtone) и НЕ восстанавливает его на stop/dispose.
    // Если звонок закончился на этапе звонка (никогда не было startCallAudio),
    // режим RINGTONE залипал → кнопки громкости телефона переставали работать
    // (фантомный вызов). Возвращаем NORMAL ПОСЛЕ полного teardown плеера;
    // натив сам гардит на активную сессию (см. resetRingtoneModeIfIdle), так
    // что переход ringing→active его не затронет.
    unawaited(() async {
      try {
        await player?.stop();
      } catch (_) {}
      try {
        await player?.dispose();
      } catch (_) {}
      try {
        await _audioRouteService.resetRingtoneModeIfIdle();
      } catch (_) {}
    }());
  }

  /// One-shot SFX for call lifecycle transitions — `connect.wav` when
  /// the remote picks up, `hangup.wav` when the line drops. Plays on
  /// a separate AudioPlayer so it doesn't clobber the ringer loop.
  void _playOneShot(String asset) {
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    if (bindingName.contains('TestWidgetsFlutterBinding')) return;
    final player = AudioPlayer();
    unawaited(() async {
      try {
        // Same telephony-aware routing as the loop. `voiceCommunicationSignalling`
        // is exactly what Android telephony uses for connect/disconnect tones.
        await player.setAudioContext(
          AudioContext(
            android: const AudioContextAndroid(
              isSpeakerphoneOn: true,
              audioMode: AndroidAudioMode.inCommunication,
              stayAwake: true,
              contentType: AndroidContentType.music,
              usageType: AndroidUsageType.voiceCommunicationSignalling,
              audioFocus: AndroidAudioFocus.gainTransientMayDuck,
            ),
            iOS: AudioContextIOS(
              category: AVAudioSessionCategory.playAndRecord,
              options: const {AVAudioSessionOptions.defaultToSpeaker},
            ),
          ),
        );
        await player.setReleaseMode(ReleaseMode.release);
        await player.play(AssetSource(asset));
      } catch (error) {
        debugPrint('[call] one-shot audio failed: $error');
      }
    }());
  }

  void _handleCoordinatorChanged() {
    final coordinatorCall = widget.coordinator.currentCall;
    if (coordinatorCall == null) {
      if (mounted) {
        Future<void>.microtask(_dismissCallScreen);
      }
      return;
    }
    if (coordinatorCall.id != _resolvedCall.id) {
      // Координатор переключился на ДРУГОЙ звонок — наш закончился и
      // был вытеснен. Раньше экран замерзал навсегда (терминальные
      // снапшоты чужих id координатор дропает — скаут, stuck-path №2).
      // Гард _coordinatorTrackedOurCall закрывает гонку свежего экрана:
      // между addListener и завершением activateCall координатор ещё
      // может уведомлять про предыдущий звонок.
      if (_coordinatorTrackedOurCall && mounted) {
        Future<void>.microtask(_dismissCallScreen);
      }
      return;
    }
    _coordinatorTrackedOurCall = true;
    // Microphone publish failure surfaced — поднимаем snackbar один
    // раз на transition false → true. Без этого юзер видит «mic on»
    // иконку хотя собеседник его не слышит (Bug 1 root cause #2 per
    // AUDIT-2026-05-22). Action button предлагает retry — повторный
    // toggleMicrophone re-arm'нёт publish path.
    final micPublishFailed = widget.coordinator.microphonePublishFailed;
    if (micPublishFailed && !_lastMicrophonePublishFailed) {
      Future<void>.microtask(() {
        if (!mounted) {
          return;
        }
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 6),
            content: const Text(
              'Микрофон не подключился. Собеседник вас не слышит.',
            ),
            action: SnackBarAction(
              label: 'Повторить',
              onPressed: () {
                if (!mounted) {
                  return;
                }
                // Reset tracker — если retry снова fails, мы хотим
                // увидеть snackbar заново (а не silently swallow'нуть).
                _lastMicrophonePublishFailed = false;
                // Single toggle off→on (_microphoneEnabled уже false
                // потому что failure обнулило truthful UI state).
                unawaited(widget.coordinator.toggleMicrophone());
              },
            ),
          ),
        );
      });
    }
    _lastMicrophonePublishFailed = micPublishFailed;
    // Camera publish failure — тот же Q1-паттерн, что и микрофон выше:
    // snackbar один раз на false → true transition + «Повторить».
    final camPublishFailed = widget.coordinator.cameraPublishFailed;
    if (camPublishFailed && !_lastCameraPublishFailed) {
      Future<void>.microtask(() {
        if (!mounted) {
          return;
        }
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 6),
            content: const Text(
              'Камера не подключилась. Собеседник не видит видео.',
            ),
            action: SnackBarAction(
              label: 'Повторить',
              onPressed: () {
                if (!mounted) {
                  return;
                }
                // Reset tracker — если retry снова fails, показываем
                // snackbar заново (а не silently swallow'иваем).
                _lastCameraPublishFailed = false;
                // toggleCamera включит камеру заново: `_cameraEnabled`
                // уже false, потому что failure обнулило truthful state.
                unawaited(widget.coordinator.toggleCamera());
              },
            ),
          ),
        );
      });
    }
    _lastCameraPublishFailed = camPublishFailed;
    final previousState = _resolvedCall.state;
    setState(() {
      _call = coordinatorCall;
    });
    unawaited(_loadCallParticipantSummaries());
    // Re-evaluate ringer status whenever the call state mutates —
    // accept / decline / cancel / "joined on other device" all need
    // to silence the loop immediately.
    _syncRinger();
    _syncDurationTicker();
    // Lifecycle SFX: a soft chime when the line connects, a closing
    // descend when it ends. Skipped on first hop into ringing — the
    // ringer loop itself is the audio cue at that point.
    if (previousState != coordinatorCall.state) {
      if (previousState == CallState.ringing &&
          coordinatorCall.state == CallState.active) {
        _playOneShot('audio/connect.wav');
      } else if (!previousState.isTerminal &&
          coordinatorCall.state.isTerminal) {
        _playOneShot('audio/hangup.wav');
      }
    }
    // When a video call transitions to active, schedule the chrome
    // auto-hide so the user gets the full canvas after 3s.
    if (_isVideoCall && coordinatorCall.state == CallState.active) {
      _scheduleVideoChromeHide();
    }
    if (coordinatorCall.joinedOnAnotherDevice &&
        coordinatorCall.state == CallState.active) {
      Future<void>.microtask(() {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Звонок принят на другом устройстве'),
            duration: Duration(seconds: 2),
          ),
        );
        Navigator.of(context).maybePop(coordinatorCall);
      });
    }
  }

  Future<void> _acceptIncomingCall() async {
    try {
      final acceptedCall =
          await widget.coordinator.acceptCall(_resolvedCall.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _call = acceptedCall;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            humanizeError(error, fallback: 'Не удалось принять звонок.'),
          ),
        ),
      );
    }
  }

  Future<void> _joinActiveCall() async {
    try {
      final joinedCall =
          await widget.coordinator.joinActiveCall(_resolvedCall.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _call = joinedCall;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            humanizeError(error, fallback: 'Не удалось войти в звонок.'),
          ),
          // GP1: join can transiently fail (token race, brief network
          // blip) — a retry beats a dead-end snackbar.
          action: SnackBarAction(
            label: 'Ещё раз',
            onPressed: _joinActiveCall,
          ),
        ),
      );
    }
  }

  Future<void> _finishCall() async {
    // Дебаунс двойного тапа: сам API-вызов дедупится в координаторе
    // (memo-future), но второй maybePop здесь снял бы НИЖЕЛЕЖАЩИЙ роут
    // во время exit-анимации.
    if (_isFinishingCall) {
      return;
    }
    _isFinishingCall = true;
    try {
      final result = await widget.coordinator.finishCall(_resolvedCall.id);
      if (!mounted) {
        return;
      }
      Navigator.of(context).maybePop(result ?? _resolvedCall);
    } catch (_) {
    } finally {
      _isFinishingCall = false;
    }
  }

  /// Закрыть CallScreen надёжно: сперва снять СВОИ открытые шторки
  /// (аудио-маршрут / пикер устройств / чат — они живут на том же
  /// навигаторе), потом сам экран. Одиночный maybePop снимал только
  /// верхний роут — шторку — и экран зависал на терминальном состоянии
  /// (скаут 2026-07-04, stuck-path №1: _currentCall уже null, повторного
  /// notify не будет).
  void _dismissCallScreen() {
    if (!mounted || _dismissRequested) {
      return;
    }
    final navigator = Navigator.of(context);
    final ownRoute = ModalRoute.of(context);
    // Роут уже снят (exit-анимация, чужой pop): его нет в history —
    // popUntil никогда не нашёл бы предикат и слил бы ВЕСЬ стек до
    // первого роута (ревью батча). isActive == «ещё в history».
    if (ownRoute == null || !ownRoute.isActive) {
      return;
    }
    _dismissRequested = true;
    if (!ownRoute.isCurrent) {
      navigator.popUntil((route) => route == ownRoute || route.isFirst);
    }
    navigator.maybePop();
  }

  void _minimizeCall() {
    if (_resolvedCall.state == CallState.active) {
      unawaited(widget.pipService.enterPictureInPicture());
    }
    Navigator.of(context).maybePop(_resolvedCall);
  }

  Future<void> _toggleMicrophone() async {
    await widget.coordinator.toggleMicrophone();
    // Force a rebuild — the coordinator notifies its listeners but
    // edge cases (toggleMicrophone fast-failing, no notifyListeners)
    // would leave the icon stale.
    if (mounted) setState(() {});
  }

  Future<void> _toggleCamera() async {
    HapticFeedback.lightImpact();
    try {
      await widget.coordinator.toggleCamera();
    } catch (error) {
      debugPrint('toggleCamera failed: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Не удалось переключить камеру. Проверьте разрешение.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _switchCamera() async {
    try {
      await widget.coordinator.switchCamera();
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось переключить камеру.')),
      );
    }
  }

  Future<void> _openAudioRouteSheet() async {
    unawaited(_audioRouteService.refreshRoutes());
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _AudioRouteSheet(service: _audioRouteService),
    );
  }

  Future<void> _toggleSpeakerRoute() async {
    final routes = _audioRouteService.routes;
    AudioRouteOption? routeById(String id) =>
        routes.firstWhereOrNull((route) => route.id == id);

    final selectedType = _audioRouteService.selectedRoute?.type;
    final target = selectedType == AudioRouteType.speaker
        ? routeById('earpiece')
        : routeById('speaker');
    if (target == null) {
      await _openAudioRouteSheet();
      return;
    }

    HapticFeedback.lightImpact();
    await _audioRouteService.selectRoute(target);
    if (!mounted) return;
    final error = _audioRouteService.errorMessage;
    if (error != null && error.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    }
  }

  Future<void> _openDevicePickerSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => CallDevicePickerSheet(
        coordinator: widget.coordinator,
      ),
    );
  }

  Future<void> _openInCallChatSheet() async {
    final chatService = _chatService;
    if (chatService == null) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => InCallChatSheet(
        chatId: _resolvedCall.chatId,
        chatService: chatService,
      ),
    );
  }

  Future<void> _loadCallParticipantSummaries({bool force = false}) async {
    final chatId = _resolvedCall.chatId.trim();
    if (chatId.isEmpty) {
      return;
    }
    if (!force && _participantDetailsChatId == chatId) {
      return;
    }
    final chatService = _chatService;
    if (chatService == null) {
      return;
    }

    _participantDetailsChatId = chatId;
    try {
      final details = await chatService.getChatDetails(chatId);
      if (!mounted || _resolvedCall.chatId != chatId) {
        return;
      }
      setState(() {
        _callParticipantsById = <String, ChatParticipantSummary>{
          for (final participant in details.participants)
            if (participant.userId.trim().isNotEmpty)
              participant.userId.trim(): participant,
        };
      });
    } catch (_) {
      // The call screen can work without chat details; ids fall back
      // to generic labels. Avoid retry-spam on every coordinator tick.
    }
  }

  void _openSystemSettings() {
    unawaited(openAppSettings());
  }

  bool get _isGroupCall => _resolvedCall.isGroupCall;

  List<String> get _waitingGroupParticipantIds => _groupCallParticipants
      .where(
        (participant) =>
            !participant.isCurrentUser &&
            participant.state == _GroupCallParticipantConnectionState.waiting,
      )
      .map((participant) => participant.userId)
      .toList(growable: false);

  List<_GroupCallParticipantStatus> get _groupCallParticipants {
    final currentUserId = _currentUserId?.trim();
    final participantIds = <String>{
      for (final id in _resolvedCall.participantIds)
        if (id.trim().isNotEmpty) id.trim(),
      if (currentUserId != null && currentUserId.isNotEmpty) currentUserId,
    }.toList(growable: false);
    participantIds.sort((left, right) {
      if (left == currentUserId) return -1;
      if (right == currentUserId) return 1;
      return _participantLabelForCallUser(left)
          .compareTo(_participantLabelForCallUser(right));
    });

    return participantIds.map((userId) {
      final isCurrentUser = userId == currentUserId;
      final remoteParticipant = _remoteParticipantForUser(userId);
      final isConnected = isCurrentUser || remoteParticipant != null;
      final state = isConnected
          ? _GroupCallParticipantConnectionState.connected
          : (_resolvedCall.state == CallState.active ||
                  _resolvedCall.state == CallState.ringing)
              ? _GroupCallParticipantConnectionState.waiting
              : _GroupCallParticipantConnectionState.notConnected;
      return _GroupCallParticipantStatus(
        userId: userId,
        displayName:
            isCurrentUser ? 'Вы' : _participantLabelForCallUser(userId),
        photoUrl: _callParticipantsById[userId]?.photoUrl,
        state: state,
        isCurrentUser: isCurrentUser,
      );
    }).toList(growable: false);
  }

  RemoteParticipant? _remoteParticipantForUser(String userId) {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      return null;
    }
    return _remoteParticipants.firstWhereOrNull((participant) {
      final identity = participant.identity.trim();
      return identity == normalizedUserId ||
          identity.startsWith('$normalizedUserId#');
    });
  }

  String _participantLabelForCallUser(String userId) {
    final normalizedUserId = userId.trim();
    final summary = _callParticipantsById[normalizedUserId];
    final displayName = summary?.displayName.trim();
    if (displayName != null && displayName.isNotEmpty) {
      return displayName;
    }
    final remoteParticipant = _remoteParticipantForUser(normalizedUserId);
    if (remoteParticipant != null) {
      return resolveRemoteParticipantLabel(
        name: remoteParticipant.name,
        identity: remoteParticipant.identity,
        index: 0,
      );
    }
    if (normalizedUserId.length <= 8) {
      return 'Участник';
    }
    return 'Участник ${normalizedUserId.substring(0, 6)}';
  }

  Future<void> _nudgeWaitingGroupParticipants() async {
    final waitingIds = _waitingGroupParticipantIds;
    await _nudgeGroupParticipants(waitingIds);
  }

  Future<void> _nudgeGroupParticipant(String participantId) async {
    final normalizedParticipantId = participantId.trim();
    if (normalizedParticipantId.isEmpty) {
      return;
    }
    await _nudgeGroupParticipants(<String>[normalizedParticipantId]);
  }

  Future<void> _nudgeGroupParticipants(List<String> participantIds) async {
    final waitingIds = participantIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (waitingIds.isEmpty || _isNudgingGroupParticipants) {
      return;
    }
    setState(() => _isNudgingGroupParticipants = true);
    try {
      await widget.coordinator.nudgeCallParticipants(
        _resolvedCall.id,
        participantIds: waitingIds,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Повторно зовём: ${_formatParticipantCount(waitingIds.length)}',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              humanizeError(error, fallback: 'Не удалось позвать повторно.')),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isNudgingGroupParticipants = false);
      }
    }
  }

  // GP3: chat members not yet on this call — the candidates for «Добавить».
  List<ChatParticipantSummary> get _addableParticipants {
    final selfId = _currentUserId?.trim();
    final inCall = _resolvedCall.participantIds.toSet();
    return _callParticipantsById.values
        .where((participant) =>
            participant.userId.trim().isNotEmpty &&
            !inCall.contains(participant.userId) &&
            participant.userId != selfId)
        .toList(growable: false);
  }

  Future<void> _openAddParticipantSheet() async {
    if (_isAddingParticipant) {
      return;
    }
    final addable = _addableParticipants;
    if (addable.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Все участники чата уже в звонке.')),
      );
      return;
    }
    final pickedUserId = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Добавить в звонок',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ),
            ),
            for (final participant in addable)
              ListTile(
                leading: CircleAvatar(
                  backgroundImage:
                      buildAvatarImageProvider(participant.photoUrl),
                  child: buildAvatarImageProvider(participant.photoUrl) == null
                      ? Text(
                          participant.displayName.trim().isNotEmpty
                              ? participant.displayName.trim()[0].toUpperCase()
                              : '?',
                        )
                      : null,
                ),
                title: Text(participant.displayName),
                trailing: const Icon(Icons.person_add_alt_1),
                onTap: () => Navigator.of(context).pop(participant.userId),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || pickedUserId == null || pickedUserId.isEmpty) {
      return;
    }
    await _addParticipantsToCall(<String>[pickedUserId]);
  }

  Future<void> _addParticipantsToCall(List<String> participantIds) async {
    if (_isAddingParticipant) {
      return;
    }
    setState(() => _isAddingParticipant = true);
    try {
      await widget.coordinator.addCallParticipants(
        _resolvedCall.id,
        participantIds: participantIds,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Добавляем в звонок…')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            humanizeError(error, fallback: 'Не удалось добавить участника.'),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isAddingParticipant = false);
      }
    }
  }

  List<RemoteParticipant> get _remoteParticipants =>
      widget.coordinator.room?.remoteParticipants.values.toList() ??
      const <RemoteParticipant>[];

  RemoteParticipant? get _remoteParticipant => _remoteParticipants.firstOrNull;

  VideoTrack? get _remoteVideoTrack {
    final publication = _remoteParticipant?.videoTrackPublications
        .firstWhereOrNull((entry) => entry.source == TrackSource.camera);
    return publication?.track;
  }

  List<_VideoTileData> _videoTilesForGroup(VideoTrack? localVideoTrack) {
    return _groupCallParticipants.map((participant) {
      final remoteParticipant = participant.isCurrentUser
          ? null
          : _remoteParticipantForUser(participant.userId);
      final publication = remoteParticipant?.videoTrackPublications
          .firstWhereOrNull((entry) => entry.source == TrackSource.camera);
      final track =
          participant.isCurrentUser ? localVideoTrack : publication?.track;
      // GP4: mute + active-speaker per tile. Read at build — the
      // coordinator's catch-all on<RoomEvent> re-notifies on TrackMuted/
      // Unmuted and ActiveSpeakersChanged, so this reflects live state.
      final bool isMuted;
      final bool isSpeaking;
      if (participant.isCurrentUser) {
        isMuted = !widget.coordinator.microphoneEnabled;
        isSpeaking =
            widget.coordinator.room?.localParticipant?.isSpeaking ?? false;
      } else if (remoteParticipant != null) {
        final audioPublication =
            remoteParticipant.audioTrackPublications.firstOrNull;
        isMuted = audioPublication?.muted ?? false;
        isSpeaking = remoteParticipant.isSpeaking;
      } else {
        isMuted = false;
        isSpeaking = false;
      }
      return _VideoTileData(
        track: track,
        label: participant.displayName,
        statusLabel: _stageLabelForGroupParticipant(participant),
        photoUrl: participant.photoUrl,
        statusColor: _stateColorForGroupParticipant(participant.state),
        mirror: participant.isCurrentUser &&
            widget.coordinator.cameraPosition == CameraPosition.front,
        isMuted: isMuted,
        isSpeaking: isSpeaking,
      );
    }).toList(growable: false);
  }

  String _stageLabelForGroupParticipant(
    _GroupCallParticipantStatus participant,
  ) {
    if (participant.isCurrentUser) {
      return 'Вы в звонке';
    }
    switch (participant.state) {
      case _GroupCallParticipantConnectionState.connected:
        return 'В звонке';
      case _GroupCallParticipantConnectionState.waiting:
        return 'Ждём ответа';
      case _GroupCallParticipantConnectionState.notConnected:
        return 'Не подключился';
    }
  }

  Color _stateColorForGroupParticipant(
    _GroupCallParticipantConnectionState state,
  ) {
    switch (state) {
      case _GroupCallParticipantConnectionState.connected:
        return const Color(0xFF37B24D);
      case _GroupCallParticipantConnectionState.waiting:
        return const Color(0xFFFFC857);
      case _GroupCallParticipantConnectionState.notConnected:
        return const Color(0xFFADB5BD);
    }
  }

  VideoTrack? get _localVideoTrack {
    // Camera state has THREE inputs that all need to agree before we
    // render the local video tile:
    //   * the user-facing toggle (`coordinator.cameraEnabled`) — the
    //     intent we just expressed via `_toggleCamera`
    //   * the publication's `muted` flag — what livekit actually did
    //     server-side
    //   * the track being non-null — what's actually paintable
    //
    // Before this guard the getter only checked the publication, so
    // calling `setCameraEnabled(false)` (which mutes the track but
    // leaves the publication in place) left a frozen last-frame in
    // the PIP — the user reported "При видеозвонке видео не
    // отключается". Treating the muted publication or the user-side
    // disabled state as "no track" hides the tile immediately and
    // matches what the remote peer sees.
    if (!widget.coordinator.cameraEnabled) {
      return null;
    }
    final publication = widget
        .coordinator.room?.localParticipant?.videoTrackPublications
        .firstWhereOrNull((entry) => entry.source == TrackSource.camera);
    if (publication == null || publication.muted) {
      return null;
    }
    return publication.track;
  }

  bool get _showReconnectBanner =>
      _resolvedCall.state == CallState.active &&
      !widget.coordinator.hasMediaPermissionIssue &&
      // P1: before joining, the active call has no session and the
      // coordinator surfaces «Сеанс звонка ещё готовится» — that's not an
      // error here, the «Войти» button is the affordance. Suppress the
      // banner until the user has actually joined.
      !_canJoinActive &&
      (widget.coordinator.isReconnectingRoom ||
          widget.coordinator.showReconnectRestoredBanner ||
          widget.coordinator.connectionError != null);

  String _statusLabel() {
    if (widget.coordinator.isReconnectingRoom) {
      return 'Восстанавливаем соединение...';
    }
    if (widget.coordinator.isConnectingRoom) {
      return 'Подключаем звонок...';
    }
    if (widget.coordinator.connectionError != null &&
        _resolvedCall.state == CallState.active) {
      return widget.coordinator.connectionError!;
    }
    switch (_resolvedCall.state) {
      case CallState.ringing:
        return _isIncoming ? 'Входящий звонок' : 'Вызываем...';
      case CallState.active:
        if (widget.coordinator.room == null) {
          return 'Подключаем медиаканал...';
        }
        if (_isGroupCall) {
          if (_remoteParticipants.isEmpty) {
            return 'Ожидаем участников звонка...';
          }
          final connectedCount = _remoteParticipants.length + 1;
          final base = '${_formatParticipantCount(connectedCount)} в звонке';
          final duration = _callDurationText();
          return duration == null ? base : '$base · $duration';
        }
        if (_remoteParticipant == null) {
          return 'Ожидаем подключение собеседника...';
        }
        // Собеседник на линии — вместо статичного «Видеозвонок» /
        // «Аудиозвонок» показываем тикающую длительность (Telegram-
        // поведение). Fallback на старую метку, пока база не залатчена.
        return _callDurationText() ??
            (_isVideoCall ? 'Видеозвонок' : 'Аудиозвонок');
      case CallState.rejected:
        return 'Звонок отклонен';
      case CallState.cancelled:
        return 'Звонок отменен';
      case CallState.ended:
        return 'Звонок завершен';
      case CallState.missed:
        return 'Пропущенный звонок';
      case CallState.failed:
        return 'Не удалось начать звонок';
    }
  }

  /// Текущая длительность звонка «м:сс» / «ч:мм:сс», null пока звонок
  /// не стал active. Отрицательный дрейф серверного acceptedAt
  /// клампится в ноль.
  String? _callDurationText() {
    final since = widget.coordinator.activeSince;
    if (since == null) {
      return null;
    }
    var elapsed = DateTime.now().difference(since);
    if (elapsed.isNegative) {
      elapsed = Duration.zero;
    }
    return formatCallDuration(elapsed);
  }

  String _formatParticipantCount(int count) {
    final mod10 = count % 10;
    final mod100 = count % 100;
    final suffix = mod10 == 1 && mod100 != 11
        ? 'участник'
        : (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)
            ? 'участника'
            : 'участников');
    return '$count $suffix';
  }

  // Плотность: было 138/132/124dp (аватар без видео — единственный
  // визуальный контент экрана на пустом тёмном фоне, «огромный аватар»
  // из жалобы владельца). Пропорции кольца-индикатора качества и зазоров
  // сохранены (те же 3dp/4dp отступы между слоями), сам размер — под
  // порог 120dp.
  Widget _buildAvatar() {
    final avatarImage = buildAvatarImageProvider(widget.photoUrl);
    final quality = widget.coordinator.displayedConnectionQuality;
    final qualityColor = callConnectionQualityColor(
      quality,
      isReconnecting: widget.coordinator.isReconnectingRoom,
    );
    return SizedBox(
      width: 108,
      height: 108,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 102,
            height: 102,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: qualityColor.withValues(alpha: 0.92),
                width: 3,
              ),
            ),
          ),
          Container(
            width: 94,
            height: 94,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.12),
              image: avatarImage != null
                  ? DecorationImage(
                      image: avatarImage,
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: avatarImage == null
                ? Center(
                    child: Text(
                      widget.title.isNotEmpty
                          ? widget.title[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  )
                : null,
          ),
          Positioned(
            right: 2,
            bottom: 6,
            child: CallConnectionQualityBadge(
              quality: quality,
              isReconnecting: widget.coordinator.isReconnectingRoom,
              compact: true,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final remoteVideoTrack = _remoteVideoTrack;
    final localVideoTrack = _localVideoTrack;
    final groupVideoTiles = _videoTilesForGroup(localVideoTrack);
    final hasConnectedRoom = widget.coordinator.room != null;
    final showPermissionSettingsCta = _resolvedCall.state == CallState.active &&
        widget.coordinator.hasMediaPermissionIssue &&
        !hasConnectedRoom;

    return Scaffold(
      backgroundColor: const Color(0xFF111318),
      body: Stack(
        children: [
          Positioned.fill(
            // Tap-anywhere on the video stage toggles the chrome
            // visibility (title / status / quality badge). Audio
            // calls keep chrome pinned because there's nothing else
            // on screen to look at.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: (_isVideoCall && _resolvedCall.state == CallState.active)
                  ? _toggleVideoChromeVisibility
                  : null,
              // Stage normally shows the remote feed; when the user
              // taps the PIP and we swap, the local feed takes over
              // the full stage and the remote moves into the PIP.
              child: _pipShowsLocal || localVideoTrack == null
                  ? _CallStage(
                      isGroupCall: _isGroupCall,
                      remoteVideoTrack: remoteVideoTrack,
                      groupVideoTiles: groupVideoTiles,
                      fallbackAvatar: _buildAvatar(),
                    )
                  : _LocalFullStage(
                      track: localVideoTrack,
                      mirror: widget.coordinator.cameraPosition ==
                          CameraPosition.front,
                    ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.topLeft,
                    child: IconButton(
                      onPressed: _minimizeCall,
                      color: Colors.white,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      tooltip: 'Свернуть звонок',
                    ),
                  ),
                  const SizedBox(height: 12),
                  // On an active video call we auto-hide the title /
                  // status panel after 3s so the remote video gets the
                  // whole canvas. Tap-anywhere on the canvas brings it
                  // back. For audio calls + ringing we keep it pinned
                  // because there's nothing else to look at.
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    opacity: (_isVideoCall &&
                            _resolvedCall.state == CallState.active &&
                            !_videoChromeVisible)
                        ? 0.0
                        : 1.0,
                    child: IgnorePointer(
                      ignoring: _isVideoCall &&
                          _resolvedCall.state == CallState.active &&
                          !_videoChromeVisible,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: (_isVideoCall &&
                                _resolvedCall.state == CallState.active)
                            ? _toggleVideoChromeVisibility
                            : null,
                        child: GlassPanel(
                          // Экран звонка всегда тёмный (Scaffold 0xFF111318),
                          // но GlassPanel по умолчанию берёт цвет из АМБИЕНТНОЙ
                          // темы — в светлой теме панель выходит светло-бежевой,
                          // и жёстко-белые имя/статус на ней не читаются.
                          // Принудительно тёмное стекло, чтобы белый текст был
                          // виден независимо от темы устройства.
                          color: Colors.white.withValues(alpha: 0.10),
                          borderColor: Colors.white.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(22),
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: Column(
                            children: [
                              Text(
                                widget.title,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _statusLabel(),
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color:
                                          Colors.white.withValues(alpha: 0.82),
                                    ),
                                textAlign: TextAlign.center,
                              ),
                              if (_isGroupCall) ...[
                                const SizedBox(height: 12),
                                _GroupCallRoster(
                                  participants: _groupCallParticipants,
                                  isNudging: _isNudgingGroupParticipants,
                                  onNudgeWaiting:
                                      _waitingGroupParticipantIds.isEmpty
                                          ? null
                                          : _nudgeWaitingGroupParticipants,
                                  onNudgeParticipant: _nudgeGroupParticipant,
                                ),
                                // GP3: pull a new chat member into the live call.
                                if (_resolvedCall.state == CallState.active &&
                                    _addableParticipants.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  TextButton.icon(
                                    onPressed: _isAddingParticipant
                                        ? null
                                        : _openAddParticipantSheet,
                                    icon: const Icon(
                                      Icons.person_add_alt_1,
                                      size: 18,
                                    ),
                                    label: const Text('Добавить участника'),
                                    style: TextButton.styleFrom(
                                      foregroundColor: Colors.white,
                                    ),
                                  ),
                                ],
                              ],
                              if (_resolvedCall.state == CallState.active) ...[
                                const SizedBox(height: 12),
                                CallConnectionQualityBadge(
                                  quality: widget
                                      .coordinator.displayedConnectionQuality,
                                  isReconnecting:
                                      widget.coordinator.isReconnectingRoom,
                                ),
                              ],
                              if (_showReconnectBanner) ...[
                                const SizedBox(height: 12),
                                _ReconnectBanner(
                                  isReconnecting:
                                      widget.coordinator.isReconnectingRoom,
                                  isRestored: widget
                                      .coordinator.showReconnectRestoredBanner,
                                  message: widget.coordinator.connectionError,
                                ),
                              ],
                              if (showPermissionSettingsCta) ...[
                                const SizedBox(height: 12),
                                FilledButton.icon(
                                  onPressed: _openSystemSettings,
                                  icon: const Icon(Icons.settings_rounded),
                                  label: const Text('Открыть настройки'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  // PIP moved to a top-level Positioned in the outer
                  // Stack so it can be dragged + swapped freely.
                  const SizedBox(height: 8),
                  // Collapse / expand affordance — only relevant when the
                  // call is active and we actually have secondary controls
                  // to fold away. Tap toggles _actionsCollapsed; the
                  // AnimatedSize below cross-fades the row.
                  if (_resolvedCall.state == CallState.active &&
                      hasConnectedRoom)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _CollapseToggle(
                        collapsed: _actionsCollapsed,
                        onTap: () => setState(
                          () => _actionsCollapsed = !_actionsCollapsed,
                        ),
                      ),
                    ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.bottomCenter,
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 10,
                      children: [
                        if (_resolvedCall.state == CallState.active &&
                            hasConnectedRoom &&
                            !_actionsCollapsed) ...[
                          // Вторичные кнопки управления — 54dp (иконка 24 +
                          // паддинг 15), не 64: тач-таргет ≥52dp по гайду,
                          // но крупный размер оставлен только «Принять» /
                          // «Завершить» ниже — на них отвечают одной рукой.
                          AnimatedBuilder(
                            animation: _audioRouteService,
                            builder: (context, _) => _CallActionButton(
                              onPressed: _toggleSpeakerRoute,
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.14),
                              icon: _audioRouteIcon(
                                _audioRouteService.selectedRoute?.type,
                              ),
                              tooltip: _audioRouteTooltip(
                                _audioRouteService.selectedRoute,
                              ),
                              iconSize: 24,
                              buttonPadding: 15,
                            ),
                          ),
                          _CallActionButton(
                            onPressed: _toggleMicrophone,
                            backgroundColor:
                                Colors.white.withValues(alpha: 0.14),
                            icon: widget.coordinator.microphoneEnabled
                                ? Icons.mic_rounded
                                : Icons.mic_off_rounded,
                            tooltip: widget.coordinator.microphoneEnabled
                                ? 'Выключить микрофон'
                                : 'Включить микрофон',
                            iconSize: 24,
                            buttonPadding: 15,
                          ),
                          _CallActionButton(
                            onPressed: _openDevicePickerSheet,
                            backgroundColor:
                                Colors.white.withValues(alpha: 0.14),
                            icon: Icons.tune_rounded,
                            tooltip: 'Источники звука и видео',
                            iconSize: 24,
                            buttonPadding: 15,
                          ),
                          if (_chatService != null)
                            _CallActionButton(
                              onPressed: _openInCallChatSheet,
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.14),
                              icon: Icons.chat_bubble_outline_rounded,
                              tooltip: 'Чат во время звонка',
                              iconSize: 24,
                              buttonPadding: 15,
                            ),
                          // Camera toggle exposed for both audio AND
                          // video calls — pressing it inside an audio
                          // call enables the user's camera, effectively
                          // upgrading the call to video on their side.
                          // Same one-tap "switch to video" UX TG / WA
                          // have. Tooltip wording differs to make the
                          // intent clear in audio mode.
                          _CallActionButton(
                            onPressed: _toggleCamera,
                            backgroundColor:
                                Colors.white.withValues(alpha: 0.14),
                            icon: widget.coordinator.cameraEnabled
                                ? Icons.videocam_rounded
                                : Icons.videocam_off_rounded,
                            tooltip: widget.coordinator.cameraEnabled
                                ? 'Выключить камеру'
                                : (_isVideoCall
                                    ? 'Включить камеру'
                                    : 'Включить видео'),
                            iconSize: 24,
                            buttonPadding: 15,
                          ),
                          if (widget.coordinator.cameraEnabled)
                            _CallActionButton(
                              onPressed: widget.coordinator.isSwitchingCamera
                                  ? null
                                  : _switchCamera,
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.14),
                              icon: Icons.cameraswitch_rounded,
                              tooltip: 'Переключить камеру',
                              iconSize: 24,
                              buttonPadding: 15,
                            ),
                        ],
                        _CallActionButton(
                          onPressed: _finishCall,
                          backgroundColor: const Color(0xFFE5484D),
                          icon: Icons.call_end_rounded,
                          tooltip: 'Завершить звонок',
                        ),
                        if ((_resolvedCall.state == CallState.ringing &&
                                _isIncoming) ||
                            _canJoinActive)
                          _CallActionButton(
                            // «Принять» a ringing invite, «Войти» an
                            // already-active call you belong to (late-join).
                            onPressed: _canJoinActive
                                ? _joinActiveCall
                                : _acceptIncomingCall,
                            backgroundColor: const Color(0xFF2F9E44),
                            icon: _isVideoCall
                                ? Icons.videocam_rounded
                                : Icons.call_rounded,
                            tooltip: _canJoinActive
                                ? 'Войти в звонок'
                                : (_isVideoCall
                                    ? 'Принять видеозвонок'
                                    : 'Принять аудиозвонок'),
                            // Ringing → pulsing halos around accept so the
                            // primary CTA grabs attention without needing
                            // a separate "🟢 ВХОДЯЩИЙ" banner.
                            pulse: true,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Picture-in-picture for the secondary feed (local by
          // default, remote when swapped). Draggable across the
          // whole viewport with edge-snap on release; tap to swap
          // with the main stage.
          if (localVideoTrack != null && !_isGroupCall)
            _buildDraggablePip(
              context: context,
              localTrack: localVideoTrack,
              remoteTrack: remoteVideoTrack,
            ),
        ],
      ),
    );
  }

  Widget _buildDraggablePip({
    required BuildContext context,
    required VideoTrack localTrack,
    required VideoTrack? remoteTrack,
  }) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final pad = media.padding;
    // Default position: bottom-right, 16dp inside the safe area.
    final defaultOffset = Offset(
      size.width - _pipWidth - 16,
      size.height - _pipHeight - 16 - pad.bottom - 96,
    );
    final offset = _pipOffset ?? defaultOffset;
    // Currently-rendered feed in the PIP — swap flips this.
    final showLocal = _pipShowsLocal;
    final track = showLocal ? localTrack : (remoteTrack ?? localTrack);
    final mirror =
        showLocal && widget.coordinator.cameraPosition == CameraPosition.front;
    final fit = showLocal ? VideoViewFit.cover : VideoViewFit.contain;
    // Track whether the current pointer interaction has moved enough
    // to count as a drag. Without this, a quick tap that travels even
    // a few pixels was being claimed by the pan recogniser and the
    // swap never fired. We snapshot the start offset on pan-down and
    // only commit a drag when distance > _pipDragCommitThresholdDp
    // (3.0 — was 6.0, see field doc для Bug 4 tuning rationale).
    return Positioned(
      left: offset.dx,
      top: offset.dy,
      width: _pipWidth,
      height: _pipHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // dragStartBehavior.down → drag begins on touch-down without
        // the default 18px slop wait. Was the cause of "сначала надо
        // зажать и тянуть" — slop made the first finger movement
        // feel unresponsive.
        dragStartBehavior: DragStartBehavior.down,
        onTap: () {
          // Tap → swap which feed lives in the PIP. Only meaningful
          // when there's a remote track to swap with; otherwise the
          // tap is a no-op (PIP just shows local).
          if (remoteTrack == null) return;
          HapticFeedback.lightImpact();
          setState(() => _pipShowsLocal = !_pipShowsLocal);
        },
        onPanStart: (details) {
          _pipDragStartOffset = offset;
          _pipDragAccumulated = Offset.zero;
        },
        onPanUpdate: (details) {
          _pipDragAccumulated += details.delta;
          // Quick taps hit a few px of jitter before lifting. Treat
          // anything under threshold as "still a tap" — onPanEnd then
          // routes back through onTap. Past threshold we commit the
          // drag. Threshold lowered к 3dp (was 6) для snappier feel —
          // Bug 4 audit 2026-05-22.
          if (_pipDragAccumulated.distance < _pipDragCommitThresholdDp) {
            return;
          }
          final next = (_pipDragStartOffset ?? offset) + _pipDragAccumulated;
          // Clamp to viewport (minus PIP size + 8dp gutter so the
          // tile never disappears off the edge).
          final clamped = Offset(
            next.dx.clamp(8.0, size.width - _pipWidth - 8.0),
            next.dy.clamp(
              pad.top + 8.0,
              size.height - _pipHeight - pad.bottom - 8.0,
            ),
          );
          setState(() => _pipOffset = clamped);
        },
        onPanEnd: (details) {
          // If the user barely moved, treat as a tap-swap. Same
          // threshold as onPanUpdate commit — symmetry between
          // «moved enough to drag» and «moved too much for tap».
          if (_pipDragAccumulated.distance < _pipDragCommitThresholdDp) {
            if (remoteTrack != null) {
              HapticFeedback.lightImpact();
              setState(() => _pipShowsLocal = !_pipShowsLocal);
            }
            _pipDragStartOffset = null;
            return;
          }
          // Snap to nearest horizontal edge (left or right) for the
          // TG / WA "magnet" feel — vertical position stays where the
          // user dropped it.
          final mid = size.width / 2;
          final snapX = offset.dx + _pipWidth / 2 < mid
              ? 8.0
              : size.width - _pipWidth - 8.0;
          setState(() => _pipOffset = Offset(snapX, offset.dy));
          _pipDragStartOffset = null;
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.42),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: VideoTrackRenderer(
              track,
              fit: fit,
              mirrorMode:
                  mirror ? VideoViewMirrorMode.mirror : VideoViewMirrorMode.off,
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-stage local-camera renderer used when the PIP swap puts the
/// local track on the main stage. Mirror always on (front camera
/// case) — back camera swap is rare and would require dynamic
/// detection here.
class _LocalFullStage extends StatelessWidget {
  const _LocalFullStage({required this.track, required this.mirror});
  final VideoTrack track;
  final bool mirror;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: Colors.black),
      child: VideoTrackRenderer(
        track,
        fit: VideoViewFit.cover,
        mirrorMode:
            mirror ? VideoViewMirrorMode.mirror : VideoViewMirrorMode.off,
      ),
    );
  }
}

/// Формат длительности звонка: «м:сс», после часа — «ч:мм:сс».
@visibleForTesting
String formatCallDuration(Duration elapsed) {
  final totalSeconds = elapsed.inSeconds < 0 ? 0 : elapsed.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${two(minutes)}:${two(seconds)}';
  }
  return '$minutes:${two(seconds)}';
}

/// Adaptive fit (Telegram/WhatsApp-поведение): ориентации видео и сцены
/// совпадают → cover (небольшой crop, максимум картинки); сильный
/// мисматч (собеседник повернул телефон) → contain (полный кадр с
/// полосами вместо жёсткого центрального кропа). Порог 1.6 — отношение
/// аспектов: 16:9-видео на 19.5:9-экране (1.22) кропится, landscape
/// 16:9 на portrait-сцене (~3.8) letterbox'ится. Неизвестный аспект
/// (кадры ещё не пошли) → contain, прежнее безопасное поведение.
@visibleForTesting
VideoViewFit resolveAdaptiveVideoFit({
  required double? videoAspect,
  required double? stageAspect,
}) {
  if (videoAspect == null ||
      stageAspect == null ||
      videoAspect <= 0 ||
      stageAspect <= 0) {
    return VideoViewFit.contain;
  }
  final mismatch = videoAspect > stageAspect
      ? videoAspect / stageAspect
      : stageAspect / videoAspect;
  return mismatch <= 1.6 ? VideoViewFit.cover : VideoViewFit.contain;
}

/// Remote-видео с динамическим fit'ом по живым размерам кадра.
///
/// В livekit_client 2.7.0 нет события об изменении dimensions
/// publication'а, а `renderer.onResize` безусловно перезаписывается
/// внутри VideoTrackRenderer._attach — поэтому заводим СВОЙ
/// RTCVideoRenderer (он ValueNotifier: didTextureChangeVideoSize /
/// Rotation дёргают notifyListeners) и отдаём его как cachedRenderer.
/// autoDisposeRenderer:false — им владеем мы, dispose наш.
class _AdaptiveFitVideo extends StatefulWidget {
  const _AdaptiveFitVideo({required this.track, this.mirror = false});

  final VideoTrack track;
  final bool mirror;

  @override
  State<_AdaptiveFitVideo> createState() => _AdaptiveFitVideoState();
}

class _AdaptiveFitVideoState extends State<_AdaptiveFitVideo> {
  rtc.RTCVideoRenderer? _renderer;
  double? _videoAspect;

  @override
  void initState() {
    super.initState();
    unawaited(_initRenderer());
  }

  Future<void> _initRenderer() async {
    final renderer = rtc.RTCVideoRenderer();
    try {
      await renderer.initialize();
    } catch (_) {
      // Нет текстур (flutter_test / экзотическая платформа) — остаёмся
      // на fallback-рендере со статичным contain.
      unawaited(renderer.dispose());
      return;
    }
    if (!mounted) {
      unawaited(renderer.dispose());
      return;
    }
    renderer.addListener(_handleFrameMetrics);
    setState(() => _renderer = renderer);
  }

  @override
  void didUpdateWidget(covariant _AdaptiveFitVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.track, widget.track)) {
      // Плитка получила другой трек (reorder в группе) — аспект старого
      // трека больше не факт; до первых кадров нового — contain.
      _videoAspect = null;
    }
  }

  void _handleFrameMetrics() {
    final value = _renderer?.value;
    if (value == null || value.width <= 0 || value.height <= 0) {
      return;
    }
    final aspect = value.aspectRatio; // rotation-aware
    if (aspect == _videoAspect || !mounted) {
      return;
    }
    setState(() => _videoAspect = aspect);
  }

  @override
  void dispose() {
    _renderer?.removeListener(_handleFrameMetrics);
    unawaited(_renderer?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final renderer = _renderer;
    if (renderer == null) {
      // Инициализация renderer'а — миллисекунды (раньше первого кадра);
      // до готовности и при сбое — прежний contain-путь. ValueKey ниже
      // форсит remount при готовности: VideoTrackRenderer не подхватывает
      // смену cachedRenderer через didUpdateWidget.
      return VideoTrackRenderer(
        widget.track,
        key: const ValueKey('adaptive-fit-fallback'),
        fit: VideoViewFit.contain,
        mirrorMode: widget.mirror
            ? VideoViewMirrorMode.mirror
            : VideoViewMirrorMode.off,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final hasBoundedStage = constraints.hasBoundedWidth &&
            constraints.hasBoundedHeight &&
            constraints.maxHeight > 0;
        final fit = resolveAdaptiveVideoFit(
          videoAspect: _videoAspect,
          stageAspect: hasBoundedStage
              ? constraints.maxWidth / constraints.maxHeight
              : null,
        );
        return VideoTrackRenderer(
          widget.track,
          key: const ValueKey('adaptive-fit-live'),
          cachedRenderer: renderer,
          autoDisposeRenderer: false,
          fit: fit,
          mirrorMode: widget.mirror
              ? VideoViewMirrorMode.mirror
              : VideoViewMirrorMode.off,
        );
      },
    );
  }
}

IconData _audioRouteIcon(AudioRouteType? type) {
  switch (type) {
    case AudioRouteType.speaker:
      return Icons.volume_up_rounded;
    case AudioRouteType.earpiece:
      return Icons.phone_in_talk_rounded;
    case AudioRouteType.bluetooth:
      return Icons.bluetooth_audio_rounded;
    case AudioRouteType.wired:
      return Icons.headphones_rounded;
    case AudioRouteType.device:
    case null:
      return Icons.spatial_audio_off_rounded;
  }
}

String _audioRouteTooltip(AudioRouteOption? route) {
  switch (route?.type) {
    case AudioRouteType.speaker:
      return 'Переключить на наушник';
    case AudioRouteType.earpiece:
      return 'Переключить на динамик';
    case AudioRouteType.bluetooth:
    case AudioRouteType.wired:
    case AudioRouteType.device:
    case null:
      final label = route?.label;
      if (label == null || label.isEmpty) {
        return 'Аудиовыход';
      }
      return 'Аудиовыход: $label';
  }
}

class _CallStage extends StatelessWidget {
  const _CallStage({
    required this.isGroupCall,
    required this.remoteVideoTrack,
    required this.groupVideoTiles,
    required this.fallbackAvatar,
  });

  final bool isGroupCall;
  final VideoTrack? remoteVideoTrack;
  final List<_VideoTileData> groupVideoTiles;
  final Widget fallbackAvatar;

  @override
  Widget build(BuildContext context) {
    if (isGroupCall && groupVideoTiles.isNotEmpty) {
      // Adaptive grid: scales the column count and aspect ratio so 3,
      // 4, 5+ participants all fit visibly. Was hard-coded to 2-col +
      // 0.88 aspect with `NeverScrollableScrollPhysics`, which dropped
      // tiles 5+ off the bottom of the viewport with no scroll.
      // Bottom padding tightened from 220 → 160 to claw back vertical
      // room for the bigger grids. We keep scrolling enabled when
      // we'd otherwise overflow.
      final count = groupVideoTiles.length;
      final crossAxisCount = count <= 2
          ? 1
          : count <= 4
              ? 2
              : count <= 9
                  ? 3
                  : 4;
      return DecoratedBox(
        decoration: _stageDecoration,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 84, 12, 160),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isWide =
                    constraints.maxWidth > constraints.maxHeight * 1.18;
                final adaptiveCrossAxisCount =
                    isWide && count <= 4 ? count : crossAxisCount;
                final rowCount = (count / adaptiveCrossAxisCount).ceil();
                const spacing = 10.0;
                final tileWidth = (constraints.maxWidth -
                        spacing * (adaptiveCrossAxisCount - 1)) /
                    adaptiveCrossAxisCount;
                final tileHeight =
                    (constraints.maxHeight - spacing * (rowCount - 1)) /
                        rowCount;
                final adaptiveAspectRatio =
                    (tileWidth / tileHeight).clamp(0.72, 1.85).toDouble();
                final shouldScroll = count > 4 || tileHeight < 132;

                return GridView.builder(
                  physics: shouldScroll
                      ? const ClampingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: adaptiveCrossAxisCount,
                    crossAxisSpacing: spacing,
                    mainAxisSpacing: spacing,
                    childAspectRatio: adaptiveAspectRatio,
                  ),
                  itemCount: count,
                  itemBuilder: (context, index) => _RemoteVideoTile(
                    tile: groupVideoTiles[index],
                  ),
                );
              },
            ),
          ),
        ),
      );
    }

    if (remoteVideoTrack != null) {
      return _AdaptiveFitVideo(track: remoteVideoTrack!);
    }

    return DecoratedBox(
      decoration: _stageDecoration,
      child: Center(child: fallbackAvatar),
    );
  }

  static const BoxDecoration _stageDecoration = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color(0xFF1A202C),
        Color(0xFF0F1722),
        Color(0xFF201A27),
      ],
    ),
  );
}

class _VideoTileData {
  const _VideoTileData({
    required this.track,
    required this.label,
    required this.statusLabel,
    required this.statusColor,
    this.mirror = false,
    this.photoUrl,
    this.isMuted = false,
    this.isSpeaking = false,
  });

  final VideoTrack? track;
  final String label;
  final String statusLabel;
  final Color statusColor;
  final bool mirror;
  final String? photoUrl;
  // GP4: mic muted → mic-off badge; active speaker → highlighted tile border.
  // Camera-off is already conveyed by the avatar fallback (track == null).
  final bool isMuted;
  final bool isSpeaking;
}

enum _GroupCallParticipantConnectionState {
  connected,
  waiting,
  notConnected,
}

class _GroupCallParticipantStatus {
  const _GroupCallParticipantStatus({
    required this.userId,
    required this.displayName,
    required this.state,
    required this.isCurrentUser,
    this.photoUrl,
  });

  final String userId;
  final String displayName;
  final String? photoUrl;
  final _GroupCallParticipantConnectionState state;
  final bool isCurrentUser;
}

class _GroupCallRoster extends StatelessWidget {
  const _GroupCallRoster({
    required this.participants,
    required this.isNudging,
    this.onNudgeWaiting,
    this.onNudgeParticipant,
  });

  final List<_GroupCallParticipantStatus> participants;
  final bool isNudging;
  final VoidCallback? onNudgeWaiting;
  final ValueChanged<String>? onNudgeParticipant;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connectedCount = participants
        .where(
          (participant) =>
              participant.state ==
              _GroupCallParticipantConnectionState.connected,
        )
        .length;
    final waitingCount = participants
        .where(
          (participant) =>
              participant.state == _GroupCallParticipantConnectionState.waiting,
        )
        .length;
    final visibleParticipants = participants.take(8).toList(growable: false);
    final hiddenCount = participants.length - visibleParticipants.length;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.54),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.groups_2_rounded,
                  size: 18,
                  color: Colors.white.withValues(alpha: 0.88),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    waitingCount == 0
                        ? '$connectedCount в звонке'
                        : '$connectedCount в звонке · $waitingCount ждут',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (waitingCount > 0) ...[
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: isNudging ? null : onNudgeWaiting,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: isNudging
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.notifications_active_rounded),
                    label: const Text('Позвать ещё'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ...visibleParticipants.map(
                  (participant) => _GroupCallParticipantChip(
                    participant,
                    isNudging: isNudging,
                    onNudge: participant.state ==
                                _GroupCallParticipantConnectionState.waiting &&
                            !participant.isCurrentUser
                        ? onNudgeParticipant
                        : null,
                  ),
                ),
                if (hiddenCount > 0)
                  _GroupCallOverflowChip(hiddenCount: hiddenCount),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupCallParticipantChip extends StatelessWidget {
  const _GroupCallParticipantChip(
    this.participant, {
    required this.isNudging,
    this.onNudge,
  });

  final _GroupCallParticipantStatus participant;
  final bool isNudging;
  final ValueChanged<String>? onNudge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stateColor = _stateColor(participant.state);
    final avatarImage = buildAvatarImageProvider(participant.photoUrl);
    final initial = participant.displayName.trim().isNotEmpty
        ? participant.displayName.trim()[0].toUpperCase()
        : '?';

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 188),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.36),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 5, 10, 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  CircleAvatar(
                    radius: 13,
                    backgroundColor: Colors.white.withValues(alpha: 0.18),
                    backgroundImage: avatarImage,
                    child: avatarImage == null
                        ? Text(
                            initial,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          )
                        : null,
                  ),
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: stateColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF111318),
                          width: 1.5,
                        ),
                      ),
                      child: const SizedBox(width: 8, height: 8),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      participant.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      _stateLabel(participant.state),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.72),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (onNudge != null) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Позвать ${participant.displayName}',
                  child: InkResponse(
                    onTap:
                        isNudging ? null : () => onNudge!(participant.userId),
                    radius: 18,
                    child: Icon(
                      Icons.notifications_active_rounded,
                      size: 17,
                      color: isNudging
                          ? Colors.white.withValues(alpha: 0.38)
                          : Colors.white,
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

  Color _stateColor(_GroupCallParticipantConnectionState state) {
    switch (state) {
      case _GroupCallParticipantConnectionState.connected:
        return const Color(0xFF37B24D);
      case _GroupCallParticipantConnectionState.waiting:
        return const Color(0xFFF59F00);
      case _GroupCallParticipantConnectionState.notConnected:
        return const Color(0xFFADB5BD);
    }
  }

  String _stateLabel(_GroupCallParticipantConnectionState state) {
    switch (state) {
      case _GroupCallParticipantConnectionState.connected:
        return 'В звонке';
      case _GroupCallParticipantConnectionState.waiting:
        return 'Ждём';
      case _GroupCallParticipantConnectionState.notConnected:
        return 'Не подключился';
    }
  }
}

class _GroupCallOverflowChip extends StatelessWidget {
  const _GroupCallOverflowChip({required this.hiddenCount});

  final int hiddenCount;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.36),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Text(
          '+$hiddenCount',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
        ),
      ),
    );
  }
}

/// G1: подпись плитки участника группового звонка — имя, иначе identity,
/// иначе позиционный фолбэк «Участник N». Вынесено для юнит-тестов
/// (без мока LiveKit Room).
@visibleForTesting
String resolveRemoteParticipantLabel({
  required String name,
  required String identity,
  required int index,
}) {
  final trimmedName = name.trim();
  if (trimmedName.isNotEmpty) {
    return trimmedName;
  }
  final trimmedIdentity = identity.trim();
  if (trimmedIdentity.isNotEmpty) {
    return trimmedIdentity;
  }
  return 'Участник ${index + 1}';
}

class _RemoteVideoTile extends StatelessWidget {
  const _RemoteVideoTile({
    required this.tile,
  });

  final _VideoTileData tile;

  @override
  Widget build(BuildContext context) {
    final track = tile.track;
    final theme = Theme.of(context);
    final avatarImage = buildAvatarImageProvider(tile.photoUrl);
    final initial =
        tile.label.trim().isNotEmpty ? tile.label.trim()[0].toUpperCase() : '?';
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          // GP4: active speaker → green highlighted border (2.5px). Inside
          // the ClipRRect a border reads better than a shadow glow (shadows
          // are clipped). Idle tiles keep the faint 1px hairline.
          border: Border.all(
            color: tile.isSpeaking
                ? const Color(0xFF37B24D)
                : Colors.white.withValues(alpha: 0.10),
            width: tile.isSpeaking ? 2.5 : 1,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (track != null)
              _AdaptiveFitVideo(track: track, mirror: tile.mirror)
            else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 34,
                      backgroundColor: Colors.white.withValues(alpha: 0.16),
                      backgroundImage: avatarImage,
                      child: avatarImage == null
                          ? Text(
                              initial,
                              style: theme.textTheme.headlineMedium?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: tile.statusColor,
                            shape: BoxShape.circle,
                          ),
                          child: const SizedBox(width: 8, height: 8),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          tile.statusLabel,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: Colors.white.withValues(alpha: 0.78),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            Positioned(
              left: 10,
              bottom: 10,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.68),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // GP4: mic-off badge in front of the name when muted.
                      if (tile.isMuted) ...[
                        const Icon(
                          Icons.mic_off_rounded,
                          size: 13,
                          color: Color(0xFFFF8787),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Text(
                        tile.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AudioRouteSheet extends StatelessWidget {
  const _AudioRouteSheet({required this.service});

  final AudioRouteService service;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: AnimatedBuilder(
        animation: service,
        builder: (context, _) {
          final routes = service.routes;
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.spatial_audio_off_rounded),
                    const SizedBox(width: 10),
                    Text(
                      'Аудиовыход',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (service.isRefreshing && routes.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: CircularProgressIndicator(),
                    ),
                  )
                else if (routes.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Аудиовыходы не найдены.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  ...routes.map(
                    (route) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(_audioRouteIcon(route.type)),
                      title: Text(route.label),
                      trailing: service.isSelecting &&
                              service.selectedRouteId == route.id
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : service.selectedRouteId == route.id
                              ? Icon(
                                  Icons.check_rounded,
                                  color: theme.colorScheme.primary,
                                )
                              : null,
                      onTap: service.isSelecting
                          ? null
                          : () async {
                              await service.selectRoute(route);
                              if (context.mounted &&
                                  service.errorMessage == null) {
                                Navigator.of(context).pop();
                              }
                            },
                    ),
                  ),
                if (service.errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    service.errorMessage!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ReconnectBanner extends StatelessWidget {
  const _ReconnectBanner({
    required this.isReconnecting,
    required this.isRestored,
    this.message,
  });

  final bool isReconnecting;
  final bool isRestored;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = isReconnecting
        ? 'Восстанавливаем звонок. Звук вернётся автоматически.'
        : isRestored
            ? 'Соединение восстановлено.'
            : message ?? 'Проверяем соединение.';
    final color = isRestored
        ? const Color(0xFF4ADE80)
        : isReconnecting
            ? const Color(0xFFFFC857)
            : const Color(0xFFEF4444);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.56)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isRestored ? Icons.check_circle_rounded : Icons.sync_rounded,
                  color: color,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    text,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
            if (isReconnecting) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 4,
                  color: color,
                  backgroundColor: Colors.white.withValues(alpha: 0.16),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Round call-action button with two animation polish layers:
///
/// 1. Icon cross-fade + scale when [icon] changes — used for mic /
///    camera / speaker toggles so the change reads as a state flip
///    instead of a hard swap.
/// 2. Subtle scale-on-press feedback (1.0 → 0.92 → 1.0) so the round
///    surface feels "pressable" without needing a Material ripple
///    (which doesn't read as well on a translucent dark background).
///
/// Optional [pulse] flag makes the surrounding container breathe — used
/// on the incoming-call accept button so it grabs attention while the
/// call is ringing.
class _CallActionButton extends StatefulWidget {
  const _CallActionButton({
    required this.onPressed,
    required this.backgroundColor,
    required this.icon,
    required this.tooltip,
    this.pulse = false,
    this.iconSize = 28,
    this.buttonPadding = 18,
  });

  final VoidCallback? onPressed;
  final Color backgroundColor;
  final IconData icon;
  final String tooltip;
  final bool pulse;
  // Дефолты (28 + 18*2 = 64dp) — обязательный тач-таргет для «Принять» /
  // «Завершить» (на звонок отвечают одной рукой, часто старшие). Вторичные
  // кнопки (микрофон, динамик, камера и т.п.) передают меньшие значения —
  // см. вызовы ниже — но не опускаются ниже 52dp.
  final double iconSize;
  final double buttonPadding;

  @override
  State<_CallActionButton> createState() => _CallActionButtonState();
}

class _CallActionButtonState extends State<_CallActionButton>
    with TickerProviderStateMixin {
  late final AnimationController _press;
  AnimationController? _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      lowerBound: 0.0,
      upperBound: 1.0,
    );
    if (widget.pulse) {
      _pulseCtrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400),
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _CallActionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulse && _pulseCtrl == null) {
      _pulseCtrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400),
      );
    } else if (!widget.pulse && _pulseCtrl != null) {
      _pulseCtrl!.dispose();
      _pulseCtrl = null;
    }
    _syncPulse();
  }

  /// Start / stop the pulse loop. We skip the loop entirely under
  /// flutter_test's `AutomatedTestWidgetsFlutterBinding` because an
  /// infinite-`repeat()` keeps pumpAndSettle from ever settling. We
  /// also honour `MediaQuery.disableAnimations` for users with
  /// "reduce motion" enabled at the OS level. Comparing the binding
  /// type by name avoids importing flutter_test from production code.
  void _syncPulse() {
    final ctrl = _pulseCtrl;
    if (ctrl == null) return;
    final disable = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    final inTest = bindingName.contains('TestWidgetsFlutterBinding');
    if (disable || inTest) {
      ctrl.stop();
      ctrl.value = 0;
    } else if (!ctrl.isAnimating) {
      ctrl.repeat();
    }
  }

  @override
  void dispose() {
    _press.dispose();
    _pulseCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onPressed == null;
    final bgColor = disabled
        ? widget.backgroundColor.withValues(alpha: 0.45)
        : widget.backgroundColor;
    final core = AnimatedBuilder(
      animation: _press,
      builder: (context, child) {
        // 1.0 → 0.92 on press, eased back. _press is driven via
        // GestureDetector taps below.
        final scale = 1.0 - 0.08 * _press.value;
        return Transform.scale(scale: scale, child: child);
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bgColor,
          shape: BoxShape.circle,
        ),
        child: IconButton(
          onPressed: widget.onPressed,
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: Tween<double>(begin: 0.7, end: 1.0).animate(animation),
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: Icon(widget.icon, key: ValueKey<IconData>(widget.icon)),
          ),
          color: Colors.white,
          iconSize: widget.iconSize,
          padding: EdgeInsets.all(widget.buttonPadding),
          tooltip: widget.tooltip,
        ),
      ),
    );

    final pressable = Listener(
      onPointerDown: (_) {
        if (!disabled) _press.forward();
      },
      onPointerUp: (_) => _press.reverse(),
      onPointerCancel: (_) => _press.reverse(),
      child: core,
    );

    final pulseCtrl = _pulseCtrl;
    if (pulseCtrl == null) {
      return pressable;
    }
    return AnimatedBuilder(
      animation: pulseCtrl,
      builder: (context, child) {
        // 0 → 1 cycle. We layer two halos that fade out as they expand
        // so the button looks like it's pulsing rings outward — same
        // pattern Telegram / WhatsApp use on incoming-call accept.
        final t = pulseCtrl.value;
        return Stack(
          alignment: Alignment.center,
          children: [
            for (final phase in const [0.0, 0.5])
              Builder(
                builder: (context) {
                  final localT = ((t + phase) % 1.0).clamp(0.0, 1.0);
                  final scale = 1.0 + 0.55 * localT;
                  final opacity = (1.0 - localT) * 0.48;
                  return IgnorePointer(
                    child: Opacity(
                      opacity: opacity,
                      child: Transform.scale(
                        scale: scale,
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: bgColor,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            child!,
          ],
        );
      },
      child: pressable,
    );
  }
}

/// Slim glassy chevron pill above the call action row. Tapping toggles
/// the actions row between full (mic / audio / camera / chat / device)
/// and minimal (just the end-call button + accept if ringing). Lets the
/// user reclaim canvas height during a video call without sacrificing
/// the ability to hang up.
class _CollapseToggle extends StatelessWidget {
  const _CollapseToggle({
    required this.collapsed,
    required this.onTap,
  });

  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: collapsed ? 'Показать управление' : 'Скрыть управление',
      child: Material(
        color: Colors.white.withValues(alpha: 0.14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  collapsed
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Text(
                  collapsed ? 'Управление' : 'Свернуть',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.92),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.1,
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
