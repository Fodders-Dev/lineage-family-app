import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../backend/models/user_facing_exception.dart';
import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/storage_service_interface.dart';
import '../utils/url_utils.dart';
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
        contentType: _resolveContentType(imageFile, extension),
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
        contentType: _resolveContentType(imageFile, extension),
      ),
    );
  }

  @override
  Future<String?> uploadCoverImage(XFile imageFile) async {
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
      bucket: 'covers',
      path: '$userId/cover_${DateTime.now().millisecondsSinceEpoch}$extension',
      fileBytes: fileBytes,
      fileOptions: FileOptions(
        upsert: true,
        contentType: _resolveContentType(imageFile, extension),
      ),
    );
  }

  /// Потолок бинарного роута бэка. Проверяем ЗДЕСЬ, до отправки: сервер
  /// свой 413 честно доставит только после того, как клиент дольёт всё
  /// тело — мгновенная локальная ошибка ощутимо честнее.
  static const int _maxUploadBytes = 64 * 1024 * 1024;

  @override
  Future<String?> uploadBytes({
    required String bucket,
    required String path,
    required Uint8List fileBytes,
    FileOptions? fileOptions,
  }) async {
    if (fileBytes.length > _maxUploadBytes) {
      throw const CustomApiStorageException(
        'Файл больше 64 МБ. Сожмите видео или выберите файл поменьше.',
        statusCode: 413,
      );
    }

    // Бинарный путь: тело = сами байты. Против base64-JSON экономит +33%
    // трафика и двойную память (мегабайтная строка + её парсинг на бэке),
    // а видео перестают упираться в потолок express.json(50mb).
    // Фолбэка на base64 больше нет: бэкенд закрыл его 410 (02.09.2026), а
    // единственный бэк без PUT /v1/media/object ушёл вместе со старым
    // сервером. 404/405 здесь = сломанный/чужой бэкенд, и честнее сказать
    // это сразу, чем молча слать мегабайтный base64 в никуда.
    final uri = _buildUri(
      '/v1/media/object'
      '?bucket=${Uri.encodeQueryComponent(bucket)}'
      '&path=${Uri.encodeQueryComponent(path)}',
    );
    final response = await _httpClient.put(
      uri,
      headers: _binaryHeaders(fileOptions?.contentType),
      body: fileBytes,
    );
    if (response.statusCode == 404 || response.statusCode == 405) {
      throw CustomApiStorageException(
        'Сервер не принимает загрузку файлов. Обновите приложение.',
        statusCode: response.statusCode,
      );
    }
    final payload = _decodeJsonResponse(response);
    return UrlUtils.normalizeImageUrl(payload['url']?.toString());
  }

  Map<String, String> _binaryHeaders(String? contentType) {
    final token = _authService.accessToken;
    if (token == null || token.isEmpty) {
      throw const CustomApiStorageException('Нет активной customApi session');
    }
    return {
      'Content-Type': contentType ?? 'application/octet-stream',
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  Map<String, dynamic> _decodeJsonResponse(http.Response response) {
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
    var base = _runtimeConfig.apiBaseUrl.replaceAll(
      RegExp(r'/$'),
      '',
    );
    final shouldForceHttps = base.startsWith('http://api.rodnya-tree.ru') ||
        base.startsWith('http://rodnya-tree.ru') ||
        base.startsWith('http://api.fodder-development.ru');
    if (shouldForceHttps) {
      base = 'https://${base.replaceFirst(RegExp(r'^http://'), '')}';
    }
    return Uri.parse('$base$path');
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
    final ext = p.extension(rawName).toLowerCase().trim();
    if (ext.isNotEmpty) {
      return ext;
    }

    switch (mimeType) {
      case 'image/png':
        return '.png';
      case 'image/webp':
        return '.webp';
      case 'image/jpeg':
      case 'image/jpg':
        return '.jpg';
      case 'video/mp4':
        return '.mp4';
      case 'video/quicktime':
        return '.mov';
      case 'video/webm':
        return '.webm';
      case 'application/pdf':
        return '.pdf';
      case 'application/msword':
        return '.doc';
      case 'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
        return '.docx';
    }
    return fallback;
  }

  /// Resolves the upload Content-Type. The [file]'s own `mimeType` (set by the
  /// recorder/picker) is AUTHORITATIVE and wins over extension guessing —
  /// critical for `.webm`, which is ambiguous: a voice note is `audio/webm`,
  /// a кружок is `video/webm`, same extension. Falls back to extension only
  /// when the file carries no usable mime type.
  String _resolveContentType(XFile file, String extension) {
    final mimeType = file.mimeType;
    if (mimeType != null && mimeType.isNotEmpty && mimeType.contains('/')) {
      return mimeType;
    }
    return _contentTypeForExtension(extension);
  }

  String _contentTypeForExtension(String extension) {
    switch (extension.toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.jpeg':
      case '.jpg':
        return 'image/jpeg';
      case '.mp4':
        return 'video/mp4';
      case '.mov':
        return 'video/quicktime';
      case '.webm':
        // Extension-only fallback: .webm defaults to video (кружок). For a
        // voice note (audio/webm) the file's mimeType wins via
        // _resolveContentType — extension alone cannot disambiguate.
        return 'video/webm';
      // Audio (voice notes). Native records .m4a as an MP4 container.
      case '.m4a':
      case '.aac':
        return 'audio/mp4';
      case '.mp3':
        return 'audio/mpeg';
      case '.wav':
        return 'audio/wav';
      case '.ogg':
        return 'audio/ogg';
      case '.pdf':
        return 'application/pdf';
      case '.doc':
        return 'application/msword';
      case '.docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case '.xls':
        return 'application/vnd.ms-excel';
      case '.xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case '.zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }
}

class CustomApiStorageException implements UserFacingApiException {
  const CustomApiStorageException(this.message, {this.statusCode});

  @override
  final String message;
  @override
  final int? statusCode;

  @override
  String toString() => message;
}
