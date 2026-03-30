abstract class AuthServiceInterface {
  String? get currentUserId;
  String? get currentUserEmail;
  String? get currentUserDisplayName;
  String? get currentUserPhotoUrl;
  List<String> get currentProviderIds;
  Stream<String?> get authStateChanges;

  Future<Object?> registerWithEmail({
    required String email,
    required String password,
    required String name,
  });

  Future<Object?> loginWithEmail(String email, String password);
  Future<Object?> signInWithGoogle();
  Future<void> signOut();
  Future<void> resetPassword(String email);
  Future<void> deleteAccount([String? password]);
  Future<Map<String, dynamic>> checkProfileCompleteness();
  Future<void> processPendingInvitation();
  Future<void> updateDisplayName(String displayName);
  String describeError(Object error);
}
