import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/storage_service_interface.dart';
import 'custom_api_auth_service.dart';

class CustomApiStorageService implements StorageServiceInterface {
  CustomApiStorageService({
    required CustomApiAuthService authService,
    required BackendRuntimeConfig runtimeConfig,
    http.Client? httpClient,
  })  : _authService = authService,
        _runtimeConfig = runtimeConfig,
        _httpClient = httpClient ?? http.Client();

  final CustomApiAuthService _authService;
  final BackendRuntimeConfig _runtimeConfig;
  final http.Client _httpClient;
  final Uuid _uuid = const Uuid();

  @override
  Future<String?> uploadImage(XFile imageFile, String folder) async {
    final extension = _detectExtension(
      imageFile.name,
      fallback: '.jpg',
      mimeType: imageFile.mimeType,
    );
    final fileBytes = await imageFile.readAsBytes();

    return uploadBytes(
      bucket: folder,
      path: '${_uuid.v4()}$extension',
      fileBytes: fileBytes,
      fileOptions: FileOptions(
        contentType: _contentTypeForExtension(extension),
      ),
    );
  }

  @override
  Future<bool> deleteImage(String imageUrl) async {
    final uri = _buildUri('/v1/media');
    final response = await _httpClient.delete(
      uri,
      headers: _headers(),
      body: jsonEncode({'url': imageUrl}),
    );

    return response.statusCode == 204;
  }

  @override
  Future<String?> uploadProfileImage(XFile imageFile) async {
    final userId = _authService.currentUserId;
    if (userId == null || userId.isEmpty) {
      throw const CustomApiStorageException('Пользователь не авторизован');
    }

    final extension = _detectExtension(
      imageFile.name,
      fallback: '.jpg',
      mimeType: imageFile.mimeType,
    );
    final fileBytes = await imageFile.readAsBytes();

    return uploadBytes(
      bucket: 'avatars',
      path: '$userId/avatar_${DateTime.now().millisecondsSinceEpoch}$extension',
      fileBytes: fileBytes,
      fileOptions: FileOptions(
        upsert: true,
        contentType: _contentTypeForExtension(extension),
      ),
    );
  }

  @override
  Future<String?> uploadBytes({
    required String bucket,
    required String path,
    required Uint8List fileBytes,
    FileOptions? fileOptions,
  }) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/media/upload',
      body: {
        'bucket': bucket,
        'path': path,
        'contentType': fileOptions?.contentType,
        'fileBase64': base64Encode(fileBytes),
      },
    );

    return response['url']?.toString();
  }

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) async {
    final uri = _buildUri(path);
    late http.Response response;

    switch (method) {
      case 'POST':
        response = await _httpClient.post(
          uri,
          headers: _headers(),
          body: jsonEncode(body ?? const {}),
        );
        break;
      default:
        throw const CustomApiStorageException('Неподдерживаемый HTTP-метод');
    }

    if (response.body.isEmpty) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return const <String, dynamic>{};
      }
      throw CustomApiStorageException(
        'Пустой ответ от backend',
        statusCode: response.statusCode,
      );
    }

    final dynamic decoded = jsonDecode(response.body);
    final payload = decoded is Map<String, dynamic>
        ? decoded
        : <String, dynamic>{'data': decoded};

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return payload;
    }

    throw CustomApiStorageException(
      payload['message']?.toString() ??
          payload['error']?.toString() ??
          'Ошибка media backend (${response.statusCode})',
      statusCode: response.statusCode,
    );
  }

  Uri _buildUri(String path) {
    final normalizedBase = _runtimeConfig.apiBaseUrl.replaceAll(
      RegExp(r'/$'),
      '',
    );
    return Uri.parse('$normalizedBase$path');
  }

  Map<String, String> _headers() {
    final token = _authService.accessToken;
    if (token == null || token.isEmpty) {
      throw const CustomApiStorageException('Нет активной customApi session');
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
    final normalizedName = rawName.toLowerCase().trim();
    if (normalizedName.endsWith('.png')) {
      return '.png';
    }
    if (normalizedName.endsWith('.jpeg')) {
      return '.jpeg';
    }
    if (normalizedName.endsWith('.jpg')) {
      return '.jpg';
    }
    if (normalizedName.endsWith('.webp')) {
      return '.webp';
    }

    switch (mimeType) {
      case 'image/png':
        return '.png';
      case 'image/webp':
        return '.webp';
      case 'image/jpeg':
        return '.jpeg';
      case 'image/jpg':
        return '.jpg';
    }
    return fallback;
  }

  String _contentTypeForExtension(String extension) {
    switch (extension) {
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.jpeg':
      case '.jpg':
      default:
        return 'image/jpeg';
    }
  }
}

class CustomApiStorageException implements Exception {
  const CustomApiStorageException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
