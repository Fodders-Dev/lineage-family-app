import '../utils/date_parser.dart';
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

  factory Post.fromFirestore(dynamic doc) {
    final data =
        (doc.data != null ? (doc.data() as Map<String, dynamic>?) : null) ?? {};
    final rawImageUrls = (data['imageUrls'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();

    return Post(
      id: doc.id,
      treeId: data['treeId'] ?? '',
      authorId: data['authorId'] ?? '',
      authorName: data['authorName'] ?? 'Аноним',
      authorPhotoUrl: data['authorPhotoUrl'] as String?,
      content: data['content'] ?? '',
      imageUrls: rawImageUrls,
      createdAt: parseDateTime(data['createdAt']) ?? DateTime.now(),
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
