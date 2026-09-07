import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../backend/models/user_facing_exception.dart';
import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/call_service_interface.dart';
import '../models/call_event.dart';
import '../models/call_invite.dart';
import '../models/call_media_mode.dart';
import '../utils/client_instance_id.dart';
import '../utils/startup_trace.dart';
import 'custom_api_auth_service.dart';
import 'custom_api_realtime_service.dart';

class CustomApiCallException implements UserFacingApiException {
  const CustomApiCallException(this.message);

  @override
  final String message;

  @override
  int? get statusCode => null;

  @override
  String toString() => message;
}

class CustomApiCallService
    implements CallServiceInterface, CallParticipantAdder {
  CustomApiCallService({
    required CustomApiAuthService authService,
    required BackendRuntimeConfig runtimeConfig,
    http.Client? httpClient,
    CustomApiRealtimeService? realtimeService,
  })  : _authService = authService,
        _runtimeConfig = runtimeConfig,
        _httpClient = httpClient ?? http.Client(),
        _realtimeService = realtimeService;

  final CustomApiAuthService _authService;
  final BackendRuntimeConfig _runtimeConfig;
  final http.Client _httpClient;
  final CustomApiRealtimeService? _realtimeService;
  final StreamController<CallEvent> _eventsController =
      StreamController<CallEvent>.broadcast();

  StreamSubscription<CustomApiRealtimeEvent>? _realtimeSubscription;
  bool _realtimeBridgeStarted = false;

  // perf(client): single-flight for GET /v1/calls/active. Cold start has
  // ~3 independent initiators racing to check for an active/incoming call
  // (CallCoordinatorService's own bootstrap + its realtime "connection.ready"
  // listener + IncomingCallWatcher's own listener on the same event) — all
  // legitimate, none removable without weakening incoming-call recovery.
  // When their requests overlap in time (the common case — the backend
  // response takes longer than the gap between initiators), they now share
  // one in-flight HTTP call keyed by the normalized chatId instead of firing
  // one each. A call that starts AFTER the in-flight one has resolved always
  // issues a fresh request — this is not a TTL cache, just concurrency
  // coalescing, so periodic polling and realtime-driven refreshes still see
  // up-to-date state.
  final Map<String, Future<CallInvite?>> _activeCallInFlight =
      <String, Future<CallInvite?>>{};
  static const String _activeCallGlobalKey = '_global_';

  @override
  String? get currentUserId => _authService.currentUserId;

  @override
  Stream<CallEvent> get events => _eventsController.stream;

  @override
  Future<void> startRealtimeBridge() async {
    if (_realtimeBridgeStarted) {
      return;
    }
    final activeRealtimeService = _realtimeService;
    if (activeRealtimeService == null) {
      return;
    }
    _realtimeBridgeStarted = true;
    await activeRealtimeService.connect();
    await _realtimeSubscription?.cancel();
    _realtimeSubscription = activeRealtimeService.events.listen(
      _handleRealtimeEvent,
    );
  }

  @override
  Future<void> stopRealtimeBridge() async {
    _realtimeBridgeStarted = false;
    await _realtimeSubscription?.cancel();
    _realtimeSubscription = null;
  }

  @override
  Future<CallInvite?> getActiveCall({String? chatId}) {
    final normalizedChatId = chatId?.trim();
    final key = normalizedChatId == null || normalizedChatId.isEmpty
        ? _activeCallGlobalKey
        : normalizedChatId;
    final inFlight = _activeCallInFlight[key];
    if (inFlight != null) {
      return inFlight;
    }
    final future = _fetchActiveCall(normalizedChatId);
    _activeCallInFlight[key] = future;
    unawaited(future.whenComplete(() {
      if (identical(_activeCallInFlight[key], future)) {
        _activeCallInFlight.remove(key);
      }
    }));
    return future;
  }

  Future<CallInvite?> _fetchActiveCall(String? normalizedChatId) async {
    final uri = Uri.parse(
      '${_runtimeConfig.apiBaseUrl}/v1/calls/active',
    ).replace(
      queryParameters: normalizedChatId != null && normalizedChatId.isNotEmpty
          ? <String, String>{'chatId': normalizedChatId}
          : null,
    );
    final response = await _requestJsonOptional(
      method: 'GET',
      uri: uri,
    );
    final payload = response['call'];
    if (payload is! Map<String, dynamic>) {
      return null;
    }
    return CallInvite.fromMap(payload);
  }

  @override
  Future<CallInvite?> getCall(String callId) async {
    final response = await _requestJsonOptional(
      method: 'GET',
      path: '/v1/calls/$callId',
    );
    final payload = response['call'];
    if (payload is! Map<String, dynamic>) {
      return null;
    }
    return CallInvite.fromMap(payload);
  }

  @override
  Future<CallInvite> startCall({
    required String chatId,
    required CallMediaMode mediaMode,
    List<String>? participantIds,
  }) async {
    final normalizedParticipantIds = participantIds
        ?.map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/calls',
      body: {
        'chatId': chatId,
        'mediaMode': mediaMode.value,
        if (normalizedParticipantIds != null &&
            normalizedParticipantIds.isNotEmpty)
          'participantIds': normalizedParticipantIds,
      },
    );
    return _parseCall(response);
  }

  @override
  Future<CallInvite> nudgeCallParticipants(
    String callId, {
    List<String>? participantIds,
  }) async {
    final normalizedParticipantIds = participantIds
        ?.map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/calls/$callId/nudge',
      body: {
        if (normalizedParticipantIds != null &&
            normalizedParticipantIds.isNotEmpty)
          'participantIds': normalizedParticipantIds,
      },
    );
    return _parseCall(response);
  }

  @override
  Future<CallInvite> addCallParticipants(
    String callId, {
    required List<String> participantIds,
  }) async {
    final normalizedParticipantIds = participantIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/calls/$callId/add',
      body: {'participantIds': normalizedParticipantIds},
    );
    return _parseCall(response);
  }

  @override
  Future<CallInvite> acceptCall(String callId) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/calls/$callId/accept',
      body: const <String, dynamic>{},
    );
    return _parseCall(response);
  }

  @override
  Future<CallInvite> joinCall(String callId) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/calls/$callId/join',
      body: const <String, dynamic>{},
    );
    return _parseCall(response);
  }

  @override
  Future<CallInvite> rejectCall(String callId) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/calls/$callId/reject',
      body: const <String, dynamic>{},
    );
    return _parseCall(response);
  }

  @override
  Future<CallInvite> cancelCall(String callId) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/calls/$callId/cancel',
      body: const <String, dynamic>{},
    );
    return _parseCall(response);
  }

  @override
  Future<CallInvite> hangUp(String callId) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/calls/$callId/hangup',
      body: const <String, dynamic>{},
    );
    return _parseCall(response);
  }

  void _handleRealtimeEvent(CustomApiRealtimeEvent event) {
    if (!event.isCallEvent) {
      return;
    }
    final payload = event.call;
    if (payload == null) {
      return;
    }
    _eventsController.add(
      CallEvent(
        type: CallEventType.fromValue(event.type),
        call: CallInvite.fromMap(payload),
      ),
    );
  }

  CallInvite _parseCall(Map<String, dynamic> response) {
    final payload = response['call'];
    if (payload is! Map<String, dynamic>) {
      throw const CustomApiCallException('Ответ звонка поврежден');
    }
    return CallInvite.fromMap(payload);
  }

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) async {
    return _requestJsonOptional(
      method: method,
      path: path,
      body: body,
      allowNotFound: false,
    );
  }

  Future<Map<String, dynamic>> _requestJsonOptional({
    required String method,
    String? path,
    Uri? uri,
    Map<String, dynamic>? body,
    bool allowNotFound = true,
  }) async {
    final accessToken = _authService.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      throw const CustomApiCallException('Сессия недоступна');
    }

    final resolvedUri =
        uri ?? Uri.parse('${_runtimeConfig.apiBaseUrl}${path ?? ''}');
    StartupTrace.logRequest(
      method,
      resolvedUri.hasQuery
          ? '${resolvedUri.path}?${resolvedUri.query}'
          : resolvedUri.path,
    );
    final request = http.Request(method, resolvedUri)
      ..headers['authorization'] = 'Bearer $accessToken'
      ..headers['content-type'] = 'application/json'
      ..headers['x-client-instance-id'] = ClientInstanceId.current;
    if (body != null) {
      request.body = jsonEncode(body);
    }

    final streamedResponse = await _httpClient.send(request);
    final response = await http.Response.fromStream(streamedResponse);
    final decodedBody = response.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (allowNotFound && response.statusCode == 404) {
      return const <String, dynamic>{};
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CustomApiCallException(
        decodedBody['message']?.toString() ?? 'Не удалось выполнить звонок',
      );
    }
    return decodedBody;
  }

  Future<void> dispose() async {
    await stopRealtimeBridge();
    await _eventsController.close();
  }
}
