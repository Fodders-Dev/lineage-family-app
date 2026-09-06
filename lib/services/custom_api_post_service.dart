import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../backend/models/user_facing_exception.dart';
import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/post_service_interface.dart';
import '../backend/interfaces/storage_service_interface.dart';
import '../models/comment.dart';
import '../models/media_upload_progress.dart';
import '../models/post.dart';
import '../models/reaction_summary.dart';
import '../utils/startup_trace.dart';
import 'custom_api_auth_service.dart';

class CustomApiPostService implements PostServiceInterface {
  CustomApiPostService({
    required CustomApiAuthService authService,
    required StorageServiceInterface storageService,
    required BackendRuntimeConfig runtimeConfig,
    http.Client? httpClient,
  })  : _authService = authService,
        _storageService = storageService,
        _runtimeConfig = runtimeConfig,
        _httpClient = httpClient ?? http.Client();

  final CustomApiAuthService _authService;
  final StorageServiceInterface _storageService;
  final BackendRuntimeConfig _runtimeConfig;
  final http.Client _httpClient;
  static const _requestTimeout = Duration(seconds: 12);

  @override
  Future<List<Post>> getPosts(
      {String? treeId, String? authorId, bool onlyBranches = false}) async {
    final queryParams = <String, String>{};
    if (treeId != null) queryParams['treeId'] = treeId;
    if (authorId != null) queryParams['authorId'] = authorId;
    if (onlyBranches) queryParams['scope'] = 'branches';

    try {
      final response = await _requestList(
        method: 'GET',
        path: '/v1/posts',
        queryParams: queryParams,
      );

      return response.map((json) => Post.fromJson(json)).toList();
    } on CustomApiPostException catch (error) {
      if (error.statusCode == 404) {
        return const <Post>[];
      }
      rethrow;
    }
  }

  /// S3: страница ленты через S2-курсор. Старый бэк без пагинации
  /// вернёт массив — честно отдаём его одной страницей без курсора.
  @override
  Future<PostsPage> getPostsPage({
    String? treeId,
    int limit = 20,
    String? before,
  }) async {
    final queryParams = <String, String>{
      'limit': '$limit',
      if (treeId != null) 'treeId': treeId,
      if (before != null && before.isNotEmpty) 'before': before,
    };

    try {
      final decoded = await _requestDynamic(
        method: 'GET',
        path: '/v1/posts',
        queryParams: queryParams,
      );
      if (decoded is List) {
        // Старый бэк (без S2) — прежний формат.
        return PostsPage(
          posts: decoded
              .whereType<Map<String, dynamic>>()
              .map(Post.fromJson)
              .toList(),
          nextCursor: null,
        );
      }
      if (decoded is Map<String, dynamic>) {
        final rawPosts = decoded['posts'];
        return PostsPage(
          posts: rawPosts is List
              ? rawPosts
                  .whereType<Map<String, dynamic>>()
                  .map(Post.fromJson)
                  .toList()
              : const <Post>[],
          nextCursor: decoded['nextCursor']?.toString(),
        );
      }
      return const PostsPage(posts: <Post>[], nextCursor: null);
    } on CustomApiPostException catch (error) {
      if (error.statusCode == 404) {
        return const PostsPage(posts: <Post>[], nextCursor: null);
      }
      rethrow;
    }
  }

  /// Сколько файлов грузится одновременно.
  ///
  /// Больше — не быстрее, а опаснее: `readAsBytes()` + `base64Encode()` в
  /// storage-сервисе блокирующие, и каждый файл в полёте держит в памяти
  /// исходник плюс раздутую на треть base64-строку. Четыре — предел, за
  /// которым 30 фото начинают грозить ANR/OOM на телефоне, а не ускорением.
  static const int _uploadConcurrency = 4;

