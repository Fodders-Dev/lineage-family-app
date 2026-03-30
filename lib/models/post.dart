import 'package:cloud_firestore/cloud_firestore.dart';

enum TreeContentScopeType { wholeTree, branches }

class Post {
  final String id;
  final String treeId;
  final String authorId;
  final String authorName;
  final String? authorPhotoUrl;
  final String content;
  final List<String>? imageUrls;
  final DateTime createdAt;
  final List<String> likedBy; // Список user ID
  final int commentCount;
  final bool isPublic;
  final TreeContentScopeType scopeType;
  final List<String> anchorPersonIds;

  // Геттер для удобства
  int get likeCount => likedBy.length;

  Post({
    required this.id,
    required this.treeId,
    required this.authorId,
    required this.authorName,
    this.authorPhotoUrl,
    required this.content,
    this.imageUrls,
    required this.createdAt,
    List<String>? likedBy, // Делаем nullable для удобства в fromFirestore
    this.commentCount = 0,
    this.isPublic = false,
    this.scopeType = TreeContentScopeType.wholeTree,
    List<String>? anchorPersonIds,
  })  : likedBy = likedBy ?? [],
        anchorPersonIds = anchorPersonIds ?? [];

  factory Post.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return Post(
      id: doc.id,
      treeId: data['treeId'] ?? '',
      authorId: data['authorId'] ?? '',
      authorName: data['authorName'] ?? 'Аноним',
      authorPhotoUrl: data['authorPhotoUrl'] as String?,
      content: data['content'] ?? '',
      imageUrls: (data['imageUrls'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      likedBy: (data['likedBy'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      commentCount: data['commentCount'] ?? 0,
      isPublic: data['isPublic'] ?? false,
      scopeType: _scopeTypeFromString(data['scopeType']?.toString()),
      anchorPersonIds: (data['anchorPersonIds'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'treeId': treeId,
      'authorId': authorId,
      'authorName': authorName,
      'authorPhotoUrl': authorPhotoUrl,
      'content': content,
      'imageUrls': imageUrls,
      'createdAt': Timestamp.fromDate(createdAt),
      'likedBy': likedBy,
      'commentCount': commentCount,
      'isPublic': isPublic,
      'scopeType': _scopeTypeToString(scopeType),
      'anchorPersonIds': anchorPersonIds,
    };
  }

  static TreeContentScopeType _scopeTypeFromString(String? value) {
    switch (value) {
      case 'branches':
        return TreeContentScopeType.branches;
      default:
        return TreeContentScopeType.wholeTree;
    }
  }

  static String _scopeTypeToString(TreeContentScopeType value) {
    switch (value) {
      case TreeContentScopeType.branches:
        return 'branches';
      case TreeContentScopeType.wholeTree:
        return 'wholeTree';
    }
  }
}
