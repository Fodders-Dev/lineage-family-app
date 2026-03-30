import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