  /// Грузит медиа пулом ограниченной конкурентности, СОХРАНЯЯ порядок выбора.
  ///
  /// Порядок обязателен: карусель поста и альбом рисуют `imageUrls` как
  /// массив, поэтому раскладываем результаты по исходному индексу, а не по
  /// порядку завершения (быстрые мелкие фото иначе выпрыгивают вперёд).
  ///
  /// Любая неудача файла валит весь пост осознанно: раньше `if (url != null)`
  /// молча выбрасывал непрогрузившееся фото — человек публиковал 30 снимков и
  /// получал 27, ничего об этом не узнав. Автоповтор — шаг 5 плана.
  Future<List<String>> _uploadPostMedia(
    List<XFile> images, {
    void Function(MediaUploadProgress progress)? onProgress,
  }) async {
    if (images.isEmpty) {
      return const <String>[];
    }

    final total = images.length;
    final urls = List<String?>.filled(total, null);
    var nextIndex = 0;
    var completed = 0;
    Object? failure;
    StackTrace? failureStack;

    onProgress?.call(
      MediaUploadProgress(
        stage: MediaUploadStage.preparing,
        completed: 0,
        total: total,
      ),
    );

    // Изолят однопоточный: инкремент nextIndex между await'ами атомарен,
    // так что курсор задач без мьютекса корректен.
    Future<void> worker() async {
      while (failure == null) {
        final index = nextIndex;
        if (index >= total) {
          return;
        }
        nextIndex = index + 1;
        try {
          final url = await _storageService.uploadImage(images[index], 'posts');
          if (url == null) {
            failure ??= const CustomApiPostException(
              'Не удалось загрузить одно из фото. Проверьте связь и '
              'попробуйте опубликовать ещё раз.',
            );
            return;
          }
          urls[index] = url;
          completed += 1;
          onProgress?.call(
            MediaUploadProgress(
              stage: MediaUploadStage.uploading,
              completed: completed,
              total: total,
            ),
          );
        } catch (error, stack) {
          // Первая ошибка побеждает; флаг гасит остальных воркеров, чтобы не
          // жечь трафик на заведомо проваленную публикацию.
          failure ??= error;
          failureStack ??= stack;
          return;
        }
      }
    }

    final workerCount = total < _uploadConcurrency ? total : _uploadConcurrency;
    await Future.wait(
      List<Future<void>>.generate(workerCount, (_) => worker()),
    );

    final error = failure;
    if (error != null) {
      Error.throwWithStackTrace(error, failureStack ?? StackTrace.current);
    }

    return urls.whereType<String>().toList(growable: false);
  }

  @override
  Future<Post> createPost({
    required String treeId,
    required String content,
    List<XFile> images = const [],
    bool isPublic = false,
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const [],
    String? circleId,
    List<String>? branchIds,
    String? clientRequestId,
    void Function(MediaUploadProgress progress)? onProgress,
  }) async {
    final imageUrls = await _uploadPostMedia(images, onProgress: onProgress);
    if (images.isNotEmpty) {
      onProgress?.call(
        MediaUploadProgress(
          stage: MediaUploadStage.publishing,
          completed: imageUrls.length,
          total: images.length,
        ),
      );
    }

    // Phase 3.4: only send branchIds if the caller passed a non-
    // empty list. The backend default ([treeId]) keeps the legacy
    // "single-branch publish" behavior when this is omitted.
    final cleanBranchIds = branchIds
        ?.map((b) => b.trim())
        .where((b) => b.isNotEmpty)
        .toSet()
        .toList(growable: false);

    final response = await _requestJson(
      method: 'POST',
      path: '/v1/posts',
      body: {
        'treeId': treeId,
        'content': content,
        'imageUrls': imageUrls,
        'isPublic': isPublic,
        'scopeType': scopeType == TreeContentScopeType.branches
            ? 'branches'
            : 'wholeTree',
        'anchorPersonIds': anchorPersonIds,
        if (circleId != null && circleId.trim().isNotEmpty)
          'circleId': circleId.trim(),
        if (cleanBranchIds != null && cleanBranchIds.isNotEmpty)
          'branchIds': cleanBranchIds,
        if (clientRequestId != null && clientRequestId.trim().isNotEmpty)
          'clientRequestId': clientRequestId.trim(),
      },
    );

    return Post.fromJson(response);
  }

  @override
  Future<void> deletePost(String postId) async {
    await _requestJson(
      method: 'DELETE',
      path: '/v1/posts/$postId',
    );
  }

