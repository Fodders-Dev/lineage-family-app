import 'package:image_picker/image_picker.dart';

import '../models/chat_message.dart';
import '../models/chat_preview.dart';
import '../models/family_person.dart';
import '../models/family_relation.dart';
import '../models/family_tree.dart';
import '../models/profile_note.dart';
import '../models/relation_request.dart';
import '../models/user_profile.dart';
import 'interfaces/auth_service_interface.dart';
import 'interfaces/chat_service_interface.dart';
import 'interfaces/family_tree_service_interface.dart';
import 'interfaces/profile_service_interface.dart';
import 'models/profile_form_data.dart';
import 'models/selectable_tree.dart';
import 'models/tree_invitation.dart';

String _pendingProviderMessage(String domain) {
  return 'Для домена "$domain" выбран backend provider без реализации. '
      'Подключите адаптер customApi или временно верните legacy provider.';
}

class PendingBackendAuthService implements AuthServiceInterface {
  const PendingBackendAuthService();

  @override
  String? get currentUserId => null;

  @override
  String? get currentUserEmail => null;

  @override
  String? get currentUserDisplayName => null;

  @override
  String? get currentUserPhotoUrl => null;

  @override
  List<String> get currentProviderIds => const [];

  @override
  Stream<String?> get authStateChanges => Stream<String?>.value(null);

  @override
  Future<Map<String, dynamic>> checkProfileCompleteness() async {
    return {
      'isComplete': false,
      'missingFields': const ['backendProvider'],
    };
  }

  @override
  String describeError(Object error) {
    if (error is UnsupportedError) {
      return error.message?.toString() ?? _pendingProviderMessage('auth');
    }
    return _pendingProviderMessage('auth');
  }

  @override
  Future<void> processPendingInvitation() async {}

  @override
  Future<Object?> loginWithEmail(String email, String password) {
    throw UnsupportedError(_pendingProviderMessage('auth'));
  }

  @override
  Future<Object?> registerWithEmail({
    required String email,
    required String password,
    required String name,
  }) {
    throw UnsupportedError(_pendingProviderMessage('auth'));
  }

  @override
  Future<void> resetPassword(String email) {
    throw UnsupportedError(_pendingProviderMessage('auth'));
  }

  @override
  Future<void> signOut() async {}

  @override
  Future<Object?> signInWithGoogle() {
    throw UnsupportedError(_pendingProviderMessage('auth'));
  }

  @override
  Future<void> updateDisplayName(String displayName) {
    throw UnsupportedError(_pendingProviderMessage('auth'));
  }

  @override
  Future<void> deleteAccount([String? password]) {
    throw UnsupportedError(_pendingProviderMessage('auth'));
  }
}

class PendingBackendProfileService implements ProfileServiceInterface {
  const PendingBackendProfileService();

  @override
  Future<void> addProfileNote(String userId, String title, String content) {
    throw UnsupportedError(_pendingProviderMessage('profile'));
  }

  @override
  Future<void> deleteProfileNote(String userId, String noteId) {
    throw UnsupportedError(_pendingProviderMessage('profile'));
  }

  @override
  Future<ProfileFormData> getCurrentUserProfileFormData() {
    throw UnsupportedError(_pendingProviderMessage('profile'));
  }

  @override
  Future<UserProfile?> getCurrentUserProfile() async => null;

  @override
  Stream<List<ProfileNote>> getProfileNotesStream(String userId) {
    return Stream<List<ProfileNote>>.value(const []);
  }

  @override
  Future<UserProfile?> getUserProfile(String userId) async => null;

  @override
  Future<void> saveCurrentUserProfileFormData(ProfileFormData data) {
    throw UnsupportedError(_pendingProviderMessage('profile'));
  }

  @override
  Future<List<UserProfile>> searchUsers(String query, {int limit = 10}) async {
    return const [];
  }

  @override
  Future<List<UserProfile>> searchUsersByField({
    required String field,
    required String value,
    int limit = 10,
  }) async {
    return const [];
  }

  @override
  Future<String?> uploadProfilePhoto(XFile photo) {
    throw UnsupportedError(_pendingProviderMessage('profile'));
  }

  @override
  Future<void> updateProfileNote(String userId, ProfileNote note) {
    throw UnsupportedError(_pendingProviderMessage('profile'));
  }

  @override
  Future<void> updateUserProfile(String userId, UserProfile profile) {
    throw UnsupportedError(_pendingProviderMessage('profile'));
  }

  @override
  Future<void> verifyCurrentUserPhone({
    required String phoneNumber,
    required String countryCode,
  }) {
    throw UnsupportedError(_pendingProviderMessage('profile'));
  }
}

class PendingBackendFamilyTreeService implements FamilyTreeServiceInterface {
  const PendingBackendFamilyTreeService();

