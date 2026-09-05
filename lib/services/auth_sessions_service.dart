import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../backend/backend_runtime_config.dart';
import '../utils/client_instance_id.dart';
import '../utils/device_descriptor.dart';
import 'custom_api_auth_service.dart';

/// Snapshot of one authenticated session as exposed by the backend.
class AuthSessionSummary {
  const AuthSessionSummary({
    required this.sessionPublicId,
    required this.deviceName,
    required this.platform,
    this.osVersion,
    required this.appVersion,
    required this.createdAt,
    required this.lastSeenAt,
    required this.isCurrent,
  });

  factory AuthSessionSummary.fromJson(Map<String, dynamic> json) {
    return AuthSessionSummary(
      sessionPublicId: (json['sessionPublicId'] ?? '').toString(),
      deviceName: json['deviceName']?.toString(),
      platform: json['platform']?.toString(),
      // Additive field — sessions created before this shipped (or by an
      // old client build) simply won't have it; null is the honest state.
      osVersion: json['osVersion']?.toString(),
      appVersion: json['appVersion']?.toString(),
      createdAt: _parseDateTime(json['createdAt']),
      lastSeenAt: _parseDateTime(json['lastSeenAt']),
      isCurrent: json['isCurrent'] == true,
    );
  }

  final String sessionPublicId;
  final String? deviceName;
  final String? platform;
  final String? osVersion;
  final String? appVersion;
  final DateTime? createdAt;
  final DateTime? lastSeenAt;
  final bool isCurrent;
}

DateTime? _parseDateTime(dynamic value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toLocal();
}

class AuthSessionsListResult {
  const AuthSessionsListResult({
    required this.sessions,
    required this.currentSessionPublicId,
  });

  final List<AuthSessionSummary> sessions;
  final String currentSessionPublicId;
}

class QrLoginStartResult {
  const QrLoginStartResult({required this.token, required this.expiresAt});

  final String token;
  final DateTime expiresAt;
}

enum QrLoginPollStatus { pending, approved, expired }

class QrLoginPollResult {
  const QrLoginPollResult({required this.status, this.auth});

  final QrLoginPollStatus status;
  final Map<String, dynamic>? auth;
}

class AuthSessionsService {
  AuthSessionsService({
    required CustomApiAuthService authService,
    required BackendRuntimeConfig runtimeConfig,
    http.Client? httpClient,
  })  : _authService = authService,
        _runtimeConfig = runtimeConfig,
        _httpClient = httpClient ?? http.Client();

  final CustomApiAuthService _authService;
  final BackendRuntimeConfig _runtimeConfig;
  final http.Client _httpClient;

  Future<AuthSessionsListResult> listSessions() async {
    final response = await _httpClient.get(
      _buildUri('/v1/auth/sessions'),
      headers: _authedHeaders(),
    );
    final body = _decode(response);
    final sessionsJson = (body['sessions'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(AuthSessionSummary.fromJson)
        .toList();
    return AuthSessionsListResult(
      sessions: sessionsJson,
      currentSessionPublicId: (body['currentSessionPublicId'] ?? '').toString(),
    );
  }

  Future<AuthSessionSummary> renameSession({
    required String sessionPublicId,
    required String deviceName,
  }) async {
    final response = await _httpClient.patch(
      _buildUri('/v1/auth/sessions/$sessionPublicId'),
      headers: _authedHeaders(),
      body: jsonEncode({'deviceName': deviceName}),
    );
    final body = _decode(response);
    final raw = body['session'] as Map<String, dynamic>?;
    if (raw == null) {
      throw const CustomApiException('Backend не вернул сессию');
    }
    return AuthSessionSummary.fromJson(raw);
  }

  Future<void> revokeSession(String sessionPublicId) async {
    final request = http.Request(
      'DELETE',
      _buildUri('/v1/auth/sessions/$sessionPublicId'),
    )..headers.addAll(_authedHeaders());
    final streamed = await _httpClient.send(request);
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode != 204) {
      _decode(response); // throws CustomApiException with the server message
    }
  }

  /// Device B (unauthenticated) starts a QR login session. The returned token
  /// is what the QR code carries; the device should poll [pollQrLogin] until
  /// the status flips to approved or expired.
  Future<QrLoginStartResult> startQrLogin() async {
    final descriptor = await DeviceDescriptorBuilder.resolve();
    final response = await _httpClient.post(
      _buildUri('/v1/auth/qr/start'),
      headers: _baseHeaders(),
      body: jsonEncode({
        'deviceInfo': descriptor.toJson(),
      }),
    );
    final body = _decode(response);
    final token = (body['token'] ?? '').toString();
    final expiresAtStr = (body['expiresAt'] ?? '').toString();
    if (token.isEmpty) {
      throw const CustomApiException('Backend не вернул token QR-входа');
    }
    return QrLoginStartResult(
      token: token,
      expiresAt: DateTime.tryParse(expiresAtStr)?.toUtc() ??
          DateTime.now().toUtc().add(const Duration(seconds: 60)),
    );
  }

  Future<QrLoginPollResult> pollQrLogin(String token) async {
    final response = await _httpClient.get(
      _buildUri('/v1/auth/qr/poll', queryParameters: {'token': token}),
      headers: _baseHeaders(),
    );
    if (response.statusCode == 410) {
      return const QrLoginPollResult(status: QrLoginPollStatus.expired);
    }
    final body = _decode(response);
    final status = (body['status'] ?? '').toString();
    if (status == 'approved') {
      return QrLoginPollResult(
        status: QrLoginPollStatus.approved,
        auth: (body['auth'] as Map<String, dynamic>?),
      );
    }
    if (status == 'pending') {
      return const QrLoginPollResult(status: QrLoginPollStatus.pending);
    }
    return const QrLoginPollResult(status: QrLoginPollStatus.expired);
  }

  Future<String> approveQrLogin(String token) async {
    final response = await _httpClient.post(
      _buildUri('/v1/auth/qr/approve'),
      headers: _authedHeaders(),
      body: jsonEncode({'token': token}),
    );
    final body = _decode(response);
    return (body['sessionPublicId'] ?? '').toString();
  }

  Map<String, String> _baseHeaders() => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-Client-Instance-Id': ClientInstanceId.current,
      };

  Map<String, String> _authedHeaders() {
    final token = _authService.accessToken;
    if (token == null || token.isEmpty) {
      throw const CustomApiException('Нет активной сессии');
    }
    return {
      ..._baseHeaders(),
      'Authorization': 'Bearer $token',
    };
  }

  Uri _buildUri(String path, {Map<String, String>? queryParameters}) {
    var base = _runtimeConfig.apiBaseUrl.replaceAll(RegExp(r'/$'), '');
    final shouldForceHttps = base.startsWith('http://api.rodnya-tree.ru') ||
        base.startsWith('http://rodnya-tree.ru') ||
        base.startsWith('http://api.fodder-development.ru');
    if (shouldForceHttps) {
      base = 'https://${base.replaceFirst(RegExp(r'^http://'), '')}';
    }
    return Uri.parse('$base$path').replace(queryParameters: queryParameters);
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) {
        return <String, dynamic>{};
      }
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      throw const CustomApiException('Неожиданный формат ответа от backend');
    }
    String message = 'Ошибка ${response.statusCode}';
    if (response.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['message'] is String) {
          message = decoded['message'] as String;
        }
      } catch (_) {}
    }
    throw CustomApiException(message, statusCode: response.statusCode);
  }

  void dispose() {
    _httpClient.close();
  }
}
