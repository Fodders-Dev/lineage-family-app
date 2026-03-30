import 'package:cloud_firestore/cloud_firestore.dart';

enum MemberRole {
  owner, // Владелец (создатель) дерева
  editor, // Редактор (может изменять дерево)
  viewer, // Зритель (может только просматривать)
  pending, // Ожидает принятия приглашения
}

class FamilyTreeMember {
  final String id; // Уникальный ID записи
  final String treeId; // ID семейного дерева
  final String userId; // ID пользователя
  final MemberRole role; // Роль пользователя
  final DateTime addedAt; // Когда добавлен
  final String? addedBy; // Кем добавлен
  final DateTime? acceptedAt; // Когда принял приглашение
  final String?
      relationToTree; // Описание отношения к дереву (например, "отец Ивана")

  FamilyTreeMember({
    required this.id,
    required this.treeId,
    required this.userId,
    required this.role,
    required this.addedAt,
    this.addedBy,
    this.acceptedAt,
    this.relationToTree,
  });

  factory FamilyTreeMember.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return FamilyTreeMember(
      id: doc.id,
      treeId: data['treeId'] ?? '',
      userId: data['userId'] ?? '',
      role: _stringToMemberRole(data['role'] ?? 'viewer'),
      addedAt: (data['addedAt'] as Timestamp).toDate(),
      addedBy: data['addedBy'],
      acceptedAt: data['acceptedAt'] != null
          ? (data['acceptedAt'] as Timestamp).toDate()
          : null,
      relationToTree: data['relationToTree'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'treeId': treeId,
      'userId': userId,
      'role': _memberRoleToString(role),
      'addedAt': Timestamp.fromDate(addedAt),
      'addedBy': addedBy,
      'acceptedAt': acceptedAt != null ? Timestamp.fromDate(acceptedAt!) : null,
      'relationToTree': relationToTree,
    };
  }

  // Конвертация роли из строки
  static MemberRole _stringToMemberRole(String value) {
    switch (value) {
      case 'owner':
        return MemberRole.owner;
      case 'editor':
        return MemberRole.editor;
      case 'pending':
        return MemberRole.pending;
      default:
        return MemberRole.viewer;
    }
  }

  // Конвертация роли в строку
  static String _memberRoleToString(MemberRole role) {
    switch (role) {
      case MemberRole.owner:
        return 'owner';
      case MemberRole.editor:
        return 'editor';
      case MemberRole.pending:
        return 'pending';
      case MemberRole.viewer:
        return 'viewer';
    }
  }

  // Проверка, может ли пользователь редактировать дерево
  bool canEdit() {
    return role == MemberRole.owner || role == MemberRole.editor;
  }

  // Проверка, принято ли приглашение
  bool isAccepted() {
    return role != MemberRole.pending;
  }
}