  @override
  Future<String> addRelative(String treeId, Map<String, dynamic> personData) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<void> addRelation(
    String treeId,
    String person1Id,
    String person2Id,
    RelationType relationType,
  ) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<void> addCurrentUserToTree({
    required String treeId,
    required String targetPersonId,
    required RelationType relationType,
  }) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<String> createTree({
    required String name,
    required String description,
    required bool isPrivate,
  }) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<void> deleteRelative(String treeId, String personId) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<void> checkAndCreateSpouseRelationIfNeeded(
    String treeId,
    String childId,
    String newParentId,
  ) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<void> checkAndCreateParentSiblingRelations(
    String treeId,
    String parentId,
    String childId,
  ) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<FamilyRelation> createRelation({
    required String treeId,
    required String person1Id,
    required String person2Id,
    required RelationType relation1to2,
    bool isConfirmed = true,
  }) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<String?> findSpouseId(String treeId, String personId) async => null;

  @override
  Future<List<FamilyPerson>> getOfflineProfilesByCreator(
    String treeId,
    String creatorId,
  ) async {
    return const [];
  }

  @override
  Future<FamilyPerson> getPersonById(String treeId, String personId) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<RelationType> getRelationBetween(
    String treeId,
    String person1Id,
    String person2Id,
  ) async {
    return RelationType.other;
  }

  @override
  Future<RelationType> getRelationToUser(
      String treeId, String relativeId) async {
    return RelationType.other;
  }

  @override
  Future<List<RelationRequest>> getRelationRequests({
    required String treeId,
  }) async {
    return const [];
  }

  @override
  Future<List<FamilyRelation>> getRelations(String treeId) async {
    return const [];
  }

  @override
  Stream<List<FamilyRelation>> getRelationsStream(String treeId) {
    return Stream<List<FamilyRelation>>.value(const []);
  }

  @override
  Future<List<FamilyPerson>> getRelatives(String treeId) async {
    return const [];
  }

  @override
  Stream<List<FamilyPerson>> getRelativesStream(String treeId) {
    return Stream<List<FamilyPerson>>.value(const []);
  }

  @override
  Future<List<SelectableTree>> getSelectableTreesForCurrentUser() async {
    return const [];
  }

  @override
  Future<List<RelationRequest>> getPendingRelationRequests({
    String? treeId,
  }) async {
    return const [];
  }

  @override
  Stream<List<TreeInvitation>> getPendingTreeInvitations() {
    return Stream<List<TreeInvitation>>.value(const []);
  }

  @override
  Future<List<FamilyTree>> getUserTrees() async {
    return const [];
  }

  @override
  Future<bool> hasDirectRelation({
    required String treeId,
    required String person1Id,
    required String person2Id,
  }) async {
    return false;
  }

  @override
  Future<bool> hasPendingRelationRequest({
    required String treeId,
    required String senderId,
    required String recipientId,
  }) async {
    return false;
  }

  @override
  Future<bool> isCurrentUserInTree(String treeId) async {
    return false;
  }

  @override
  Future<void> respondToRelationRequest({
    required String requestId,
    required RequestStatus response,
  }) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<void> respondToTreeInvitation(String invitationId, bool accept) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<void> removeTree(String treeId) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<void> sendOfflineRelationRequestByEmail({
    required String treeId,
    required String email,
    required String offlineRelativeId,
    required RelationType relationType,
  }) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<void> sendTreeInvitation({
    required String treeId,
    String? recipientUserId,
    String? recipientEmail,
    String? relationToTree,
  }) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<void> sendRelationRequest({
    required String treeId,
    required String recipientId,
    required RelationType relationType,
    String? message,
  }) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<void> updateRelative(
      String personId, Map<String, dynamic> personData) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }
}

class PendingBackendChatService implements ChatServiceInterface {
  const PendingBackendChatService();

  @override
  String? get currentUserId => null;

  @override
  String buildChatId(String otherUserId) {
    return 'pending:$otherUserId';
  }

  @override
  Future<String?> getOrCreateChat(String otherUserId) async => null;

  @override
  Stream<List<ChatMessage>> getMessagesStream(String chatId) {
    return Stream<List<ChatMessage>>.value(const []);
  }

  @override
  Stream<int> getTotalUnreadCountStream(String userId) {
    return Stream<int>.value(0);
  }

  @override
  Stream<List<ChatPreview>> getUserChatsStream(String userId) {
    return Stream<List<ChatPreview>>.value(const []);
  }

  @override
  Future<void> markChatAsRead(String chatId, String userId) {
    throw UnsupportedError(_pendingProviderMessage('chat'));
  }

  @override
  Future<void> sendMessage({
    required String otherUserId,
    String text = '',
    List<XFile> attachments = const <XFile>[],
  }) {
    throw UnsupportedError(_pendingProviderMessage('chat'));
  }

  @override
  Future<void> sendMessageToChat({
    required String chatId,
    String text = '',
    List<XFile> attachments = const <XFile>[],
  }) {
    throw UnsupportedError(_pendingProviderMessage('chat'));
  }

  @override
  Future<void> sendTextMessage({
    required String otherUserId,
    required String text,
  }) {
    return sendMessage(otherUserId: otherUserId, text: text);
  }

  @override
  Future<String?> createGroupChat({
    required List<String> participantIds,
    String? title,
    String? treeId,
  }) {
    throw UnsupportedError(_pendingProviderMessage('chat'));
  }
}
