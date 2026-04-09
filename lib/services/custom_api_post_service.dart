import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/post_service_interface.dart';
import '../backend/interfaces/storage_service_interface.dart';
import '../models/comment.dart';
import '../models/post.dart';
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

  @override
  Future<Post> createPost({
    required String treeId,
    required String content,
    List<XFile> images = const [],
    bool isPublic = false,
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const [],
  }) async {
    final imageUrls = <String>[];
    for (final image in images) {
      final url = await _storageService.uploadImage(image, 'posts');
      if (url != null) imageUrls.add(url);
    }

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
  Future<void> toggleLike(String postId) async {
    await _requestJson(
      method: 'POST',
      path: '/v1/posts/$postId/like',
    );
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
  Future<Comment> addComment(String postId, String content) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/posts/$postId/comments',
      body: {'content': content},
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
    final uri = _buildUri(path);
    late http.Response response;

    final headers = _headers();

    switch (method) {
      case 'GET':
        response = await _httpClient.get(uri, headers: headers);
        break;
      case 'POST':
        response = await _httpClient.post(uri,
            headers: headers, body: jsonEncode(body));
        break;
      case 'DELETE':
        response = await _httpClient.delete(uri, headers: headers);
        break;
      default:
        throw Exception('Unsupported HTTP method: $method');
    }

    return _handleResponse(response);
  }

  Future<List<dynamic>> _requestList({
    required String method,
    required String path,
    Map<String, String>? queryParams,
  }) async {
    final uri = _buildUri(path, queryParams: queryParams);
    late http.Response response;

    final headers = _headers();

    if (method == 'GET') {
      response = await _httpClient.get(uri, headers: headers);
    } else {
      throw Exception('Unsupported List HTTP method: $method');
    }

    final decoded = _handleResponse(response);
    if (decoded is List) return decoded;
    if (decoded is Map && decoded.containsKey('data')) {
      final data = decoded['data'];
      if (data is List) return data;
    }
    return [];
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

class CustomApiPostException implements Exception {
  const CustomApiPostException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
