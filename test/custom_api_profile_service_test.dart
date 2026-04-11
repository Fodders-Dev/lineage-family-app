import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lineage/backend/backend_runtime_config.dart';
import 'package:lineage/backend/interfaces/storage_service_interface.dart';
import 'package:lineage/backend/models/profile_form_data.dart';
import 'package:lineage/models/profile_note.dart';
import 'package:lineage/services/custom_api_auth_service.dart';
import 'package:lineage/services/custom_api_profile_service.dart';
import 'package:lineage/services/invitation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('CustomApiProfileService loads and saves bootstrap profile data',
      () async {
    final client = MockClient((request) async {
      if (request.url.path == '/v1/profile/me/bootstrap' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'profile': {
              'id': 'user-1',
              'email': 'dev@lineage.app',
              'firstName': 'Иван',
              'lastName': 'Иванов',
              'middleName': 'Иванович',
              'displayName': 'Иван Иванович Иванов',
              'username': 'ivanov',
              'phoneNumber': '+79990001122',
              'countryCode': '+7',
              'countryName': 'Россия',
              'city': 'Москва',
              'gender': 'male',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/profile/me/bootstrap' &&
          request.method == 'PUT') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['firstName'], 'Пётр');
        expect(body['username'], 'petrov');

        return http.Response(
          jsonEncode({
            'profile': {
              'id': 'user-1',
              'email': 'dev@lineage.app',
              'firstName': body['firstName'],
              'lastName': body['lastName'],
              'middleName': body['middleName'],
              'displayName': body['displayName'],
              'username': body['username'],
              'phoneNumber': body['phoneNumber'],
              'countryCode': body['countryCode'],
              'countryName': body['countryName'],
              'city': body['city'],
              'gender': body['gender'],
            },
            'profileStatus': {
              'isComplete': true,
              'missingFields': [],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/auth/session') {
        return http.Response('{"message":"offline"}', 500);
      }

      return http.Response('{"message":"not found"}', 404);
    });

    final runtimeConfig = const BackendRuntimeConfig(
      apiBaseUrl: 'https://api.example.ru',
    );
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
        'missingFields': ['phoneNumber', 'username'],
      }),
    );

    final authService = await CustomApiAuthService.create(
      httpClient: client,
      preferences: prefs,
      runtimeConfig: runtimeConfig,
      invitationService: InvitationService(),
    );
    final profileService = await CustomApiProfileService.create(
      authService: authService,
      httpClient: client,
      preferences: prefs,
      runtimeConfig: runtimeConfig,
    );

    final bootstrap = await profileService.getCurrentUserProfileFormData();
    expect(bootstrap.firstName, 'Иван');
    expect(bootstrap.username, 'ivanov');
    expect(bootstrap.countryName, 'Россия');

    await profileService.saveCurrentUserProfileFormData(
      const ProfileFormData(
        userId: 'user-1',
        email: 'dev@lineage.app',
        firstName: 'Пётр',
        lastName: 'Петров',
        middleName: '',
        username: 'petrov',
        phoneNumber: '+79991112233',
        countryCode: '+7',
        countryName: 'Россия',
        city: 'Казань',
      ),
    );

    final savedProfile = await profileService.getCurrentUserProfile();
    expect(savedProfile?.firstName, 'Пётр');
    expect(savedProfile?.username, 'petrov');

    final profileStatus = await authService.checkProfileCompleteness();
    expect(profileStatus['isComplete'], isTrue);
    expect(profileStatus['missingFields'], isEmpty);
  });

  test('CustomApiProfileService uploads profile photo and manages notes',
      () async {
    final client = MockClient((request) async {
      if (request.url.path == '/v1/profile/me' && request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(
          body['photoUrl'],
          'https://api.example.ru/media/avatars/user-1/avatar.png',
        );

        return http.Response(
          jsonEncode({
            'user': {
              'id': 'user-1',
              'email': 'dev@lineage.app',
              'displayName': 'Dev User',
              'photoUrl': body['photoUrl'],
            },
            'profileStatus': {
              'isComplete': true,
              'missingFields': [],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/users/user-1/profile-notes' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'notes': [
              {
                'id': 'note-1',
                'title': 'Первая заметка',
                'content': 'Содержимое заметки',
                'createdAt': '2026-03-27T10:00:00.000Z',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/users/user-1/profile-notes' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['title'], 'Новая заметка');
        expect(body['content'], 'Новый текст');

        return http.Response(
          jsonEncode({
            'note': {
              'id': 'note-2',
              'title': body['title'],
              'content': body['content'],
              'createdAt': '2026-03-27T11:00:00.000Z',
            },
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/users/user-1/profile-notes/note-1' &&
          request.method == 'PATCH') {
        return http.Response(
          jsonEncode({
            'note': {
              'id': 'note-1',
              'title': 'Обновлённая заметка',
              'content': 'Исправленный текст',
              'createdAt': '2026-03-27T10:00:00.000Z',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/users/user-1/profile-notes/note-1' &&
          request.method == 'DELETE') {
        return http.Response('', 204);
      }

      if (request.url.path == '/v1/auth/session') {
        return http.Response('{"message":"offline"}', 500);
      }

      return http.Response('{"message":"not found"}', 404);
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
        'missingFields': ['photoUrl'],
      }),
    );
    await prefs.setString(
      'custom_api_profile_form_v1',
      jsonEncode({
        'userId': 'user-1',
        'email': 'dev@lineage.app',
        'firstName': 'Dev',
        'lastName': 'User',
        'middleName': '',
        'displayName': 'Dev User',
        'username': 'devuser',
        'phoneNumber': '+79990001122',
        'countryCode': '+7',
        'countryName': 'Россия',
        'city': 'Москва',
        'photoUrl': null,
        'isPhoneVerified': true,
        'gender': 'unknown',
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

    final profileService = await CustomApiProfileService.create(
      authService: authService,
      httpClient: client,
      preferences: prefs,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      storageService: _FakeStorageService(
        uploadedUrl: 'https://api.example.ru/media/avatars/user-1/avatar.png',
      ),
    );

    final photoUrl = await profileService.uploadProfilePhoto(
      XFile.fromData(
        Uint8List.fromList(List<int>.filled(8, 1)),
        name: 'avatar.png',
        mimeType: 'image/png',
      ),
    );
    expect(photoUrl, 'https://api.example.ru/media/avatars/user-1/avatar.png');

    final notesStream = profileService.getProfileNotesStream('user-1');
    final initialNotes = await notesStream.first;
    expect(initialNotes, hasLength(1));
    expect(initialNotes.first.title, 'Первая заметка');

    await profileService.addProfileNote(
      'user-1',
      'Новая заметка',
      'Новый текст',
    );
    await profileService.updateProfileNote(
      'user-1',
      ProfileNote(
        id: 'note-1',
        title: 'Обновлённая заметка',
        content: 'Исправленный текст',
        createdAt: initialNotes.first.createdAt,
      ),
    );
    await profileService.deleteProfileNote('user-1', 'note-1');
  });
}

class _FakeStorageService implements StorageServiceInterface {
  const _FakeStorageService({required this.uploadedUrl});

  final String uploadedUrl;

  @override
  Future<bool> deleteImage(String imageUrl) async => true;

  @override
  Future<String?> uploadImage(XFile imageFile, String folder) async =>
      uploadedUrl;

  @override
  Future<String?> uploadProfileImage(XFile imageFile) async => uploadedUrl;

  @override
  Future<String?> uploadBytes({
    required String bucket,
    required String path,
    required Uint8List fileBytes,
    FileOptions? fileOptions,
  }) async =>
      uploadedUrl;
}
