import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../backend/models/user_facing_exception.dart';
import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/identity_service_interface.dart';
import '../models/identity_claim.dart';
import '../models/merge_proposal.dart';
import '../models/person_attribute.dart';
import '../models/public_identity_result.dart';
import '../utils/startup_trace.dart';
import 'custom_api_auth_service.dart';

class CustomApiIdentityService implements IdentityServiceInterface {
  CustomApiIdentityService({
    required CustomApiAuthService authService,
    required BackendRuntimeConfig runtimeConfig,
    http.Client? httpClient,
  })  : _authService = authService,
        _runtimeConfig = runtimeConfig,
        _httpClient = httpClient ?? http.Client();

  final CustomApiAuthService _authService;
  final BackendRuntimeConfig _runtimeConfig;
  final http.Client _httpClient;

  static const _requestTimeout = Duration(seconds: 12);

  @override
  Future<List<MergeProposal>> getPendingMergeProposals() async {
    final response = await _requestJson(
      method: 'GET',
      path: '/v1/merge-proposals/pending',
    );
    final rawProposals = response['proposals'];
    if (rawProposals is! List<dynamic>) {
      return const <MergeProposal>[];
    }
    return rawProposals
        .whereType<Map<String, dynamic>>()
        .map(MergeProposal.fromJson)
        .where((proposal) => proposal.id.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<MergeProposal> reviewMergeProposal(
    String proposalId, {
    required bool accept,
    String? reason,
  }) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/merge-proposals/$proposalId/review',
      body: {
        'decision': accept ? 'accept' : 'reject',
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason,
      },
    );
    return MergeProposal.fromJson(
      Map<String, dynamic>.from(response['proposal'] as Map? ?? const {}),
    );
  }

  @override
  Future<List<MergeProposal>> getMergedProposals() async {
    final response = await _requestJson(
      method: 'GET',
      path: '/v1/merge-proposals/merged',
    );
    final rawProposals = response['proposals'];
    if (rawProposals is! List<dynamic>) {
      return const <MergeProposal>[];
    }
    return rawProposals
        .whereType<Map<String, dynamic>>()
        .map(MergeProposal.fromJson)
        .where((proposal) => proposal.id.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<MergeProposal> unmergeMergeProposal(String proposalId) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/merge-proposals/$proposalId/unmerge',
    );
    return MergeProposal.fromJson(
      Map<String, dynamic>.from(response['proposal'] as Map? ?? const {}),
    );
  }

