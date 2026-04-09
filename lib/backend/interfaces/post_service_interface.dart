import 'package:image_picker/image_picker.dart';
import '../../models/post.dart';
import '../../models/comment.dart';

abstract class PostServiceInterface {
  /// Fetch posts for a specific tree, author, or globally.
  /// [onlyBranches] if true, fetches only posts scoped to specific branches.
  Future<List<Post>> getPosts(
      {String? treeId, String? authorId, bool onlyBranches = false});

  /// Create a new family post.
  /// [images] optional attachments for the post.
  Future<Post> createPost({
    required String treeId,
    required String content,
    List<XFile> images = const [],
    bool isPublic = false,
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const [],
  });

  /// Delete a post by ID.
  Future<void> deletePost(String postId);

  /// Toggle like status for a post.
  Future<void> toggleLike(String postId);

  /// Fetch comments for a specific post.
  Future<List<Comment>> getComments(String postId);

  /// Add a comment to a post.
  Future<Comment> addComment(String postId, String content);

  /// Delete a comment.
  Future<void> deleteComment(String postId, String commentId);
}
