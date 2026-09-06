import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../backend/models/user_facing_exception.dart';
import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/gathering_service_interface.dart';
import '../backend/interfaces/storage_service_interface.dart';
import '../models/gathering.dart';
import '../models/post.dart' show TreeContentScopeType;
import '../utils/startup_trace.dart';
import 'custom_api_auth_service.dart';

/// Phase E2: HTTP client for /v1/gatherings. Cloned from
/// CustomApiPostService (same _requestJson/_requestList + 401/403
/// refresh-and-retry), without the storage dependency (gatherings carry
/// no media).
class CustomApiGatheringService implements GatheringServiceInterface {
  CustomApiGatheringService({
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
  Future<List<Gathering>> getGatherings({required String treeId}) async {
    try {
      final response = await _requestList(
        method: 'GET',
        path: '/v1/gatherings',
        queryParams: {'treeId': treeId},
      );
      return response.map((json) => Gathering.fromJson(json)).toList();
    } on CustomApiGatheringException catch (error) {
      if (error.statusCode == 404) {
        return const <Gathering>[];
      }
      rethrow;
    }
  }

  @override
  Future<Gathering> createGathering({
    required String treeId,
    required String title,
    String? description,
    required DateTime startAt,
    DateTime? endAt,
    bool isAllDay = false,
    String? place,
    List<XFile> images = const [],
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const [],
    String? circleId,
    List<String>? branchIds,
  }) async {
    // Same pipeline as posts: upload each photo to the media service
    // (its own bucket) → collect the public URLs for the request body.
    final imageUrls = <String>[];
    for (final image in images) {
      final url = await _storageService.uploadImage(image, 'gatherings');
      if (url != null) imageUrls.add(url);
    }

    final cleanBranchIds = branchIds
        ?.map((b) => b.trim())
        .where((b) => b.isNotEmpty)
        .toSet()
        .toList(growable: false);

    final response = await _requestJson(
      method: 'POST',
      path: '/v1/gatherings',
      body: {
        'treeId': treeId,
        'title': title,
        'startAt': startAt.toIso8601String(),
        if (endAt != null) 'endAt': endAt.toIso8601String(),
        'isAllDay': isAllDay,
        'imageUrls': imageUrls,
        'scopeType': scopeType == TreeContentScopeType.branches
            ? 'branches'
            : 'wholeTree',
        'anchorPersonIds': anchorPersonIds,
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
        if (place != null && place.trim().isNotEmpty) 'place': place.trim(),
        if (circleId != null && circleId.trim().isNotEmpty)
          'circleId': circleId.trim(),
        if (cleanBranchIds != null && cleanBranchIds.isNotEmpty)
          'branchIds': cleanBranchIds,
      },
    );

    return Gathering.fromJson(response);
  }

  @override
  Future<void> deleteGathering(String gatheringId) async {
    await _requestJson(
      method: 'DELETE',
      path: '/v1/gatherings/$gatheringId',
    );
  }

  @override
  Future<Gathering> setRsvp(
    String gatheringId,
    String status, {
    int? headcount,
    String? note,
  }) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/gatherings/$gatheringId/rsvp',
      body: {
        'status': status,
        if (headcount != null) 'headcount': headcount,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      },
    );
    return Gathering.fromJson(response);
  }

  // Helper Methods (cloned from CustomApiPostService)

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) async {
    final response = await _sendRequest(method: method, path: path, body: body);
    try {
      return _handleResponse(response);
    } on CustomApiGatheringException catch (error) {
      if (await _shouldRefreshAndRetry(error)) {
        final retryResponse =
            await _sendRequest(method: method, path: path, body: body);
        return _handleResponse(retryResponse);
      }
      rethrow;
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
    } on CustomApiGatheringException catch (error) {
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
          throw CustomApiGatheringException('Unsupported HTTP method: $method');
      }
    } on TimeoutException {
      throw const CustomApiGatheringException(
        'Backend не ответил за 12 секунд',
      );
    } on http.ClientException catch (error) {
      throw CustomApiGatheringException(error.message);
    }
  }

  Future<bool> _shouldRefreshAndRetry(CustomApiGatheringException error) async {
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
    throw CustomApiGatheringException(
      errorData['message']?.toString() ??
          'Gathering Service Error: ${response.statusCode}',
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

class CustomApiGatheringException implements UserFacingApiException {
  const CustomApiGatheringException(this.message, {this.statusCode});

  @override
  final String message;
  @override
  final int? statusCode;

  @override
  String toString() => message;
}