  @override
  Future<List<PersonAttribute>> getPersonAttributes({
    required String treeId,
    required String personId,
  }) async {
    final response = await _requestJson(
      method: 'GET',
      path: '/v1/trees/$treeId/persons/$personId/attributes',
    );
    final rawAttributes = response['attributes'];
    if (rawAttributes is! List<dynamic>) {
      return const <PersonAttribute>[];
    }
    return rawAttributes
        .whereType<Map<String, dynamic>>()
        .map(PersonAttribute.fromJson)
        .where((attribute) => attribute.field.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<List<PersonAttribute>> updatePersonAttributeVisibility({
    required String treeId,
    required String personId,
    String? visibility,
    Map<String, String> attributes = const <String, String>{},
  }) async {
    final response = await _requestJson(
      method: 'PUT',
      path: '/v1/trees/$treeId/persons/$personId/attributes',
      body: {
        if (visibility != null) 'visibility': visibility,
        'attributes': attributes.entries
            .map((entry) => {
                  'field': entry.key,
                  'visibility': entry.value,
                })
            .toList(growable: false),
      },
    );
    final rawAttributes = response['attributes'];
    if (rawAttributes is! List<dynamic>) {
      return const <PersonAttribute>[];
    }
    return rawAttributes
        .whereType<Map<String, dynamic>>()
        .map(PersonAttribute.fromJson)
        .where((attribute) => attribute.field.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<IdentityClaim> createIdentityClaim({
    required String treeId,
    required String personId,
    String? evidence,
  }) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/identity-claims',
      body: {
        'treeId': treeId,
        'personId': personId,
        if (evidence != null && evidence.trim().isNotEmpty)
          'evidence': evidence,
      },
    );
    return IdentityClaim.fromJson(
      Map<String, dynamic>.from(response['claim'] as Map? ?? const {}),
    );
  }

  @override
  Future<List<IdentityClaim>> getPendingIdentityClaims() async {
    final response = await _requestJson(
      method: 'GET',
      path: '/v1/identity-claims/pending',
    );
    final rawClaims = response['claims'];
    if (rawClaims is! List<dynamic>) {
      return const <IdentityClaim>[];
    }
    return rawClaims
        .whereType<Map<String, dynamic>>()
        .map(IdentityClaim.fromJson)
        .where((claim) => claim.id.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<IdentityClaim> reviewIdentityClaim(
    String claimId, {
    required bool approve,
    String? reason,
  }) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/identity-claims/$claimId/review',
      body: {
        'decision': approve ? 'approve' : 'deny',
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason,
      },
    );
    return IdentityClaim.fromJson(
      Map<String, dynamic>.from(response['claim'] as Map? ?? const {}),
    );
  }

  @override
  Future<bool> setPublicDiscoverability(bool enabled) async {
    final response = await _requestJson(
      method: 'PATCH',
      path: '/v1/identity-discovery/me',
      body: {'isPublicDiscoverable': enabled},
    );
    return response['isPublicDiscoverable'] == true;
  }

  @override
  Future<List<PublicIdentityResult>> searchPublicIdentities({
    String? query,
    String? birthYear,
  }) async {
    final queryParameters = <String, String>{
      if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
      if (birthYear != null && birthYear.trim().isNotEmpty)
        'birthYear': birthYear.trim(),
    };
    final response = await _requestJson(
      method: 'GET',
      path: Uri(
        path: '/v1/identity-discovery/search',
        queryParameters: queryParameters.isEmpty ? null : queryParameters,
      ).toString(),
    );
    final rawResults = response['results'];
    if (rawResults is! List<dynamic>) {
      return const <PublicIdentityResult>[];
    }
    return rawResults
        .whereType<Map<String, dynamic>>()
        .map(PublicIdentityResult.fromJson)
        .where((result) => result.identityId.isNotEmpty)
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) async {
    StartupTrace.logRequest(method, path);
    final request = http.Request(method, _buildUri(path))
      ..headers.addAll(_headers(hasBody: body != null));
    if (body != null) {
      request.body = jsonEncode(body);
    }

    final streamedResponse =
        await _httpClient.send(request).timeout(_requestTimeout);
    final response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) {
        return <String, dynamic>{};
      }
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    }

    final errorData = response.body.isNotEmpty ? jsonDecode(response.body) : {};
    throw CustomApiIdentityException(
      errorData is Map<String, dynamic>
          ? errorData['message']?.toString() ??
              'Identity Service Error: ${response.statusCode}'
          : 'Identity Service Error: ${response.statusCode}',
      statusCode: response.statusCode,
    );
  }

  Uri _buildUri(String path) {
    var base = _runtimeConfig.apiBaseUrl.replaceAll(RegExp(r'/$'), '');
    final shouldForceHttps = base.startsWith('http://api.rodnya-tree.ru') ||
        base.startsWith('http://rodnya-tree.ru') ||
        base.startsWith('http://api.fodder-development.ru');
    if (shouldForceHttps) {
      base = 'https://${base.replaceFirst(RegExp(r'^http://'), '')}';
    }
    return Uri.parse('$base$path');
  }

  Map<String, String> _headers({required bool hasBody}) {
    final token = _authService.accessToken;
    if (token == null || token.isEmpty) {
      throw const CustomApiIdentityException(
        'Нет активной сессии',
        statusCode: 401,
      );
    }

    return {
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
      if (hasBody) 'Content-Type': 'application/json',
    };
  }
}

class CustomApiIdentityException implements UserFacingApiException {
  const CustomApiIdentityException(this.message, {this.statusCode});

  @override
  final String message;
  @override
  final int? statusCode;

  @override
  String toString() => message;
}
