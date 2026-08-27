import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rodnya/backend/backend_runtime_config.dart';
import 'package:image_picker/image_picker.dart';
import 'package:rodnya/backend/interfaces/storage_service_interface.dart';
import 'package:rodnya/models/media_upload_progress.dart';
import 'package:rodnya/services/custom_api_auth_service.dart';
import 'package:rodnya/services/custom_api_post_service.dart';
import 'package:rodnya/services/invitation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('CustomApiPostService returns server-truth snapshot from like endpoint',
      () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/v1/posts/post-1/like');
      expect(request.headers['authorization'], 'Bearer access-token');
      expect(request.body, isEmpty);

      return http.Response(
        jsonEncode({
          'id': 'post-1',
          'treeId': 'tree-1',
          'authorId': 'author-1',
          'authorName': 'Анна',
          'content': 'Семейная новость',
          'createdAt': '2026-04-13T10:00:00.000Z',
          'likedBy': ['user-1', 'user-2'],
          'commentCount': 3,
          'imageUrls': const [],
          'circleId': 'circle-1',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

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

    final authService = await CustomApiAuthService.create(
      httpClient: client,
      preferences: prefs,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      invitationService: InvitationService(),
    );

    final service = CustomApiPostService(
      authService: authService,
      storageService: _FakeStorageService(),
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final post = await service.toggleLike('post-1');

    expect(post.id, 'post-1');
    expect(post.likedBy, ['user-1', 'user-2']);
    expect(post.likeCount, 2);
    expect(post.commentCount, 3);
    expect(post.circleId, 'circle-1');
  });

  test('CustomApiPostService sends optional circleId on create', () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/v1/posts');
      expect(request.headers['authorization'], 'Bearer access-token');
      expect(jsonDecode(request.body), {
        'treeId': 'tree-1',
        'content': 'Для близких',
        'imageUrls': const [],
        'isPublic': false,
        'scopeType': 'wholeTree',
        'anchorPersonIds': const [],
        'circleId': 'circle-1',
      });

      return http.Response(
        jsonEncode({
          'id': 'post-1',
          'treeId': 'tree-1',
          'authorId': 'author-1',
          'authorName': 'Анна',
          'content': 'Для близких',
          'createdAt': '2026-04-13T10:00:00.000Z',
          'likedBy': const [],
          'commentCount': 0,
          'imageUrls': const [],
          'circleId': 'circle-1',
        }),
        201,
        headers: {'content-type': 'application/json'},
      );
    });

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

    final authService = await CustomApiAuthService.create(
      httpClient: client,
      preferences: prefs,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      invitationService: InvitationService(),
    );
    final service = CustomApiPostService(
      authService: authService,
      storageService: _FakeStorageService(),
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final post = await service.createPost(
      treeId: 'tree-1',
      content: 'Для близких',
      circleId: 'circle-1',
    );

    expect(post.circleId, 'circle-1');
  });

  test('CustomApiPostService refreshes session once before retrying feed',
      () async {
    var postRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/posts') {
        postRequests += 1;
        if (postRequests == 1) {
          expect(request.headers['authorization'], 'Bearer old-token');
          return http.Response.bytes(
            utf8.encode(jsonEncode({'message': 'Сессия истекла'})),
            401,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }

        expect(request.headers['authorization'], 'Bearer new-token');
        return http.Response(
          jsonEncode([
            {
              'id': 'post-1',
              'treeId': 'tree-1',
              'authorId': 'author-1',
              'authorName': 'Анна',
              'content': 'Семейная новость',
              'createdAt': '2026-04-13T10:00:00.000Z',
              'likedBy': const [],
              'commentCount': 0,
              'imageUrls': const [],
            }
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/auth/refresh') {
        expect(request.method, 'POST');
        // Multi-device session work (commit b9eb0d8) appended a
        // deviceInfo block to refresh-token requests so the server
        // can attribute sessions to specific devices. We only assert
        // refreshToken here — deviceInfo content is platform-derived
        // and tested separately.
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['refreshToken'], 'refresh-token');
        return http.Response(
          jsonEncode({
            'accessToken': 'new-token',
            'refreshToken': 'new-refresh-token',
            'user': {
              'id': 'user-1',
              'email': 'dev@rodnya.app',
              'displayName': 'Dev User',
              'providerIds': ['password'],
            },
            'profileStatus': {
              'isComplete': true,
              'missingFields': const [],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response('{"message":"not found"}', 404);
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'custom_api_session_v1',
      jsonEncode({
        'accessToken': 'old-token',
        'refreshToken': 'refresh-token',
        'userId': 'user-1',
        'email': 'dev@rodnya.app',
        'displayName': 'Dev User',
        'providerIds': ['password'],
        'isProfileComplete': true,
        'missingFields': const [],
      }),
    );

    final authService = await CustomApiAuthService.create(
      httpClient: client,
      preferences: prefs,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      invitationService: InvitationService(),
    );
    final service = CustomApiPostService(
      authService: authService,
      storageService: _FakeStorageService(),
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final posts = await service.getPosts(treeId: 'tree-1');

    expect(posts, hasLength(1));
    expect(posts.single.id, 'post-1');
    expect(postRequests, 2);
    expect(authService.accessToken, 'new-token');
  });

  // ── Шаг 2/3 плана массовой загрузки: пул с ограниченной конкурентностью ──

  test('bulk upload: порядок выбора сохраняется, даже если файлы финишируют '
      'вразнобой', () async {
    // Мелкие фото реально финишируют раньше крупных; карусель и альбом рисуют
    // imageUrls как массив, поэтому раскладка обязана идти по индексу выбора.
    final storage = _RecordingStorageService(
      delayForName: (name) {
        final index = int.parse(name.split('-').last);
        // Обратные задержки: последний файл финиширует первым.
        return Duration(milliseconds: (10 - index) * 6);
      },
    );
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(
        body['imageUrls'],
        List<String>.generate(10, (i) => 'https://cdn/photo-$i.jpg'),
        reason: 'URL-ы должны идти в порядке выбора, а не завершения',
      );
      return _postResponse();
    });

    final service = await _buildService(client, storage);
    await service.createPost(
      treeId: 'tree-1',
      content: 'Поездка',
      images: List<XFile>.generate(10, (i) => XFile('/tmp/photo-$i')),
    );
    expect(storage.uploadCount, 10);
  });

  test('bulk upload: одновременно в полёте не больше 4 файлов', () async {
    // Больше — риск ANR/OOM: readAsBytes+base64Encode блокирующие.
    final storage = _RecordingStorageService(
      delayForName: (_) => const Duration(milliseconds: 12),
    );
    final client = MockClient((_) async => _postResponse());

    final service = await _buildService(client, storage);
    await service.createPost(
      treeId: 'tree-1',
      content: 'Поездка',
      images: List<XFile>.generate(20, (i) => XFile('/tmp/photo-$i')),
    );

    expect(storage.maxInFlight, lessThanOrEqualTo(4));
    expect(storage.maxInFlight, greaterThan(1), reason: 'должно быть параллельно');
    expect(storage.uploadCount, 20);
  });

  test('bulk upload: прогресс доходит от preparing до publishing', () async {
    final storage = _RecordingStorageService(
      delayForName: (_) => const Duration(milliseconds: 4),
    );
    final client = MockClient((_) async => _postResponse());
    final service = await _buildService(client, storage);

    final events = <MediaUploadProgress>[];
    await service.createPost(
      treeId: 'tree-1',
      content: 'Поездка',
      images: List<XFile>.generate(5, (i) => XFile('/tmp/photo-$i')),
      onProgress: events.add,
    );

    expect(events.first.stage, MediaUploadStage.preparing);
    expect(events.last.stage, MediaUploadStage.publishing);
    final uploaded = events
        .where((e) => e.stage == MediaUploadStage.uploading)
        .map((e) => e.completed)
        .toList();
    expect(uploaded, [1, 2, 3, 4, 5]);
    expect(events.every((e) => e.total == 5), isTrue);
  });

  test('bulk upload: провал одного файла валит пост целиком и гасит остальные '
      'загрузки', () async {
    // Раньше `if (url != null)` молча выбрасывал непрогрузившееся фото:
    // человек публиковал 30 снимков и получал 27, не узнав об этом.
    var postRequested = false;
    final storage = _RecordingStorageService(
      delayForName: (_) => const Duration(milliseconds: 5),
      failOnName: 'photo-2',
    );
    final client = MockClient((_) async {
      postRequested = true;
      return _postResponse();
    });

    final service = await _buildService(client, storage);
    await expectLater(
      service.createPost(
        treeId: 'tree-1',
        content: 'Поездка',
        images: List<XFile>.generate(20, (i) => XFile('/tmp/photo-$i')),
      ),
      throwsA(isA<Exception>()),
    );

    expect(postRequested, isFalse, reason: 'частичный пост публиковать нельзя');
    expect(
      storage.uploadCount,
      lessThan(20),
      reason: 'после ошибки воркеры не должны разбирать оставшиеся файлы',
    );
  });
}

http.Response _postResponse() => http.Response(
      jsonEncode({
        'id': 'post-1',
        'treeId': 'tree-1',
        'authorId': 'author-1',
        'authorName': 'Анна',
        'content': 'Поездка',
        'createdAt': '2026-04-13T10:00:00.000Z',
        'likedBy': const [],
        'commentCount': 0,
        'imageUrls': const [],
      }),
      201,
      headers: {'content-type': 'application/json'},
    );

Future<CustomApiPostService> _buildService(
  http.Client client,
  StorageServiceInterface storage,
) async {
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
  final authService = await CustomApiAuthService.create(
    httpClient: client,
    preferences: prefs,
    runtimeConfig: const BackendRuntimeConfig(apiBaseUrl: 'https://api.example.ru'),
    invitationService: InvitationService(),
  );
  return CustomApiPostService(
    authService: authService,
    storageService: storage,
    runtimeConfig: const BackendRuntimeConfig(apiBaseUrl: 'https://api.example.ru'),
    httpClient: client,
  );
}

/// Фейковое хранилище: считает пик одновременных загрузок и умеет падать
/// на конкретном файле.
class _RecordingStorageService implements StorageServiceInterface {
  _RecordingStorageService({required this.delayForName, this.failOnName});

  final Duration Function(String name) delayForName;
  final String? failOnName;

  int inFlight = 0;
  int maxInFlight = 0;
  int uploadCount = 0;

  @override
  Future<String?> uploadImage(XFile imageFile, String folder) async {
    final name = imageFile.path.split('/').last;
    inFlight += 1;
    uploadCount += 1;
    if (inFlight > maxInFlight) {
      maxInFlight = inFlight;
    }
    try {
      await Future<void>.delayed(delayForName(name));
      if (name == failOnName) {
        throw Exception('upload failed for $name');
      }
      return 'https://cdn/$name.jpg';
    } finally {
      inFlight -= 1;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStorageService implements StorageServiceInterface {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