  @override
  Future<List<Post>> searchPosts({
    required String query,
    String? treeId,
    int limit = 50,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <Post>[];
    final params = <String, String>{
      'q': trimmed,
      if (treeId != null && treeId.trim().isNotEmpty) 'treeId': treeId.trim(),
      'limit': limit.toString(),
    };
    final response = await _requestList(
      method: 'GET',
      path: '/v1/posts/search',
      queryParams: params,
    );
    return response.map((json) => Post.fromJson(json)).toList();
  }

  @override
  Future<Post> toggleLike(String postId) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/posts/$postId/like',
    );
    return Post.fromJson(response);
  }

  @override
  Future<List<ReactionSummary>> togglePostReaction({
    required String postId,
    required String emoji,
  }) async {
    final normalized = emoji.trim();
    if (normalized.isEmpty) return const <ReactionSummary>[];
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/posts/$postId/reactions',
      body: <String, dynamic>{'emoji': normalized},
    );
    return ReactionSummary.listFromDynamic(response['reactions']);
  }

  @override
  Future<List<ReactionSummary>> toggleCommentReaction({
    required String postId,
    required String commentId,
    required String emoji,
  }) async {
    final normalized = emoji.trim();
    if (normalized.isEmpty) return const <ReactionSummary>[];
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/posts/$postId/comments/$commentId/reactions',
      body: <String, dynamic>{'emoji': normalized},
    );
    return ReactionSummary.listFromDynamic(response['reactions']);
  }

  @override
  Future<List<Comment>> getComments(String postId) async {
    final response = await _requestList(
      method: 'GET',
      path: '/v1/posts/$postId/comments',
    );

    return response.map((json) => Comment.fromJson(json)).toList();
  }

  @override
  Future<Comment> addComment(
    String postId,
    String content, {
    String? parentCommentId,
  }) async {
    final body = <String, dynamic>{'content': content};
    final trimmedParent = (parentCommentId ?? '').trim();
    if (trimmedParent.isNotEmpty) {
      body['parentCommentId'] = trimmedParent;
    }
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/posts/$postId/comments',
      body: body,
    );

    return Comment.fromJson(response);
  }

  @override
  Future<void> deleteComment(String postId, String commentId) async {
    await _requestJson(
      method: 'DELETE',
      path: '/v1/posts/$postId/comments/$commentId',
    );
  }

  // Helper Methods

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) async {
    final response = await _sendRequest(
      method: method,
      path: path,
      body: body,
    );
    try {
      return _handleResponse(response);
    } on CustomApiPostException catch (error) {
      if (await _shouldRefreshAndRetry(error)) {
        final retryResponse = await _sendRequest(
          method: method,
          path: path,
          body: body,
        );
        return _handleResponse(retryResponse);
      }
      rethrow;
    }
  }

  /// S3: сырой decoded-ответ — пагинированный GET /v1/posts может
  /// вернуть и массив (старый бэк), и {posts, nextCursor}.
  Future<dynamic> _requestDynamic({
    required String method,
    required String path,
    Map<String, String>? queryParams,
  }) async {
    final response = await _sendRequest(
      method: method,
      path: path,
      queryParams: queryParams,
    );
    try {
      return _handleResponse(response);
    } on CustomApiPostException catch (error) {
      if (!await _shouldRefreshAndRetry(error)) {
        rethrow;
      }
      final retryResponse = await _sendRequest(
        method: method,
        path: path,
        queryParams: queryParams,
      );
      return _handleResponse(retryResponse);
    }
  }

  Future<List<dynamic>> _requestList({
    required String method,
    required String path,
    Map<String, String>? queryParams,
  }) async {
    final response = await _sendRequest(
      method: method,
      path: path,
      queryParams: queryParams,
    );

    dynamic decoded;
    try {
      decoded = _handleResponse(response);
    } on CustomApiPostException catch (error) {
      if (!await _shouldRefreshAndRetry(error)) {
        rethrow;
      }
      final retryResponse = await _sendRequest(
        method: method,
        path: path,
        queryParams: queryParams,
      );
      decoded = _handleResponse(retryResponse);
    }
    if (decoded is List) return decoded;
    if (decoded is Map && decoded.containsKey('data')) {
      final data = decoded['data'];
      if (data is List) return data;
    }
    return [];
  }

  Future<http.Response> _sendRequest({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    Map<String, String>? queryParams,
  }) async {
    StartupTrace.logRequest(method, path);
    final uri = _buildUri(path, queryParams: queryParams);
    final headers = _headers();

    try {
      switch (method) {
        case 'GET':
          return await _httpClient
              .get(uri, headers: headers)
              .timeout(_requestTimeout);
        case 'POST':
          return await _httpClient
              .post(
                uri,
                headers: headers,
                body: body == null ? null : jsonEncode(body),
              )
              .timeout(_requestTimeout);
        case 'DELETE':
          return await _httpClient
              .delete(uri, headers: headers)
              .timeout(_requestTimeout);
        default:
          throw CustomApiPostException('Unsupported HTTP method: $method');
      }
    } on TimeoutException {
      throw const CustomApiPostException(
        'Backend не ответил за 12 секунд',
      );
    } on http.ClientException catch (error) {
      throw CustomApiPostException(error.message);
    }
  }

  Future<bool> _shouldRefreshAndRetry(CustomApiPostException error) async {
    if (error.statusCode != 401 && error.statusCode != 403) {
      return false;
    }
    await _authService.refreshSession();
    return _authService.accessToken != null;
  }

  dynamic _handleResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return <String, dynamic>{};
      return jsonDecode(response.body);
    }

    final errorData = response.body.isNotEmpty ? jsonDecode(response.body) : {};
    throw CustomApiPostException(
      errorData['message']?.toString() ??
          'Post Service Error: ${response.statusCode}',
      statusCode: response.statusCode,
    );
  }

  Uri _buildUri(String path, {Map<String, String>? queryParams}) {
    var base = _runtimeConfig.apiBaseUrl.replaceAll(RegExp(r'/$'), '');
    final shouldForceHttps = base.startsWith('http://api.rodnya-tree.ru') ||
        base.startsWith('http://rodnya-tree.ru') ||
        base.startsWith('http://api.fodder-development.ru');
    if (shouldForceHttps) {
      base = 'https://${base.replaceFirst(RegExp(r'^http://'), '')}';
    }

    final fullUrl = '$base$path';
    final uri = Uri.parse(fullUrl);

    if (queryParams != null && queryParams.isNotEmpty) {
      return uri.replace(queryParameters: queryParams);
    }
    return uri;
  }

  Map<String, String> _headers() {
    final token = _authService.accessToken;
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }
}

class CustomApiPostException implements UserFacingApiException {
  const CustomApiPostException(this.message, {this.statusCode});

  @override
  final String message;
  @override
  final int? statusCode;

  @override
  String toString() => message;
}
