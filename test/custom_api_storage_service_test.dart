// Бинарная загрузка медиа: uploadBytes шлёт сами байты (PUT
// /v1/media/object), а на бэк без этого роута (404/405) откатывается на
// легаси base64-JSON и запоминает это на сессию.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rodnya/backend/backend_runtime_config.dart';
import 'package:rodnya/backend/interfaces/storage_service_interface.dart';
import 'package:rodnya/services/custom_api_auth_service.dart';
import 'package:rodnya/services/custom_api_storage_service.dart';
import 'package:rodnya/services/invitation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final bytes = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);

  /// Общая обвязка: настоящий auth-сервис логинится через тот же MockClient
  /// (storage-сервис требует конкретный CustomApiAuthService ради токена).
  Future<CustomApiStorageService> buildService(
    Future<http.Response> Function(http.Request request) onMediaRequest,
  ) async {
    final client = MockClient((request) async {
      if (request.url.path == '/v1/auth/login') {
        return http.Response(
          jsonEncode({
            'accessToken': 'access-token',
            'refreshToken': 'refresh-token',
            'user': {
              'id': 'user-1',
              'email': 'dev@rodnya.app',
              'displayName': 'Dev User',
              'providerIds': ['password'],
            },
            'profileStatus': {'isComplete': true, 'missingFields': []},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path.startsWith('/v1/media')) {
        return onMediaRequest(request);
      }
      return http.Response('{"message":"not found"}', 404);
    });

    const runtimeConfig = BackendRuntimeConfig();
    final authService = await CustomApiAuthService.create(
      httpClient: client,
      preferences: await SharedPreferences.getInstance(),
      runtimeConfig: runtimeConfig,
      invitationService: InvitationService(),
    );
    await authService.loginWithEmail('dev@rodnya.app', 'secret123');

    return CustomApiStorageService(
      authService: authService,
      runtimeConfig: runtimeConfig,
      httpClient: client,
    );
  }

  test('uploadBytes шлёт бинарный PUT: байты как есть, mime в Content-Type',
      () async {
    late http.Request captured;
    final service = await buildService((request) async {
      captured = request;
      return http.Response(
        jsonEncode({'url': 'https://api.rodnya-tree.ru/media/posts/a.jpg'}),
        201,
      );
    });

    final url = await service.uploadBytes(
      bucket: 'posts',
      path: 'trip/a.jpg',
      fileBytes: bytes,
      fileOptions: const FileOptions(contentType: 'image/jpeg'),
    );

    expect(url, isNotNull);
    expect(captured.method, 'PUT');
    expect(captured.url.path, '/v1/media/object');
    expect(captured.url.queryParameters['bucket'], 'posts');
    expect(captured.url.queryParameters['path'], 'trip/a.jpg');
    expect(captured.headers['Content-Type'], startsWith('image/jpeg'));
    expect(captured.headers['Authorization'], 'Bearer access-token');
    expect(captured.bodyBytes, bytes,
        reason: 'никакого base64 — байты уходят как есть');
  });

  test('404 от старого бэка → фолбэк на base64-JSON, дальше без повторных PUT',
      () async {
    final mediaCalls = <String>[];
    final service = await buildService((request) async {
      mediaCalls.add('${request.method} ${request.url.path}');
      if (request.url.path == '/v1/media/object') {
        return http.Response('Not found', 404);
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(base64Decode(body['fileBase64'] as String), bytes);
      return http.Response(
        jsonEncode({'url': 'https://api.rodnya-tree.ru/media/posts/b.jpg'}),
        201,
      );
    });

    final first = await service.uploadBytes(
      bucket: 'posts',
      path: 'b.jpg',
      fileBytes: bytes,
    );
    final second = await service.uploadBytes(
      bucket: 'posts',
      path: 'c.jpg',
      fileBytes: bytes,
    );

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(mediaCalls, [
      'PUT /v1/media/object',
      'POST /v1/media/upload',
      'POST /v1/media/upload',
    ], reason: 'после первого 404 бинарный путь не пробуем до перезапуска');
  });

  test('содержательная ошибка бинарного пути НЕ маскируется фолбэком',
      () async {
    final service = await buildService((request) async {
      expect(request.url.path, '/v1/media/object');
      return http.Response(
        jsonEncode({'message': 'Файл больше 64 МБ'}),
        413,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    await expectLater(
      service.uploadBytes(
        bucket: 'posts',
        path: 'huge.mp4',
        fileBytes: bytes,
      ),
      throwsA(isA<CustomApiStorageException>().having(
        (error) => error.message,
        'message',
        'Файл больше 64 МБ',
      )),
    );
  });
}
