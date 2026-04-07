import 'package:hive/hive.dart';
import '../utils/date_parser.dart';

part 'family_tree.g.dart';

@HiveType(typeId: 2)
class FamilyTree extends HiveObject {
  @HiveField(0)
  final String id;
  @HiveField(1)
  final String name;
  @HiveField(2)
  final String description;
  @HiveField(3)
  final String creatorId;
  @HiveField(4)
  final List<String> memberIds;
  @HiveField(5)
  final DateTime createdAt;
  @HiveField(6)
  final DateTime updatedAt;
  @HiveField(7)
  final bool isPrivate;
  @HiveField(8)
  final List<String> members;
  @HiveField(9)
  final String? publicSlug;
  @HiveField(10)
  final bool isCertified;
  @HiveField(11)
  final String? certificationNote;

  FamilyTree({
    required this.id,
    required this.name,
    required this.description,
    required this.creatorId,
    required this.memberIds,
    required this.createdAt,
    required this.updatedAt,
    required this.isPrivate,
    required this.members,
    this.publicSlug,
    this.isCertified = false,
    this.certificationNote,
  });

  bool get isPublic => !isPrivate;

  String get publicRouteId {
    final slug = publicSlug?.trim();
    if (slug != null && slug.isNotEmpty) {
      return slug;
    }
    return id;
  }

  factory FamilyTree.fromFirestore(dynamic doc) {
    final data =
        (doc.data != null ? (doc.data() as Map<String, dynamic>?) : null) ?? {};
    return FamilyTree(
      id: doc.id,
      name: data['name'] ?? '',
      description: data['description'] ?? '',
      creatorId: data['creatorId'] ?? '',
      memberIds: List<String>.from(data['memberIds'] ?? []),
      createdAt: parseDateTime(data['createdAt']) ?? DateTime.now(),
      updatedAt: parseDateTime(data['updatedAt']) ?? DateTime.now(),
      isPrivate: data['isPrivate'] ?? false,
      members: List<String>.from(data['members'] ?? []),
      publicSlug: data['publicSlug']?.toString(),
      isCertified: data['isCertified'] == true,
      certificationNote: data['certificationNote']?.toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'description': description,
      'creatorId': creatorId,
      'memberIds': memberIds,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'isPrivate': isPrivate,
      'members': members,
      'publicSlug': publicSlug,
      'isCertified': isCertified,
      'certificationNote': certificationNote,
    };
  }

  static FamilyTree fromMap(Map<String, dynamic> data, String id) {
    return FamilyTree(
      id: id,
      name: data['name'] ?? 'Семейное дерево',
      description: data['description'] ?? '',
      creatorId: data['creatorId'] ?? '',
      createdAt: parseDateTimeRequired(data['createdAt']),
      updatedAt: parseDateTimeRequired(data['updatedAt']),
      members: List<String>.from(data['members'] ?? []),
      isPrivate: data['isPrivate'] ?? true,
      memberIds: List<String>.from(data['memberIds'] ?? []),
      publicSlug: data['publicSlug']?.toString(),
      isCertified: data['isCertified'] == true,
      certificationNote: data['certificationNote']?.toString(),
    );
  }
}
