import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rodnya/backend/backend_runtime_config.dart';
import 'package:rodnya/models/call_event.dart';
import 'package:rodnya/models/call_media_mode.dart';
import 'package:rodnya/models/call_state.dart';
import 'package:rodnya/services/custom_api_auth_service.dart';
import 'package:rodnya/services/custom_api_call_service.dart';
import 'package:rodnya/services/custom_api_realtime_service.dart';
import 'package:rodnya/services/invitation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('CustomApiCallService starts and accepts calls through REST endpoints',
      () async {
    final requestedPaths = <String>[];
    final requestedMethods = <String>[];
    final requestBodies = <Map<String, dynamic>>[];

    final client = MockClient((request) async {
      requestedPaths.add(request.url.path);
      requestedMethods.add(request.method);
      requestBodies.add(
        request.body.isEmpty
            ? const <String, dynamic>{}
            : jsonDecode(request.body) as Map<String, dynamic>,
      );

      if (request.url.path == '/v1/calls' && request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'call': _callPayload(
              state: 'ringing',
              mediaMode: 'video',
            ),
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/calls/call-1/accept' &&
          request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'call': _callPayload(
              state: 'active',
              mediaMode: 'video',
              includeSession: true,
            ),
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/calls/active' && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'call': _callPayload(
              state: 'active',
              mediaMode: 'video',
              includeSession: true,
            ),
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/calls/call-1' && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'call': _callPayload(
              state: 'active',
              mediaMode: 'video',
              includeSession: true,
            ),
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response('{"message":"not found"}', 404);
    });

    final authService = await _createAuthService(client);
    final service = CustomApiCallService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final startedCall = await service.startCall(
      chatId: 'chat-1',
      mediaMode: CallMediaMode.video,
    );
    expect(startedCall.state, CallState.ringing);
    expect(startedCall.mediaMode, CallMediaMode.video);
    expect(startedCall.chatId, 'chat-1');

    final acceptedCall = await service.acceptCall('call-1');
    expect(acceptedCall.state, CallState.active);
    expect(acceptedCall.session, isNotNull);
    expect(acceptedCall.session?.roomName, 'room-1');
    expect(acceptedCall.session?.participantIdentity, 'user-1');

    final activeCall = await service.getActiveCall(chatId: 'chat-1');
    expect(activeCall, isNotNull);
    expect(activeCall?.state, CallState.active);

    final fetchedCall = await service.getCall('call-1');
    expect(fetchedCall, isNotNull);
    expect(fetchedCall?.chatId, 'chat-1');

    expect(requestedMethods, ['POST', 'POST', 'GET', 'GET']);
    expect(requestedPaths, [
      '/v1/calls',
      '/v1/calls/call-1/accept',
      '/v1/calls/active',
      '/v1/calls/call-1',
    ]);
    expect(requestBodies.first, {
      'chatId': 'chat-1',
      'mediaMode': 'video',
    });
    expect(requestBodies.last, isEmpty);
  });

  test('CustomApiCallService sends selected group call participants', () async {
    Map<String, dynamic>? requestBody;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/calls' && request.method == 'POST') {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'call': _callPayload(
              state: 'ringing',
              mediaMode: 'audio',
            ),
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"message":"not found"}', 404);
    });
    final authService = await _createAuthService(client);
    final service = CustomApiCallService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    await service.startCall(
      chatId: 'chat-1',
      mediaMode: CallMediaMode.audio,
      participantIds: const [' user-2 ', '', 'user-3', 'user-2'],
    );

    expect(requestBody, {
      'chatId': 'chat-1',
      'mediaMode': 'audio',
      'participantIds': ['user-2', 'user-3'],
    });
  });

  test('CustomApiCallService nudges selected call participants', () async {
    String? requestedPath;
    String? requestedMethod;
    Map<String, dynamic>? requestBody;
    final client = MockClient((request) async {
      requestedPath = request.url.path;
      requestedMethod = request.method;
      requestBody = jsonDecode(request.body) as Map<String, dynamic>;
      if (request.url.path == '/v1/calls/call-1/nudge' &&
          request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'call': _callPayload(
              state: 'active',
              mediaMode: 'video',
              includeSession: true,
            ),
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"message":"not found"}', 404);
    });
    final authService = await _createAuthService(client);
    final service = CustomApiCallService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final call = await service.nudgeCallParticipants(
      'call-1',
      participantIds: const [' user-2 ', '', 'user-3', 'user-2'],
    );

    expect(call.state, CallState.active);
    expect(requestedPath, '/v1/calls/call-1/nudge');
    expect(requestedMethod, 'POST');
    expect(requestBody, {
      'participantIds': ['user-2', 'user-3'],
    });
  });

  test('CustomApiCallService adds new participants to a live call', () async {
    String? requestedPath;
    String? requestedMethod;
    Map<String, dynamic>? requestBody;
    final client = MockClient((request) async {
      requestedPath = request.url.path;
      requestedMethod = request.method;
      requestBody = jsonDecode(request.body) as Map<String, dynamic>;
      if (request.url.path == '/v1/calls/call-1/add' &&
          request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'call': _callPayload(
              state: 'active',
              mediaMode: 'audio',
              includeSession: true,
            ),
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"message":"not found"}', 404);
    });
    final authService = await _createAuthService(client);
    final service = CustomApiCallService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final call = await service.addCallParticipants(
      'call-1',
      participantIds: const [' dave ', '', 'erin', 'dave'],
    );

    expect(call.state, CallState.active);
    expect(requestedPath, '/v1/calls/call-1/add');
    expect(requestedMethod, 'POST');
    expect(requestBody, {
      'participantIds': ['dave', 'erin'],
    });
  });

  test('CustomApiCallService emits call events from realtime payloads',
      () async {
    final client = MockClient((request) async {
      return http.Response('{}', 200);
    });
    final authService = await _createAuthService(client);
    final realtimeController = StreamController<dynamic>.broadcast();
    final realtimeService = CustomApiRealtimeService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      channelFactory: (_) => _FakeWebSocketChannel(realtimeController.stream),
      reconnectDelay: const Duration(milliseconds: 10),
    );

    final service = CustomApiCallService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
        webSocketBaseUrl: 'wss://api.example.ru',
      ),
      httpClient: client,
      realtimeService: realtimeService,
    );

    await service.startRealtimeBridge();

    final eventFuture =
        service.events.first.timeout(const Duration(seconds: 1));

    realtimeController.add(
      jsonEncode({
        'type': 'call.state.updated',
        'call': _callPayload(
          state: 'active',
          mediaMode: 'audio',
          includeSession: true,
        ),
      }),
    );

    final event = await eventFuture;
    expect(event.type, CallEventType.stateUpdated);
    expect(event.call.state, CallState.active);
    expect(event.call.mediaMode, CallMediaMode.audio);
    expect(event.call.session?.url, 'wss://livekit.example.ru');

    await realtimeController.close();
    await realtimeService.dispose();
    await service.dispose();
  });

  test(
    'perf(client): getActiveCall single-flights concurrent overlapping '
    'calls into one HTTP request',
    () async {
      var requestCount = 0;
      final responseGate = Completer<void>();
      final client = MockClient((request) async {
        if (request.url.path == '/v1/calls/active') {
          requestCount += 1;
          await responseGate.future;
          return http.Response(
            jsonEncode({'call': null}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{"message":"not found"}', 404);
      });
      final authService = await _createAuthService(client);
      final service = CustomApiCallService(
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        httpClient: client,
      );

      // Cold-start scenario: several independent initiators (call
      // coordinator bootstrap, its realtime "connection.ready"
      // listener, IncomingCallWatcher) all ask for the active call
      // within the same tick, before the first HTTP response lands.
      final futures = List.generate(4, (_) => service.getActiveCall());
      // Let the futures actually start their HTTP call before we
      // release the gate, so they genuinely overlap in time.
      await Future<void>.delayed(Duration.zero);
      responseGate.complete();
      final results = await Future.wait(futures);

      expect(requestCount, 1);
      expect(results, everyElement(isNull));

      // A call issued AFTER the in-flight one has resolved is NOT a
      // TTL cache hit — periodic polling and realtime-driven refreshes
      // must still see a fresh request.
      await service.getActiveCall();
      expect(requestCount, 2);

      await service.dispose();
    },
  );

  test(
    'perf(client): getActiveCall single-flight is keyed per chatId',
    () async {
      final requestedChatIds = <String?>[];
      final client = MockClient((request) async {
        if (request.url.path == '/v1/calls/active') {
          requestedChatIds.add(request.url.queryParameters['chatId']);
          return http.Response(
            jsonEncode({'call': null}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{"message":"not found"}', 404);
      });
      final authService = await _createAuthService(client);
      final service = CustomApiCallService(
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        httpClient: client,
      );

      // A chat-scoped lookup and the global lookup must never share an
      // in-flight future with each other — different queries, both
      // legitimate concurrently.
      await Future.wait([
        service.getActiveCall(chatId: 'chat-1'),
        service.getActiveCall(),
      ]);

      expect(requestedChatIds, hasLength(2));
      expect(requestedChatIds, containsAll(<String?>['chat-1', null]));

      await service.dispose();
    },
  );
}

Future<CustomApiAuthService> _createAuthService(http.Client client) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    'custom_api_session_v1',
    jsonEncode({
      'accessToken': 'access-token',
      'refreshToken': 'refresh-token',
      'userId': 'user-1',
      'email': 'dev@rodnya.app',
      'displayName': 'Dev User',
      'providerIds': ['password'],
      'isProfileComplete': true,
      'missingFields': const [],
    }),
  );

  return CustomApiAuthService.create(
    httpClient: client,
    preferences: prefs,
    runtimeConfig: const BackendRuntimeConfig(
      apiBaseUrl: 'https://api.example.ru',
      webSocketBaseUrl: 'wss://api.example.ru',
    ),
    invitationService: InvitationService(),
  );
}

Map<String, dynamic> _callPayload({
  required String state,
  required String mediaMode,
  bool includeSession = false,
}) {
  return {
    'id': 'call-1',
    'chatId': 'chat-1',
    'initiatorId': 'user-1',
    'recipientId': 'user-2',
    'participantIds': ['user-1', 'user-2'],
    'mediaMode': mediaMode,
    'state': state,
    'roomName': 'room-1',
    'createdAt': '2026-04-20T10:00:00.000Z',
    'updatedAt': '2026-04-20T10:01:00.000Z',
    if (includeSession)
      'session': {
        'roomName': 'room-1',
        'url': 'wss://livekit.example.ru',
        'token': 'token-1',
        'participantIdentity': 'user-1',
        'participantName': 'Dev User',
        'createdAt': '2026-04-20T10:01:00.000Z',
      },
  };
}

class _FakeWebSocketChannel implements WebSocketChannel {
  _FakeWebSocketChannel(this._stream);

  final Stream<dynamic> _stream;
  final _FakeWebSocketSink _sink = _FakeWebSocketSink();

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _stream;

  @override
  _FakeWebSocketSink get sink => _sink;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWebSocketSink implements WebSocketSink {
  @override
  void add(event) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream stream) async {}

  @override
  Future close([int? closeCode, String? closeReason]) async {}

  @override
  Future get done async {}
}
