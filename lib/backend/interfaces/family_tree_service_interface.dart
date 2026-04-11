import '../../models/family_person.dart';
import '../../models/family_relation.dart';
import '../../models/relation_request.dart';
import '../../models/family_tree.dart';
import '../models/selectable_tree.dart';
import '../models/tree_invitation.dart';

abstract class FamilyTreeServiceInterface {
  Future<String> createTree({
    required String name,
    required String description,
    required bool isPrivate,
    TreeKind kind = TreeKind.family,
  });
  Future<List<FamilyTree>> getUserTrees();
  Future<List<FamilyPerson>> getRelatives(String treeId);
  Future<List<FamilyRelation>> getRelations(String treeId);
  Stream<List<FamilyPerson>> getRelativesStream(String treeId);
  Stream<List<FamilyRelation>> getRelationsStream(String treeId);
  Future<String> addRelative(String treeId, Map<String, dynamic> personData);
  Future<void> updateRelative(String personId, Map<String, dynamic> personData);
  Future<FamilyPerson> getPersonById(String treeId, String personId);
  Future<RelationType> getRelationToUser(String treeId, String relativeId);
  Future<void> addRelation(
    String treeId,
    String person1Id,
    String person2Id,
    RelationType relationType,
  );
  Future<FamilyRelation> createRelation({
    required String treeId,
    required String person1Id,
    required String person2Id,
    required RelationType relation1to2,
    bool isConfirmed,
  });
  Future<List<FamilyPerson>> getOfflineProfilesByCreator(
    String treeId,
    String creatorId,
  );
  Future<String?> findSpouseId(String treeId, String personId);
  Future<void> checkAndCreateSpouseRelationIfNeeded(
    String treeId,
    String childId,
    String newParentId,
  );
  Future<void> checkAndCreateParentSiblingRelations(
    String treeId,
    String parentId,
    String childId,
  );
  Stream<List<TreeInvitation>> getPendingTreeInvitations();
  Future<List<RelationRequest>> getRelationRequests({required String treeId});
  Future<List<RelationRequest>> getPendingRelationRequests({String? treeId});
  Future<void> respondToTreeInvitation(String invitationId, bool accept);
  Future<void> respondToRelationRequest({
    required String requestId,
    required RequestStatus response,
  });
  Future<List<SelectableTree>> getSelectableTreesForCurrentUser();
  Future<RelationType> getRelationBetween(
    String treeId,
    String person1Id,
    String person2Id,
  );
  Future<bool> isCurrentUserInTree(String treeId);
  Future<void> addCurrentUserToTree({
    required String treeId,
    required String targetPersonId,
    required RelationType relationType,
  });
  Future<void> removeTree(String treeId);
  Future<void> deleteRelative(String treeId, String personId);
  Future<bool> hasDirectRelation({
    required String treeId,
    required String person1Id,
    required String person2Id,
  });
  Future<bool> hasPendingRelationRequest({
    required String treeId,
    required String senderId,
    required String recipientId,
  });
  Future<void> sendRelationRequest({
    required String treeId,
    required String recipientId,
    required RelationType relationType,
    String? message,
  });
  Future<void> sendTreeInvitation({
    required String treeId,
    String? recipientUserId,
    String? recipientEmail,
    String? relationToTree,
  });
  Future<void> sendOfflineRelationRequestByEmail({
    required String treeId,
    required String email,
    required String offlineRelativeId,
    required RelationType relationType,
  });
}
