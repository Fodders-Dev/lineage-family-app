import 'package:image_picker/image_picker.dart';

import '../../models/profile_note.dart';
import '../../models/user_profile.dart';
import '../models/profile_form_data.dart';

abstract class ProfileServiceInterface {
  Future<UserProfile?> getUserProfile(String userId);
  Future<UserProfile?> getCurrentUserProfile();
  Future<ProfileFormData> getCurrentUserProfileFormData();
  Future<void> saveCurrentUserProfileFormData(ProfileFormData data);
  Future<void> verifyCurrentUserPhone({
    required String phoneNumber,
    required String countryCode,
  });
  Future<String?> uploadProfilePhoto(XFile photo);
  Future<void> updateUserProfile(String userId, UserProfile profile);
  Stream<List<ProfileNote>> getProfileNotesStream(String userId);
  Future<void> addProfileNote(String userId, String title, String content);
  Future<void> updateProfileNote(String userId, ProfileNote note);
  Future<void> deleteProfileNote(String userId, String noteId);
  Future<List<UserProfile>> searchUsersByField({
    required String field,
    required String value,
    int limit = 10,
  });
  Future<List<UserProfile>> searchUsers(String query, {int limit = 10});
}
