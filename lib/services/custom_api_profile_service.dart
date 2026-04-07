import 'dart:convert';
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/profile_service_interface.dart';
import '../backend/interfaces/storage_service_interface.dart';
import '../backend/models/profile_form_data.dart';
import '../models/family_person.dart';
import '../models/profile_note.dart';
import '../models/user_profile.dart';
import 'custom_api_auth_service.dart';

class CustomApiProfileService implements ProfileServiceInterface {
  CustomApiProfileService._({
    required CustomApiAuthService authService,
    required http.Client httpClient,
    required SharedPreferences preferences,
    required BackendRuntimeConfig runtimeConfig,
    StorageServiceInterface? storageService,
  })  : _authService = authService,
        _httpClient = httpClient,
        _preferences = preferences,
        _runtimeConfig = runtimeConfig,
        _storageService = storageService;

  static const _profileStorageKey = 'custom_api_profile_form_v1';
  static const _maxPhotoSizeBytes = 5 * 1024 * 1024;
  static const _allowedExtensions = ['.jpg', '.jpeg', '.png', '.webp'];

  final CustomApiAuthService _authService;
  final http.Client _httpClient;
  final SharedPreferences _preferences;
  final BackendRuntimeConfig _runtimeConfig;
  final StorageServiceInterface? _storageService;
  final Map<String, StreamController<List<ProfileNote>>> _noteControllers = {};

  static Future<CustomApiProfileService> create({
    required CustomApiAuthService authService,
    http.Client? httpClient,
    SharedPreferences? preferences,
    BackendRuntimeConfig? runtimeConfig,
    StorageServiceInterface? storageService,
  }) async {
    return CustomApiProfileService._(
      authService: authService,
      httpClient: httpClient ?? http.Client(),
      preferences: preferences ?? await SharedPreferences.getInstance(),
      runtimeConfig: runtimeConfig ?? BackendRuntimeConfig.current,
      storageService: storageService,
    );
  }

