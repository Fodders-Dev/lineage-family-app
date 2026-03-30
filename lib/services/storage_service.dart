import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:path/path.dart' as p; // Для работы с расширениями файлов
import '../backend/interfaces/storage_service_interface.dart';

class NoopStorageService implements StorageServiceInterface {
  @override
  Future<bool> deleteImage(String imageUrl) async => false;

  @override
  Future<String?> uploadImage(XFile imageFile, String folder) async => null;

  @override
  Future<String?> uploadProfileImage(XFile imageFile) async => null;

  @override
  Future<String?> uploadBytes({
    required String bucket,
    required String path,
    required Uint8List fileBytes,
    FileOptions? fileOptions,
  }) async =>
      null;
}

class StorageService implements StorageServiceInterface {
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final SupabaseClient _supabaseClient = Supabase.instance.client;
  final String _bucketName = 'avatars'; // Имя вашего бакета

  // Загрузка изображения в Firebase Storage
  @override
  Future<String?> uploadImage(XFile imageFile, String folder) async {
    try {
      // Генерируем уникальное имя файла
      final String fileName = '${Uuid().v4()}.jpg';
      final String path = '$folder/$fileName';

      // Загружаем файл
      if (kIsWeb) {
        // Для веб-платформы
        final bytes = await imageFile.readAsBytes();
        final ref = _storage.ref().child(path);
        await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
        return await ref.getDownloadURL();
      } else {
        // Для мобильных платформ
        final file = File(imageFile.path);
        final ref = _storage.ref().child(path);
        await ref.putFile(file);
        return await ref.getDownloadURL();
      }
    } catch (e) {
      print('Ошибка загрузки изображения: $e');
      return null;
    }
  }

  // Удаление изображения из Firebase Storage
  @override
  Future<bool> deleteImage(String imageUrl) async {
    try {
      // Извлекаем путь к файлу из URL
      final ref = _storage.refFromURL(imageUrl);
      await ref.delete();
      return true;
    } catch (e) {
      print('Ошибка удаления изображения: $e');
      return false;
    }
  }

  // Добавление специфического метода для загрузки профильных изображений
  @override
  Future<String?> uploadProfileImage(XFile imageFile) async {
    return uploadImage(imageFile, 'profile_images');
  }

  /// Загружает файл аватара в Supabase Storage и возвращает публичный URL.
  ///
  /// [userId] - ID пользователя, для которого загружается аватар.
  /// [file] - Файл для загрузки.
  Future<String?> uploadAvatar(String userId, File file) async {
    try {
      // Получаем расширение файла
      final fileExtension = p.extension(file.path).toLowerCase();
      if (fileExtension.isEmpty) {
        print('Ошибка: Не удалось определить расширение файла.');
        return null; // Или выбросить исключение
      }

      // Генерируем путь к файлу в Supabase Storage
      // Пример: public/avatars/user_id_123456789.jpg
      // Добавляем timestamp для уникальности и предотвращения проблем с кэшированием CDN
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filePath = '$userId/avatar_$timestamp$fileExtension';

      print('Загрузка файла в Supabase Storage: $_bucketName/$filePath');

      // Загружаем файл
      final response = await _supabaseClient.storage.from(_bucketName).upload(
            filePath,
            file,
            fileOptions: const FileOptions(
              cacheControl: '3600', // Кэшировать на час
              upsert:
                  true, // Перезаписывать, если файл с таким именем существует
            ),
          );

      // Проверяем наличие ошибок при загрузке
      // Supabase Storage API не всегда явно выбрасывает исключения при ошибках загрузки,
      // но response может содержать информацию об ошибке или быть null/пустым в некоторых случаях.
      // Более надежная проверка может потребоваться в зависимости от версии supabase_flutter
      print(
        'Ответ Supabase Storage upload: $response',
      ); // Логируем ответ для отладки

      // Непосредственно после загрузки получаем публичный URL
      // Важно: getPublicUrl не гарантирует, что файл УЖЕ доступен через CDN,
      // может быть небольшая задержка.
      final publicUrl =
          _supabaseClient.storage.from(_bucketName).getPublicUrl(filePath);

      print('Получен публичный URL: $publicUrl');
      return publicUrl;
    } on StorageException catch (e) {
      // Обрабатываем специфичные ошибки Supabase Storage
      print('Ошибка Supabase Storage при загрузке аватара: ${e.message}');
      // Можно добавить более специфичную обработку разных кодов ошибок
      return null;
    } catch (e) {
      // Обрабатываем другие возможные ошибки
      print('Непредвиденная ошибка при загрузке аватара: $e');
      return null;
    }
  }

  // <<< НОВЫЙ МЕТОД: Загрузка байтов файла в Supabase >>>
  @override
  Future<String?> uploadBytes({
    required String bucket,
    required String path,
    required Uint8List fileBytes,
    FileOptions? fileOptions,
  }) async {
    try {
      print('Загрузка байтов в Supabase Storage: $bucket/$path');
      // Загружаем байты
      final response = await _supabaseClient.storage.from(bucket).uploadBinary(
            path,
            fileBytes,
            fileOptions: fileOptions ??
                const FileOptions(
                  cacheControl: '3600',
                  upsert: false,
                ), // Настройки по умолчанию
          );
      print('Ответ Supabase Storage uploadBinary: $response');

      // Получаем публичный URL
      final publicUrl = _supabaseClient.storage.from(bucket).getPublicUrl(path);

      print('Получен публичный URL: $publicUrl');
      return publicUrl;
    } on StorageException catch (e) {
      print(
        'Ошибка Supabase Storage при загрузке байтов ($bucket/$path): ${e.message}',
      );
      return null;
    } catch (e) {
      print('Непредвиденная ошибка при загрузке байтов ($bucket/$path): $e');
      return null;
    }
  }
  // <<< КОНЕЦ НОВОГО МЕТОДА >>>

  // В будущем здесь можно добавить методы для загрузки других типов файлов, удаления и т.д.
  // Future<String?> uploadPostImage(String postId, File file) async { ... }
  // Future<void> deleteFile(String filePath) async { ... }
}
