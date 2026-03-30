import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lineage/backend/backend_runtime_config.dart';
import 'package:lineage/services/custom_api_auth_service.dart';
import 'package:lineage/services/custom_api_storage_service.dart';
import 'package:lineage/services/invitation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('CustomApiStorageService uploads bytes and returns backend URL',
      () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/v1/media/upload');
      expect(request.method, 'POST');

      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['bucket'], 'avatars');
      expect(body['path'], 'user-1/avatar.png');
      expect(body['contentType'], 'image/png');
      expect(body['fileBase64'], base64Encode(Uint8List.fromList([1, 2, 3])));

      return http.Response(
        jsonEncode({
          'url': 'https://api.example.ru/media/avatars/user-1/avatar.png',
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
        'email': 'dev@lineage.app',
        'displayName': 'Dev User',
        'providerIds': ['password'],
        'isProfileComplete': false,
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

    final storageService = CustomApiStorageService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final uploadedUrl = await storageService.uploadBytes(
      bucket: 'avatars',
      path: 'user-1/avatar.png',
      fileBytes: Uint8List.fromList([1, 2, 3]),
      fileOptions: const FileOptions(contentType: 'image/png'),
    );

    expect(
        uploadedUrl, 'https://api.example.ru/media/avatars/user-1/avatar.png');
  });
}