  @override
  Future<UserProfile?> getUserProfile(String userId) async {
    if (_authService.currentUserId == userId) {
      return getCurrentUserProfile();
    }

    try {
      final response = await _requestJson(
        method: 'GET',
        path: '/v1/users/$userId/profile',
      );
      return _userProfileFromJson(userId, response);
    } on CustomApiException catch (error) {
      if (error.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<UserProfile?> getCurrentUserProfile() async {
    final cached = _getCachedProfileForm();
    if (cached != null) {
      return _toUserProfile(cached);
    }

    final formData = await getCurrentUserProfileFormData();
    return _toUserProfile(formData);
  }

  @override
  Future<ProfileFormData> getCurrentUserProfileFormData() async {
    if (_authService.currentUserId == null) {
      throw const CustomApiException('Пользователь не авторизован');
    }

    try {
      final response = await _requestJson(
        method: 'GET',
        path: '/v1/profile/me/bootstrap',
      );
      final formData = _profileFormDataFromResponse(response);
      await _cacheProfileForm(formData);
      return formData;
    } catch (_) {
      final cached = _getCachedProfileForm();
      if (cached != null) {
        return cached;
      }
      rethrow;
    }
  }

  @override
  Future<void> saveCurrentUserProfileFormData(ProfileFormData data) async {
    final response = await _requestJson(
      method: 'PUT',
      path: '/v1/profile/me/bootstrap',
      body: _profilePayload(data),
    );

    final savedData = _profileFormDataFromResponse(response).copyWith(
      userId: data.userId,
    );
    await _cacheProfileForm(savedData);

    final profileStatus = _extractProfileStatus(response);
    await _authService.updateCachedSession(
      email: savedData.email,
      displayName: savedData.displayName.isNotEmpty
          ? savedData.displayName
          : _composeDisplayName(savedData),
      photoUrl: savedData.photoUrl,
      isProfileComplete: profileStatus['isComplete'] == true,
      missingFields:
          (profileStatus['missingFields'] as List<dynamic>? ?? const [])
              .map((value) => value.toString())
              .toList(),
    );
  }

  @override
  Future<void> verifyCurrentUserPhone({
    required String phoneNumber,
    required String countryCode,
  }) async {
    await _requestJson(
      method: 'POST',
      path: '/v1/profile/me/verify-phone',
      body: {
        'phoneNumber': phoneNumber,
        'countryCode': countryCode,
      },
    );

    final cached = _getCachedProfileForm();
    if (cached != null) {
      await _cacheProfileForm(
        cached.copyWith(
          phoneNumber: phoneNumber,
          countryCode: countryCode,
          isPhoneVerified: true,
        ),
      );
    }
  }

  @override
  Future<String?> uploadProfilePhoto(XFile photo) async {
    final storageService = _storageService;
    if (storageService == null) {
      throw UnsupportedError(
        'Для customApi profile adapter нужен storage provider customApi.',
      );
    }

    final extension = _detectExtension(photo.name, mimeType: photo.mimeType);
    if (!_allowedExtensions.contains(extension)) {
      throw Exception(
        'Недопустимый формат файла. Разрешены только ${_allowedExtensions.join(', ')}',
      );
    }

    final fileBytes = await photo.readAsBytes();
    if (fileBytes.length > _maxPhotoSizeBytes) {
      throw Exception('Размер файла превышает 5MB');
    }

    final photoUrl = await storageService.uploadProfileImage(photo);
    if (photoUrl == null || photoUrl.isEmpty) {
      throw Exception('Не удалось загрузить фото профиля');
    }

    final response = await _requestJson(
      method: 'PATCH',
      path: '/v1/profile/me',
      body: {
        'photoUrl': photoUrl,
      },
    );

    final cached = _getCachedProfileForm();
    if (cached != null) {
      await _cacheProfileForm(cached.copyWith(photoUrl: photoUrl));
    }

    final profileStatus = _extractProfileStatus(response);
    await _authService.updateCachedSession(
      email: cached?.email,
      displayName: cached?.displayName,
      photoUrl: photoUrl,
      isProfileComplete: profileStatus['isComplete'] == true,
      missingFields:
          (profileStatus['missingFields'] as List<dynamic>? ?? const [])
              .map((value) => value.toString())
              .toList(),
    );

    return photoUrl;
  }

  @override
  Future<void> updateUserProfile(String userId, UserProfile profile) async {
    await _requestJson(
      method: 'PATCH',
      path: '/v1/users/$userId/profile',
      body: _profilePayload(
        ProfileFormData(
          userId: userId,
          email: profile.email,
          firstName: profile.firstName,
          lastName: profile.lastName,
          middleName: profile.middleName,
          displayName: profile.displayName,
          username: profile.username,
          phoneNumber: profile.phoneNumber,
          countryCode: profile.countryCode,
          countryName: profile.country,
          city: profile.city ?? '',
          photoUrl: profile.photoURL,
          isPhoneVerified: profile.isPhoneVerified,
          gender: profile.gender ?? Gender.unknown,
          birthDate: profile.birthDate,
        ),
      ),
    );
  }

  @override
  Stream<List<ProfileNote>> getProfileNotesStream(String userId) {
    final controller = _noteControllers.putIfAbsent(
      userId,
      () {
        final streamController = StreamController<List<ProfileNote>>.broadcast(
          onListen: () {
            _refreshProfileNotes(userId);
          },
        );
        return streamController;
      },
    );

    _refreshProfileNotes(userId);
    return controller.stream;
  }

  @override
  Future<void> addProfileNote(
      String userId, String title, String content) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/users/$userId/profile-notes',
      body: {
        'title': title,
        'content': content,
      },
    );

    final note = _profileNoteFromResponse(response);
    await _refreshProfileNotes(userId, insertedNote: note);
  }

  @override
  Future<void> updateProfileNote(String userId, ProfileNote note) async {
    await _requestJson(
      method: 'PATCH',
      path: '/v1/users/$userId/profile-notes/${note.id}',
      body: {
        'title': note.title,
        'content': note.content,
      },
    );
    await _refreshProfileNotes(userId);
  }

  @override
  Future<void> deleteProfileNote(String userId, String noteId) async {
    await _requestDelete(
      path: '/v1/users/$userId/profile-notes/$noteId',
    );
    await _refreshProfileNotes(userId);
  }

  @override
  Future<List<UserProfile>> searchUsersByField({
    required String field,
    required String value,
    int limit = 10,
  }) async {
    final response = await _requestJson(
      method: 'GET',
      path: '/v1/users/search/by-field',
      queryParameters: {
        'field': field,
        'value': value,
        'limit': '$limit',
      },
    );
    return _userProfileListFromResponse(response);
  }

  @override
  Future<List<UserProfile>> searchUsers(String query, {int limit = 10}) async {
    final response = await _requestJson(
      method: 'GET',
      path: '/v1/users/search',
      queryParameters: {
        'query': query,
        'limit': '$limit',
      },
    );
    return _userProfileListFromResponse(response);
  }

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    Map<String, String>? queryParameters,
  }) async {
    final uri = _buildUri(path, queryParameters: queryParameters);
    late http.Response response;

    switch (method) {
      case 'GET':
        response = await _httpClient.get(uri, headers: _headers());
        break;
      case 'PUT':
        response = await _httpClient.put(
          uri,
          headers: _headers(),
          body: jsonEncode(body ?? const {}),
        );
        break;
      case 'PATCH':
        response = await _httpClient.patch(
          uri,
          headers: _headers(),
          body: jsonEncode(body ?? const {}),
        );
        break;
      case 'POST':
        response = await _httpClient.post(
          uri,
          headers: _headers(),
          body: jsonEncode(body ?? const {}),
        );
        break;
      default:
        throw CustomApiException('Неподдерживаемый HTTP-метод: $method');
    }

    if (response.body.isEmpty) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return const <String, dynamic>{};
      }
      throw CustomApiException(
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

    throw CustomApiException(
      payload['message']?.toString() ??
          payload['error']?.toString() ??
          'Ошибка backend (${response.statusCode})',
      statusCode: response.statusCode,
    );
  }

  Future<void> _requestDelete({
    required String path,
  }) async {
    final uri = _buildUri(path);
    final response = await _httpClient.delete(uri, headers: _headers());

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }

    if (response.body.isNotEmpty) {
      final dynamic decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        throw CustomApiException(
          decoded['message']?.toString() ??
              'Ошибка backend (${response.statusCode})',
          statusCode: response.statusCode,
        );
      }
    }

    throw CustomApiException(
      'Ошибка backend (${response.statusCode})',
      statusCode: response.statusCode,
    );
  }

  Uri _buildUri(String path, {Map<String, String>? queryParameters}) {
    final normalizedBase = _runtimeConfig.apiBaseUrl.replaceAll(
      RegExp(r'/$'),
      '',
    );
    return Uri.parse('$normalizedBase$path')
        .replace(queryParameters: queryParameters);
  }

  Map<String, String> _headers() {
    final token = _authService.accessToken;
    if (token == null || token.isEmpty) {
      throw const CustomApiException('Нет активной customApi session');
    }

    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  Future<void> _cacheProfileForm(ProfileFormData data) async {
    await _preferences.setString(
      _profileStorageKey,
      jsonEncode({
        'userId': data.userId,
        'email': data.email,
        'firstName': data.firstName,
        'lastName': data.lastName,
        'middleName': data.middleName,
        'displayName': data.displayName,
        'username': data.username,
        'phoneNumber': data.phoneNumber,
        'countryCode': data.countryCode,
        'countryName': data.countryName,
        'city': data.city,
        'photoUrl': data.photoUrl,
        'isPhoneVerified': data.isPhoneVerified,
        'gender': data.gender.name,
        'maidenName': data.maidenName,
        'birthDate': data.birthDate?.toIso8601String(),
      }),
    );
  }

  ProfileFormData? _getCachedProfileForm() {
    final rawValue = _preferences.getString(_profileStorageKey);
    if (rawValue == null || rawValue.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(rawValue);
      if (decoded is Map<String, dynamic>) {
        return _profileFormDataFromJson(decoded);
      }
    } catch (_) {}
    return null;
  }

  ProfileFormData _profileFormDataFromResponse(Map<String, dynamic> response) {
    final profile = response['profile'];
    if (profile is Map<String, dynamic>) {
      return _profileFormDataFromJson(profile);
    }
    return _profileFormDataFromJson(response);
  }

  ProfileFormData _profileFormDataFromJson(Map<String, dynamic> json) {
    final userId = json['userId']?.toString() ??
        json['id']?.toString() ??
        _authService.currentUserId ??
        '';
    final firstName = json['firstName']?.toString() ?? '';
    final lastName = json['lastName']?.toString() ?? '';
    final middleName = json['middleName']?.toString() ?? '';
    final displayName = json['displayName']?.toString() ??
        _composeDisplayNameFromParts(firstName, middleName, lastName);
    final gender = _genderFromValue(json['gender']);
    final birthDateValue = json['birthDate']?.toString();

    return ProfileFormData(
      userId: userId,
      email: json['email']?.toString() ?? _authService.currentUserEmail,
      firstName: firstName,
      lastName: lastName,
      middleName: middleName,
      displayName: displayName,
      username: json['username']?.toString() ?? '',
      phoneNumber: json['phoneNumber']?.toString() ?? '',
      countryCode: json['countryCode']?.toString(),
      countryName:
          json['countryName']?.toString() ?? json['country']?.toString(),
      city: json['city']?.toString() ?? '',
      photoUrl: json['photoUrl']?.toString() ?? json['photoURL']?.toString(),
      isPhoneVerified: json['isPhoneVerified'] == true,
      gender: gender,
      maidenName: json['maidenName']?.toString() ?? '',
      birthDate: birthDateValue != null && birthDateValue.isNotEmpty
          ? DateTime.tryParse(birthDateValue)
          : null,
    );
  }

  Gender _genderFromValue(dynamic value) {
    switch (value?.toString()) {
      case 'male':
        return Gender.male;
      case 'female':
        return Gender.female;
      case 'other':
        return Gender.other;
      default:
        return Gender.unknown;
    }
  }

  Map<String, dynamic> _profilePayload(ProfileFormData data) {
    final displayName = data.displayName.isNotEmpty
        ? data.displayName
        : _composeDisplayName(data);

    return {
      'email': data.email,
      'firstName': data.firstName.trim(),
      'lastName': data.lastName.trim(),
      'middleName': data.middleName.trim(),
      'displayName': displayName,
      'username': data.username.trim(),
      'phoneNumber': data.phoneNumber.trim(),
      'countryCode': data.countryCode,
      'countryName': data.countryName,
      'city': data.city.trim(),
      'photoUrl': data.photoUrl,
      'isPhoneVerified': data.isPhoneVerified,
      'gender': data.gender.name,
      'maidenName': data.maidenName.trim(),
      'birthDate': data.birthDate?.toIso8601String(),
    };
  }

  Map<String, dynamic> _extractProfileStatus(Map<String, dynamic> response) {
    final value = response['profileStatus'];
    if (value is Map<String, dynamic>) {
      return value;
    }
    return const <String, dynamic>{};
  }

  UserProfile _toUserProfile(ProfileFormData data) {
    return UserProfile(
      id: data.userId,
      email: data.email ?? '',
      displayName: data.displayName.isNotEmpty
          ? data.displayName
          : _composeDisplayName(data),
      firstName: data.firstName,
      lastName: data.lastName,
      middleName: data.middleName,
      username: data.username,
      photoURL: data.photoUrl,
      phoneNumber: data.phoneNumber,
      isPhoneVerified: data.isPhoneVerified,
      gender: data.gender,
      birthDate: data.birthDate,
      country: data.countryName,
      city: data.city,
      countryCode: data.countryCode,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  UserProfile _userProfileFromJson(
      String fallbackId, Map<String, dynamic> json) {
    final profile = json['profile'];
    final payload = profile is Map<String, dynamic> ? profile : json;
    final formData = _profileFormDataFromJson({
      'id': payload['id'] ?? fallbackId,
      ...payload,
    });
    return _toUserProfile(formData).copyWith(id: fallbackId);
  }

  List<UserProfile> _userProfileListFromResponse(
      Map<String, dynamic> response) {
    final list = response['users'] ?? response['data'];
    if (list is! List<dynamic>) {
      return const [];
    }
    return list
        .whereType<Map<String, dynamic>>()
        .map((item) {
          final id = item['id']?.toString() ?? '';
          return _userProfileFromJson(id, item);
        })
        .where((profile) => profile.id.isNotEmpty)
        .toList();
  }

  String _composeDisplayName(ProfileFormData data) {
    return _composeDisplayNameFromParts(
      data.firstName,
      data.middleName,
      data.lastName,
    );
  }

  String _composeDisplayNameFromParts(
    String firstName,
    String middleName,
    String lastName,
  ) {
    return [
      firstName.trim(),
      middleName.trim(),
      lastName.trim(),
    ].where((part) => part.isNotEmpty).join(' ');
  }

  String _detectExtension(String fileName, {String? mimeType}) {
    final normalizedName = fileName.toLowerCase().trim();
    for (final extension in _allowedExtensions) {
      if (normalizedName.endsWith(extension)) {
        return extension;
      }
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
    return '';
  }

  Future<void> _refreshProfileNotes(
    String userId, {
    ProfileNote? insertedNote,
  }) async {
    final controller = _noteControllers[userId];
    if (controller == null || controller.isClosed) {
      return;
    }

    try {
      final notes = insertedNote == null
          ? await _fetchProfileNotes(userId)
          : [
              insertedNote,
              ...await _fetchProfileNotes(userId).then((items) =>
                  items.where((item) => item.id != insertedNote.id).toList()),
            ];
      controller.add(notes);
    } catch (error, stackTrace) {
      controller.addError(error, stackTrace);
    }
  }

  Future<List<ProfileNote>> _fetchProfileNotes(String userId) async {
    final response = await _requestJson(
      method: 'GET',
      path: '/v1/users/$userId/profile-notes',
    );

    final rawList = response['notes'];
    if (rawList is! List<dynamic>) {
      return const [];
    }

    return rawList
        .whereType<Map<String, dynamic>>()
        .map(_profileNoteFromJson)
        .toList();
  }

  ProfileNote _profileNoteFromResponse(Map<String, dynamic> response) {
    final note = response['note'];
    if (note is Map<String, dynamic>) {
      return _profileNoteFromJson(note);
    }
    return _profileNoteFromJson(response);
  }

  ProfileNote _profileNoteFromJson(Map<String, dynamic> json) {
    final createdAtValue = json['createdAt']?.toString();
    final createdAt = createdAtValue != null && createdAtValue.isNotEmpty
        ? DateTime.tryParse(createdAtValue) ?? DateTime.now()
        : DateTime.now();

    return ProfileNote(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      createdAt: createdAt,
    );
  }
}
