import 'dart:async';
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';

import '../models/media_upload_progress.dart';
import '../models/chat_attachment.dart';
import '../models/call_event.dart';
import '../models/call_invite.dart';
import '../models/call_media_mode.dart';
import '../models/chat_message.dart';
import '../models/chat_details.dart';
import '../models/chat_preview.dart';
import '../models/chat_message_search_result.dart';
import '../models/chat_send_progress.dart';
import '../models/circle.dart';
import '../models/identity_claim.dart';
import '../models/merge_proposal.dart';
import '../models/account_linking_status.dart';
import '../models/family_person.dart';
import '../models/family_relation.dart';
import '../models/family_tree.dart';
import '../models/person_dossier.dart';
import '../models/person_attribute.dart';
import '../models/profile_contribution.dart';
import '../models/profile_note.dart';
import '../models/relation_request.dart';
import '../models/user_profile.dart';
import '../models/audience_preset.dart';
import '../models/post.dart';
import '../models/gathering.dart';
import '../models/poll.dart';
import '../models/comment.dart';
import '../models/reaction_summary.dart';
import '../models/story.dart';
import '../models/tree_change_record.dart';
import '../models/public_identity_result.dart';
import '../models/user_block_record.dart';
import 'interfaces/auth_service_interface.dart';
import 'models/auth_providers_availability.dart';
import 'models/google_account_preview.dart';
import 'interfaces/call_service_interface.dart';
import 'interfaces/chat_service_interface.dart';
import 'interfaces/circle_service_interface.dart';
import 'interfaces/gathering_service_interface.dart';
import 'interfaces/poll_service_interface.dart';
import 'interfaces/family_tree_service_interface.dart';
import 'interfaces/identity_service_interface.dart';
import 'interfaces/profile_service_interface.dart';
import 'interfaces/storage_service_interface.dart';
import 'interfaces/notification_service_interface.dart';
import 'interfaces/post_service_interface.dart';
import 'interfaces/safety_service_interface.dart';
import 'interfaces/story_service_interface.dart';
import 'models/include_rules.dart';
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
  bool get currentRequiresOnboarding => false;

  @override
  Future<void> markOnboardingSkipped() async {}

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
    String? consentDocVersion,
  }) {
    throw UnsupportedError(_pendingProviderMessage('auth'));
  }

  @override
  Future<void> resetPassword(String email) {
    throw UnsupportedError(_pendingProviderMessage('auth'));
  }

  @override
  Future<void> confirmPasswordReset({
    required String token,
    required String newPassword,
  }) {
    throw UnsupportedError(_pendingProviderMessage('auth'));
  }

  @override
  Future<void> signOut() async {}

  @override
  Future<Object?> signInWithGoogle({
    GoogleAccountConfirmCallback? confirm,
    String? consentDocVersion,
  }) {
    throw UnsupportedError(_pendingProviderMessage('auth'));
  }

  @override
  Future<AuthProvidersAvailability?> fetchAuthProvidersAvailability() async =>
      null;

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
  Future<AccountLinkingStatus> getCurrentAccountLinkingStatus() async {
    return const AccountLinkingStatus();
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
  Future<String?> uploadCoverPhoto(XFile photo) {
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
  Future<List<ProfileContribution>> getPendingProfileContributions() async {
    return const [];
  }

  @override
  Future<void> acceptProfileContribution(String contributionId) {
    throw UnsupportedError(_pendingProviderMessage('profile'));
  }

  @override
  Future<void> rejectProfileContribution(String contributionId) {
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
    TreeKind kind = TreeKind.family,
    IncludeRules? includeRules,
  }) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<void> deleteRelative(String treeId, String personId) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<FamilyPerson> unlinkUserFromPerson({
    required String treeId,
    required String personId,
  }) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<FamilyPerson> addRelativeMedia({
    required String treeId,
    required String personId,
    required Map<String, dynamic> mediaData,
  }) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<FamilyPerson> updateRelativeMedia({
    required String treeId,
    required String personId,
    required String mediaId,
    required Map<String, dynamic> mediaData,
  }) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<FamilyPerson> deleteRelativeMedia({
    required String treeId,
    required String personId,
    required String mediaId,
    String? fallbackUrl,
  }) {
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
    DateTime? marriageDate,
    DateTime? divorceDate,
    String? customRelationLabel1to2,
    String? customRelationLabel2to1,
    String? unionStatus,
  }) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<void> disconnectRelation({
    required String treeId,
    required String relationId,
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
  Future<PersonDossier> getPersonDossier(String treeId, String personId) {
    throw UnsupportedError(_pendingProviderMessage('tree'));
  }

  @override
  Future<void> proposePersonProfileContribution({
    required String treeId,
    required String personId,
    required Map<String, dynamic> fields,
    String? message,
  }) {
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
  Future<List<TreeChangeRecord>> getTreeHistory({
    required String treeId,
    String? personId,
    String? type,
    String? actorId,
  }) async {
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
  Future<void> refreshMessages(String chatId) async {}

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
    List<ChatAttachment> forwardedAttachments = const <ChatAttachment>[],
    ChatReplyReference? replyTo,
    String? clientMessageId,
    int? expiresInSeconds,
    void Function(ChatSendProgress progress)? onProgress,
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
  Future<void> editChatMessage({
    required String chatId,
    required String messageId,
    required String text,
  }) {
    throw UnsupportedError(_pendingProviderMessage('chat'));
  }

  @override
  Future<void> deleteChatMessage({
    required String chatId,
    required String messageId,
  }) {
    throw UnsupportedError(_pendingProviderMessage('chat'));
  }

  @override
  Future<void> toggleMessageReaction({
    required String chatId,
    required String messageId,
    required String emoji,
  }) {
    throw UnsupportedError(_pendingProviderMessage('chat'));
  }

  @override
  Future<String?> createGroupChat({
    required List<String> participantIds,
    String? title,
    String? treeId,
  }) {
    throw UnsupportedError(_pendingProviderMessage('chat'));
  }

  @override
  Future<String?> createBranchChat({
    required String treeId,
    required List<String> branchRootPersonIds,
    String? title,
  }) {
    throw UnsupportedError(_pendingProviderMessage('chat'));
  }

  @override
  Future<ChatDetails> getChatDetails(String chatId) {
    throw UnsupportedError(_pendingProviderMessage('chat'));
  }

  @override
  Future<ChatDetails> renameGroupChat({
    required String chatId,
    required String title,
  }) {
    throw UnsupportedError(_pendingProviderMessage('chat'));
  }

  @override
  Future<ChatDetails> updateGroupChatPhoto({
    required String chatId,
    required XFile photo,
  }) {
    throw UnsupportedError(_pendingProviderMessage('chat'));
  }

  @override
  Future<ChatDetails> addGroupParticipants({
    required String chatId,
    required List<String> participantIds,
  }) {
    throw UnsupportedError(_pendingProviderMessage('chat'));
  }

  @override
  Future<ChatDetails> removeGroupParticipant({
    required String chatId,
    required String participantId,
  }) {
    throw UnsupportedError(_pendingProviderMessage('chat'));
  }

  @override
  Future<void> leaveGroup(String chatId) {
    throw UnsupportedError(_pendingProviderMessage('chat'));
  }

  @override
  Future<List<ChatMessageSearchResult>> searchMessages({
    required String query,
    String? chatId,
    int limit = 50,
  }) {
    throw UnsupportedError(_pendingProviderMessage('chat'));
  }
}

class PendingBackendCallService implements CallServiceInterface {
  const PendingBackendCallService();

  @override
  String? get currentUserId => null;

  @override
  Stream<CallEvent> get events => const Stream<CallEvent>.empty();

  @override
  Future<void> startRealtimeBridge() async {}

  @override
  Future<void> stopRealtimeBridge() async {}

  @override
  Future<CallInvite?> getActiveCall({String? chatId}) async => null;

  @override
  Future<CallInvite?> getCall(String callId) async => null;

  @override
  Future<CallInvite> acceptCall(String callId) {
    throw UnsupportedError(_pendingProviderMessage('calls'));
  }

  @override
  Future<CallInvite> cancelCall(String callId) {
    throw UnsupportedError(_pendingProviderMessage('calls'));
  }

  @override
  Future<CallInvite> hangUp(String callId) {
    throw UnsupportedError(_pendingProviderMessage('calls'));
  }

  @override
  Future<CallInvite> rejectCall(String callId) {
    throw UnsupportedError(_pendingProviderMessage('calls'));
  }

  @override
  Future<CallInvite> startCall({
    required String chatId,
    required CallMediaMode mediaMode,
    List<String>? participantIds,
  }) {
    throw UnsupportedError(_pendingProviderMessage('calls'));
  }

  @override
  Future<CallInvite> joinCall(String callId) => acceptCall(callId);

  @override
  Future<CallInvite> nudgeCallParticipants(
    String callId, {
    List<String>? participantIds,
  }) {
    throw UnsupportedError(_pendingProviderMessage('calls'));
  }
}

class PendingBackendCircleService implements CircleServiceInterface {
  const PendingBackendCircleService();

  @override
  Future<List<FamilyCircle>> getCircles(String treeId) async {
    return const <FamilyCircle>[];
  }

  @override
  Future<AudiencePresetsResponse> getAudiencePresets(String treeId) async {
    return AudiencePresetsResponse.empty;
  }
}

class PendingBackendIdentityService implements IdentityServiceInterface {
  const PendingBackendIdentityService();

  @override
  Future<IdentityClaim> createIdentityClaim({
    required String treeId,
    required String personId,
    String? evidence,
  }) {
    throw UnsupportedError(_pendingProviderMessage('identity'));
  }

  @override
  Future<List<MergeProposal>> getMergedProposals() async {
    return const <MergeProposal>[];
  }

  @override
  Future<MergeProposal> unmergeMergeProposal(String proposalId) {
    throw UnsupportedError(_pendingProviderMessage('identity'));
  }

  @override
  Future<List<PersonAttribute>> getPersonAttributes({
    required String treeId,
    required String personId,
  }) async {
    return const <PersonAttribute>[];
  }

  @override
  Future<List<IdentityClaim>> getPendingIdentityClaims() async {
    return const <IdentityClaim>[];
  }

  @override
  Future<List<MergeProposal>> getPendingMergeProposals() async {
    return const <MergeProposal>[];
  }

  @override
  Future<IdentityClaim> reviewIdentityClaim(
    String claimId, {
    required bool approve,
    String? reason,
  }) {
    throw UnsupportedError(_pendingProviderMessage('identity'));
  }

  @override
  Future<MergeProposal> reviewMergeProposal(
    String proposalId, {
    required bool accept,
    String? reason,
  }) {
    throw UnsupportedError(_pendingProviderMessage('identity'));
  }

  @override
  Future<List<PublicIdentityResult>> searchPublicIdentities({
    String? query,
    String? birthYear,
  }) async {
    return const <PublicIdentityResult>[];
  }

  @override
  Future<bool> setPublicDiscoverability(bool enabled) {
    throw UnsupportedError(_pendingProviderMessage('identity'));
  }

  @override
  Future<List<PersonAttribute>> updatePersonAttributeVisibility({
    required String treeId,
    required String personId,
    String? visibility,
    Map<String, String> attributes = const <String, String>{},
  }) {
    throw UnsupportedError(_pendingProviderMessage('identity'));
  }
}

class PendingBackendPostService implements PostServiceInterface {
  const PendingBackendPostService();

  @override
  Future<List<Post>> getPosts(
      {String? treeId, String? authorId, bool onlyBranches = false}) async {
    return const [];
  }

  @override
  Future<PostsPage> getPostsPage({
    String? treeId,
    int limit = 20,
    String? before,
  }) async {
    return const PostsPage(posts: <Post>[], nextCursor: null);
  }

  @override
  Future<Post> createPost({
    required String treeId,
    required String content,
    List<XFile> images = const [],
    bool isPublic = false,
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const [],
    String? circleId,
    List<String>? branchIds,
    void Function(MediaUploadProgress progress)? onProgress,
  }) {
    throw UnsupportedError(_pendingProviderMessage('post'));
  }

  @override
  Future<void> deletePost(String postId) {
    throw UnsupportedError(_pendingProviderMessage('post'));
  }

  @override
  Future<Post> toggleLike(String postId) {
    throw UnsupportedError(_pendingProviderMessage('post'));
  }

  @override
  Future<List<ReactionSummary>> togglePostReaction({
    required String postId,
    required String emoji,
  }) {
    throw UnsupportedError(_pendingProviderMessage('post'));
  }

  @override
  Future<List<Post>> searchPosts({
    required String query,
    String? treeId,
    int limit = 50,
  }) async {
    return const <Post>[];
  }

  @override
  Future<List<ReactionSummary>> toggleCommentReaction({
    required String postId,
    required String commentId,
    required String emoji,
  }) {
    throw UnsupportedError(_pendingProviderMessage('post'));
  }

  @override
  Future<List<Comment>> getComments(String postId) async {
    return const [];
  }

  @override
  Future<Comment> addComment(
    String postId,
    String content, {
    String? parentCommentId,
  }) {
    throw UnsupportedError(_pendingProviderMessage('post'));
  }

  @override
  Future<void> deleteComment(String postId, String commentId) {
    throw UnsupportedError(_pendingProviderMessage('post'));
  }
}

class PendingBackendStoryService implements StoryServiceInterface {
  const PendingBackendStoryService();

  @override
  Future<List<Story>> getStories({
    String? treeId,
    String? authorId,
    bool includeArchive = false,
  }) async {
    return const <Story>[];
  }

  @override
  Future<List<ReactionSummary>> toggleStoryReaction({
    required String storyId,
    required String emoji,
  }) {
    throw UnsupportedError(_pendingProviderMessage('story'));
  }

  @override
  Future<Story> createStory({
    required String treeId,
    required StoryType type,
    String? text,
    XFile? media,
    String? thumbnailUrl,
    DateTime? expiresAt,
    String? circleId,
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const <String>[],
  }) {
    throw UnsupportedError(_pendingProviderMessage('story'));
  }

  @override
  Future<Story> markViewed(String storyId) {
    throw UnsupportedError(_pendingProviderMessage('story'));
  }

  @override
  Future<void> deleteStory(String storyId) {
    throw UnsupportedError(_pendingProviderMessage('story'));
  }
}

class NoopStorageService implements StorageServiceInterface {
  const NoopStorageService();

  @override
  Future<String?> uploadImage(XFile imageFile, String folder) async => null;
  @override
  Future<bool> deleteImage(String imageUrl) async => true;
  @override
  Future<String?> uploadProfileImage(XFile imageFile) async => null;
  @override
  Future<String?> uploadCoverImage(XFile imageFile) async => null;
  @override
  Future<String?> uploadBytes({
    required String bucket,
    required String path,
    required Uint8List fileBytes,
    FileOptions? fileOptions,
  }) async =>
      null;
}

class NoopNotificationService implements NotificationServiceInterface {
  const NoopNotificationService();

  @override
  Future<void> initialize() async {}
  @override
  Future<void> showBirthdayNotification(FamilyPerson person) async {}
  @override
  Future<void> showChatMessageNotification({
    required String chatId,
    required String senderId,
    required String senderName,
    required String messageText,
    required int notificationId,
    bool playSound = true,
  }) async {}

  @override
  Future<void> dismissChatNotifications(String chatId) async {}
}

class PendingBackendSafetyService implements SafetyServiceInterface {
  const PendingBackendSafetyService();

  @override
  Future<UserBlockRecord> blockUser({
    required String userId,
    String? reason,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) {
    throw UnsupportedError(_pendingProviderMessage('safety'));
  }

  @override
  Future<List<UserBlockRecord>> listBlockedUsers() async {
    return const <UserBlockRecord>[];
  }

  @override
  Future<void> reportTarget({
    required String targetType,
    required String targetId,
    required String reason,
    String? details,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) {
    throw UnsupportedError(_pendingProviderMessage('safety'));
  }

  @override
  Future<void> unblockUser(String blockId) {
    throw UnsupportedError(_pendingProviderMessage('safety'));
  }
}

class PendingBackendGatheringService implements GatheringServiceInterface {
  const PendingBackendGatheringService();

  @override
  Future<List<Gathering>> getGatherings({required String treeId}) async {
    return const [];
  }

  @override
  Future<Gathering> createGathering({
    required String treeId,
    required String title,
    String? description,
    required DateTime startAt,
    DateTime? endAt,
    bool isAllDay = false,
    String? place,
    List<XFile> images = const [],
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const [],
    String? circleId,
    List<String>? branchIds,
  }) {
    throw UnsupportedError(_pendingProviderMessage('gathering'));
  }

  @override
  Future<void> deleteGathering(String gatheringId) {
    throw UnsupportedError(_pendingProviderMessage('gathering'));
  }

  @override
  Future<Gathering> setRsvp(
    String gatheringId,
    String status, {
    int? headcount,
    String? note,
  }) {
    throw UnsupportedError(_pendingProviderMessage('gathering'));
  }
}

class PendingBackendPollService implements PollServiceInterface {
  const PendingBackendPollService();

  @override
  Future<List<Poll>> getPolls({String? treeId}) async {
    return const [];
  }

  @override
  Future<Poll> createPoll({
    required String treeId,
    required String question,
    required List<String> options,
    bool allowMultiple = false,
    DateTime? closesAt,
    List<XFile> images = const [],
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const [],
    String? circleId,
    List<String>? branchIds,
  }) {
    throw UnsupportedError(_pendingProviderMessage('poll'));
  }

  @override
  Future<Poll> vote(String pollId, List<String> optionIds) {
    throw UnsupportedError(_pendingProviderMessage('poll'));
  }

  @override
  Future<void> deletePoll(String pollId) {
    throw UnsupportedError(_pendingProviderMessage('poll'));
  }
}
