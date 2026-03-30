// Убираем условный импорт
// import 'dart:io' if (dart.library.html) 'dart:html' as html_file;

// Убираем import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/family_person.dart';
import '../models/user_profile.dart';
import '../models/profile_note.dart';
// Добавляем импорты
import 'package:get_it/get_it.dart';
import 'local_storage_service.dart'; // Добавляем импорт LocalStorageService
import 'sync_service.dart'; // Добавляем импорт SyncService
import '../backend/interfaces/profile_service_interface.dart';
import '../backend/models/profile_form_data.dart';
import '../backend/interfaces/storage_service_interface.dart';

class ProfileService implements ProfileServiceInterface {
  // Убираем FirebaseStorage final FirebaseStorage _storage = FirebaseStorage.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  // Получаем StorageServiceInterface через GetIt
  final StorageServiceInterface _storageService =
      GetIt.I<StorageServiceInterface>();
  // Получаем LocalStorageService через GetIt
  final LocalStorageService _localStorage = GetIt.I<LocalStorageService>();
  // Получаем SyncService через GetIt
  final SyncService _syncService = GetIt.I<SyncService>();

  // Максимальный размер фото (в байтах) - 5MB
  static const int maxPhotoSize = 5 * 1024 * 1024;

  // Допустимые форматы файлов
  static const List<String> allowedExtensions = ['.jpg', '.jpeg', '.png'];

