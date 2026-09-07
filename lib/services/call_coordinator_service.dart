import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
// hide ConnectionState: Flutter's async ConnectionState collides with
// LiveKit's room ConnectionState; this file only needs LiveKit's.
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../backend/interfaces/call_service_interface.dart';
import '../models/call_event.dart';
import '../models/call_invite.dart';
import '../models/call_media_mode.dart';
import '../models/call_state.dart';
import 'android_incoming_call_service.dart';
import 'audio_route_service.dart';
import 'call_foreground_service.dart';
import 'call_preferences.dart';
import 'custom_api_realtime_service.dart';
import 'rustore_service.dart';

typedef MediaPermissionRequester = Future<bool> Function(
  CallMediaMode mediaMode,
);
typedef CameraPositionSwitcher = Future<void> Function(
  LocalVideoTrack track,
  CameraPosition position,
);
typedef CallMediaDeviceEnumerator = Future<List<MediaDevice>> Function();
typedef CallMediaDeviceSelector = Future<void> Function(
  Room room,
  MediaDevice device,
);
typedef CallVibrationTrigger = Future<void> Function();
// Гигиена звонков (2026-07-04): держатель экрана на время живого звонка.
// Seam — тесты инжектят рекордер вместо реального WakelockPlus (platform
// channel в flutter_test кидает MissingPluginException).
typedef CallWakelockToggler = Future<void> Function(bool enable);

