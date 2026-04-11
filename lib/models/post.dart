import '../utils/url_utils.dart';

enum TreeContentScopeType { wholeTree, branches }

class Post {
  final String id;
  final String treeId;
  final String authorId;
  final String authorName;
  final String? _authorPhotoUrl;
  final String content;
  final List<String>? _imageUrls;
  final DateTime createdAt;
  final List<String> likedBy; // Список user ID
  final int commentCount;
  final bool isPublic;
  final TreeContentScopeType scopeType;
  final List<String> anchorPersonIds;

  // Геттеры для нормализованных URL
  String? get authorPhotoUrl => _authorPhotoUrl;
  List<String>? get imageUrls => _imageUrls;
  int get likeCount => likedBy.length;

  Post({
    required this.id,
    required this.treeId,
    required this.authorId,
    required this.authorName,
    String? authorPhotoUrl,
    required this.content,
    List<String>? imageUrls,
    required this.createdAt,
    List<String>? likedBy,
    this.commentCount = 0,
    this.isPublic = false,
    this.scopeType = TreeContentScopeType.wholeTree,
    List<String>? anchorPersonIds,
  })  : _authorPhotoUrl = UrlUtils.normalizeImageUrl(authorPhotoUrl),
        _imageUrls = imageUrls
            ?.map((url) => UrlUtils.normalizeImageUrl(url))
            .whereType<String>()
            .toList(),
        likedBy = likedBy ?? [],
        anchorPersonIds = anchorPersonIds ?? [];

  factory Post.fromJson(Map<String, dynamic> json) {
    final rawImageUrls = (json['imageUrls'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();

    return Post(
      id: json['id']?.toString() ?? '',
      treeId: json['treeId']?.toString() ?? '',
      authorId: json['authorId']?.toString() ?? '',
      authorName: json['authorName']?.toString() ?? 'Аноним',
      authorPhotoUrl: json['authorPhotoUrl'] as String?,
      content: json['content']?.toString() ?? '',
      imageUrls: rawImageUrls,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'].toString())
          : DateTime.now(),
      likedBy: (json['likedBy'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      commentCount: json['commentCount'] ?? 0,
      isPublic: json['isPublic'] ?? false,
      scopeType: _scopeTypeFromString(json['scopeType']?.toString()),
      anchorPersonIds: (json['anchorPersonIds'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'treeId': treeId,
      'authorId': authorId,
      'authorName': authorName,
      'authorPhotoUrl': authorPhotoUrl,
      'content': content,
      'imageUrls': imageUrls,
      'createdAt': createdAt.toIso8601String(),
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
