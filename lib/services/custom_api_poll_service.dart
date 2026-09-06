import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../backend/models/user_facing_exception.dart';
import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/poll_service_interface.dart';
import '../backend/interfaces/storage_service_interface.dart';
import '../models/poll.dart';
import '../models/post.dart' show TreeContentScopeType;
import '../utils/startup_trace.dart';
import 'custom_api_auth_service.dart';

/// Phase E5: HTTP client for /v1/polls. Cloned from
/// CustomApiGatheringService (same _requestJson/_requestList + 401/403
/// refresh-and-retry + storage upload for photos), with option-based
/// voting in place of RSVP.
class CustomApiPollService implements PollServiceInterface {
  CustomApiPollService({
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
  Future<List<Poll>> getPolls({String? treeId}) async {
    try {
      final response = await _requestList(
        method: 'GET',
        path: '/v1/polls',
        // null/empty treeId → audience mode (all accessible circles),
        // mirroring posts. Only send the param when scoped to a circle.
        queryParams: {
          if (treeId != null && treeId.isNotEmpty) 'treeId': treeId,
        },
      );
      return response.map((json) => Poll.fromJson(json)).toList();
    } on CustomApiPollException catch (error) {
      if (error.statusCode == 404) {
        return const <Poll>[];
      }
      rethrow;
    }
  }

  @override
  Future<Poll> createPoll({
    required String treeId,
    required String question,
    required List<String> options,
    bool allowMultiple = false,
    DateTime? closesAt,
    List<XFile> images = const [],
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const [],
    String? circleId,
    List<String>? branchIds,
  }) async {
    final imageUrls = <String>[];
    for (final image in images) {
      final url = await _storageService.uploadImage(image, 'polls');
      if (url != null) imageUrls.add(url);
    }

    final cleanBranchIds = branchIds
        ?.map((b) => b.trim())
        .where((b) => b.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final cleanOptions =
        options.map((o) => o.trim()).where((o) => o.isNotEmpty).toList();

    final response = await _requestJson(
      method: 'POST',
      path: '/v1/polls',
      body: {
        'treeId': treeId,
        'question': question,
        'options': cleanOptions,
        'allowMultiple': allowMultiple,
        'imageUrls': imageUrls,
        'scopeType': scopeType == TreeContentScopeType.branches
            ? 'branches'
            : 'wholeTree',
        'anchorPersonIds': anchorPersonIds,
        if (closesAt != null) 'closesAt': closesAt.toIso8601String(),
        if (circleId != null && circleId.trim().isNotEmpty)
          'circleId': circleId.trim(),
        if (cleanBranchIds != null && cleanBranchIds.isNotEmpty)
          'branchIds': cleanBranchIds,
      },
    );

    return Poll.fromJson(response);
  }

  @override
  Future<Poll> vote(String pollId, List<String> optionIds) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/polls/$pollId/respond',
      body: {'optionIds': optionIds},
    );
    return Poll.fromJson(response);
  }

  @override
  Future<void> deletePoll(String pollId) async {
    await _requestJson(
      method: 'DELETE',
      path: '/v1/polls/$pollId',
    );
  }

  // Helper Methods (cloned from CustomApiGatheringService)

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) async {
    final response = await _sendRequest(method: method, path: path, body: body);
    try {
      return _handleResponse(response);
    } on CustomApiPollException catch (error) {
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
    } on CustomApiPollException catch (error) {
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
          throw CustomApiPollException('Unsupported HTTP method: $method');
      }
    } on TimeoutException {
      throw const CustomApiPollException(
        'Backend не ответил за 12 секунд',
      );
    } on http.ClientException catch (error) {
      throw CustomApiPollException(error.message);
    }
  }

  Future<bool> _shouldRefreshAndRetry(CustomApiPollException error) async {
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
    throw CustomApiPollException(
      errorData['message']?.toString() ??
          'Poll Service Error: ${response.statusCode}',
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

class CustomApiPollException implements UserFacingApiException {
  const CustomApiPollException(this.message, {this.statusCode});

  @override
  final String message;
  @override
  final int? statusCode;

  @override
  String toString() => message;
}
