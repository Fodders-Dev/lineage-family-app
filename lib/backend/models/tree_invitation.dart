import '../../models/family_tree.dart';

class TreeInvitation {
  const TreeInvitation({
    required this.invitationId,
    required this.tree,
    this.invitedBy,
  });

  final String invitationId;
  final FamilyTree tree;
  final String? invitedBy;
}