class CallCoordinatorService extends ChangeNotifier
    with WidgetsBindingObserver {
  static const AudioEncoding _callAudioEncoding = AudioEncoding(
    maxBitrate: 32000,
    bitratePriority: Priority.high,
  );
  // ВАЖНО: без bitratePriority. LiveKit подставляет его только в верхний
  // simulcast-слой, авто-слои q/h остаются с дефолтным low, а нативный
  // WebRTC требует одинаковый bitrate_priority у всех encodings — иначе
  // addTransceiver падает целиком («C++ addTransceiver failed», камера
  // не публикуется вовсе). Санитайзер в _publishLocalCamera страхует
  // это инвариантом на случай будущих правок профиля.
  static const VideoEncoding _callVideoEncoding = VideoEncoding(
    maxFramerate: 30,
    maxBitrate: 2000 * 1000,
  );
  static const RoomOptions _callRoomOptions = RoomOptions(
    defaultCameraCaptureOptions: CameraCaptureOptions(
      params: VideoParametersPresets.h720_169,
      maxFrameRate: 30,
    ),
    defaultAudioCaptureOptions: AudioCaptureOptions(
      noiseSuppression: true,
      echoCancellation: true,
      autoGainControl: true,
      highPassFilter: true,
      voiceIsolation: true,
      typingNoiseDetection: true,
    ),
    defaultAudioPublishOptions: AudioPublishOptions(
      encoding: _callAudioEncoding,
      dtx: true,
      red: true,
    ),
    defaultVideoPublishOptions: VideoPublishOptions(
      videoEncoding: _callVideoEncoding,
      simulcast: true,
      degradationPreference: DegradationPreference.balanced,
      backupVideoCodec: BackupVideoCodec(enabled: false),
    ),
    adaptiveStream: true,
    dynacast: true,
  );
  static const ConnectOptions _callConnectOptions = ConnectOptions(
    rtcConfiguration: RTCConfiguration(isDscpEnabled: true),
  );

  CallCoordinatorService({
    required CallServiceInterface callService,
    CustomApiRealtimeService? realtimeService,
    Stream<RustorePushMessage>? pushMessages,
    MediaPermissionRequester? mediaPermissionRequester,
    AudioRouteService? audioRouteService,
    CameraPositionSwitcher? cameraPositionSwitcher,
    CallMediaDeviceEnumerator? audioInputEnumerator,
    CallMediaDeviceEnumerator? videoInputEnumerator,
    CallMediaDeviceSelector? microphoneDeviceSelector,
    CallMediaDeviceSelector? cameraDeviceSelector,
    CallPreferences? callPreferences,
    AndroidIncomingCallService? androidIncomingCallService,
    CallForegroundService? callForegroundService,
    CallVibrationTrigger? vibrationTrigger,
    CallWakelockToggler? wakelockToggler,
    Duration ringingRecoveryInterval = const Duration(seconds: 2),
    Duration activeCallRecoveryInterval = const Duration(seconds: 2),
  })  : _callService = callService,
        _realtimeService = realtimeService,
        _pushMessages = pushMessages,
        _audioRouteService = audioRouteService ?? AudioRouteService(),
        _cameraPositionSwitcher =
            cameraPositionSwitcher ?? _switchLiveKitCameraPosition,
        _audioInputEnumerator =
            audioInputEnumerator ?? _defaultAudioInputEnumerator,
        _videoInputEnumerator =
            videoInputEnumerator ?? _defaultVideoInputEnumerator,
        _microphoneDeviceSelector =
            microphoneDeviceSelector ?? _selectLiveKitMicrophoneDevice,
        _cameraDeviceSelector =
            cameraDeviceSelector ?? _selectLiveKitCameraDevice,
        _callPreferences = callPreferences ?? const DisabledCallPreferences(),
        _androidIncomingCallService = androidIncomingCallService,
        _callForegroundService = callForegroundService,
        _vibrationTrigger = vibrationTrigger ?? _defaultVibrationTrigger,
        _wakelockToggler = wakelockToggler ?? _defaultWakelockToggler,
        _ringingRecoveryInterval = ringingRecoveryInterval,
        _activeCallRecoveryInterval = activeCallRecoveryInterval,
        _mediaPermissionRequester =
            mediaPermissionRequester ?? _requestPlatformMediaPermissions {
    WidgetsFlutterBinding.ensureInitialized();
    WidgetsBinding.instance.addObserver(this);
    _callEventsSubscription = _callService.events.listen(_handleCallEvent);
    final activeRealtimeService = _realtimeService;
    if (activeRealtimeService != null) {
      _realtimeSubscription = activeRealtimeService.events.listen((event) {
        if (event.type == 'connection.ready') {
          unawaited(resync());
        }
      });
    }
    final activePushMessages = _pushMessages;
    if (activePushMessages != null) {
      _pushSubscription = activePushMessages.listen(_handlePushMessage);
    }
    unawaited(_androidIncomingCallService?.registerPhoneAccount());
    unawaited(ensureRuntimeReady());
    unawaited(_handlePendingAndroidCallAction());
    // Proximity-политика зависит от аудио-маршрута (ушной/динамик) —
    // пересчитываем её на каждую смену маршрута.
    _audioRouteService.addListener(_handleAudioRouteChanged);
  }

  final CallServiceInterface _callService;
  final CustomApiRealtimeService? _realtimeService;
  final Stream<RustorePushMessage>? _pushMessages;
  final MediaPermissionRequester _mediaPermissionRequester;
  final AudioRouteService _audioRouteService;
  final CameraPositionSwitcher _cameraPositionSwitcher;
  final CallMediaDeviceEnumerator _audioInputEnumerator;
  final CallMediaDeviceEnumerator _videoInputEnumerator;
  final CallMediaDeviceSelector _microphoneDeviceSelector;
  final CallMediaDeviceSelector _cameraDeviceSelector;
  final CallPreferences _callPreferences;
  final AndroidIncomingCallService? _androidIncomingCallService;
  // Foreground service для активного звонка (Bug A 2026-05-22).
  // Запускается на active transition, обновляется на mic toggle /
  // peer name resolved, останавливается на terminal. Null на
  // non-Android либо когда test'ы инжектят null explicitly.
  final CallForegroundService? _callForegroundService;
  // Tracks current foreground-service active callId — null когда
  // service не запущен. Reused чтобы избежать redundant start
  // calls (idempotency на rapid `_applyCall(active)` re-fires).
  String? _foregroundServiceCallId;
  final CallVibrationTrigger _vibrationTrigger;
  final CallWakelockToggler _wakelockToggler;
  final Duration _ringingRecoveryInterval;
  final Duration _activeCallRecoveryInterval;

  StreamSubscription<CallEvent>? _callEventsSubscription;
  StreamSubscription<CustomApiRealtimeEvent>? _realtimeSubscription;
  StreamSubscription<RustorePushMessage>? _pushSubscription;
  Future<void>? _runtimeReadyFuture;
  Future<void>? _androidCallActionFuture;
  Timer? _ringingRecoveryTimer;
  Timer? _activeCallRecoveryTimer;
  Timer? _reconnectRestoredTimer;
  // P2: never let the «Переподключение» overlay wedge forever — if the
  // LiveKit transport is actually live while the flag is still up, this
  // watchdog force-clears it.
  Timer? _reconnectWatchdogTimer;
  String? _ringingRecoveryCallId;
  String? _activeCallRecoveryCallId;

  CallInvite? _currentCall;
  // Гигиена звонков: текущее желаемое состояние wakelock'а — guard от
  // повторных platform-вызовов на каждый recovery-snapshot (2s poll).
  bool _wakelockActive = false;
  // Момент, когда звонок стал active — база для таймера длительности.
  // Латчится ОДИН раз на звонок (`??=`): recovery-snapshot'ы и
  // reconnect'ы не сбрасывают отсчёт. Серверный acceptedAt
  // предпочтительнее (переживает рестарт приложения), локальный
  // DateTime.now() — fallback для снапшотов без acceptedAt.
  DateTime? _activeSince;
  Room? _room;
  EventsListener<RoomEvent>? _roomListener;
  String? _connectedRoomName;
  DateTime? _roomConnectStartedAt;
  bool _isConnectingRoom = false;
  bool _isReconnectingRoom = false;
  // P2: re-entrancy latch for an ACTUAL in-flight room connect. Kept
  // SEPARATE from the _isReconnectingRoom DISPLAY flag — previously
  // _handleRoomDisconnected set _isReconnectingRoom=true and then the
  // reconnect it triggered early-returned on that same flag (deadlock),
  // so the room never reconnected and «Переподключение» stuck forever
  // while audio was actually live.
  bool _connectAttemptInFlight = false;
  bool _microphoneEnabled = true;
  // True когда LiveKit вернул успех на `setMicrophoneEnabled(true)` но
  // фактическая publication отсутствует (publication == null либо
  // `isMicrophoneEnabled()` после await вернул false). Симптом
  // соответствует Артёмов reported Bug 1 «собеседник не слышит» —
  // UI showed «mic on» хотя трек не публиковался. Surface'им через
  // separate flag чтобы CallScreen мог поднять banner / snackbar и
  // юзер увидел real state вместо silent fail.
  bool _microphonePublishFailed = false;
  // Камерный аналог `_microphonePublishFailed`: publish упал (нативный
  // отказ addTransceiver, permission, HAL) — UI обязан показать честное
  // «камера не подключилась» вместо перечёркнутой иконки без объяснений.
  bool _cameraPublishFailed = false;
  bool _cameraEnabled = false;
  bool _isSwitchingCamera = false;
  CameraPosition _cameraPosition = CameraPosition.front;
  List<MediaDevice> _microphoneDevices = const <MediaDevice>[];
  List<MediaDevice> _cameraDevices = const <MediaDevice>[];
  String? _selectedMicrophoneDeviceId;
  String? _selectedCameraDeviceId;
  bool _isRefreshingInputDevices = false;
  bool _isSelectingMediaDevice = false;
  String? _devicePickerErrorMessage;
  ConnectionQuality _localConnectionQuality = ConnectionQuality.unknown;
  ConnectionQuality _remoteConnectionQuality = ConnectionQuality.unknown;
  bool _showReconnectRestoredBanner = false;
  String? _connectionError;
  bool _hasMediaPermissionIssue = false;
  bool _hasSeenRemoteParticipant = false;
  bool _joinedOnAnotherDevice = false;
  String? _lastIncomingVibrationCallId;
  final Set<String> _visibleCallScreenIds = <String>{};
  final Set<String> _locallyStartedCallIds = <String>{};
  // Caller display names captured from VKPNS push payloads, keyed
  // by callId. Push delivery beats the realtime hydrate (the push
  // arrives before the GET /v1/calls/:id response lands), so we
  // park the name here and pull it out when the Telecom-side
  // showIncomingCall fires from _applyCall.
  final Map<String, String> _pushCallerNames = <String, String>{};
  // Native incoming-call UIs (self-managed Telecom connection + ringtone
  // notification) currently shown, keyed by callId. This is a SET, not a
  // single slot: a superseded/orphaned incoming call (rapid successive
  // calls, or one that ends server-side while a different call is
  // _currentCall) must still be torn down — otherwise its Telecom
  // connection strands on paired watches and holds MODE_RINGTONE, killing
  // the phone's volume buttons. De-dupes showIncomingCall too (a call can
  // fan out via both push and notification.created realtime).
  final Set<String> _shownNativeIncomingCallIds = <String>{};

  String? get currentUserId => _callService.currentUserId;
  CallInvite? get currentCall => _currentCall;

  /// Момент перехода текущего звонка в active — база таймера
  /// длительности в UI. Null пока звонок не active (и после конца).
  DateTime? get activeSince => _activeSince;
  Room? get room => _room;
  bool get isConnectingRoom => _isConnectingRoom;
  bool get isReconnectingRoom => _isReconnectingRoom;
  bool get joinedOnAnotherDevice => _joinedOnAnotherDevice;
  bool get microphoneEnabled => _microphoneEnabled;

  /// True если попытка enable microphone в активном звонке отказала
  /// silently — `setMicrophoneEnabled(true)` либо вернул null
  /// publication, либо `isMicrophoneEnabled()` после await вернул
  /// false. CallScreen listens и поднимает banner/snackbar чтобы
  /// surface'ить факт пользователю (без этого UI lies about mic
  /// state и собеседник просто не слышит).
  bool get microphonePublishFailed => _microphonePublishFailed;

  /// True если попытка включить камеру не дошла до публикации —
  /// CallScreen поднимает snackbar с «Повторить» (Q1-паттерн микрофона).
  bool get cameraPublishFailed => _cameraPublishFailed;
  bool get cameraEnabled => _cameraEnabled;
  bool get isSwitchingCamera => _isSwitchingCamera;
  CameraPosition get cameraPosition => _cameraPosition;
  List<MediaDevice> get microphoneDevices => _microphoneDevices;
  List<MediaDevice> get cameraDevices => _cameraDevices;
  String? get selectedMicrophoneDeviceId => _selectedMicrophoneDeviceId;
  String? get selectedCameraDeviceId => _selectedCameraDeviceId;
  bool get isRefreshingInputDevices => _isRefreshingInputDevices;
  bool get isSelectingMediaDevice => _isSelectingMediaDevice;
  String? get devicePickerErrorMessage => _devicePickerErrorMessage;
  ConnectionQuality get localConnectionQuality => _localConnectionQuality;
  ConnectionQuality get remoteConnectionQuality {
    if (_isReconnectingRoom) {
      return ConnectionQuality.lost;
    }
    if (_remoteConnectionQuality != ConnectionQuality.unknown) {
      return _remoteConnectionQuality;
    }
    final participants = _room?.remoteParticipants.values;
    if (participants == null) {
      return ConnectionQuality.unknown;
    }
    // Group calls have N remotes — surface the WORST link, not the first seen.
    return _worstRemoteQuality(participants.map((p) => p.connectionQuality));
  }

  ConnectionQuality get displayedConnectionQuality {
    if (_isReconnectingRoom || _connectionError != null) {
      return ConnectionQuality.lost;
    }
    final remoteQuality = remoteConnectionQuality;
    if (remoteQuality != ConnectionQuality.unknown) {
      return remoteQuality;
    }
    return _localConnectionQuality;
  }

  bool get showReconnectRestoredBanner => _showReconnectRestoredBanner;
  String? get connectionError => _connectionError;
  bool get hasMediaPermissionIssue => _hasMediaPermissionIssue;
  AudioRouteService get audioRouteService => _audioRouteService;

  bool isCallScreenVisible(String? callId) {
    if (callId == null || callId.isEmpty) {
      return false;
    }
    return _visibleCallScreenIds.contains(callId);
  }

  bool isLocallyStartedCall(String? callId) {
    final normalizedCallId = callId?.trim();
    if (normalizedCallId == null || normalizedCallId.isEmpty) {
      return false;
    }
    return _locallyStartedCallIds.contains(normalizedCallId);
  }

  void setCallScreenVisible(
    String callId, {
    required bool isVisible,
  }) {
    if (callId.isEmpty) {
      return;
    }
    final hasChanged = isVisible
        ? _visibleCallScreenIds.add(callId)
        : _visibleCallScreenIds.remove(callId);
    if (hasChanged) {
      notifyListeners();
    }
  }

  Future<CallInvite?> hydrateIncomingCall({
    String? callId,
    String? chatId,
  }) async {
    final currentUser = currentUserId?.trim();
    if (currentUser == null || currentUser.isEmpty) {
      return null;
    }

    final activeCall = _currentCall;
    final normalizedCallId = callId?.trim();
    if (activeCall != null &&
        !activeCall.state.isTerminal &&
        (normalizedCallId == null ||
            normalizedCallId.isEmpty ||
            activeCall.id == normalizedCallId)) {
      return activeCall;
    }

    try {
      CallInvite? nextCall;
      if (normalizedCallId != null && normalizedCallId.isNotEmpty) {
        nextCall = await _callService.getCall(normalizedCallId);
      }
      final normalizedChatId = chatId?.trim();
      nextCall ??= await _callService.getActiveCall(chatId: normalizedChatId);
      // Global fallback only makes sense when the first lookup was actually
      // scoped to a chat — otherwise it's the exact same request repeated
      // (perf: this used to fire unconditionally, doubling GET
      // /v1/calls/active on every cold-start incoming-call check).
      if (nextCall == null &&
          normalizedChatId != null &&
          normalizedChatId.isNotEmpty) {
        nextCall = await _callService.getActiveCall();
      }
      if (nextCall == null || nextCall.state.isTerminal) {
        return null;
      }
      await _applyCall(nextCall);
      return nextCall;
    } catch (_) {
      return null;
    }
  }

  Future<void> activateCall(CallInvite call) async {
    await _applyCall(call);
  }

  // GP5: a one-shot "the user explicitly asked to see this call now" flag. Set
  // by requestForegroundPresentation (e.g. tapping «Позвонить» on a chat whose
  // call is already live but was minimized). The runtime host consumes it to
  // force-present, overriding a stale dismissal (_suppressedCallId).
  String? _foregroundPresentationCallId;

  // Bring an already-live call to the foreground on an EXPLICIT user request,
  // overriding any prior minimize/dismiss. _applyCall can early-return via the
  // ignore-gate without notifying when the call is unchanged (the exact case:
  // the user minimized this very call), so force a notify to make the host
  // re-evaluate and consume the request.
  Future<void> requestForegroundPresentation(CallInvite call) async {
    if (call.state.isTerminal) {
      return;
    }
    _foregroundPresentationCallId = call.id;
    await _applyCall(call);
    notifyListeners();
  }

  bool consumeForegroundPresentationRequest(String callId) {
    if (_foregroundPresentationCallId != null &&
        _foregroundPresentationCallId == callId) {
      _foregroundPresentationCallId = null;
      return true;
    }
    return false;
  }

  Future<void> ensureRuntimeReady() {
    final existingFuture = _runtimeReadyFuture;
    if (existingFuture != null) {
      return existingFuture;
    }

    final completer = Completer<void>();
    _runtimeReadyFuture = completer.future;
    unawaited(() async {
      try {
        await _callService.startRealtimeBridge();
        await resync();
        completer.complete();
      } catch (_) {
        _runtimeReadyFuture = null;
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    }());
    return completer.future;
  }

  Future<void> _handlePendingAndroidCallAction() {
    final existingFuture = _androidCallActionFuture;
    if (existingFuture != null) {
      return existingFuture;
    }

    final future = _consumePendingAndroidCallAction();
    _androidCallActionFuture = future;
    future.whenComplete(() {
      if (identical(_androidCallActionFuture, future)) {
        _androidCallActionFuture = null;
      }
    });
    return future;
  }

  Future<void> _consumePendingAndroidCallAction() async {
    final service = _androidIncomingCallService;
    if (service == null) {
      return;
    }

    final action = await service.consumePendingAction();
    if (action == null) {
      return;
    }

    await ensureRuntimeReady();
    final call = await hydrateIncomingCall(
      callId: action.callId,
      chatId: action.chatId,
    );
    if (call == null) {
      return;
    }

    if (action.isAccept) {
      if (call.state == CallState.ringing &&
          call.isIncomingFor(currentUserId ?? '')) {
        await acceptCall(call.id);
      } else {
        await activateCall(call);
      }
      return;
    }

    if (action.isReject || action.isDisconnect) {
      await finishCall(call.id);
    }
  }

  /// Consume pending action from foreground service notification
  /// button tap. Called on app resume — если юзер ткнул «Микрофон»
  /// либо «Завершить» в notification action, бэкенд (Kotlin bridge)
  /// сохранил action в SharedPreferences, мы вычитываем + applyим.
  /// No-op если service не инжектирован либо нет pending action.
  Future<void> _consumePendingForegroundNotificationAction() async {
    final service = _callForegroundService;
    if (service == null || !service.isSupported) {
      return;
    }
    final action = await service.consumePendingNotificationAction();
    if (action == null) {
      return;
    }
    final activeCall = _currentCall;
    if (activeCall == null || activeCall.id != action.callId) {
      // Action для другого звонка — ignore (звонок мог уже завершиться).
      return;
    }
    if (action.isToggleMic) {
      await toggleMicrophone();
      return;
    }
    if (action.isEndCall) {
      await finishCall(action.callId);
    }
  }

  Future<CallInvite?> getCall(String callId) {
    return _callService.getCall(callId);
  }

  Future<CallInvite?> getActiveCall({String? chatId}) {
    return _callService.getActiveCall(chatId: chatId);
  }

  Future<CallInvite?> resync({String? chatId}) async {
    final currentUser = currentUserId?.trim();
    if (currentUser == null || currentUser.isEmpty) {
      if (chatId == null || _currentCall?.chatId == chatId) {
        await _applyCall(null);
      }
      return null;
    }

    try {
      final activeCall = await _callService.getActiveCall(chatId: chatId);
      if (activeCall == null) {
        if (chatId == null || _currentCall?.chatId == chatId) {
          await _applyCall(null);
        }
        return null;
      }

      await _applyCall(activeCall);
      return activeCall;
    } catch (_) {
      return null;
    }
  }

  Future<CallInvite?> refreshCurrentCall() async {
    final currentCall = _currentCall;
    if (currentCall == null) {
      return null;
    }
    final refreshedCall = await _callService.getCall(currentCall.id);
    await _applyCall(refreshedCall);
    return refreshedCall;
  }

  Future<CallInvite> startCall({
    required String chatId,
    required CallMediaMode mediaMode,
    List<String>? participantIds,
  }) async {
    final invite = await _callService.startCall(
      chatId: chatId,
      mediaMode: mediaMode,
      participantIds: participantIds,
    );
    final normalizedCallId = invite.id.trim();
    if (normalizedCallId.isNotEmpty) {
      _locallyStartedCallIds.add(normalizedCallId);
    }
    await _applyCall(invite);
    return invite;
  }

  Future<CallInvite> nudgeCallParticipants(
    String callId, {
    List<String>? participantIds,
  }) async {
    final invite = await _callService.nudgeCallParticipants(
      callId,
      participantIds: participantIds,
    );
    if (_currentCall?.id == invite.id) {
      await _applyCall(invite);
    }
    return invite;
  }

  /// GP3: add NEW chat members to the live call. Feature-detects the
  /// [CallParticipantAdder] capability (only the live backend implements it)
  /// so the base [CallServiceInterface] — and every fake — stays untouched.
  /// Re-applies the grown roster to the current call so the UI updates.
  Future<CallInvite> addCallParticipants(
    String callId, {
    required List<String> participantIds,
  }) async {
    final service = _callService;
    if (service is CallParticipantAdder) {
      final adder = service as CallParticipantAdder;
      final invite = await adder.addCallParticipants(
        callId,
        participantIds: participantIds,
      );
      if (_currentCall?.id == invite.id) {
        await _applyCall(invite);
      }
      return invite;
    }
    throw UnsupportedError(
      'Добавление участников не поддерживается этим бэкендом',
    );
  }

  // Дебаунс lifecycle-действий (UX-аудит P1): double-tap по «Принять»/
  // «Завершить» на лагающем устройстве давал дубль state-dependent
  // API-вызова (повторный reject/cancel/hangUp по уже меняющемуся
  // звонку). Memo-future: повторный вызов для того же callId получает
  // УЖЕ идущую операцию. Покрывает все входы разом — кнопки экрана,
  // Telecom pending actions, кнопки FGS-уведомления.
  Future<CallInvite>? _acceptInFlight;
  String? _acceptInFlightCallId;
  Future<CallInvite>? _joinInFlight;
  String? _joinInFlightCallId;
  Future<CallInvite?>? _finishInFlight;
  String? _finishInFlightCallId;

  Future<CallInvite> acceptCall([String? callId]) {
    final resolvedCallId = callId ?? _currentCall?.id;
    if (resolvedCallId == null || resolvedCallId.isEmpty) {
      throw StateError('Нет активного звонка для принятия.');
    }
    final inFlight = _acceptInFlight;
    if (inFlight != null && _acceptInFlightCallId == resolvedCallId) {
      return inFlight;
    }
    late final Future<CallInvite> future;
    Future<CallInvite> run() async {
      try {
        final invite = await _callService.acceptCall(resolvedCallId);
        await _applyCall(invite);
        return invite;
      } finally {
        // Чистим memo ТОЛЬКО если он всё ещё наш: медленный accept
        // звонка A не должен затирать memo уже стартовавшего B.
        if (identical(_acceptInFlight, future)) {
          _acceptInFlight = null;
          _acceptInFlightCallId = null;
        }
      }
    }

    future = run();
    _acceptInFlight = future;
    _acceptInFlightCallId = resolvedCallId;
    return future;
  }

  /// P1: «залететь в группу» — enter an already-active group call the user
  /// belongs to but hasn't joined yet. POST /join mints the per-participant
  /// token, then _applyCall connects to the room exactly like accept.
  Future<CallInvite> joinActiveCall([String? callId]) {
    final resolvedCallId = callId ?? _currentCall?.id;
    if (resolvedCallId == null || resolvedCallId.isEmpty) {
      throw StateError('Нет звонка для входа.');
    }
    final inFlight = _joinInFlight;
    if (inFlight != null && _joinInFlightCallId == resolvedCallId) {
      return inFlight;
    }
    late final Future<CallInvite> future;
    Future<CallInvite> run() async {
      try {
        final invite = await _callService.joinCall(resolvedCallId);
        await _applyCall(invite);
        return invite;
      } finally {
        if (identical(_joinInFlight, future)) {
          _joinInFlight = null;
          _joinInFlightCallId = null;
        }
      }
    }

    future = run();
    _joinInFlight = future;
    _joinInFlightCallId = resolvedCallId;
    return future;
  }

  Future<CallInvite?> finishCall([String? callId]) {
    final resolvedForDedup = callId ?? _currentCall?.id;
    final inFlight = _finishInFlight;
    if (inFlight != null &&
        resolvedForDedup != null &&
        _finishInFlightCallId == resolvedForDedup) {
      return inFlight;
    }
    late final Future<CallInvite?> future;
    Future<CallInvite?> run() async {
      try {
        return await _finishCallInner(callId);
      } finally {
        if (identical(_finishInFlight, future)) {
          _finishInFlight = null;
          _finishInFlightCallId = null;
        }
      }
    }

    future = run();
    if (resolvedForDedup != null) {
      _finishInFlight = future;
      _finishInFlightCallId = resolvedForDedup;
    }
    return future;
  }

  Future<CallInvite?> _finishCallInner(String? callId) async {
    final activeCall = _currentCall;
    final resolvedCallId = callId ?? activeCall?.id;
    if (resolvedCallId == null || resolvedCallId.isEmpty) {
      return null;
    }

    CallInvite? result;
    final callToFinish = resolvedCallId == activeCall?.id
        ? activeCall
        : await _callService.getCall(resolvedCallId);
    if (callToFinish == null) {
      await _applyCall(null);
      return null;
    }

    if (callToFinish.state == CallState.ringing) {
      if (callToFinish.isIncomingFor(currentUserId ?? '')) {
        result = await _callService.rejectCall(resolvedCallId);
      } else {
        result = await _callService.cancelCall(resolvedCallId);
      }
    } else if (callToFinish.state == CallState.active) {
      result = await _callService.hangUp(resolvedCallId);
    } else {
      result = callToFinish;
    }

    await _applyCall(result);
    return result;
  }

  Future<void> toggleMicrophone() async {
    final room = _room;
    if (room == null) {
      return;
    }

    final nextValue = !_microphoneEnabled;
    if (nextValue) {
      // Re-enable path — verify publication actually attached иначе
      // юзер увидит «mic on» а собеседник продолжит nothing hear.
      final published = await _publishLocalMicrophone(room);
      _microphonePublishFailed = !published;
      // Fix A (2026-05-22): без этой строки `_microphoneEnabled`
      // застревал в false после un-mute, и UI showed «mic off» хотя
      // publication успешно active (Bug 2 desync). _publishLocalMicrophone
      // только sets к false на failure; success case caller обязан
      // explicitly toggle к true.
      _microphoneEnabled = published;
    } else {
      try {
        await room.localParticipant?.setMicrophoneEnabled(false);
      } catch (error) {
        debugPrint('[call] toggle mic off threw: $error');
      }
      _microphoneEnabled = false;
      // Mute не может «silent fail» в смысле Bug 1 — даже если
      // localParticipant.setMicrophoneEnabled(false) кидает, эффект
      // юзеру (микрофон тише) хуже-не-станет. Clear publish failure
      // flag — следующий enable retry'нется свежим.
      _microphonePublishFailed = false;
    }
    notifyListeners();
    // Update Android foreground notification чтобы action button
    // label «Заглушить/Включить микрофон» reflected actual state.
    unawaited(_updateForegroundService());
  }

  Future<void> toggleCamera() async {
    final room = _room;
    final activeCall = _currentCall;
    // Was: also bailed when `!activeCall.mediaMode.isVideo`. That
    // turned the camera-toggle button into a no-op inside audio
    // calls, blocking the "upgrade to video" path the user asked
    // for. We now allow the toggle in any active call as long as
    // there's a live room — flipping the local camera on/off is a
    // pure local-participant operation.
    if (room == null || activeCall == null) {
      return;
    }

    final nextValue = !_cameraEnabled;
    if (nextValue) {
      // Enable-путь зеркалит микрофон (Q1): проверяем что публикация
      // реально состоялась, иначе иконка врала бы «камера включена»
      // при молчаливом фейле (Samsung S20 FE, 2026-07-04: нативный
      // addTransceiver отверг simulcast-энкодинги — камера открылась
      // на HAL, но в комнату не публиковалась, без единой ошибки в UI).
      final published = await _publishLocalCamera(room);
      _cameraPublishFailed = !published;
      _cameraEnabled = published;
    } else {
      try {
        await room.localParticipant?.setCameraEnabled(
          false,
          cameraCaptureOptions: _cameraCaptureOptionsFor(room),
        );
      } catch (error) {
        debugPrint('[call] toggle camera off threw: $error');
      }
      // Выключение не может «навредить» юзеру — состояние honest-off,
      // flag чистим чтобы следующий enable retry'нулся свежим.
      _cameraEnabled = false;
      _cameraPublishFailed = false;
    }
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final track = _localCameraTrack();
    if (track == null || _isSwitchingCamera) {
      return;
    }

    final nextPosition = _cameraPosition.switched();
    _isSwitchingCamera = true;
    notifyListeners();
    try {
      await _cameraPositionSwitcher(track, nextPosition);
      _cameraPosition = nextPosition;
      _selectedCameraDeviceId = null;
      _cameraEnabled = true;
    } finally {
      _isSwitchingCamera = false;
      notifyListeners();
    }
  }

  Future<void> refreshInputDevices() async {
    if (_isRefreshingInputDevices) {
      return;
    }
    _isRefreshingInputDevices = true;
    _devicePickerErrorMessage = null;
    notifyListeners();
    try {
      final results = await Future.wait<List<MediaDevice>>([
        _audioInputEnumerator(),
        _videoInputEnumerator(),
      ]);
      _microphoneDevices = List<MediaDevice>.unmodifiable(results[0]);
      _cameraDevices = List<MediaDevice>.unmodifiable(results[1]);
      _selectedMicrophoneDeviceId = _resolveSelectedDeviceId(
        _microphoneDevices,
        _selectedMicrophoneDeviceId,
      );
      _selectedCameraDeviceId = _resolveSelectedDeviceId(
        _cameraDevices,
        _selectedCameraDeviceId,
      );
    } catch (_) {
      _devicePickerErrorMessage =
          'Не удалось обновить список микрофонов и камер.';
    } finally {
      _isRefreshingInputDevices = false;
      notifyListeners();
    }
  }

  Future<void> selectMicrophoneDevice(MediaDevice device) async {
    final room = _room;
    if (room == null || _isSelectingMediaDevice) {
      return;
    }
    _isSelectingMediaDevice = true;
    _devicePickerErrorMessage = null;
    notifyListeners();
    try {
      await _microphoneDeviceSelector(room, device);
      _selectedMicrophoneDeviceId = device.deviceId;
    } catch (_) {
      _devicePickerErrorMessage = 'Не удалось выбрать микрофон.';
    } finally {
      _isSelectingMediaDevice = false;
      notifyListeners();
    }
  }

  Future<void> selectCameraDevice(MediaDevice device) async {
    final room = _room;
    if (room == null || _isSelectingMediaDevice) {
      return;
    }
    _isSelectingMediaDevice = true;
    _devicePickerErrorMessage = null;
    notifyListeners();
    try {
      await _cameraDeviceSelector(room, device);
      _selectedCameraDeviceId = device.deviceId;
      _cameraPosition = _cameraPositionFromDevice(device) ?? _cameraPosition;
      _cameraEnabled = true;
    } catch (_) {
      _devicePickerErrorMessage = 'Не удалось выбрать камеру.';
    } finally {
      _isSelectingMediaDevice = false;
      notifyListeners();
    }
  }

  Future<void> _applyCall(CallInvite? nextCall) async {
    final currentCall = _currentCall;
    // A terminal snapshot must ALWAYS tear down its native incoming UI,
    // even when it isn't the tracked _currentCall — a superseded/orphaned
    // call reaches terminal while a different call is current, and both the
    // ignore-gate (_shouldIgnoreCallSnapshot) and the terminal branch below
    // return early for a non-current call. Without this, the orphan's
    // Telecom connection strands on paired watches + holds MODE_RINGTONE.
    if (nextCall != null && nextCall.state.isTerminal) {
      _dismissNativeIncomingCall(nextCall.id);
    }
    if (nextCall == null) {
      if (currentCall != null) {
        _pushCallerNames.remove(currentCall.id);
        _locallyStartedCallIds.remove(currentCall.id);
      }
      // No active call server-side → sweep every shown native incoming UI,
      // not just _currentCall's (rapid successive calls can leave more than
      // one Telecom connection registered).
      _dismissStaleNativeIncomingCalls();
      _cancelRingingRecovery();
      _cancelActiveCallRecovery();
      _currentCall = null;
      _isConnectingRoom = false;
      _isReconnectingRoom = false;
      _isSwitchingCamera = false;
      _cameraPosition = CameraPosition.front;
      _clearInputDeviceState();
      _connectionError = null;
      _hasMediaPermissionIssue = false;
      _microphonePublishFailed = false;
      _cameraPublishFailed = false;
      _hasSeenRemoteParticipant = false;
      _joinedOnAnotherDevice = false;
      _lastIncomingVibrationCallId = null;
      _activeSince = null;
      _clearConnectionQualityState();
      notifyListeners();
      await _setWakelockActive(false);
      await _stopForegroundService(force: true);
      await _disposeRoom();
      return;
    }

    if (nextCall.state.isTerminal) {
      _locallyStartedCallIds.remove(nextCall.id);
    }

    if (_shouldIgnoreCallSnapshot(nextCall)) {
      return;
    }

    if (nextCall.state.isTerminal) {
      if (currentCall == null || currentCall.id != nextCall.id) {
        return;
      }
      _dismissNativeIncomingCall(nextCall.id);
      _pushCallerNames.remove(nextCall.id);
      _locallyStartedCallIds.remove(nextCall.id);
      _cancelRingingRecovery();
      _cancelActiveCallRecovery();
      _currentCall = null;
      _isConnectingRoom = false;
      _isReconnectingRoom = false;
      _isSwitchingCamera = false;
      _cameraPosition = CameraPosition.front;
      _clearInputDeviceState();
      _connectionError = null;
      _hasMediaPermissionIssue = false;
      _microphonePublishFailed = false;
      _cameraPublishFailed = false;
      _hasSeenRemoteParticipant = false;
      _joinedOnAnotherDevice = false;
      _lastIncomingVibrationCallId = null;
      _activeSince = null;
      _clearConnectionQualityState();
      notifyListeners();
      await _setWakelockActive(false);
      await _stopForegroundService(force: true);
      await _disposeRoom();
      return;
    }

    final previousCallId = _currentCall?.id;
    final previousRoomName = _connectedRoomName;
    _currentCall = nextCall;
    // A different call just became current — tear down any earlier native
    // incoming UI so a superseded call can't keep ringing on a paired watch.
    _dismissStaleNativeIncomingCalls(keepCallId: nextCall.id);
    // Живой звонок (ringing/active) — экран не должен гаснуть. Гейт на
    // joinedOnAnotherDevice: иначе recovery-poll (2s) чередовал бы
    // enable здесь / disable в joined-ветке ниже весь звонок (ревью P1).
    unawaited(_setWakelockActive(!nextCall.joinedOnAnotherDevice));
    if (nextCall.state == CallState.ringing) {
      _scheduleRingingRecovery(nextCall);
      _cancelActiveCallRecovery();
      unawaited(_maybeVibrateForIncomingCall(nextCall));
      // User-reported: «приложение свернуто — звонок на устройство
      // не проходит». Корень: в backgrounded состоянии CallScreen
      // не примонтирован к навигатору, поэтому
      // `notifyListeners` не приводит к появлению UI. Раньше единственный
      // путь к лаунчеру системного звонка проходил через
      // `notification.created` → notification_service →
      // showIncomingCallNotification → AndroidIncomingCallService.
      // Но push приходит как push-message и попадает сюда напрямую,
      // обходя notification.created. Пингуем Telecom отсюда — он
      // самостоятельный и работает поверх любого app state.
      // addNewIncomingCall идемпотентен по callId (через registry),
      // так что параллельный путь из notification_service не
      // создаст дубль.
      unawaited(_maybeShowNativeIncomingCall(nextCall));
    } else {
      if (currentCall?.id == nextCall.id &&
          currentCall?.state == CallState.ringing) {
        _dismissNativeIncomingCall(nextCall.id);
      }
      _cancelRingingRecovery();
      if (_lastIncomingVibrationCallId == nextCall.id) {
        _lastIncomingVibrationCallId = null;
      }
    }
    if (nextCall.state == CallState.active) {
      _scheduleActiveCallRecovery(nextCall);
    } else {
      _cancelActiveCallRecovery();
    }
    if (previousCallId != nextCall.id) {
      _connectionError = null;
      _hasMediaPermissionIssue = false;
      _hasSeenRemoteParticipant = false;
      _clearReconnectRestoredBanner();
      _lastIncomingVibrationCallId = null;
      _cameraPosition = CameraPosition.front;
      _isSwitchingCamera = false;
      _activeSince = null;
    }
    if (!nextCall.mediaMode.isVideo) {
      // Fix B (2026-05-22): не reset'им cameraEnabled пока room
      // connected — user мог upgrade audio→video через local
      // `toggleCamera`, backend `mediaMode` за этим не следит и
      // recovery snapshot каждые 2s триггерил reset. Preview
      // disappeared, peer всё ещё видел камеру (Bug 3 desync).
      // Reset только когда room dispose'нут — actual track gone anyway.
      // `debugTreatRoomAsActive` — test seam (visibleForTesting) чтобы
      // экзерсайз preservation path без real LiveKit Room mock.
      if (_room == null && !debugTreatRoomAsActive) {
        _cameraEnabled = false;
      }
    }
    if (nextCall.state == CallState.active && _activeSince == null) {
      // Живой переход ringing→active наблюдали сами → локальные часы
      // (без серверного дрейфа). Иначе (рестарт приложения / late-join
      // уже active звонка) — серверный acceptedAt, клампнутый «не из
      // будущего»: устройство с отстающими часами не должно видеть
      // замороженный 0:00 (ревью P2).
      final observedLiveTransition = currentCall?.id == nextCall.id &&
          currentCall?.state == CallState.ringing;
      final now = DateTime.now();
      final accepted = nextCall.acceptedAt;
      _activeSince = observedLiveTransition || accepted == null
          ? now
          : (accepted.isAfter(now) ? now : accepted);
    }
    _joinedOnAnotherDevice = nextCall.joinedOnAnotherDevice;
    notifyListeners();

    if (nextCall.state == CallState.active) {
      if (nextCall.joinedOnAnotherDevice) {
        _isConnectingRoom = false;
        _isReconnectingRoom = false;
        _connectionError = null;
        _activeSince = null;
        _clearReconnectRestoredBanner();
        notifyListeners();
        // Звонок продолжается на другом устройстве — ЭТОТ девайс
        // отпускает экран и сервис.
        await _setWakelockActive(false);
        await _stopForegroundService(force: true);
        await _disposeRoom();
        return;
      }
      if (_hasMediaPermissionIssue &&
          previousCallId == nextCall.id &&
          _room == null) {
        notifyListeners();
        return;
      }
      // Start foreground service ДО room.connect — Android 14+
      // нуждается в running foreground service с
      // foregroundServiceType="microphone" чтобы mic capture не
      // revoked'нулся. Без этого собеседник перестаёт слышать как
      // только screen blank / app backgrounded (Bug A).
      await _ensureForegroundServiceStarted(nextCall);
      final shouldReconnect = previousCallId == nextCall.id &&
          previousRoomName != null &&
          _room == null;
      await _ensureConnected(nextCall, reconnect: shouldReconnect);
      // Медиаканал (пере)подключён — пересчитать proximity-политику
      // (маршрут по умолчанию уже применён внутри attachRoom).
      unawaited(_syncProximityWakeLock());
      return;
    }

    if (previousCallId != null && previousCallId != nextCall.id) {
      await _stopForegroundService(force: true);
      await _disposeRoom();
    }
  }

  void _scheduleRingingRecovery(CallInvite call) {
    if (_ringingRecoveryInterval <= Duration.zero) {
      return;
    }
    if (_ringingRecoveryCallId == call.id &&
        _ringingRecoveryTimer?.isActive == true) {
      return;
    }
    _cancelRingingRecovery();
    _ringingRecoveryCallId = call.id;
    _ringingRecoveryTimer = Timer.periodic(_ringingRecoveryInterval, (_) {
      unawaited(_refreshRingingCall(call.id));
    });
  }

  void _cancelRingingRecovery() {
    _ringingRecoveryTimer?.cancel();
    _ringingRecoveryTimer = null;
    _ringingRecoveryCallId = null;
  }

  void _scheduleActiveCallRecovery(CallInvite call) {
    if (_activeCallRecoveryInterval <= Duration.zero) {
      return;
    }
    if (_activeCallRecoveryCallId == call.id &&
        _activeCallRecoveryTimer?.isActive == true) {
      return;
    }
    _cancelActiveCallRecovery();
    _activeCallRecoveryCallId = call.id;
    _activeCallRecoveryTimer = Timer.periodic(_activeCallRecoveryInterval, (_) {
      unawaited(_refreshActiveCall(call.id));
    });
  }

  void _cancelActiveCallRecovery() {
    _activeCallRecoveryTimer?.cancel();
    _activeCallRecoveryTimer = null;
    _activeCallRecoveryCallId = null;
  }

  Future<void> _refreshRingingCall(String callId) async {
    final activeCall = _currentCall;
    if (activeCall == null ||
        activeCall.id != callId ||
        activeCall.state != CallState.ringing) {
      _cancelRingingRecovery();
      return;
    }

    try {
      final refreshedCall = await _callService.getCall(callId);
      if (_currentCall == null || _currentCall!.id != callId) {
        return;
      }
      if (refreshedCall != null) {
        await _applyCall(refreshedCall);
        return;
      }

      final refreshedActiveCall =
          await _callService.getActiveCall(chatId: activeCall.chatId);
      if (_currentCall == null || _currentCall!.id != callId) {
        return;
      }
      if (refreshedActiveCall == null || refreshedActiveCall.id != callId) {
        await _applyCall(null);
        return;
      }
      await _applyCall(refreshedActiveCall);
    } catch (_) {
      // Keep the current ringing state and retry on the next interval.
    }
  }

  Future<void> _refreshActiveCall(String callId) async {
    final activeCall = _currentCall;
    if (activeCall == null ||
        activeCall.id != callId ||
        activeCall.state != CallState.active) {
      _cancelActiveCallRecovery();
      return;
    }

    try {
      final refreshedCall = await _callService.getCall(callId);
      if (_currentCall == null || _currentCall!.id != callId) {
        return;
      }
      if (refreshedCall == null) {
        await _applyCall(null);
        return;
      }
      await _applyCall(refreshedCall);
    } catch (_) {
      // Keep the current active state and retry on the next interval.
    }
  }

  Future<void> _ensureConnected(
    CallInvite call, {
    bool reconnect = false,
  }) async {
    final session = call.session;
    if (session == null ||
        session.url.trim().isEmpty ||
        session.token.trim().isEmpty) {
      _connectionError = 'Сеанс звонка ещё готовится.';
      _isConnectingRoom = false;
      _isReconnectingRoom = false;
      notifyListeners();
      return;
    }

    if (_room != null && _connectedRoomName == session.roomName) {
      return;
    }
    // P2: gate only on an ACTUAL in-flight connect — NOT on the
    // _isReconnectingRoom display flag, which _handleRoomDisconnected
    // sets before triggering this very reconnect (the old deadlock).
    if (_connectAttemptInFlight) {
      return;
    }

    _connectAttemptInFlight = true;
    if (reconnect) {
      _isReconnectingRoom = true;
      _armReconnectWatchdog();
    } else {
      _isConnectingRoom = true;
    }
    _connectionError = null;
    _hasMediaPermissionIssue = false;
    _microphonePublishFailed = false;
    _cameraPublishFailed = false;
    notifyListeners();

    final hasMediaPermissions =
        await _mediaPermissionRequester.call(call.mediaMode);
    if (!hasMediaPermissions) {
      _hasMediaPermissionIssue = true;
      // UX-аудит P1: для аудио-звонка камера не запрашивается вовсе —
      // говорим конкретно про микрофон, а не пугаем «или камере».
      _connectionError = call.mediaMode.isVideo
          ? 'Нет доступа к микрофону или камере. Разрешите доступ в настройках приложения.'
          : 'Нет доступа к микрофону. Разрешите доступ в настройках приложения.';
      _isConnectingRoom = false;
      _isReconnectingRoom = false;
      _connectAttemptInFlight = false;
      _cancelReconnectWatchdog();
      notifyListeners();
      return;
    }

    await _disposeRoom();

    final room = Room(roomOptions: _callRoomOptions);
    final listener = room.createListener();
    listener
      ..on<RoomDisconnectedEvent>((event) {
        debugPrint(
          '[call] room disconnected reason=${event.reason} '
          'uptime=${_uptimeSinceConnect()}ms '
          'localQuality=${room.localParticipant?.connectionQuality} '
          'remoteCount=${room.remoteParticipants.length}',
        );
        unawaited(_handleRoomDisconnected());
      })
      ..on<RoomReconnectingEvent>((_) {
        debugPrint(
          '[call] room reconnecting uptime=${_uptimeSinceConnect()}ms '
          'localQuality=${room.localParticipant?.connectionQuality}',
        );
        _isReconnectingRoom = true;
        _connectionError = 'Связь прервалась. Переподключаем...';
        _clearReconnectRestoredBanner();
        _armReconnectWatchdog();
        notifyListeners();
      })
      ..on<RoomReconnectedEvent>((_) {
        debugPrint(
          '[call] room reconnected uptime=${_uptimeSinceConnect()}ms',
        );
        _isReconnectingRoom = false;
        _connectionError = null;
        _cancelReconnectWatchdog();
        _showReconnectRestoredBannerForMoment();
        _syncConnectionQualityFromRoom(room);
        notifyListeners();
        unawaited(_resumeLocalMediaAfterReconnect());
      })
      ..on<ParticipantConnectionQualityUpdatedEvent>((event) {
        _applyParticipantConnectionQuality(
          event.participant,
          event.connectionQuality,
        );
        notifyListeners();
      })
      ..on<ParticipantConnectedEvent>((_) {
        _hasSeenRemoteParticipant = true;
        _syncConnectionQualityFromRoom(room);
        notifyListeners();
      })
      ..on<ParticipantDisconnectedEvent>((_) {
        unawaited(_handleRemoteParticipantDisconnected());
      })
      // Fix C (2026-05-22): treat LiveKit publication state as source
      // of truth для mic/camera UI buttons. Без этих listener'ов Dart
      // booleans могли desync от actual publications (Bug 2/3 mute &
      // camera state mismatch). Local-only filter на TrackMuted/Unmuted
      // — иначе remote participant mute events корруптили бы наш state.
      ..on<LocalTrackPublishedEvent>((_) {
        _syncMediaStateFromLiveKit(room);
      })
      ..on<LocalTrackUnpublishedEvent>((_) {
        _syncMediaStateFromLiveKit(room);
      })
      ..on<TrackMutedEvent>((event) {
        if (identical(event.participant, room.localParticipant)) {
          _syncMediaStateFromLiveKit(room);
        }
      })
      ..on<TrackUnmutedEvent>((event) {
        if (identical(event.participant, room.localParticipant)) {
          _syncMediaStateFromLiveKit(room);
        }
      })
      ..on<TrackSubscribedEvent>((_) {
        // A REMOTE track (esp. the peer's audio) just subscribed. LiveKit
        // reconfigures Android audio on subscribe and re-grabs the route from
        // the native bridge — which silently kills the «Динамик» toggle and
        // drops hardware volume off the call stream the instant the other
        // person's audio connects. This was the uncovered re-grab point that
        // made the speaker fix flaky («раз работает, раз нет»). Re-assert.
        unawaited(_audioRouteService.reassertNativeAudioOwnership());
      })
      ..on<TrackUnsubscribedEvent>((_) {
        unawaited(_audioRouteService.reassertNativeAudioOwnership());
      })
      ..on<ParticipantEvent>((_) {
        notifyListeners();
      })
      ..on<RoomEvent>((_) {
        notifyListeners();
      });

    try {
      _roomConnectStartedAt = DateTime.now();
      debugPrint(
        '[call] room.connect start url=${session.url} '
        'roomName=${session.roomName} reconnect=$reconnect',
      );
      await room.connect(
        session.url,
        session.token,
        connectOptions: _callConnectOptions,
      );
      debugPrint(
        '[call] room.connect ok uptime=${_uptimeSinceConnect()}ms',
      );
      _microphoneEnabled = true;
      // Publish mic separately от room.connect — на Android 14+ без
      // FOREGROUND_SERVICE_MICROPHONE permission setMicrophoneEnabled
      // может silently fail (publication == null) даже когда room
      // успешно connected. Этот fix surface'ит failure через
      // `microphonePublishFailed` flag вместо silently lying в UI.
      _microphonePublishFailed = !(await _publishLocalMicrophone(room));
      // Камеру для видео-звонка публикуем БЕЗУСЛОВНО по mediaMode, а
      // `_cameraEnabled` выставляем из РЕЗУЛЬТАТА. Раньше здесь было
      // «_cameraEnabled = isVideo (до mic-await) … setCameraEnabled(
      // _cameraEnabled)» — гонка: пока ждали publish микрофона, его
      // LocalTrackPublishedEvent триггерил _syncMediaStateFromLiveKit,
      // тот читал «камера ещё не опубликована» и затирал intent-флаг в
      // false → setCameraEnabled(false) → тихий no-op, видео-звонок
      // поднимался без видео (S20 FE, 2026-07-04). Failure камеры
      // больше не роняет весь connect (звук живёт, юзеру — Q1-баннер).
      if (call.mediaMode.isVideo) {
        final published = await _publishLocalCamera(room);
        _cameraPublishFailed = !published;
        _cameraEnabled = published;
      }
      _connectionError = null;
      _hasMediaPermissionIssue = false;
      _hasSeenRemoteParticipant = room.remoteParticipants.isNotEmpty;
      _room = room;
      _roomListener = listener;
      _connectedRoomName = session.roomName;
      _syncConnectionQualityFromRoom(room);
      if (reconnect) {
        _showReconnectRestoredBannerForMoment();
      }
      // CA1 FR3: дефолт маршрута на коннекте — ушной для аудио, динамик
      // для видео; применяется внутри attachRoom (даже без сохранённой
      // преференции).
      await _audioRouteService.attachRoom(room,
          isVideo: call.mediaMode.isVideo);
      await refreshInputDevices();
      await _applyCallPreferences(room, call);
    } catch (error) {
      await listener.dispose();
      await room.dispose();
      _hasMediaPermissionIssue = _looksLikeMediaPermissionIssue(error);
      // Mode-aware и здесь (ревью батча): аудио-звонок не должен пугать
      // «или камере» и на connect-catch пути, не только на pre-flight.
      _connectionError = _hasMediaPermissionIssue
          ? (call.mediaMode.isVideo
              ? 'Нет доступа к микрофону или камере. Разрешите доступ в настройках приложения.'
              : 'Нет доступа к микрофону. Разрешите доступ в настройках приложения.')
          : 'Не удалось подключиться к звонку.';
      // Connection-level failure уже surface'ится через connectionError —
      // mic-specific signal на этом этапе redundant. Clear чтобы не
      // surface'ить stale mic banner поверх banner'а connection failure.
      _microphonePublishFailed = false;
      _cameraPublishFailed = false;
    } finally {
      _isConnectingRoom = false;
      _isReconnectingRoom = false;
      _connectAttemptInFlight = false;
      // The attempt is over: success cleared _connectionError (and set
      // _room); failure set a real error. Either way the watchdog's job
      // is done — a stuck overlay can't outlive a finished attempt.
      _cancelReconnectWatchdog();
      notifyListeners();
    }
  }

  Future<void> _handleRoomDisconnected() async {
    await _disposeRoom();

    final activeCall = _currentCall;
    if (activeCall == null || activeCall.state != CallState.active) {
      notifyListeners();
      return;
    }
    if (_hasMediaPermissionIssue) {
      notifyListeners();
      return;
    }

    _connectionError = 'Связь прервалась. Переподключаем...';
    _isReconnectingRoom = true;
    _clearReconnectRestoredBanner();
    _armReconnectWatchdog();
    notifyListeners();
    await refreshCurrentCall();
  }

  Future<void> _handleRemoteParticipantDisconnected() async {
    final activeCall = _currentCall;
    final room = _room;
    if (activeCall == null ||
        activeCall.state != CallState.active ||
        room == null) {
      notifyListeners();
      return;
    }
    if (!_hasSeenRemoteParticipant || room.remoteParticipants.isNotEmpty) {
      _syncConnectionQualityFromRoom(room);
      notifyListeners();
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (_currentCall?.id != activeCall.id || _room == null) {
      return;
    }
    if (_room!.remoteParticipants.isNotEmpty) {
      _syncConnectionQualityFromRoom(_room!);
      notifyListeners();
      return;
    }
    await refreshCurrentCall();
  }

  bool _looksLikeMediaPermissionIssue(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('permission') ||
        message.contains('microphone') ||
        message.contains('camera') ||
        message.contains('device');
  }

  LocalVideoTrack? _localCameraTrack() {
    final publications = _room?.localParticipant?.videoTrackPublications;
    if (publications == null || publications.isEmpty) {
      return null;
    }
    for (final publication in publications) {
      if (publication.source == TrackSource.camera) {
        return publication.track;
      }
    }
    return null;
  }

  String? _resolveSelectedDeviceId(
    List<MediaDevice> devices,
    String? currentId,
  ) {
    if (currentId != null &&
        devices.any((device) => device.deviceId == currentId)) {
      return currentId;
    }
    return devices.isEmpty ? null : devices.first.deviceId;
  }

  CameraPosition? _cameraPositionFromDevice(MediaDevice device) {
    final haystack =
        '${device.deviceId} ${device.label} ${device.groupId ?? ''}'
            .toLowerCase();
    if (haystack.contains('back') ||
        haystack.contains('rear') ||
        haystack.contains('environment') ||
        haystack.contains('зад') ||
        haystack.contains('основ')) {
      return CameraPosition.back;
    }
    if (haystack.contains('front') ||
        haystack.contains('user') ||
        haystack.contains('face') ||
        haystack.contains('фронт') ||
        haystack.contains('перед')) {
      return CameraPosition.front;
    }
    return null;
  }

  void _clearInputDeviceState() {
    _microphoneDevices = const <MediaDevice>[];
    _cameraDevices = const <MediaDevice>[];
    _selectedMicrophoneDeviceId = null;
    _selectedCameraDeviceId = null;
    _isRefreshingInputDevices = false;
    _isSelectingMediaDevice = false;
    _devicePickerErrorMessage = null;
  }

  // Worst (lowest-quality) link across remotes, ignoring `unknown` (no data
  // yet). `ConnectionQuality` is declared worst→best (lost < poor < good <
  // excellent), so the smallest non-unknown `.index` wins. Group calls must
  // surface the peer most at risk, not whichever participant was iterated
  // first. Returns `unknown` only when no remote has reported quality yet.
  ConnectionQuality _worstRemoteQuality(Iterable<ConnectionQuality> qualities) {
    var worst = ConnectionQuality.unknown;
    for (final quality in qualities) {
      if (quality == ConnectionQuality.unknown) {
        continue;
      }
      if (worst == ConnectionQuality.unknown || quality.index < worst.index) {
        worst = quality;
      }
    }
    return worst;
  }

  void _syncConnectionQualityFromRoom(Room room) {
    _localConnectionQuality =
        room.localParticipant?.connectionQuality ?? ConnectionQuality.unknown;
    // Aggregate the WORST remote link so the group-call badge reflects the
    // peer most at risk rather than whichever participant iterated first.
    _remoteConnectionQuality = _worstRemoteQuality(
      room.remoteParticipants.values.map((p) => p.connectionQuality),
    );
  }

  void _applyParticipantConnectionQuality(
    Participant participant,
    ConnectionQuality quality,
  ) {
    final room = _room;
    if (room != null && participant == room.localParticipant) {
      _localConnectionQuality = quality;
      return;
    }
    if (participant is LocalParticipant) {
      _localConnectionQuality = quality;
      return;
    }
    // A remote's quality changed — recompute the worst across ALL remotes
    // (using this fresh value for the updated peer, since the room snapshot may
    // still lag the event) so one good link can't mask another's degraded one
    // in a group call.
    if (room == null) {
      _remoteConnectionQuality = quality;
      return;
    }
    final qualities = <ConnectionQuality>[quality];
    for (final other in room.remoteParticipants.values) {
      if (other.identity != participant.identity) {
        qualities.add(other.connectionQuality);
      }
    }
    _remoteConnectionQuality = _worstRemoteQuality(qualities);
  }

  void _showReconnectRestoredBannerForMoment() {
    _reconnectRestoredTimer?.cancel();
    _showReconnectRestoredBanner = true;
    _reconnectRestoredTimer = Timer(const Duration(seconds: 3), () {
      _showReconnectRestoredBanner = false;
      notifyListeners();
    });
  }

  void _clearReconnectRestoredBanner() {
    _reconnectRestoredTimer?.cancel();
    _reconnectRestoredTimer = null;
    _showReconnectRestoredBanner = false;
  }

  // P2: while «Переподключение» is shown, guarantee it can never wedge on
  // forever. If after the timeout the LiveKit transport is actually live
  // (the peer is audible), force-clear the overlay — the old code waited
  // for a RoomReconnectedEvent that, on a disposed or internally-recovered
  // room, may never arrive.
  void _armReconnectWatchdog() {
    _reconnectWatchdogTimer?.cancel();
    _reconnectWatchdogTimer = Timer(const Duration(seconds: 12), () {
      _reconnectWatchdogTimer = null;
      if (!_isReconnectingRoom) {
        return;
      }
      final room = _room;
      final live =
          room != null && room.connectionState == ConnectionState.connected;
      if (live) {
        // Room is actually back but RoomReconnectedEvent never cleared the
        // overlay — force-clear it (the original 0b254b7 deadlock backstop).
        _isReconnectingRoom = false;
        _connectionError = null;
        _showReconnectRestoredBannerForMoment();
        _syncConnectionQualityFromRoom(room);
        notifyListeners();
        return;
      }
      // Residual gap (was: no else branch → «Переподключение» wedged forever
      // with the timer nulled and nothing re-arming it). Still reconnecting and
      // NOT live at the deadline. Never lie that we reconnected; instead tie the
      // overlay to the call's real lifetime: drop it if the call is gone or
      // terminal, otherwise re-arm a self-perpetuating re-check so the moment
      // the room comes back (or the call ends) the overlay resolves on the next
      // tick instead of spinning indefinitely.
      final activeCall = _currentCall;
      if (activeCall == null || activeCall.state != CallState.active) {
        _isReconnectingRoom = false;
        notifyListeners();
        return;
      }
      _armReconnectWatchdog();
    });
  }

  void _cancelReconnectWatchdog() {
    _reconnectWatchdogTimer?.cancel();
    _reconnectWatchdogTimer = null;
  }

  void _clearConnectionQualityState() {
    _localConnectionQuality = ConnectionQuality.unknown;
    _remoteConnectionQuality = ConnectionQuality.unknown;
    _clearReconnectRestoredBanner();
  }

  Future<void> _resumeLocalMediaAfterReconnect() async {
    final room = _room;
    final activeCall = _currentCall;
    if (room == null ||
        activeCall == null ||
        activeCall.state != CallState.active) {
      return;
    }
    try {
      if (_microphoneEnabled) {
        _microphonePublishFailed = !(await _publishLocalMicrophone(room));
      }
      // Камера поднимается заново если была включена ДО реконнекта —
      // это покрывает и видео-звонок, и audio→video upgrade (раньше
      // гейт `mediaMode.isVideo` терял камеру апгрейднутого аудио-
      // звонка). Была выключена — не трогаем: не включаем камеру
      // за спиной пользователя.
      if (_cameraEnabled) {
        _cameraPublishFailed = !(await _publishLocalCamera(room));
        _cameraEnabled = !_cameraPublishFailed;
      }
    } catch (_) {
      // LiveKit will continue reconnecting if media resume is not ready yet.
    }
    // CA1+: on reconnect LiveKit re-runs its connect-time audio config
    // (setAndroidAudioConfiguration(communication) = manageAudioFocus:true),
    // re-grabbing the route from the native bridge even when no track
    // (re)publish event fires. Re-assert so the speaker toggle and hardware
    // volume keep working after «Переподключение» clears.
    await _audioRouteService.reassertNativeAudioOwnership();
  }

  /// Запускает Kotlin foreground service для активного звонка
  /// (либо update если уже running для того же callId). Idempotent
  /// на re-fires `_applyCall(active)` для того же звонка.
  /// No-op на non-Android либо когда service не инжектирован
  /// (некоторые tests).
  /// Гигиена звонков: держим экран включённым пока звонок живой
  /// (ringing/active), отпускаем на любом terminal/teardown-пути.
  /// Идемпотентно — guard на _wakelockActive, потому что _applyCall
  /// re-fire'ится каждые 2s recovery-poll'ом.
  Future<void> _setWakelockActive(bool active) async {
    if (_wakelockActive == active) {
      return;
    }
    _wakelockActive = active;
    try {
      await _wakelockToggler(active);
    } catch (error) {
      // Best-effort: сбой wakelock не должен ломать звонок.
      debugPrint('[call-wakelock] toggle($active) failed: $error');
    }
  }

  static Future<void> _defaultWakelockToggler(bool enable) {
    return WakelockPlus.toggle(enable: enable);
  }

  void _handleAudioRouteChanged() {
    unawaited(_syncProximityWakeLock());
  }

  /// Proximity-политика (Telegram-поведение): гасим экран у уха ТОЛЬКО
  /// в чисто аудио-состоянии — звонок active, медиаканал подключён,
  /// маршрут «ушной», камера не поднята (mediaMode video или локальный
  /// audio→video upgrade выключают датчик). AudioRouteService сам
  /// no-op'ит вне Android-пути, а Kotlin-мост дополнительно отпускает
  /// лок в stop()/teardown() — страховка от пропущенного false.
  Future<void> _syncProximityWakeLock() async {
    final call = _currentCall;
    final desired = call != null &&
        call.state == CallState.active &&
        _room != null &&
        !call.mediaMode.isVideo &&
        !_cameraEnabled &&
        _audioRouteService.selectedRoute?.type == AudioRouteType.earpiece;
    await _audioRouteService.setProximityEnabled(desired);
  }

  Future<void> _ensureForegroundServiceStarted(CallInvite call) async {
    final service = _callForegroundService;
    if (service == null || !service.isSupported) {
      return;
    }
    final callId = call.id.trim();
    if (callId.isEmpty) {
      return;
    }
    final peerName = _resolvePeerName(call);
    final isVideo = call.mediaMode.isVideo;
    if (_foregroundServiceCallId == callId) {
      // Already running для этого звонка — update notification на
      // случай если peer name / mic state поменялись.
      await service.update(
        callId: callId,
        peerName: peerName,
        isVideo: isVideo,
        micEnabled: _microphoneEnabled,
      );
      return;
    }
    final started = await service.start(
      callId: callId,
      peerName: peerName,
      isVideo: isVideo,
      micEnabled: _microphoneEnabled,
    );
    if (started) {
      _foregroundServiceCallId = callId;
    }
  }

  /// Останавливает foreground service. По умолчанию no-op если он не был
  /// запущен этим coordinator instance; cleanup paths pass [force], чтобы
  /// погасить возможный Android service, переживший Dart-state race/restart.
  Future<void> _stopForegroundService({bool force = false}) async {
    final service = _callForegroundService;
    final callId = _foregroundServiceCallId;
    _foregroundServiceCallId = null;
    if (service == null || !service.isSupported || (!force && callId == null)) {
      return;
    }
    await service.stop();
  }

  /// Update notification text без restart service. Вызывается на
  /// mic toggle reflection (icon в notification отражает on/off).
  /// No-op если service не running.
  Future<void> _updateForegroundService() async {
    final service = _callForegroundService;
    final callId = _foregroundServiceCallId;
    if (service == null || !service.isSupported || callId == null) {
      return;
    }
    final activeCall = _currentCall;
    await service.update(
      callId: callId,
      peerName: activeCall != null ? _resolvePeerName(activeCall) : null,
      isVideo: activeCall?.mediaMode.isVideo ?? false,
      micEnabled: _microphoneEnabled,
    );
  }

  /// Resolve peer display name из CallInvite — push payload-side
  /// name preferred, fallback на participant identity. Empty string
  /// если ничего нет (notification покажет «Идёт голосовой/видео-
  /// звонок» вместо «Идёт звонок с»).
  String? _resolvePeerName(CallInvite call) {
    final pushName = _pushCallerNames[call.id]?.trim();
    if (pushName != null && pushName.isNotEmpty) {
      return pushName;
    }
    return null;
  }

  /// Public read of the push-payload caller name for a call. The incoming-call
  /// FCM push carries the caller's name (the native notification already shows
  /// it); the in-app call screen uses this so it shows WHO is calling instead
  /// of a bare «Звонок» when getChatDetails is slow / the chat isn't cached.
  /// Empty/absent → null.
  String? pushCallerNameFor(String callId) {
    final name = _pushCallerNames[callId.trim()]?.trim();
    return (name != null && name.isNotEmpty) ? name : null;
  }

  /// Fix C (2026-05-22): pull local track state from LiveKit
  /// (`participant.isMicrophoneEnabled()` / `isCameraEnabled()`)
  /// и обновляет Dart fields на разнице. Source of truth — LiveKit
  /// publication state, Dart fields — reflected mirror для UI.
  ///
  /// Triggered events listener'ом в `_connectRoom` на
  /// `LocalTrackPublishedEvent`, `LocalTrackUnpublishedEvent`,
  /// `TrackMutedEvent` (local), `TrackUnmutedEvent` (local). Catches
  /// any future code path который mutates track state без touching
  /// Dart booleans — например notification action handler (Bug A
  /// added 2 entry points), server-side mute permissions, auto-republish
  /// после reconnect.
  ///
  /// Infinite loop prevention: change detection — `notifyListeners`
  /// fires только когда фактический value diff. Setter sequence
  /// (`_microphoneEnabled = ...` → `notifyListeners` → UI rebuild →
  /// читает getter — no LiveKit invocation → no event re-fire).
  void _syncMediaStateFromLiveKit(Room? room) {
    final participant = room?.localParticipant;
    if (participant == null) {
      return;
    }
    final micActual = participant.isMicrophoneEnabled();
    final camActual = participant.isCameraEnabled();
    var changed = false;
    if (_microphoneEnabled != micActual) {
      _microphoneEnabled = micActual;
      changed = true;
    }
    if (_cameraEnabled != camActual) {
      _cameraEnabled = camActual;
      changed = true;
    }
    // Defensive reconciliation (2026-05-22 Q1 false-positive fix
    // follow-up): если mic actually published per LiveKit, clear
    // any stale `microphonePublishFailed` flag. Без этого ранее
    // false-positive Q1 banner оставался стуком висеть после event-
    // driven sync corrected `_microphoneEnabled` к true.
    if (micActual && _microphonePublishFailed) {
      _microphonePublishFailed = false;
      changed = true;
    }
    // Симметрично для камеры: publication реально поднялась — stale
    // «камера не подключилась» баннер должен уйти.
    if (camActual && _cameraPublishFailed) {
      _cameraPublishFailed = false;
      changed = true;
    }
    if (changed) {
      notifyListeners();
      unawaited(_updateForegroundService());
    }
    // CA1+: a local track (un)publish just settled (this runs from the
    // LocalTrackPublished/Unpublished + mute listeners) — LiveKit re-grabs the
    // Android audio focus/route on publish, so re-assert the native bridge's
    // ownership now, or «Динамик» and hardware volume silently stop working
    // after a mic/camera toggle. No-op off-Android and after the call ends.
    unawaited(_audioRouteService.reassertNativeAudioOwnership());
    // Камера могла подняться/опуститься (audio→video upgrade) —
    // proximity-политика зависит от неё.
    unawaited(_syncProximityWakeLock());
  }

  /// Try to publish the local microphone. Возвращает true при
  /// успехе, false при failure. На failure обновляет
  /// `_microphoneEnabled = false` для truthful UI state.
  ///
  /// **Success signal**: non-null publication object от
  /// `setMicrophoneEnabled(true)` — это LiveKit API contract на
  /// successful publish. Throwing exception либо null return
  /// considered failure.
  ///
  /// **Removed (2026-05-22)**: post-await `participant.isMicrophoneEnabled()`
  /// race-prone secondary check. Та lookup traversal происходит до
  /// того как track publications list propagate'нулся, fire'ила
  /// false positive «микрофон не подключился» banner хотя peer
  /// actually слышит. После Fix C (commit `207245a`) async truth
  /// sync handles это event-driven через `LocalTrackPublishedEvent`
  /// listener — `_syncMediaStateFromLiveKit` updates Dart booleans
  /// AND clears `_microphonePublishFailed` когда mic actually
  /// published. Race window больше не surfaces.
  ///
  /// На Android 14+ это первая линия защиты от Bug 1 (audio one-way):
  /// LiveKit shortcut может вернуть null publication когда microphone
  /// capture revoked'нут OS-ью (foreground service не запущен → mic
  /// stream killed). Bug A foreground service shipped 2026-05-22
  /// closed основной trigger, но Q1 backup remains для других
  /// failure modes (codec init, HAL error, etc.).
  Future<bool> _publishLocalMicrophone(Room room) async {
    final participant = room.localParticipant;
    if (participant == null) {
      _microphoneEnabled = false;
      return false;
    }
    try {
      final publication = await participant.setMicrophoneEnabled(true);
      final published = publication != null;
      if (!published) {
        _microphoneEnabled = false;
        debugPrint(
          '[call] microphone publish failed — LiveKit returned null '
          'publication (likely OS revoked mic capture)',
        );
      }
      return published;
    } catch (error, stack) {
      _microphoneEnabled = false;
      debugPrint('[call] microphone publish threw: $error\n$stack');
      return false;
    }
  }

  /// Публикует локальную камеру. true при успехе, false при failure
  /// (на failure `_cameraEnabled = false` для truthful UI state) —
  /// зеркало [_publishLocalMicrophone].
  ///
  /// Первую публикацию делаем вручную (createCameraTrack +
  /// publishVideoTrack) вместо `setCameraEnabled(true)`: в
  /// livekit_client 2.7.0 setCameraEnabled при падении publish бросает,
  /// а созданный им трек НЕ останавливает — камера остаётся захваченной
  /// на уровне HAL до перезапуска приложения (наблюдали 6+ минут live
  /// capture после единственного тапа; конкурирующие приложения
  /// получали «Too many cameras already open»). Владея треком сами,
  /// глушим его в catch. Повторное включение после mute идёт через
  /// setCameraEnabled — там unmute существующей publication, трек не
  /// создаётся и утечка невозможна.
  Future<bool> _publishLocalCamera(Room room) async {
    final participant = room.localParticipant;
    if (participant == null) {
      _cameraEnabled = false;
      return false;
    }
    try {
      final existing =
          participant.getTrackPublicationBySource(TrackSource.camera);
      if (existing != null) {
        final publication = await participant.setCameraEnabled(
          true,
          cameraCaptureOptions: _cameraCaptureOptionsFor(room),
        );
        return publication != null;
      }
      final track = await LocalVideoTrack.createCameraTrack(
        _cameraCaptureOptionsFor(room),
      );
      try {
        await participant.publishVideoTrack(
          track,
          publishOptions: _sanitizedVideoPublishOptions(room),
        );
        return true;
      } catch (_) {
        await track.stop();
        await track.dispose();
        rethrow;
      }
    } catch (error, stack) {
      _cameraEnabled = false;
      debugPrint('[call] camera publish threw: $error\n$stack');
      return false;
    }
  }

  /// Страховка инварианта нативного WebRTC: при simulcast у всех
  /// encodings должен быть ОДИНАКОВЫЙ bitrate_priority/network_priority.
  /// LiveKit подставляет приоритет из videoEncoding только в верхний
  /// слой (авто-слои q/h остаются с дефолтным low) → addTransceiver
  /// отвергает весь набор («C++ addTransceiver failed»), камера не
  /// публикуется вовсе. Срезаем приоритеты из videoEncoding, оставляя
  /// битрейт/fps — рабочую часть медиа-профиля.
  VideoPublishOptions _sanitizedVideoPublishOptions(Room room) {
    final options = room.roomOptions.defaultVideoPublishOptions;
    final encoding = options.videoEncoding;
    if (!options.simulcast ||
        encoding == null ||
        (encoding.bitratePriority == null &&
            encoding.networkPriority == null)) {
      return options;
    }
    return options.copyWith(
      videoEncoding: VideoEncoding(
        maxFramerate: encoding.maxFramerate,
        maxBitrate: encoding.maxBitrate,
      ),
    );
  }

  Future<void> _applyCallPreferences(Room room, CallInvite call) async {
    final preferences = await _callPreferences.load();
    await _applyPreferredMicrophone(
        room, preferences.defaultMicrophoneDeviceId);
    if (call.mediaMode.isVideo) {
      await _applyPreferredCamera(room, preferences.defaultCameraDeviceId);
    }
    await _applyPreferredAudioOutput(preferences.defaultAudioOutputId);
  }

  Future<void> _applyPreferredMicrophone(
    Room room,
    String? deviceId,
  ) async {
    final device = _findMediaDevice(_microphoneDevices, deviceId);
    if (device == null) {
      return;
    }
    try {
      await _microphoneDeviceSelector(room, device);
      _selectedMicrophoneDeviceId = device.deviceId;
    } catch (_) {
      // Keep the system-selected input when the saved device is stale.
    }
  }

  Future<void> _applyPreferredCamera(Room room, String? deviceId) async {
    final device = _findMediaDevice(_cameraDevices, deviceId);
    if (device == null) {
      return;
    }
    try {
      await _cameraDeviceSelector(room, device);
      _selectedCameraDeviceId = device.deviceId;
      _cameraPosition = _cameraPositionFromDevice(device) ?? _cameraPosition;
      _cameraEnabled = true;
    } catch (_) {
      // Keep the system-selected camera when the saved device is stale.
    }
  }

  Future<void> _applyPreferredAudioOutput(String? routeId) async {
    if (routeId == null || routeId.trim().isEmpty) {
      return;
    }
    AudioRouteOption? preferredRoute;
    for (final route in _audioRouteService.routes) {
      if (route.id == routeId) {
        preferredRoute = route;
        break;
      }
    }
    if (preferredRoute == null) {
      return;
    }
    await _audioRouteService.selectRoute(preferredRoute);
  }

  MediaDevice? _findMediaDevice(
    List<MediaDevice> devices,
    String? deviceId,
  ) {
    final normalizedDeviceId = deviceId?.trim();
    if (normalizedDeviceId == null || normalizedDeviceId.isEmpty) {
      return null;
    }
    for (final device in devices) {
      if (device.deviceId == normalizedDeviceId) {
        return device;
      }
    }
    return null;
  }

  Future<void> _maybeVibrateForIncomingCall(CallInvite call) async {
    final currentUser = currentUserId;
    if (currentUser == null ||
        !call.isIncomingFor(currentUser) ||
        _lastIncomingVibrationCallId == call.id) {
      return;
    }
    final preferences = await _callPreferences.load();
    if (!preferences.vibrationOnIncoming) {
      return;
    }
    _lastIncomingVibrationCallId = call.id;
    try {
      await _vibrationTrigger();
    } catch (_) {}
  }

  /// Lift the system-level incoming-call UI (Telecom self-managed
  /// connection) for an incoming ringing call. Idempotent per
  /// callId so a parallel `notification.created` path doesn't
  /// trigger a second `addNewIncomingCall`.
  ///
  /// This is the path that lets the user see + answer the call
  /// when the app is BACKGROUNDED (process alive, no UI mounted).
  /// Without it, push delivery hydrates the call into Dart state
  /// and notifies listeners, but no one is rendering — so the user
  /// gets vibration and silence. With Telecom in the picture, the
  /// system itself shows the native ringer screen over whatever
  /// the user is doing, identical to a phone call.
  Future<void> _maybeShowNativeIncomingCall(CallInvite call) async {
    final service = _androidIncomingCallService;
    if (service == null || !service.isSupported) {
      return;
    }
    final currentUser = currentUserId;
    if (currentUser == null || !call.isIncomingFor(currentUser)) {
      return;
    }
    if (_shownNativeIncomingCallIds.contains(call.id)) {
      return;
    }
    _shownNativeIncomingCallIds.add(call.id);
    // Never surface the raw initiatorId (a UUID): the Telecom side turns it
    // into a bogus «phone number» on paired watches (they strip non-digits
    // → «21433289429097»). The VKPNS push carries the real display name and
    // lands before hydrate; without it we fall back to an empty string so
    // the native side shows its neutral «Родня» label, not a user id.
    final pushCallerName = _pushCallerNames[call.id]?.trim();
    final callerName =
        (pushCallerName != null && pushCallerName.isNotEmpty)
            ? pushCallerName
            : '';
    try {
      await service.showIncomingCall(
        callId: call.id,
        callerName: callerName,
        isVideo: call.mediaMode.isVideo,
        chatId: call.chatId,
      );
    } catch (_) {
      // Telecom registration races vs. permissions are non-fatal —
      // the native push service builds a full-screen intent
      // notification as a parallel safety net so the user still
      // sees the call.
    }
  }

  void _dismissNativeIncomingCall(String callId) {
    final normalizedCallId = callId.trim();
    if (normalizedCallId.isEmpty) {
      return;
    }
    unawaited(_androidIncomingCallService?.dismissCall(normalizedCallId));
    _shownNativeIncomingCallIds.remove(normalizedCallId);
  }

  /// Tears down every shown native incoming-call UI except [keepCallId].
  /// Called when a call is superseded by another, or when the server
  /// reports no active call — orphaned Telecom connections must not linger
  /// (phantom call on paired watch + stuck MODE_RINGTONE). Iterates a copy
  /// because [_dismissNativeIncomingCall] mutates the set.
  void _dismissStaleNativeIncomingCalls({String? keepCallId}) {
    if (_shownNativeIncomingCallIds.isEmpty) {
      return;
    }
    final stale = _shownNativeIncomingCallIds
        .where((id) => id != keepCallId)
        .toList(growable: false);
    for (final id in stale) {
      _dismissNativeIncomingCall(id);
      _pushCallerNames.remove(id);
    }
  }

  static Future<void> _switchLiveKitCameraPosition(
    LocalVideoTrack track,
    CameraPosition position,
  ) {
    return track.setCameraPosition(position);
  }

  CameraCaptureOptions _cameraCaptureOptionsFor(Room room) {
    return room.roomOptions.defaultCameraCaptureOptions.copyWith(
      cameraPosition: _cameraPosition,
    );
  }

  static Future<List<MediaDevice>> _defaultAudioInputEnumerator() {
    return Hardware.instance.audioInputs();
  }

  static Future<List<MediaDevice>> _defaultVideoInputEnumerator() {
    return Hardware.instance.videoInputs();
  }

  static Future<void> _selectLiveKitMicrophoneDevice(
    Room room,
    MediaDevice device,
  ) {
    return room.setAudioInputDevice(device);
  }

  static Future<void> _selectLiveKitCameraDevice(
    Room room,
    MediaDevice device,
  ) {
    return room.setVideoInputDevice(device);
  }

  static Future<void> _defaultVibrationTrigger() {
    return HapticFeedback.mediumImpact();
  }

  static Future<bool> _requestPlatformMediaPermissions(
    CallMediaMode mediaMode,
  ) async {
    if (kIsWeb) {
      return true;
    }
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return true;
    }

    final microphoneStatus = await Permission.microphone.request();
    if (!(microphoneStatus.isGranted || microphoneStatus.isLimited)) {
      return false;
    }
    // Bug B (audit 2026-05-22): запрашиваем BLUETOOTH_CONNECT
    // best-effort параллельно. Android 12+ silently rejects
    // enumeration paired BT гарнитур без этого grant'а — user
    // подключил наушники, но в audio picker они не видны → fallback
    // на speaker/earpiece. Не gate'им room.connect — BT-permission
    // отказ не ломает звонок (просто без BT routing options).
    unawaited(_requestBluetoothConnectPermissionIfNeeded());

    if (!mediaMode.isVideo) {
      return true;
    }

    final cameraStatus = await Permission.camera.request();
    return cameraStatus.isGranted || cameraStatus.isLimited;
  }

  /// Best-effort BLUETOOTH_CONNECT runtime permission request на
  /// Android 12+ (API 31+). No-op на других платформах либо когда
  /// already-granted/permanently-denied (не спамим dialog).
  ///
  /// Не gate'ит call connect — denied BT permission означает только
  /// что BT гарнитуры не показываются в audio device picker. User
  /// останется на speaker/earpiece, не surfaceит fatal error.
  static Future<void> _requestBluetoothConnectPermissionIfNeeded() async {
    if (kIsWeb) {
      return;
    }
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      final status = await Permission.bluetoothConnect.status;
      if (status.isGranted ||
          status.isLimited ||
          status.isPermanentlyDenied ||
          status.isRestricted) {
        // Already settled — no point re-asking.
        return;
      }
      final result = await Permission.bluetoothConnect.request();
      if (kDebugMode) {
        debugPrint(
          '[call] BLUETOOTH_CONNECT permission result=$result',
        );
      }
    } catch (error) {
      debugPrint(
        '[call] BLUETOOTH_CONNECT permission request threw: $error',
      );
    }
  }

  void _handleCallEvent(CallEvent event) {
    unawaited(_applyCall(event.call));
  }

  void _handlePushMessage(RustorePushMessage message) {
    if (!message.isCallInvite) {
      return;
    }
    final callId = message.callId;
    if (callId != null && callId.isNotEmpty) {
      // Stash the caller name from the push payload before we
      // hydrate — _applyCall will read it back from this cache
      // when it fires the native Telecom UI. CallInvite from
      // /v1/calls/:id only carries initiatorId, not the display
      // name, so without this hop the lockscreen would show the
      // raw user id (or worse, a generic «Звонок» fallback).
      final pushCallerName = message.data['callerName']?.trim();
      if (pushCallerName != null && pushCallerName.isNotEmpty) {
        _pushCallerNames[callId] = pushCallerName;
      }
    }
    unawaited(
      hydrateIncomingCall(
        callId: callId,
        chatId: message.chatId,
      ),
    );
  }

  bool _shouldIgnoreCallSnapshot(CallInvite nextCall) {
    final currentCall = _currentCall;
    if (currentCall == null) {
      return false;
    }
    if (currentCall.id != nextCall.id) {
      return nextCall.state.isTerminal;
    }
    if (nextCall.state.isTerminal) {
      return false;
    }

    final currentUpdatedAt = currentCall.updatedAt.millisecondsSinceEpoch;
    final nextUpdatedAt = nextCall.updatedAt.millisecondsSinceEpoch;
    if (nextUpdatedAt < currentUpdatedAt) {
      return true;
    }
    if (nextUpdatedAt > currentUpdatedAt) {
      return false;
    }

    final currentRank = _callStatePriority(currentCall);
    final nextRank = _callStatePriority(nextCall);
    if (nextRank < currentRank) {
      return true;
    }

    if (currentCall.state == CallState.active &&
        nextCall.state == CallState.active &&
        currentCall.session != null &&
        nextCall.session == null) {
      return true;
    }

    return false;
  }

  int _callStatePriority(CallInvite call) {
    if (call.state == CallState.active) {
      return call.session != null ? 4 : 3;
    }
    if (call.state == CallState.ringing) {
      return 2;
    }
    return 1;
  }

  Future<void> _disposeRoom() async {
    await _audioRouteService.attachRoom(null);
    await _roomListener?.dispose();
    _roomListener = null;
    if (_room != null) {
      await _room!.disconnect();
      await _room!.dispose();
    }
    _room = null;
    _connectedRoomName = null;
    _roomConnectStartedAt = null;
    _hasSeenRemoteParticipant = false;
  }

  int _uptimeSinceConnect() {
    final startedAt = _roomConnectStartedAt;
    if (startedAt == null) {
      return -1;
    }
    return DateTime.now().difference(startedAt).inMilliseconds;
  }

  Future<void> reset() async {
    final activeCall = _currentCall;
    if (activeCall != null) {
      _pushCallerNames.remove(activeCall.id);
      _locallyStartedCallIds.remove(activeCall.id);
    }
    _dismissStaleNativeIncomingCalls();
    _cancelRingingRecovery();
    _cancelActiveCallRecovery();
    _currentCall = null;
    _connectionError = null;
    _isConnectingRoom = false;
    _isReconnectingRoom = false;
    _microphoneEnabled = true;
    _microphonePublishFailed = false;
    _cameraPublishFailed = false;
    _cameraEnabled = false;
    _isSwitchingCamera = false;
    _cameraPosition = CameraPosition.front;
    _clearInputDeviceState();
    _clearConnectionQualityState();
    _hasMediaPermissionIssue = false;
    _hasSeenRemoteParticipant = false;
    _joinedOnAnotherDevice = false;
    _lastIncomingVibrationCallId = null;
    _activeSince = null;
    _locallyStartedCallIds.clear();
    await _setWakelockActive(false);
    await _stopForegroundService(force: true);
    await _disposeRoom();
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_hasMediaPermissionIssue) {
        _hasMediaPermissionIssue = false;
        _connectionError = null;
      }
      unawaited(ensureRuntimeReady().then((_) => resync()));
      unawaited(_handlePendingAndroidCallAction());
      // Pending notification button tap (Микрофон/Завершить) ждёт
      // в SharedPreferences пока app resumes — consume & apply.
      unawaited(_consumePendingForegroundNotificationAction());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dismissStaleNativeIncomingCalls();
    _cancelRingingRecovery();
    _cancelActiveCallRecovery();
    _clearReconnectRestoredBanner();
    _cancelReconnectWatchdog();
    _audioRouteService.removeListener(_handleAudioRouteChanged);
    unawaited(_callEventsSubscription?.cancel());
    unawaited(_realtimeSubscription?.cancel());
    unawaited(_pushSubscription?.cancel());
    unawaited(_setWakelockActive(false));
    unawaited(_audioRouteService.setProximityEnabled(false));
    unawaited(_stopForegroundService(force: true));
    unawaited(_disposeRoom());
    super.dispose();
  }

  /// Test seam — exposes call media defaults without a real LiveKit Room.
  @visibleForTesting
  static RoomOptions get debugCallRoomOptions => _callRoomOptions;

  @visibleForTesting
  static ConnectOptions get debugCallConnectOptions => _callConnectOptions;

  /// Test seam — позволяет flip'ать `microphonePublishFailed` без
  /// настоящей LiveKit Room. Используется unit-test'ом для проверки
  /// что getter + notifier работают на boundary. Production-кода это
  /// никогда не вызывает.
  @visibleForTesting
  void debugMarkMicrophonePublishFailed(bool failed) {
    if (_microphonePublishFailed == failed) {
      return;
    }
    _microphonePublishFailed = failed;
    if (failed) {
      _microphoneEnabled = false;
    }
    notifyListeners();
  }

  /// Test seam — камерное зеркало [debugMarkMicrophonePublishFailed]:
  /// flip'ает `cameraPublishFailed` без настоящей LiveKit Room для
  /// unit-проверки getter + notifier boundary. Production-кода это
  /// никогда не вызывает.
  @visibleForTesting
  void debugMarkCameraPublishFailed(bool failed) {
    if (_cameraPublishFailed == failed) {
      return;
    }
    _cameraPublishFailed = failed;
    if (failed) {
      _cameraEnabled = false;
    }
    notifyListeners();
  }

  /// Test seam — direct set `_cameraEnabled` для проверки Fix B
  /// preservation flow. Production-кода не использует.
  @visibleForTesting
  void debugSetCameraEnabled(bool value) {
    if (_cameraEnabled == value) {
      return;
    }
    _cameraEnabled = value;
    notifyListeners();
  }

  /// Test seam — flag pretending что LiveKit Room is connected, чтобы
  /// `_applyCall` preservation path для Fix B можно было exercise без
  /// настоящего room mock. Production-кода это field никогда не sets.
  @visibleForTesting
  bool debugTreatRoomAsActive = false;

  /// Test seam — directly invokes the same diff-apply logic как
  /// `_syncMediaStateFromLiveKit`, но без необходимости Room/Participant
  /// instance. Verifies change detection + notify-on-diff invariant
  /// (Fix C). Production-кода не использует.
  @visibleForTesting
  void debugApplyMediaSync({
    required bool micEnabled,
    required bool camEnabled,
  }) {
    var changed = false;
    if (_microphoneEnabled != micEnabled) {
      _microphoneEnabled = micEnabled;
      changed = true;
    }
    if (_cameraEnabled != camEnabled) {
      _cameraEnabled = camEnabled;
      changed = true;
    }
    // Mirror production `_syncMediaStateFromLiveKit` defensive
    // reconciliation: clear stale microphonePublishFailed когда
    // mic actually published per LiveKit truth.
    if (micEnabled && _microphonePublishFailed) {
      _microphonePublishFailed = false;
      changed = true;
    }
    if (camEnabled && _cameraPublishFailed) {
      _cameraPublishFailed = false;
      changed = true;
    }
    if (changed) {
      notifyListeners();
      unawaited(_updateForegroundService());
    }
  }
}
