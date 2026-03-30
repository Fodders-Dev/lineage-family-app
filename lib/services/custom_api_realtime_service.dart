import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../backend/backend_runtime_config.dart';
import 'custom_api_auth_service.dart';

typedef WebSocketChannelFactory = WebSocketChannel Function(Uri uri);

class CustomApiRealtimeEvent {
  const CustomApiRealtimeEvent({
    required this.type,
    required this.payload,
  });

  final String type;
  final Map<String, dynamic> payload;

  String? get chatId => payload['chatId']?.toString();

  Map<String, dynamic>? get notification {
    final value = payload['notification'];
    return value is Map<String, dynamic> ? value : null;
  }

  Map<String, dynamic>? get message {
    final value = payload['message'];
    return value is Map<String, dynamic> ? value : null;
  }

  bool get isChatEvent =>
      type == 'chat.message.created' || type == 'chat.read.updated';

  bool get isNotificationEvent => type == 'notification.created';

  factory CustomApiRealtimeEvent.fromJson(Map<String, dynamic> json) {
    return CustomApiRealtimeEvent(
      type: json['type']?.toString() ?? 'unknown',
      payload: json,
    );
  }
}

class CustomApiRealtimeService {
  CustomApiRealtimeService({
    required CustomApiAuthService authService,
    required BackendRuntimeConfig runtimeConfig,
    WebSocketChannelFactory? channelFactory,
    Duration? reconnectDelay,
  })  : _authService = authService,
        _runtimeConfig = runtimeConfig,
        _channelFactory = channelFactory ?? WebSocketChannel.connect,
        _reconnectDelay = reconnectDelay ?? const Duration(seconds: 3);

  final CustomApiAuthService _authService;
  final BackendRuntimeConfig _runtimeConfig;
  final WebSocketChannelFactory _channelFactory;
  final Duration _reconnectDelay;
  final StreamController<CustomApiRealtimeEvent> _eventsController =
      StreamController<CustomApiRealtimeEvent>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubscription;
  Timer? _reconnectTimer;
  bool _isConnecting = false;
  bool _disposed = false;

  Stream<CustomApiRealtimeEvent> get events => _eventsController.stream;

  Future<void> connect() async {
    if (_disposed || _isConnecting || _channel != null) {
      return;
    }

    final accessToken = _authService.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      return;
    }

    _isConnecting = true;
    try {
      final uri = _buildUri(accessToken);
      final channel = _channelFactory(uri);
      await channel.ready;
      _channel = channel;
      _channelSubscription = channel.stream.listen(
        _handleEvent,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
    } finally {
      _isConnecting = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    await _channelSubscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    await _eventsController.close();
  }

  Uri _buildUri(String accessToken) {
    final normalizedBase = _runtimeConfig.webSocketBaseUrl.replaceAll(
      RegExp(r'/$'),
      '',
    );
    return Uri.parse(
      '$normalizedBase/v1/realtime?accessToken=$accessToken',
    );
  }

  void _handleEvent(dynamic rawEvent) {
    if (rawEvent is! String || rawEvent.trim().isEmpty) {
      return;
    }

    final dynamic decoded = jsonDecode(rawEvent);
    if (decoded is! Map<String, dynamic>) {
      return;
    }

    final event = CustomApiRealtimeEvent.fromJson(decoded);
    _eventsController.add(event);
  }

  void _scheduleReconnect() {
    _channelSubscription?.cancel();
    _channelSubscription = null;
    _channel = null;

    if (_disposed) {
      return;
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelay, () {
      unawaited(connect());
    });
  }
}
