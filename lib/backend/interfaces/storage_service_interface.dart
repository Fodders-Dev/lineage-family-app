import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

class FileOptions {
  const FileOptions({
    this.contentType,
    this.cacheControl,
    this.upsert = false,
  });

  final String? contentType;
  final String? cacheControl;
  final bool upsert;
}

abstract class StorageServiceInterface {
  Future<String?> uploadImage(XFile imageFile, String folder);
  Future<bool> deleteImage(String imageUrl);
  Future<String?> uploadProfileImage(XFile imageFile);
  Future<String?> uploadBytes({
    required String bucket,
    required String path,
    required Uint8List fileBytes,
    FileOptions? fileOptions,
  });
}
