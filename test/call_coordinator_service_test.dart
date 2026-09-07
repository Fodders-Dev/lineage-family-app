import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:rodnya/backend/interfaces/call_service_interface.dart';
import 'package:rodnya/models/call_event.dart';
import 'package:rodnya/models/call_invite.dart';
import 'package:rodnya/models/call_media_mode.dart';
import 'package:rodnya/models/call_session.dart';
import 'package:rodnya/models/call_state.dart';
import 'package:rodnya/services/android_incoming_call_service.dart';
import 'package:rodnya/services/call_coordinator_service.dart';
import 'package:rodnya/services/call_foreground_service.dart';
import 'package:rodnya/services/call_preferences.dart';
import 'package:rodnya/services/rustore_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('CallCoordinatorService uses voice-first LiveKit media defaults', () {
    final roomOptions = CallCoordinatorService.debugCallRoomOptions;
    final connectOptions = CallCoordinatorService.debugCallConnectOptions;

    expect(roomOptions.adaptiveStream, isTrue);
    expect(roomOptions.dynacast, isTrue);
    expect(roomOptions.defaultCameraCaptureOptions.params,
        VideoParametersPresets.h720_169);
    expect(roomOptions.defaultCameraCaptureOptions.maxFrameRate, 30);
    expect(roomOptions.defaultAudioCaptureOptions.highPassFilter, isTrue);
    expect(roomOptions.defaultAudioCaptureOptions.noiseSuppression, isTrue);
    expect(roomOptions.defaultAudioCaptureOptions.echoCancellation, isTrue);
    expect(roomOptions.defaultAudioPublishOptions.encoding?.maxBitrate, 32000);
    expect(
      roomOptions.defaultVideoPublishOptions.videoEncoding?.maxBitrate,
      2000 * 1000,
    );
    expect(connectOptions.rtcConfiguration.isDscpEnabled, isTrue);
  });

  test(
    'CallCoordinatorService resyncs active call on resume even without a current call',
    () async {
      final service = _CountingCallService(
        activeCall: _buildCall(state: CallState.ringing),
      );
      final coordinator = CallCoordinatorService(callService: service);

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      service.resetCounters();

      coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(service.activeCallRequests, greaterThanOrEqualTo(1));
      expect(coordinator.currentCall?.id, 'call-1');

      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService exposes media permission issue before room connect',
    () async {
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(
        callService: service,
        mediaPermissionRequester: (_) async => false,
      );

      await coordinator.activateCall(
        _buildCall(
          state: CallState.active,
          session: const CallSession(
            roomName: 'room-1',
            url: 'wss://livekit.example.test',
            token: 'token-1',
            participantIdentity: 'user-1',
          ),
        ),
      );

      expect(coordinator.hasMediaPermissionIssue, isTrue);
      // Аудио-звонок → сообщение только про микрофон (UX-аудит P1:
      // «или камере» пугало, хотя камера не запрашивалась вовсе).
      expect(
        coordinator.connectionError,
        'Нет доступа к микрофону. Разрешите доступ в настройках приложения.',
      );
      expect(coordinator.isConnectingRoom, isFalse);
      expect(coordinator.room, isNull);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'requestForegroundPresentation applies the call and arms a one-shot '
    'foreground request the host consumes exactly once',
    () async {
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(callService: service);
      // Let the constructor's initial resync settle so its _applyCall(null)
      // can't clobber the call we present.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final call = _buildCall(state: CallState.active);
      await coordinator.requestForegroundPresentation(call);

      expect(coordinator.currentCall?.id, call.id);
      // The host consumes the request to FORCE-present (overriding a stale
      // dismissal); it must fire exactly once, then clear so later notifies
      // don't re-hijack the UI.
      expect(coordinator.consumeForegroundPresentationRequest(call.id), isTrue);
      expect(coordinator.consumeForegroundPresentationRequest(call.id), isFalse);

      coordinator.dispose();
    },
  );

  test(
    'requestForegroundPresentation ignores a terminal call — no foreground '
    'request is armed',
    () async {
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(callService: service);
      final ended = _buildCall(state: CallState.ended);

      await coordinator.requestForegroundPresentation(ended);

      expect(
        coordinator.consumeForegroundPresentationRequest(ended.id),
        isFalse,
        reason: 'a terminal call must never arm a foreground present',
      );
      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService starts foreground service on active call '
    'and stops on terminal',
    () async {
      final service = _CountingCallService(activeCall: null);
      final foreground = _FakeCallForegroundService();
      final coordinator = CallCoordinatorService(
        callService: service,
        // mediaPermissionRequester denied — coordinator bail'нет ДО
        // room.connect, но foreground service start вызывается ПЕРЕД
        // _ensureConnected (Bug A fix design — mic capture survival
        // на Android 14+ требует service alive ДО mic publish).
        mediaPermissionRequester: (_) async => false,
        callForegroundService: foreground,
      );

      // Settle initial ensureRuntimeReady resync (constructor schedules
      // its own resync → _applyCall(null) → _stopForegroundService).
      // Без этого resync race'нётся с activateCall и стоп flush'ит
      // foreground service flag сразу после start, ломая assertion.
      await coordinator.ensureRuntimeReady();

      final activeCall = _buildCall(
        state: CallState.active,
        session: const CallSession(
          roomName: 'room-1',
          url: 'wss://livekit.example.test',
          token: 'token-1',
          participantIdentity: 'user-1',
        ),
      );

      // Reset counters перед activate, чтобы initial resync stop'ы
      // не learked в подсчёт.
      foreground.startCalls = 0;
      foreground.updateCalls = 0;
      foreground.stopCalls = 0;

      await coordinator.activateCall(activeCall);

      expect(foreground.startCalls, greaterThanOrEqualTo(1));
      expect(foreground.lastStartCallId, 'call-1');
      expect(foreground.lastStartIsVideo, isFalse);
      expect(foreground.lastStartMicEnabled, isTrue);

      // Reset stopCalls перед terminal transition, чтобы verify
      // что именно terminal triggered stop.
      foreground.stopCalls = 0;

      // Terminal transition → stop foreground service.
      final terminalCall = _buildCall(
        state: CallState.ended,
        updatedAt: DateTime(2026, 4, 20, 10, 5),
      );
      await coordinator.activateCall(terminalCall);

      expect(foreground.stopCalls, greaterThanOrEqualTo(1));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService stops foreground service на explicit reset',
    () async {
      final service = _CountingCallService(activeCall: null);
      final foreground = _FakeCallForegroundService();
      final coordinator = CallCoordinatorService(
        callService: service,
        mediaPermissionRequester: (_) async => false,
        callForegroundService: foreground,
      );

      await coordinator.ensureRuntimeReady();
      foreground.startCalls = 0;
      foreground.stopCalls = 0;

      await coordinator.activateCall(
        _buildCall(
          state: CallState.active,
          session: const CallSession(
            roomName: 'room-1',
            url: 'wss://livekit.example.test',
            token: 'token-1',
            participantIdentity: 'user-1',
          ),
        ),
      );
      expect(foreground.startCalls, greaterThanOrEqualTo(1));

      foreground.stopCalls = 0;
      await coordinator.reset();
      expect(foreground.stopCalls, greaterThanOrEqualTo(1));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService tracks only calls started by this app session',
    () async {
      final service = _CountingCallService(
        activeCall: _buildCall(state: CallState.ringing),
      );
      final coordinator = CallCoordinatorService(callService: service);

      await coordinator.ensureRuntimeReady();

      final startedCall = await coordinator.startCall(
        chatId: 'chat-1',
        mediaMode: CallMediaMode.audio,
      );

      expect(coordinator.isLocallyStartedCall(startedCall.id), isTrue);

      await coordinator.activateCall(
        startedCall.copyWith(
          state: CallState.cancelled,
          updatedAt: DateTime(2026, 4, 20, 10, 2),
          endedAt: DateTime(2026, 4, 20, 10, 2),
          endedReason: 'cancelled',
        ),
      );

      expect(coordinator.isLocallyStartedCall(startedCall.id), isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService dismisses native incoming UI when call is answered elsewhere',
    () async {
      final incomingCall = _buildCall(state: CallState.ringing);
      final service = _CountingCallService(activeCall: null);
      final androidCalls = _FakeAndroidIncomingCallService(null);
      final coordinator = CallCoordinatorService(
        callService: service,
        androidIncomingCallService: androidCalls,
      );

      await coordinator.ensureRuntimeReady();

      await coordinator.activateCall(incomingCall);
      await Future<void>.delayed(Duration.zero);
      androidCalls.dismissedCallIds.clear();

      await coordinator.activateCall(
        incomingCall.copyWith(
          state: CallState.active,
          joinedOnAnotherDevice: true,
          updatedAt: DateTime(2026, 4, 20, 10, 2),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(androidCalls.dismissedCallIds, contains(incomingCall.id));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService never surfaces the raw initiatorId as the '
    'native caller name (watch «21433289429097» regression)',
    () async {
      final incomingCall = _buildCall(state: CallState.ringing);
      final service = _CountingCallService(activeCall: null);
      final androidCalls = _FakeAndroidIncomingCallService(null);
      final coordinator = CallCoordinatorService(
        callService: service,
        androidIncomingCallService: androidCalls,
      );

      await coordinator.ensureRuntimeReady();
      await coordinator.activateCall(incomingCall);
      await Future<void>.delayed(Duration.zero);

      expect(androidCalls.shownCallIds, contains(incomingCall.id));
      // Without a VKPNS push name we must pass an empty string (native side
      // shows its neutral «Родня» label), NEVER the initiatorId UUID.
      expect(androidCalls.shownCallerNames, isNot(contains('user-2')));
      expect(androidCalls.shownCallerNames.last, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService dismisses a superseded native incoming call '
    'when a different call becomes current (orphan watch phantom)',
    () async {
      final callA = _buildCall(id: 'call-a', state: CallState.ringing);
      final callB = _buildCall(
        id: 'call-b',
        state: CallState.ringing,
        updatedAt: DateTime(2026, 4, 20, 10, 5),
      );
      final service = _CountingCallService(activeCall: null);
      final androidCalls = _FakeAndroidIncomingCallService(null);
      final coordinator = CallCoordinatorService(
        callService: service,
        androidIncomingCallService: androidCalls,
      );

      await coordinator.ensureRuntimeReady();

      await coordinator.activateCall(callA);
      await Future<void>.delayed(Duration.zero);
      expect(androidCalls.shownCallIds, contains('call-a'));
      androidCalls.dismissedCallIds.clear();

      // A different call rings — the earlier one is now orphaned and must be
      // torn down natively (else its Telecom connection strands on the watch).
      await coordinator.activateCall(callB);
      await Future<void>.delayed(Duration.zero);

      expect(androidCalls.dismissedCallIds, contains('call-a'));
      expect(androidCalls.shownCallIds, contains('call-b'));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService dismisses native UI for a terminal snapshot of a '
    'non-current call (ignore-gate would otherwise strand it)',
    () async {
      final current = _buildCall(id: 'call-a', state: CallState.ringing);
      final service = _CountingCallService(activeCall: null);
      final androidCalls = _FakeAndroidIncomingCallService(null);
      final coordinator = CallCoordinatorService(
        callService: service,
        androidIncomingCallService: androidCalls,
      );

      await coordinator.ensureRuntimeReady();
      await coordinator.activateCall(current);
      await Future<void>.delayed(Duration.zero);
      androidCalls.dismissedCallIds.clear();

      // A terminal snapshot arrives for a *different* call. The ignore-gate
      // drops it, and the terminal branch returns early because it isn't
      // _currentCall — but the native incoming UI must still be dismissed
      // (this is the push-path Telecom connection the coordinator never
      // tracked in its shown-set).
      await coordinator.activateCall(
        _buildCall(
          id: 'call-b',
          state: CallState.ended,
          updatedAt: DateTime(2026, 4, 20, 10, 6),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(androidCalls.dismissedCallIds, contains('call-b'));
      // The current call is untouched — it stays ringing.
      expect(coordinator.currentCall?.id, 'call-a');

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService Fix A: un-mute updates microphoneEnabled '
    'через debugApplyMediaSync mirror того что _publishLocalMicrophone '
    'success path should leave',
    () async {
      // Bug 2 repro: pre-fix toggleMicrophone enable path вызывал
      // _publishLocalMicrophone (which set _microphoneEnabled = false
      // only на failure) но НЕ sets к true на success — поле застревал
      // в false после mute, UI showed «mic off» хотя peer слышит.
      // Fix A добавил `_microphoneEnabled = published` после await.
      //
      // Unit test'е без real Room мы exercise эквивалентный путь:
      // debugApplyMediaSync соответствует тому же diff-detect логике
      // (mic enabled flag transitions от false к true когда LiveKit
      // truth == true).
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(callService: service);

      // Simulate mute first — sets _microphoneEnabled = false
      coordinator.debugApplyMediaSync(micEnabled: false, camEnabled: false);
      expect(coordinator.microphoneEnabled, isFalse);

      // Simulate un-mute success — Fix A guarantees _microphoneEnabled
      // tracks LiveKit truth.
      coordinator.debugApplyMediaSync(micEnabled: true, camEnabled: false);
      expect(coordinator.microphoneEnabled, isTrue);

      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService Fix B: _applyCall preserves cameraEnabled '
    'когда room считается connected (audio→video upgrade override)',
    () async {
      // Bug 3 repro: user в audio call activated camera локально через
      // toggleCamera (audio→video upgrade), preview появилось. Затем
      // recovery snapshot каждые 2s вызывал _applyCall(audioCall),
      // line 752 reset'ил _cameraEnabled = false → preview disappeared
      // хотя publication active → peer всё ещё видел.
      // Fix B обернул reset в `if (_room == null)` — preservation на
      // connected room. Unit test'е используем debugTreatRoomAsActive
      // чтобы exercise preservation path без real Room mock.
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(
        callService: service,
        mediaPermissionRequester: (_) async => false,
      );

      await coordinator.ensureRuntimeReady();

      // Simulate locally-activated camera (audio→video upgrade)
      coordinator.debugSetCameraEnabled(true);
      coordinator.debugTreatRoomAsActive = true;
      expect(coordinator.cameraEnabled, isTrue);

      // Trigger _applyCall с audio mediaMode — recovery snapshot path.
      final audioCall = _buildCall(
        state: CallState.active,
        mediaMode: CallMediaMode.audio,
        session: const CallSession(
          roomName: 'room-1',
          url: 'wss://livekit.example.test',
          token: 'token-1',
          participantIdentity: 'user-1',
        ),
      );
      await coordinator.activateCall(audioCall);

      // Fix B: camera flag preserved потому что мы treat room as active.
      expect(coordinator.cameraEnabled, isTrue);

      // Sanity — без preservation flag _applyCall очистил бы.
      coordinator.debugTreatRoomAsActive = false;
      coordinator.debugSetCameraEnabled(true);
      await coordinator.activateCall(
        _buildCall(
          state: CallState.active,
          mediaMode: CallMediaMode.audio,
          updatedAt: DateTime(2026, 4, 20, 10, 10),
          session: const CallSession(
            roomName: 'room-1',
            url: 'wss://livekit.example.test',
            token: 'token-1',
            participantIdentity: 'user-1',
          ),
        ),
      );
      expect(coordinator.cameraEnabled, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService Q1 false-positive fix: media sync clears '
    'stale microphonePublishFailed когда mic actually published',
    () async {
      // Q1 false positive race (post-Bug A device-verify): Q1
      // immediate check фired snackbar когда LiveKit publication
      // table briefly empty между setMicrophoneEnabled return и
      // LocalTrackPublishedEvent fire. Fix C event listener corrected
      // _microphoneEnabled но не clear'ил _microphonePublishFailed
      // → banner persisted пока user не reset call.
      //
      // Defensive reconciliation в _syncMediaStateFromLiveKit clears
      // flag когда LiveKit truth confirms mic is published.
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(callService: service);

      // Simulate Q1 false positive: flag set, mic считается off.
      coordinator.debugMarkMicrophonePublishFailed(true);
      expect(coordinator.microphonePublishFailed, isTrue);
      expect(coordinator.microphoneEnabled, isFalse);

      // Simulate Fix C event-driven sync: LiveKit truth says mic IS
      // published. Helper должен update _microphoneEnabled И clear
      // stale _microphonePublishFailed flag.
      coordinator.debugApplyMediaSync(micEnabled: true, camEnabled: false);

      expect(coordinator.microphoneEnabled, isTrue);
      expect(coordinator.microphonePublishFailed, isFalse);

      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService Fix C: debugApplyMediaSync notifies '
    'только on diff, no infinite loop',
    () async {
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(callService: service);

      var notifyCount = 0;
      void listener() => notifyCount++;
      coordinator.addListener(listener);

      // Initial state — mic enabled true, cam enabled false (defaults).
      // Sync с same values — no diff, no notify.
      coordinator.debugApplyMediaSync(micEnabled: true, camEnabled: false);
      expect(notifyCount, 0);
      expect(coordinator.microphoneEnabled, isTrue);
      expect(coordinator.cameraEnabled, isFalse);

      // Diff на mic — notify fires once.
      coordinator.debugApplyMediaSync(micEnabled: false, camEnabled: false);
      expect(notifyCount, 1);
      expect(coordinator.microphoneEnabled, isFalse);

      // Diff на cam — notify fires.
      coordinator.debugApplyMediaSync(micEnabled: false, camEnabled: true);
      expect(notifyCount, 2);
      expect(coordinator.cameraEnabled, isTrue);

      // Repeat same values — no notify.
      coordinator.debugApplyMediaSync(micEnabled: false, camEnabled: true);
      expect(notifyCount, 2);

      // Both diff — single notify.
      coordinator.debugApplyMediaSync(micEnabled: true, camEnabled: false);
      expect(notifyCount, 3);

      coordinator.removeListener(listener);
      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService exposes microphonePublishFailed flag и '
    'notifies listeners on transition',
    () async {
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(callService: service);

      // Initial state — flag must be false и mic считается enabled
      // (default state до connect).
      expect(coordinator.microphonePublishFailed, isFalse);
      expect(coordinator.microphoneEnabled, isTrue);

      var notifyCount = 0;
      void listener() => notifyCount++;
      coordinator.addListener(listener);

      // Simulate Bug 1 publish failure scenario через test seam —
      // production-flow это происходит когда LiveKit
      // setMicrophoneEnabled возвращает null publication либо
      // isMicrophoneEnabled() == false после await (Android 14+
      // foreground service absent → mic capture revoked).
      coordinator.debugMarkMicrophonePublishFailed(true);

      expect(coordinator.microphonePublishFailed, isTrue);
      // Truthful UI — mic считается off потому что publication
      // отсутствует. Без этого иконка в CallScreen lies (показывает
      // «mic on» хотя собеседник не слышит).
      expect(coordinator.microphoneEnabled, isFalse);
      expect(notifyCount, 1);

      // Idempotent — flip к тому же значению should be no-op (никакого
      // повторного notify, иначе snackbar fire'нется каждый раз).
      coordinator.debugMarkMicrophonePublishFailed(true);
      expect(notifyCount, 1);

      // Reset path — used когда retry succeeded либо call'reset.
      coordinator.debugMarkMicrophonePublishFailed(false);
      expect(coordinator.microphonePublishFailed, isFalse);
      expect(notifyCount, 2);

      coordinator.removeListener(listener);
      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService media profile: simulcast без per-encoding '
    'приоритетов (иначе нативный addTransceiver отвергает камеру)',
    () {
      // S20 FE 2026-07-04: bitratePriority из videoEncoding LiveKit
      // подставляет только в верхний simulcast-слой, авто-слои q/h
      // остаются с дефолтным low. Нативный WebRTC требует одинаковый
      // bitrate_priority/network_priority у всех encodings и отвергает
      // весь набор («C++ addTransceiver failed») — камера не
      // публикуется ни в одном звонке. Гвардия от возврата поля в
      // профиль; runtime-страховка — _sanitizedVideoPublishOptions.
      final videoPublish = CallCoordinatorService
          .debugCallRoomOptions.defaultVideoPublishOptions;
      if (videoPublish.simulcast) {
        expect(videoPublish.videoEncoding?.bitratePriority, isNull);
        expect(videoPublish.videoEncoding?.networkPriority, isNull);
      }
    },
  );

  test(
    'CallCoordinatorService exposes cameraPublishFailed flag и '
    'notifies listeners on transition',
    () async {
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(callService: service);

      expect(coordinator.cameraPublishFailed, isFalse);
      expect(coordinator.cameraEnabled, isFalse);

      var notifyCount = 0;
      void listener() => notifyCount++;
      coordinator.addListener(listener);

      // Production-flow: _publishLocalCamera вернул false (нативный
      // отказ addTransceiver / permission / HAL). Truthful UI: камера
      // остаётся off, флаг поднят для Q1-баннера в CallScreen.
      coordinator.debugMarkCameraPublishFailed(true);
      expect(coordinator.cameraPublishFailed, isTrue);
      expect(coordinator.cameraEnabled, isFalse);
      expect(notifyCount, 1);

      // Idempotent — повторный set того же значения без notify,
      // иначе snackbar перепоказывался бы на каждый notifyListeners.
      coordinator.debugMarkCameraPublishFailed(true);
      expect(notifyCount, 1);

      coordinator.debugMarkCameraPublishFailed(false);
      expect(coordinator.cameraPublishFailed, isFalse);
      expect(notifyCount, 2);

      coordinator.removeListener(listener);
      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService media sync clears stale cameraPublishFailed '
    'когда camera actually published',
    () async {
      // Зеркало Q1-reconciliation микрофона: если retry (или поздний
      // LocalTrackPublishedEvent) поднял камеру, stale баннер «камера
      // не подключилась» обязан уйти без пересоздания звонка.
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(callService: service);

      coordinator.debugMarkCameraPublishFailed(true);
      expect(coordinator.cameraPublishFailed, isTrue);
      expect(coordinator.cameraEnabled, isFalse);

      coordinator.debugApplyMediaSync(micEnabled: true, camEnabled: true);

      expect(coordinator.cameraEnabled, isTrue);
      expect(coordinator.cameraPublishFailed, isFalse);

      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService skips background resync when session is missing',
    () async {
      final service = _CountingCallService(
        activeCall: _buildCall(state: CallState.ringing),
        currentUserId: null,
      );
      final coordinator = CallCoordinatorService(callService: service);

      await coordinator.ensureRuntimeReady();
      final activeCall = await coordinator.resync();

      expect(activeCall, isNull);
      expect(service.activeCallRequests, 0);

      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService refreshes microphone and camera device lists',
    () async {
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(
        callService: service,
        audioInputEnumerator: () async => const <MediaDevice>[
          MediaDevice('mic-1', 'USB mic', 'audioinput', null),
        ],
        videoInputEnumerator: () async => const <MediaDevice>[
          MediaDevice('camera-1', 'Front Camera', 'videoinput', null),
        ],
      );

      await coordinator.refreshInputDevices();

      expect(coordinator.microphoneDevices.single.deviceId, 'mic-1');
      expect(coordinator.cameraDevices.single.deviceId, 'camera-1');
      expect(coordinator.selectedMicrophoneDeviceId, 'mic-1');
      expect(coordinator.selectedCameraDeviceId, 'camera-1');
      expect(coordinator.devicePickerErrorMessage, isNull);

      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService hydrates incoming call from RuStore push payload',
    () async {
      final pushMessages = StreamController<RustorePushMessage>.broadcast();
      final pushedCall = _buildCall(state: CallState.ringing);
      final service = _CountingCallService(
        activeCall: null,
        callById: pushedCall,
      );
      final coordinator = CallCoordinatorService(
        callService: service,
        pushMessages: pushMessages.stream,
      );

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      service.resetCounters();

      pushMessages.add(
        const RustorePushMessage(
          messageId: 'push-1',
          data: <String, String>{
            'type': 'call_invite',
            'callId': 'call-1',
            'chatId': 'chat-1',
          },
          title: 'Caller',
          body: 'Видеозвонок',
        ),
      );

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(service.callByIdRequests, 1);
      expect(coordinator.currentCall?.id, 'call-1');
      expect(coordinator.currentCall?.state, CallState.ringing);

      await pushMessages.close();
      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService accepts pending Android telecom action',
    () async {
      final incomingCall = _buildCall(state: CallState.ringing);
      final acceptedCall = _buildCall(
        state: CallState.active,
        session: const CallSession(
          roomName: 'room-1',
          url: 'wss://livekit.example.test',
          token: 'token-1',
          participantIdentity: 'user-1',
        ),
      );
      final service = _CountingCallService(
        activeCall: incomingCall,
        callById: incomingCall,
      )..acceptResult = acceptedCall;
      final androidCalls = _FakeAndroidIncomingCallService(
        const AndroidCallAction(
          action: 'accept',
          callId: 'call-1',
          chatId: 'chat-1',
        ),
      );
      final coordinator = CallCoordinatorService(
        callService: service,
        androidIncomingCallService: androidCalls,
        mediaPermissionRequester: (_) async => false,
      );

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(androidCalls.registerPhoneAccountCalls, 1);
      expect(androidCalls.consumePendingActionCalls, 1);
      expect(service.acceptCallRequests, 1);
      expect(coordinator.currentCall?.state, CallState.active);

      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService ignores terminal updates for another call id',
    () async {
      final events = StreamController<CallEvent>.broadcast();
      final activeCall = _buildCall(
        state: CallState.active,
        session: const CallSession(
          roomName: 'room-1',
          url: 'wss://livekit.example.test',
          token: 'token-1',
          participantIdentity: 'user-1',
        ),
      );
      final service = _CountingCallService(
        activeCall: activeCall,
        events: events.stream,
      );
      final coordinator = CallCoordinatorService(
        callService: service,
        mediaPermissionRequester: (_) async => false,
      );

      await coordinator.activateCall(activeCall);
      expect(coordinator.currentCall?.id, 'call-1');
      expect(coordinator.currentCall?.state, CallState.active);

      events.add(
        CallEvent(
          type: CallEventType.stateUpdated,
          call: _buildCall(
            id: 'call-legacy',
            state: CallState.missed,
          ),
        ),
      );

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(coordinator.currentCall?.id, 'call-1');
      expect(coordinator.currentCall?.state, CallState.active);

      await events.close();
      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService ignores stale same-call downgrade snapshot',
    () async {
      final events = StreamController<CallEvent>.broadcast();
      final activeCall = _buildCall(
        state: CallState.active,
        updatedAt: DateTime(2026, 4, 20, 10, 5),
        session: const CallSession(
          roomName: 'room-1',
          url: 'wss://livekit.example.test',
          token: 'token-1',
          participantIdentity: 'user-1',
        ),
      );
      final service = _CountingCallService(
        activeCall: activeCall,
        events: events.stream,
      );
      final coordinator = CallCoordinatorService(
        callService: service,
        mediaPermissionRequester: (_) async => false,
      );

      await coordinator.activateCall(activeCall);

      events.add(
        CallEvent(
          type: CallEventType.inviteCreated,
          call: _buildCall(
            state: CallState.ringing,
            updatedAt: DateTime(2026, 4, 20, 10, 1),
          ),
        ),
      );

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(coordinator.currentCall?.state, CallState.active);
      expect(coordinator.currentCall?.session, isNotNull);

      await events.close();
      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService applies terminal same-call snapshot even when stale',
    () async {
      final events = StreamController<CallEvent>.broadcast();
      final activeCall = _buildCall(
        state: CallState.active,
        updatedAt: DateTime(2026, 4, 20, 10, 5),
        session: const CallSession(
          roomName: 'room-1',
          url: 'wss://livekit.example.test',
          token: 'token-1',
          participantIdentity: 'user-1',
        ),
      );
      final service = _CountingCallService(
        activeCall: activeCall,
        events: events.stream,
      );
      final coordinator = CallCoordinatorService(
        callService: service,
        mediaPermissionRequester: (_) async => false,
      );

      await coordinator.activateCall(activeCall);

      events.add(
        CallEvent(
          type: CallEventType.stateUpdated,
          call: _buildCall(
            state: CallState.ended,
            updatedAt: DateTime(2026, 4, 20, 10, 1),
          ),
        ),
      );

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(coordinator.currentCall, isNull);

      await events.close();
      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService refreshes active call until terminal state',
    () async {
      final activeCall = _buildCall(
        state: CallState.active,
        session: const CallSession(
          roomName: 'room-1',
          url: 'wss://livekit.example.test',
          token: 'token-1',
          participantIdentity: 'user-1',
        ),
      );
      final service = _CountingCallService(activeCall: activeCall);
      final coordinator = CallCoordinatorService(
        callService: service,
        mediaPermissionRequester: (_) async => false,
        activeCallRecoveryInterval: const Duration(milliseconds: 20),
      );

      await coordinator.activateCall(activeCall);
      service.callById = _buildCall(
        state: CallState.ended,
        updatedAt: DateTime(2026, 4, 20, 10, 2),
      );

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(service.callByIdRequests, greaterThanOrEqualTo(1));
      expect(coordinator.currentCall, isNull);

      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService refreshes stale ringing call until terminal state',
    () async {
      final service = _CountingCallService(
        activeCall: _buildCall(state: CallState.ringing),
      );
      final coordinator = CallCoordinatorService(
        callService: service,
        ringingRecoveryInterval: const Duration(milliseconds: 20),
      );

      await coordinator.activateCall(_buildCall(state: CallState.ringing));
      service.callById = _buildCall(
        state: CallState.missed,
        updatedAt: DateTime(2026, 4, 20, 10, 2),
      );

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(service.callByIdRequests, greaterThanOrEqualTo(1));
      expect(coordinator.currentCall, isNull);

      coordinator.dispose();
    },
  );

  test(
    'CallCoordinatorService uses call preferences for incoming vibration',
    () async {
      final service = _CountingCallService(activeCall: null);
      var vibrationCount = 0;
      final coordinator = CallCoordinatorService(
        callService: service,
        callPreferences: MemoryCallPreferences(
          CallPreferencesSnapshot.defaults(),
        ),
        vibrationTrigger: () async {
          vibrationCount += 1;
        },
      );

      await coordinator.ensureRuntimeReady();

      await coordinator.activateCall(_buildCall(state: CallState.ringing));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(vibrationCount, 1);

      await coordinator.activateCall(
        _buildCall(
          state: CallState.ringing,
          updatedAt: DateTime(2026, 4, 20, 10, 2),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(vibrationCount, 1);

      coordinator.dispose();
    },
  );

  test(
    'Гигиена звонков: wakelock держится на живом звонке и отпускается '
    'на terminal',
    () async {
      final service = _CountingCallService(activeCall: null);
      final wakelockLog = <bool>[];
      final coordinator = CallCoordinatorService(
        callService: service,
        mediaPermissionRequester: (_) async => false,
        wakelockToggler: (enable) async => wakelockLog.add(enable),
      );

      await coordinator.ensureRuntimeReady();
      wakelockLog.clear();

      // Ringing — уже живой звонок, экран не должен гаснуть.
      await coordinator.activateCall(_buildCall(state: CallState.ringing));
      expect(wakelockLog, contains(true));

      // Recovery-snapshot того же звонка — идемпотентно, без
      // повторного platform-вызова.
      wakelockLog.clear();
      await coordinator.activateCall(
        _buildCall(
          state: CallState.active,
          updatedAt: DateTime(2026, 4, 20, 10, 2),
          session: const CallSession(
            roomName: 'room-1',
            url: 'wss://livekit.example.test',
            token: 'token-1',
            participantIdentity: 'user-1',
          ),
        ),
      );
      expect(wakelockLog, isEmpty);

      // Terminal — отпускаем.
      await coordinator.activateCall(
        _buildCall(
          state: CallState.ended,
          updatedAt: DateTime(2026, 4, 20, 10, 5),
        ),
      );
      expect(wakelockLog, contains(false));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'Гигиена звонков: activeSince латчится один раз (acceptedAt) и '
    'чистится на terminal',
    () async {
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(
        callService: service,
        mediaPermissionRequester: (_) async => false,
        wakelockToggler: (_) async {},
      );

      await coordinator.ensureRuntimeReady();
      expect(coordinator.activeSince, isNull);

      const session = CallSession(
        roomName: 'room-1',
        url: 'wss://livekit.example.test',
        token: 'token-1',
        participantIdentity: 'user-1',
      );
      // Первый снапшот УЖЕ active (рестарт / late-join) → база из
      // серверного acceptedAt (переживает рестарт приложения).
      final accepted = DateTime.now().subtract(const Duration(minutes: 5));
      await coordinator.activateCall(
        _buildCall(
          state: CallState.active,
          acceptedAt: accepted,
          session: session,
        ),
      );
      expect(coordinator.activeSince, accepted);

      // Recovery-snapshot с другим acceptedAt не перезапускает отсчёт.
      await coordinator.activateCall(
        _buildCall(
          state: CallState.active,
          acceptedAt: accepted.add(const Duration(minutes: 1)),
          updatedAt: DateTime(2026, 4, 20, 10, 2),
          session: session,
        ),
      );
      expect(coordinator.activeSince, accepted);

      await coordinator.activateCall(
        _buildCall(
          state: CallState.ended,
          updatedAt: DateTime(2026, 4, 20, 10, 5),
        ),
      );
      expect(coordinator.activeSince, isNull);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'Гигиена звонков: activeSince латчится локальным временем без acceptedAt',
    () async {
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(
        callService: service,
        mediaPermissionRequester: (_) async => false,
        wakelockToggler: (_) async {},
      );

      await coordinator.ensureRuntimeReady();

      final before = DateTime.now();
      await coordinator.activateCall(
        _buildCall(
          state: CallState.active,
          session: const CallSession(
            roomName: 'room-1',
            url: 'wss://livekit.example.test',
            token: 'token-1',
            participantIdentity: 'user-1',
          ),
        ),
      );
      final after = DateTime.now();

      final since = coordinator.activeSince;
      expect(since, isNotNull);
      expect(since!.isBefore(before), isFalse);
      expect(since.isAfter(after), isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'Дебаунс: параллельные acceptCall одного звонка → один API-вызов',
    () async {
      final service = _CountingCallService(
        activeCall: _buildCall(state: CallState.ringing),
      );
      final coordinator = CallCoordinatorService(
        callService: service,
        mediaPermissionRequester: (_) async => false,
        wakelockToggler: (_) async {},
      );

      await coordinator.ensureRuntimeReady();
      service.acceptCallRequests = 0;

      // Double-tap по «Принять»: оба вызова стартуют до первого await.
      final results = await Future.wait([
        coordinator.acceptCall('call-1'),
        coordinator.acceptCall('call-1'),
      ]);

      expect(service.acceptCallRequests, 1);
      expect(results[0].id, results[1].id);

      // После завершения memo снят — следующий accept снова идёт в API.
      await coordinator.acceptCall('call-1');
      expect(service.acceptCallRequests, 2);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'Дебаунс: параллельные finishCall одного звонка → один hangUp',
    () async {
      final activeCall = _buildCall(
        state: CallState.active,
        session: const CallSession(
          roomName: 'room-1',
          url: 'wss://livekit.example.test',
          token: 'token-1',
          participantIdentity: 'user-1',
        ),
      );
      final service = _CountingCallService(activeCall: activeCall);
      final coordinator = CallCoordinatorService(
        callService: service,
        mediaPermissionRequester: (_) async => false,
        wakelockToggler: (_) async {},
      );

      await coordinator.ensureRuntimeReady();
      await coordinator.activateCall(activeCall);
      service.hangUpRequests = 0;

      await Future.wait([
        coordinator.finishCall('call-1'),
        coordinator.finishCall('call-1'),
      ]);

      expect(service.hangUpRequests, 1);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'Гигиена звонков: живой переход ringing→active латчится локальными '
    'часами (без серверного дрейфа)',
    () async {
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(
        callService: service,
        mediaPermissionRequester: (_) async => false,
        wakelockToggler: (_) async {},
      );

      await coordinator.ensureRuntimeReady();
      await coordinator.activateCall(_buildCall(state: CallState.ringing));

      // Серверные часы «уехали» на минуту вперёд — наблюдённый живой
      // переход должен игнорировать acceptedAt и взять локальное время.
      final skewedAccepted = DateTime.now().add(const Duration(minutes: 1));
      final before = DateTime.now();
      await coordinator.activateCall(
        _buildCall(
          state: CallState.active,
          acceptedAt: skewedAccepted,
          updatedAt: DateTime(2026, 4, 20, 10, 2),
          session: const CallSession(
            roomName: 'room-1',
            url: 'wss://livekit.example.test',
            token: 'token-1',
            participantIdentity: 'user-1',
          ),
        ),
      );
      final after = DateTime.now();

      final since = coordinator.activeSince;
      expect(since, isNotNull);
      expect(since!.isBefore(before), isFalse);
      expect(since.isAfter(after), isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'Гигиена звонков: acceptedAt из будущего клампится в локальное сейчас',
    () async {
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(
        callService: service,
        mediaPermissionRequester: (_) async => false,
        wakelockToggler: (_) async {},
      );

      await coordinator.ensureRuntimeReady();

      // Первый снапшот сразу active (рестарт) при часах устройства,
      // отстающих от сервера: таймер не должен замерзать на 0:00.
      final before = DateTime.now();
      await coordinator.activateCall(
        _buildCall(
          state: CallState.active,
          acceptedAt: DateTime.now().add(const Duration(seconds: 45)),
          session: const CallSession(
            roomName: 'room-1',
            url: 'wss://livekit.example.test',
            token: 'token-1',
            participantIdentity: 'user-1',
          ),
        ),
      );
      final after = DateTime.now();

      final since = coordinator.activeSince;
      expect(since, isNotNull);
      expect(since!.isBefore(before), isFalse);
      expect(since.isAfter(after), isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'Гигиена звонков: joinedOnAnotherDevice не дёргает wakelock on/off',
    () async {
      final service = _CountingCallService(activeCall: null);
      final wakelockLog = <bool>[];
      final coordinator = CallCoordinatorService(
        callService: service,
        mediaPermissionRequester: (_) async => false,
        wakelockToggler: (enable) async => wakelockLog.add(enable),
      );

      await coordinator.ensureRuntimeReady();
      wakelockLog.clear();

      final joinedElsewhere = _buildCall(
        state: CallState.active,
        session: const CallSession(
          roomName: 'room-1',
          url: 'wss://livekit.example.test',
          token: 'token-1',
          participantIdentity: 'user-1',
        ),
      ).copyWith(joinedOnAnotherDevice: true);

      await coordinator.activateCall(joinedElsewhere);
      // Recovery-снапшоты того же joined-звонка (2s poll) — ни одного
      // enable и ни одного повторного platform-вызова (ревью P1).
      await coordinator.activateCall(
        joinedElsewhere.copyWith(updatedAt: DateTime(2026, 4, 20, 10, 2)),
      );
      await coordinator.activateCall(
        joinedElsewhere.copyWith(updatedAt: DateTime(2026, 4, 20, 10, 3)),
      );

      expect(wakelockLog, isNot(contains(true)));
      expect(wakelockLog.length, lessThanOrEqualTo(1));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.dispose();
    },
  );

  test(
    'perf(client): hydrateIncomingCall skips the redundant global fallback '
    'when the scoped lookup already found a call',
    () async {
      // Bootstrap with no active call so ensureRuntimeReady's own resync()
      // leaves _currentCall null — otherwise hydrateIncomingCall's
      // already-current-call short-circuit would return without ever
      // reaching _callService.getActiveCall, and this test would pass
      // for the wrong reason (0 requests instead of the fix mattering).
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(callService: service);
      await coordinator.ensureRuntimeReady();
      service.activeCall = _buildCall(state: CallState.ringing);
      service.resetCounters();

      final call = await coordinator.hydrateIncomingCall(chatId: 'chat-1');

      expect(call?.id, 'call-1');
      // Before the fix this fired getActiveCall(chatId: 'chat-1') AND
      // getActiveCall() unconditionally — the exact same request twice
      // whenever the scoped lookup already succeeded.
      expect(service.activeCallRequests, 1);

      coordinator.dispose();
    },
  );

  test(
    'perf(client): hydrateIncomingCall falls back to the global lookup only '
    'when the scoped one comes up empty',
    () async {
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(callService: service);
      await coordinator.ensureRuntimeReady();
      service.resetCounters();

      final call = await coordinator.hydrateIncomingCall(chatId: 'chat-1');

      expect(call, isNull);
      // Scoped lookup (chat-1) came up empty, so the global fallback is
      // legitimate here — exactly one extra request, not more.
      expect(service.activeCallRequests, 2);

      coordinator.dispose();
    },
  );

  test(
    'perf(client): hydrateIncomingCall with no chatId never double-fetches',
    () async {
      final service = _CountingCallService(activeCall: null);
      final coordinator = CallCoordinatorService(callService: service);
      await coordinator.ensureRuntimeReady();
      service.activeCall = _buildCall(state: CallState.ringing);
      service.resetCounters();

      final call = await coordinator.hydrateIncomingCall();

      expect(call?.id, 'call-1');
      // No chatId to begin with → the first lookup IS the global one;
      // the fallback branch must not fire a second time.
      expect(service.activeCallRequests, 1);

      coordinator.dispose();
    },
  );
}

CallInvite _buildCall({
  String id = 'call-1',
  required CallState state,
  CallMediaMode mediaMode = CallMediaMode.audio,
  CallSession? session,
  DateTime? updatedAt,
  DateTime? acceptedAt,
}) {
  return CallInvite(
    id: id,
    chatId: 'chat-1',
    initiatorId: 'user-2',
    recipientId: 'user-1',
    participantIds: const ['user-1', 'user-2'],
    mediaMode: mediaMode,
    state: state,
    createdAt: DateTime(2026, 4, 20, 10),
    updatedAt: updatedAt ?? DateTime(2026, 4, 20, 10, 1),
    acceptedAt: acceptedAt,
    session: session,
  );
}

class _CountingCallService implements CallServiceInterface {
  CallInvite? activeCall;
  CallInvite? callById;
  CallInvite? acceptResult;
  final Stream<CallEvent> _events;
  final String? _currentUserId;
  int activeCallRequests = 0;
  int callByIdRequests = 0;
  int acceptCallRequests = 0;
  int hangUpRequests = 0;

  _CountingCallService._internal({
    required this.activeCall,
    required Stream<CallEvent> events,
    required String? currentUserId,
    this.callById,
  })  : _events = events,
        _currentUserId = currentUserId;

  factory _CountingCallService({
    required CallInvite? activeCall,
    CallInvite? callById,
    Stream<CallEvent>? events,
    String? currentUserId = 'user-1',
  }) {
    return _CountingCallService._internal(
      activeCall: activeCall,
      callById: callById,
      events: events ?? const Stream<CallEvent>.empty(),
      currentUserId: currentUserId,
    );
  }

  void resetCounters() {
    activeCallRequests = 0;
    callByIdRequests = 0;
  }

  @override
  String? get currentUserId => _currentUserId;

  @override
  Stream<CallEvent> get events => _events;

  @override
  Future<CallInvite> acceptCall(String callId) async {
    acceptCallRequests += 1;
    activeCall = acceptResult ?? activeCall;
    return activeCall!;
  }

  @override
  Future<CallInvite> cancelCall(String callId) async => activeCall!;

  @override
  Future<CallInvite?> getActiveCall({String? chatId}) async {
    activeCallRequests += 1;
    return activeCall;
  }

  @override
  Future<CallInvite?> getCall(String callId) async {
    callByIdRequests += 1;
    return callById ?? activeCall;
  }

  @override
  Future<CallInvite> hangUp(String callId) async {
    hangUpRequests += 1;
    return activeCall!;
  }

  @override
  Future<CallInvite> rejectCall(String callId) async => activeCall!;

  @override
  Future<void> startRealtimeBridge() async {}

  @override
  Future<CallInvite> startCall({
    required String chatId,
    required CallMediaMode mediaMode,
    List<String>? participantIds,
  }) async =>
      activeCall!;

  @override
  Future<CallInvite> joinCall(String callId) => acceptCall(callId);

  @override
  Future<CallInvite> nudgeCallParticipants(
    String callId, {
    List<String>? participantIds,
  }) async =>
      activeCall!;

  @override
  Future<void> stopRealtimeBridge() async {}
}

class _FakeCallForegroundService extends CallForegroundService {
  _FakeCallForegroundService() : super();

  int startCalls = 0;
  int updateCalls = 0;
  int stopCalls = 0;
  int consumeActionCalls = 0;
  CallForegroundNotificationAction? pendingAction;
  String? lastStartCallId;
  String? lastStartPeerName;
  bool? lastStartIsVideo;
  bool? lastStartMicEnabled;

  @override
  bool get isSupported => true;

  @override
  Future<bool> start({
    required String callId,
    String? peerName,
    required bool isVideo,
    required bool micEnabled,
  }) async {
    startCalls += 1;
    lastStartCallId = callId;
    lastStartPeerName = peerName;
    lastStartIsVideo = isVideo;
    lastStartMicEnabled = micEnabled;
    return true;
  }

  @override
  Future<bool> update({
    required String callId,
    String? peerName,
    required bool isVideo,
    required bool micEnabled,
  }) async {
    updateCalls += 1;
    return true;
  }

  @override
  Future<bool> stop() async {
    stopCalls += 1;
    return true;
  }

  @override
  Future<CallForegroundNotificationAction?>
      consumePendingNotificationAction() async {
    consumeActionCalls += 1;
    return pendingAction;
  }
}

class _FakeAndroidIncomingCallService extends AndroidIncomingCallService {
  _FakeAndroidIncomingCallService(this.action);

  final AndroidCallAction? action;
  int registerPhoneAccountCalls = 0;
  int consumePendingActionCalls = 0;
  final List<String> shownCallIds = <String>[];
  final List<String> shownCallerNames = <String>[];
  final List<String> dismissedCallIds = <String>[];

  @override
  bool get isSupported => true;

  @override
  Future<bool> registerPhoneAccount() async {
    registerPhoneAccountCalls += 1;
    return true;
  }

  @override
  Future<AndroidCallAction?> consumePendingAction() async {
    consumePendingActionCalls += 1;
    return action;
  }

  @override
  Future<bool> showIncomingCall({
    required String callId,
    required String callerName,
    required bool isVideo,
    String? chatId,
  }) async {
    shownCallIds.add(callId);
    shownCallerNames.add(callerName);
    return true;
  }

  @override
  Future<bool> dismissCall(String callId) async {
    dismissedCallIds.add(callId);
    return true;
  }
}
