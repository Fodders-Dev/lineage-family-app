import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/models/custom_api_session.dart';
import 'invitation_service.dart';

class CustomApiException implements Exception {
  const CustomApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class CustomApiAuthService implements AuthServiceInterface {
  CustomApiAuthService._({
    required http.Client httpClient,
    required SharedPreferences preferences,
    required BackendRuntimeConfig runtimeConfig,
    required InvitationService invitationService,
  })  : _httpClient = httpClient,
        _preferences = preferences,
        _runtimeConfig = runtimeConfig,
        _invitationService = invitationService;

  static const _sessionStorageKey = 'custom_api_session_v1';

  final http.Client _httpClient;
  final SharedPreferences _preferences;
  final BackendRuntimeConfig _runtimeConfig;
  final InvitationService _invitationService;
  final StreamController<String?> _authStateController =
      StreamController<String?>.broadcast();

  CustomApiSession? _session;

  static Future<CustomApiAuthService> create({
    http.Client? httpClient,
    SharedPreferences? preferences,
    BackendRuntimeConfig? runtimeConfig,
    InvitationService? invitationService,
  }) async {
    final service = CustomApiAuthService._(
      httpClient: httpClient ?? http.Client(),
      preferences: preferences ?? await SharedPreferences.getInstance(),
      runtimeConfig: runtimeConfig ?? BackendRuntimeConfig.current,
      invitationService: invitationService ?? InvitationService(),
    );
    await service.restoreSession();
    return service;
  }

  String? get accessToken => _session?.accessToken;

  @override
  String? get currentUserId => _session?.userId;

  @override
  String? get currentUserEmail => _session?.email;

  @override
  String? get currentUserDisplayName => _session?.displayName;

  @override
  String? get currentUserPhotoUrl => _session?.photoUrl;

  @override
  List<String> get currentProviderIds => _session?.providerIds ?? const [];

  @override
  Stream<String?> get authStateChanges => _authStateController.stream;

  Future<void> restoreSession() async {
    final rawValue = _preferences.getString(_sessionStorageKey);
    if (rawValue == null || rawValue.isEmpty) {
      _session = null;
      return;
    }

    try {
      final json = jsonDecode(rawValue);
      if (json is Map<String, dynamic>) {
        final session = CustomApiSession.fromJson(json);
        _session = session.userId.isEmpty ? null : session;
      }
    } catch (_) {
      _session = null;
      await _preferences.remove(_sessionStorageKey);
    }
  }

  @override
  Future<Object?> registerWithEmail({
    required String email,
    required String password,
    required String name,
  }) {
    return _authenticate(
      path: '/v1/auth/register',
      payload: {
        'email': email,
        'password': password,
        'displayName': name,
      },
    );
  }

  @override
  Future<Object?> loginWithEmail(String email, String password) {
    return _authenticate(
      path: '/v1/auth/login',
      payload: {
        'email': email,
        'password': password,
      },
    );
  }

  @override
  Future<Object?> signInWithGoogle() {
    return _authenticate(
      path: '/v1/auth/google',
      payload: const {},
    );
  }

  @override
  Future<void> signOut() async {
    final currentToken = accessToken;
    if (currentToken != null && currentToken.isNotEmpty) {
      try {
        await _httpClient.post(
          _buildUri('/v1/auth/logout'),
          headers: _jsonHeaders(authenticated: true),
        );
      } catch (_) {}
    }

    await _clearSession();
  }

  @override
  Future<void> resetPassword(String email) async {
    await _requestJson(
      method: 'POST',
      path: '/v1/auth/password-reset',
      body: {'email': email},
    );
  }

  @override
  Future<void> deleteAccount([String? password]) async {
    await _requestJson(
      method: 'DELETE',
      path: '/v1/auth/account',
      authenticated: true,
      body: {
        if (password != null && password.isNotEmpty) 'password': password,
      },
    );
    await _clearSession();
  }

  @override
  Future<Map<String, dynamic>> checkProfileCompleteness() async {
    if (_session == null) {
      return {
        'isComplete': false,
        'missingFields': ['auth'],
      };
    }

    try {
      final response = await _requestJson(
        method: 'GET',
        path: '/v1/auth/session',
        authenticated: true,
      );
      final refreshedSession = _sessionFromResponse(response);
      await _saveSession(refreshedSession);
      return _profileStatusMap(refreshedSession);
    } catch (_) {
      return _profileStatusMap(_session!);
    }
  }

  @override
  Future<void> processPendingInvitation() async {
    if (_session == null || !_invitationService.hasPendingInvitation) {
      return;
    }

    try {
      await _requestJson(
        method: 'POST',
        path: '/v1/invitations/pending/process',
        authenticated: true,
        body: {
          'treeId': _invitationService.pendingTreeId,
          'personId': _invitationService.pendingPersonId,
        },
      );
      _invitationService.clearPendingInvitation();
    } catch (_) {
      // Не ломаем auth flow, пока invite-путь ещё мигрирует.
    }
  }

  @override
  Future<void> updateDisplayName(String displayName) async {
    final response = await _requestJson(
      method: 'PATCH',
      path: '/v1/profile/me',
      authenticated: true,
      body: {
        'displayName': displayName.trim(),
      },
    );

    final user = _extractUserJson(response);
    if (_session != null) {
      await updateCachedSession(
        displayName: user['displayName']?.toString() ?? displayName.trim(),
      );
    }
  }

  Future<void> updateCachedSession({
    String? email,
    String? displayName,
    String? photoUrl,
    bool? isProfileComplete,
    List<String>? missingFields,
  }) async {
    final currentSession = _session;
    if (currentSession == null) {
      return;
    }

    await _saveSession(
      currentSession.copyWith(
        email: email ?? currentSession.email,
        displayName: displayName ?? currentSession.displayName,
        photoUrl: photoUrl ?? currentSession.photoUrl,
        isProfileComplete:
            isProfileComplete ?? currentSession.isProfileComplete,
        missingFields: missingFields ?? currentSession.missingFields,
      ),
    );
  }

  Future<Object?> _authenticate({
    required String path,
    required Map<String, dynamic> payload,
  }) async {
    final response = await _requestJson(
      method: 'POST',
      path: path,
      body: payload,
    );
    final session = _sessionFromResponse(response);
    await _saveSession(session);
    _authStateController.add(session.userId);
    await processPendingInvitation();
    return session;
  }

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    bool authenticated = false,
    Map<String, dynamic>? body,
  }) async {
    final uri = _buildUri(path);
    late http.Response response;

    switch (method) {
      case 'GET':
        response = await _httpClient.get(
          uri,
          headers: _jsonHeaders(authenticated: authenticated),
        );
        break;
      case 'POST':
        response = await _httpClient.post(
          uri,
          headers: _jsonHeaders(authenticated: authenticated),
          body: jsonEncode(body ?? const {}),
        );
        break;
      case 'PATCH':
        response = await _httpClient.patch(
          uri,
          headers: _jsonHeaders(authenticated: authenticated),
          body: jsonEncode(body ?? const {}),
        );
        break;
      case 'DELETE':
        final request = http.Request('DELETE', uri)
          ..headers.addAll(_jsonHeaders(authenticated: authenticated))
          ..body = jsonEncode(body ?? const {});
        final streamedResponse = await _httpClient.send(request);
        response = await http.Response.fromStream(streamedResponse);
        break;
      default:
        throw CustomApiException('Неподдерживаемый HTTP-метод: $method');
    }

    return _decodeResponse(response);
  }

  Future<void> _saveSession(CustomApiSession session) async {
    _session = session;
    await _preferences.setString(
      _sessionStorageKey,
      jsonEncode(session.toJson()),
    );
  }

  Future<void> _clearSession() async {
    _session = null;
    await _preferences.remove(_sessionStorageKey);
    _authStateController.add(null);
  }

  Uri _buildUri(String path) {
    final normalizedBase = _runtimeConfig.apiBaseUrl.replaceAll(
      RegExp(r'/$'),
      '',
    );
    return Uri.parse('$normalizedBase$path');
  }

  Map<String, String> _jsonHeaders({bool authenticated = false}) {
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (authenticated && accessToken != null)
        'Authorization': 'Bearer ${accessToken!}',
    };
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    if (response.body.isEmpty) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return const <String, dynamic>{};
      }
      throw CustomApiException(
        'Пустой ответ от backend',
        statusCode: response.statusCode,
      );
    }

    final dynamic decodedBody = jsonDecode(response.body);
    final bodyMap = decodedBody is Map<String, dynamic>
        ? decodedBody
        : <String, dynamic>{'data': decodedBody};

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return bodyMap;
    }

    final message = bodyMap['message']?.toString() ??
        bodyMap['error']?.toString() ??
        'Ошибка backend (${response.statusCode})';
    throw CustomApiException(message, statusCode: response.statusCode);
  }

  CustomApiSession _sessionFromResponse(Map<String, dynamic> response) {
    final sessionJson = _extractSessionJson(response);
    final userJson = _extractUserJson(response);
    final profileStatus = _extractProfileStatus(response);
    final providerIds = (userJson['providerIds'] as List<dynamic>? ??
            sessionJson['providerIds'] as List<dynamic>? ??
            const [])
        .map((value) => value.toString())
        .toList();

    final session = CustomApiSession(
      accessToken: sessionJson['accessToken']?.toString() ??
          response['accessToken']?.toString() ??
          '',
      refreshToken: sessionJson['refreshToken']?.toString() ??
          response['refreshToken']?.toString(),
      userId: userJson['id']?.toString() ??
          sessionJson['userId']?.toString() ??
          response['userId']?.toString() ??
          '',
      email: userJson['email']?.toString() ?? response['email']?.toString(),
      displayName: userJson['displayName']?.toString() ??
          response['displayName']?.toString(),
      photoUrl: userJson['photoUrl']?.toString() ??
          userJson['photoURL']?.toString() ??
          response['photoUrl']?.toString() ??
          response['photoURL']?.toString(),
      providerIds: providerIds,
      isProfileComplete: profileStatus['isComplete'] == true,
      missingFields:
          (profileStatus['missingFields'] as List<dynamic>? ?? const [])
              .map((value) => value.toString())
              .toList(),
    );

    if (session.accessToken.isEmpty || session.userId.isEmpty) {
      throw const CustomApiException(
        'Backend не вернул session/access token для customApi auth',
      );
    }

    return session;
  }

  Map<String, dynamic> _extractSessionJson(Map<String, dynamic> response) {
    final sessionValue = response['session'];
    if (sessionValue is Map<String, dynamic>) {
      return sessionValue;
    }
    return response;
  }

  Map<String, dynamic> _extractUserJson(Map<String, dynamic> response) {
    final sessionJson = _extractSessionJson(response);
    final userValue = response['user'] ?? sessionJson['user'];
    if (userValue is Map<String, dynamic>) {
      return userValue;
    }
    return sessionJson;
  }

  Map<String, dynamic> _extractProfileStatus(Map<String, dynamic> response) {
    final sessionJson = _extractSessionJson(response);
    final statusValue =
        response['profileStatus'] ?? sessionJson['profileStatus'];
    if (statusValue is Map<String, dynamic>) {
      return statusValue;
    }
    return const <String, dynamic>{};
  }

  Map<String, dynamic> _profileStatusMap(CustomApiSession session) {
    return {
      'isComplete': session.isProfileComplete,
      'missingFields': session.missingFields,
    };
  }

  @override
  String describeError(Object error) {
    if (error is CustomApiException) {
      return error.message;
    }

    final rawMessage = error.toString();
    if (rawMessage.startsWith('Exception: ')) {
      return rawMessage.substring('Exception: '.length);
    }
    return rawMessage;
  }
}