  Future<String?> uploadProfilePhoto(XFile photo) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Пользователь не авторизован');
    }

    try {
      // 1. Проверка расширения файла (упрощенная)
      final fileNameLower = photo.name.toLowerCase();
      final fileExtension = allowedExtensions.firstWhere(
        (ext) => fileNameLower.endsWith(ext),
        orElse: () =>
            '', // Возвращаем пустую строку, если расширение не найдено
      );

      if (fileExtension.isEmpty) {
        throw Exception(
          'Недопустимый формат файла. Разрешены только ${allowedExtensions.join(', ')}',
        );
      }

      final fileBytes = await photo.readAsBytes();
      if (fileBytes.length > maxPhotoSize) {
        throw Exception('Размер файла превышает 5MB');
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final storagePath = '${user.uid}/avatar_$timestamp$fileExtension';

      print('Вызов _storageService.uploadBytes для пользователя ${user.uid}');
      final downloadUrl = await _storageService.uploadBytes(
        bucket: 'avatars',
        path: storagePath,
        fileBytes: fileBytes,
        fileOptions: FileOptions(
          cacheControl: '3600',
          upsert: true,
          contentType: _contentTypeForExtension(fileExtension),
        ),
      );

      if (downloadUrl == null) {
        print('Ошибка: _storageService.uploadBytes вернул null.');
        throw Exception('Не удалось загрузить фото в хранилище.');
      }

      print('Получен URL изображения профиля: $downloadUrl');

      await _firestore.collection('users').doc(user.uid).update({
        'photoURL': downloadUrl,
      });
      print('Firestore обновлен с новым URL.');

      await user.updatePhotoURL(downloadUrl);
      print('FirebaseAuth обновлен с новым URL.');

      return downloadUrl;
    } catch (e) {
      print('Ошибка при загрузке фото профиля (ProfileService): $e');
      rethrow; // Пробрасываем ошибку для обработки в UI
    }
  }

  String _contentTypeForExtension(String extension) {
    switch (extension) {
      case '.png':
        return 'image/png';
      case '.jpeg':
      case '.jpg':
      default:
        return 'image/jpeg';
    }
  }

  Future<UserProfile?> getUserProfile(String userId) async {
    try {
      // 1. Пытаемся получить профиль из локального кэша
      final cachedProfile = await _localStorage.getUser(userId);
      if (cachedProfile != null) {
        print('UserProfile for $userId found in cache.');
        return cachedProfile;
      }

      // 2. Если в кэше нет, проверяем сеть
      if (!_syncService.isOnline) {
        print(
          'UserProfile for $userId not in cache and offline. Returning null.',
        );
        return null; // Нет в кэше и нет сети
      }

      // 3. Если есть сеть, загружаем из Firestore
      print('UserProfile for $userId not in cache, fetching from Firestore...');
      final doc = await _firestore.collection('users').doc(userId).get();

      if (doc.exists) {
        final profileFromFirestore = UserProfile.fromFirestore(doc);
        // 4. Сохраняем в кэш
        await _localStorage.saveUser(profileFromFirestore);
        print(
          'UserProfile for $userId fetched from Firestore and saved to cache.',
        );
        return profileFromFirestore;
      } else {
        print('UserProfile for $userId not found in Firestore.');
        return null;
      }
    } catch (e) {
      print('Error getting user profile (ProfileService): $e');
      // В случае ошибки можно попробовать вернуть данные из кэша, если они там вдруг появились
      // Или просто вернуть null
      try {
        final cachedProfile = await _localStorage.getUser(userId);
        if (cachedProfile != null) {
          print('Returning cached profile for $userId after Firestore error.');
          return cachedProfile;
        }
      } catch (cacheError) {
        print('Error reading cache after Firestore error: $cacheError');
      }
      return null;
    }
  }

  @override
  Future<UserProfile?> getCurrentUserProfile() async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      return null;
    }
    return getUserProfile(userId);
  }

  @override
  Future<ProfileFormData> getCurrentUserProfileFormData() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Пользователь не авторизован');
    }

    final doc = await _firestore.collection('users').doc(user.uid).get();
    final data = doc.data() ?? <String, dynamic>{};
    final displayName =
        (data['displayName'] ?? user.displayName ?? '').toString();
    final nameParts =
        displayName.split(' ').where((part) => part.isNotEmpty).toList();

    Gender gender = Gender.unknown;
    final genderValue = data['gender'];
    if (genderValue == 'male') {
      gender = Gender.male;
    } else if (genderValue == 'female') {
      gender = Gender.female;
    } else if (genderValue == 'other') {
      gender = Gender.other;
    }

    return ProfileFormData(
      userId: user.uid,
      email: (data['email'] ?? user.email)?.toString(),
      firstName:
          (data['firstName'] ?? (nameParts.isNotEmpty ? nameParts.first : ''))
              .toString(),
      lastName:
          (data['lastName'] ?? (nameParts.length > 1 ? nameParts.last : ''))
              .toString(),
      middleName: (data['middleName'] ??
              (nameParts.length > 2
                  ? nameParts.sublist(1, nameParts.length - 1).join(' ')
                  : ''))
          .toString(),
      displayName: displayName,
      username: (data['username'] ?? '').toString(),
      phoneNumber: (data['phoneNumber'] ?? user.phoneNumber ?? '').toString(),
      countryCode: data['countryCode']?.toString(),
      countryName: data['country']?.toString(),
      city: (data['city'] ?? '').toString(),
      photoUrl: (data['photoURL'] ?? user.photoURL)?.toString(),
      isPhoneVerified: data['isPhoneVerified'] == true,
      gender: gender,
      maidenName: (data['maidenName'] ?? '').toString(),
      birthDate: data['birthDate'] is Timestamp
          ? (data['birthDate'] as Timestamp).toDate()
          : null,
    );
  }

  @override
  Future<void> saveCurrentUserProfileFormData(ProfileFormData data) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Пользователь не авторизован');
    }

    final displayName = [
      data.firstName.trim(),
      data.middleName.trim(),
      data.lastName.trim(),
    ].where((part) => part.isNotEmpty).join(' ');

    await _firestore.collection('users').doc(user.uid).set({
      'id': user.uid,
      'email': data.email ?? user.email,
      'firstName': data.firstName.trim(),
      'lastName': data.lastName.trim(),
      'middleName': data.middleName.trim(),
      'displayName': displayName,
      'username': data.username.trim(),
      'phoneNumber': data.phoneNumber.trim(),
      'countryCode': data.countryCode,
      'country': data.countryName,
      'city': data.city.trim(),
      'photoURL': data.photoUrl,
      'isPhoneVerified': data.isPhoneVerified,
      'gender': _genderToString(data.gender),
      'birthDate':
          data.birthDate != null ? Timestamp.fromDate(data.birthDate!) : null,
      'maidenName':
          data.gender == Gender.female ? data.maidenName.trim() : null,
      'updatedAt': Timestamp.now(),
    }, SetOptions(merge: true));

    if (displayName.isNotEmpty) {
      await user.updateDisplayName(displayName);
    }
  }

  @override
  Future<void> verifyCurrentUserPhone({
    required String phoneNumber,
    required String countryCode,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Пользователь не авторизован');
    }

    await _firestore.collection('users').doc(user.uid).update({
      'phoneNumber': phoneNumber,
      'countryCode': countryCode,
      'isPhoneVerified': true,
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> updateUserProfile(String userId, UserProfile profile) async {
    try {
      await _firestore.collection('users').doc(userId).update(profile.toMap());
      print('User profile updated successfully.');
    } catch (e) {
      print('Error updating user profile: $e');
      rethrow; // Пробрасываем ошибку дальше
    }
  }

  // Получение потока заметок пользователя
  Stream<List<ProfileNote>> getProfileNotesStream(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('profile_notes') // Используем подколлекцию
        .orderBy('createdAt', descending: true) // Сортируем по дате создания
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map(
            (doc) => ProfileNote.fromFirestore(
              doc as DocumentSnapshot<Map<String, dynamic>>,
            ),
          )
          .toList();
    });
  }

  // Добавление новой заметки
  Future<void> addProfileNote(
    String userId,
    String title,
    String content,
  ) async {
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('profile_notes')
          .add({
        'title': title,
        'content': content,
        'createdAt': FieldValue.serverTimestamp(), // Используем серверное время
      });
      print('Profile note added successfully.');
    } catch (e) {
      print('Error adding profile note: $e');
      rethrow;
    }
  }

  // Обновление существующей заметки
  Future<void> updateProfileNote(String userId, ProfileNote note) async {
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('profile_notes')
          .doc(note.id) // Используем ID заметки
          .update(note.toMap()); // Используем toMap для обновления полей
      print('Profile note updated successfully.');
    } catch (e) {
      print('Error updating profile note: $e');
      rethrow;
    }
  }

  // Удаление заметки
  Future<void> deleteProfileNote(String userId, String noteId) async {
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('profile_notes')
          .doc(noteId) // Используем ID заметки
          .delete();
      print('Profile note deleted successfully.');
    } catch (e) {
      print('Error deleting profile note: $e');
      rethrow;
    }
  }

  @override
  Future<List<UserProfile>> searchUsersByField({
    required String field,
    required String value,
    int limit = 10,
  }) async {
    final querySnapshot = await _firestore
        .collection('users')
        .where(field, isEqualTo: value)
        .limit(limit)
        .get();

    return querySnapshot.docs.map(UserProfile.fromFirestore).toList();
  }

  @override
  Future<List<UserProfile>> searchUsers(String query, {int limit = 10}) async {
    final currentUserId = _auth.currentUser?.uid;

    final nameSnapshot = await _firestore
        .collection('users')
        .where('displayName', isGreaterThanOrEqualTo: query)
        .where('displayName', isLessThanOrEqualTo: '$query\uf8ff')
        .limit(limit)
        .get();

    final emailSnapshot = await _firestore
        .collection('users')
        .where('email', isEqualTo: query)
        .limit(1)
        .get();

    final phoneSnapshot = await _firestore
        .collection('users')
        .where('phoneNumber', isEqualTo: query)
        .where('isPhoneVerified', isEqualTo: true)
        .limit(1)
        .get();

    final addedIds = <String>{};
    final results = <UserProfile>[];
    for (final doc in [
      ...nameSnapshot.docs,
      ...emailSnapshot.docs,
      ...phoneSnapshot.docs,
    ]) {
      if (doc.id == currentUserId || addedIds.contains(doc.id)) {
        continue;
      }
      addedIds.add(doc.id);
      results.add(UserProfile.fromFirestore(doc));
    }
    return results;
  }

  String _genderToString(Gender gender) {
    switch (gender) {
      case Gender.male:
        return 'male';
      case Gender.female:
        return 'female';
      case Gender.other:
        return 'other';
      case Gender.unknown:
      default:
        return 'unknown';
    }
  }
}
