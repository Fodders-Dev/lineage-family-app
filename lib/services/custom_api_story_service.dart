import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../backend/models/user_facing_exception.dart';
import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/storage_service_interface.dart';
import '../backend/interfaces/story_service_interface.dart';
import '../models/post.dart' show TreeContentScopeType;
import '../models/reaction_summary.dart';
import '../models/story.dart';
import '../utils/startup_trace.dart';
import 'custom_api_auth_service.dart';

class CustomApiStoryService implements StoryServiceInterface {
  CustomApiStoryService({
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
  final Uuid _uuid = const Uuid();

  @override
  Future<List<Story>> getStories({
    String? treeId,
    String? authorId,
    bool includeArchive = false,
  }) async {
    final queryParams = <String, String>{};
    if (treeId != null && treeId.trim().isNotEmpty) {
      queryParams['treeId'] = treeId.trim();
    }
    if (authorId != null && authorId.trim().isNotEmpty) {
      queryParams['authorId'] = authorId.trim();
    }
    if (includeArchive) {
      // Server hint — when the backend implements archive support this
      // surfaces expired entries as well. Until then it's harmless: the
      // current handler just ignores unknown query params.
      queryParams['includeArchive'] = 'true';
    }

    final response = await _requestList(
      method: 'GET',
      path: '/v1/stories',
      queryParams: queryParams,
    );

    return response
        .map((entry) => Story.fromJson(entry as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Story> createStory({
    required String treeId,
    required StoryType type,
    String? text,
    XFile? media,
    String? thumbnailUrl,
    DateTime? expiresAt,
    String? circleId,
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const <String>[],
  }) async {
    String? uploadedMediaUrl;
    if (media != null) {
      uploadedMediaUrl = await _uploadStoryMedia(type: type, media: media);
    }

    final response = await _requestJson(
      method: 'POST',
      path: '/v1/stories',
      body: {
        'treeId': treeId,
        'type': Story.storyTypeToString(type),
        'text': text?.trim(),
        'mediaUrl': uploadedMediaUrl,
        'thumbnailUrl': thumbnailUrl,
        'expiresAt': expiresAt?.toIso8601String(),
        if (circleId != null && circleId.trim().isNotEmpty)
          'circleId': circleId.trim(),
        'scopeType': scopeType == TreeContentScopeType.branches
            ? 'branches'
            : 'wholeTree',
        if (anchorPersonIds.isNotEmpty) 'anchorPersonIds': anchorPersonIds,
      },
    );

    return Story.fromJson(response);
  }

  @override
  Future<Story> markViewed(String storyId) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/stories/$storyId/view',
    );

    return Story.fromJson(response);
  }

  @override
  Future<void> deleteStory(String storyId) async {
    await _requestJson(
      method: 'DELETE',
      path: '/v1/stories/$storyId',
    );
  }

  @override
  Future<List<ReactionSummary>> toggleStoryReaction({
    required String storyId,
    required String emoji,
  }) async {
    final normalized = emoji.trim();
    if (normalized.isEmpty) return const <ReactionSummary>[];
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/stories/$storyId/reactions',
      body: <String, dynamic>{'emoji': normalized},
    );
    return ReactionSummary.listFromDynamic(response['reactions']);
  }

  Future<String?> _uploadStoryMedia({
    required StoryType type,
    required XFile media,
  }) async {
    switch (type) {
      case StoryType.text:
        return null;
      case StoryType.image:
        return _storageService.uploadImage(media, 'stories');
      case StoryType.video:
        final extension = _detectExtension(
          media.name,
          fallback: '.mp4',
          mimeType: media.mimeType,
        );
        return _storageService.uploadBytes(
          bucket: 'stories',
          path: '${_uuid.v4()}$extension',
          fileBytes: await media.readAsBytes(),
          fileOptions: FileOptions(
            contentType: _contentTypeForExtension(extension),
          ),
        );
    }
  }

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) async {
    StartupTrace.logRequest(method, path);
    final uri = _buildUri(path);
    late http.Response response;
    final headers = _headers();

    switch (method) {
      case 'POST':
        response = await _httpClient.post(
          uri,
          headers: headers,
          body: jsonEncode(body ?? const <String, dynamic>{}),
        );
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
    StartupTrace.logRequest(method, path);
    final uri = _buildUri(path, queryParams: queryParams);
    late http.Response response;

    switch (method) {
      case 'GET':
        response = await _httpClient.get(uri, headers: _headers());
        break;
      default:
        throw Exception('Unsupported list HTTP method: $method');
    }

    final decoded = _handleResponse(response);
    if (decoded is List<dynamic>) {
      return decoded;
    }
    if (decoded is Map<String, dynamic> && decoded['data'] is List<dynamic>) {
      return decoded['data'] as List<dynamic>;
    }
    return const <dynamic>[];
  }

  dynamic _handleResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) {
        return <String, dynamic>{};
      }
      return jsonDecode(response.body);
    }

    final errorData = response.body.isNotEmpty ? jsonDecode(response.body) : {};
    throw CustomApiStoryException(
      errorData['message']?.toString() ??
          'Story Service Error: ${response.statusCode}',
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

    final uri = Uri.parse('$base$path');
    if (queryParams == null || queryParams.isEmpty) {
      return uri;
    }
    return uri.replace(queryParameters: queryParams);
  }

  Map<String, String> _headers() {
    final token = _authService.accessToken;
    if (token == null || token.isEmpty) {
      throw const CustomApiStoryException(
        'Нет активной сессии',
        statusCode: 401,
      );
    }

    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  String _detectExtension(
    String rawName, {
    required String fallback,
    String? mimeType,
  }) {
    final extension = p.extension(rawName).toLowerCase().trim();
    if (extension.isNotEmpty) {
      return extension;
    }

    switch (mimeType) {
      case 'image/png':
        return '.png';
      case 'image/webp':
        return '.webp';
      case 'image/jpeg':
      case 'image/jpg':
        return '.jpg';
      case 'video/quicktime':
        return '.mov';
      case 'video/webm':
        return '.webm';
      case 'video/mp4':
        return '.mp4';
      default:
        return fallback;
    }
  }

  String _contentTypeForExtension(String extension) {
    switch (extension.toLowerCase()) {
      case '.mov':
        return 'video/quicktime';
      case '.webm':
        return 'video/webm';
      case '.mp4':
      default:
        return 'video/mp4';
    }
  }
}

class CustomApiStoryException implements UserFacingApiException {
  const CustomApiStoryException(this.message, {this.statusCode});

  @override
  final String message;
  @override
  final int? statusCode;

  @override
  String toString() => message;
}
