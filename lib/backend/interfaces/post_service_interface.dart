import 'package:image_picker/image_picker.dart';
import '../../models/media_upload_progress.dart';
import '../../models/post.dart';
import '../../models/comment.dart';
import '../../models/reaction_summary.dart';

/// S3: страница ленты для курсорной пагинации (S2).
class PostsPage {
  const PostsPage({required this.posts, this.nextCursor});

  final List<Post> posts;

  /// null — лента закончилась.
  final String? nextCursor;
}

abstract class PostServiceInterface {
  /// Fetch posts for a specific tree, author, or globally.
  /// [onlyBranches] if true, fetches only posts scoped to specific branches.
  Future<List<Post>> getPosts(
      {String? treeId, String? authorId, bool onlyBranches = false});

  /// S3: страница ленты (S2-курсор: limit + before). Дефолтная
  /// реализация — фолбэк на [getPosts] одной «бесконечной» страницей,
  /// чтобы старые адаптеры и тестовые фейки работали без правок.
  Future<PostsPage> getPostsPage({
    String? treeId,
    int limit = 20,
    String? before,
  }) async {
    final posts = await getPosts(treeId: treeId);
    return PostsPage(posts: posts, nextCursor: null);
  }

  /// Create a new family post.
  /// [images] optional attachments for the post.
  /// [branchIds] (Phase 3.4) — optional list of branch ids the
  /// post should appear in. The primary [treeId] is implicit; the
  /// server validates every entry against the trees the author
  /// can access and silently drops the rest. When omitted/null,
  /// backend defaults to a single-branch publish (`[treeId]`).
  ///
  /// [clientRequestId] (необязательный) — идемпотентный ключ публикации:
  /// сервер, увидев повтор от того же автора, возвращает уже созданный
  /// пост вместо второго экземпляра. Очередь фоновой публикации передаёт
  /// сюда стабильный localId — ретрай после таймаута (когда первый запрос
  /// «зомби» и мог дойти) не задваивает пост.
  ///
  /// [onProgress] (необязательный) вызывается по мере загрузки медиа —
  /// экран composer'а показывает «Загружено N из M» вместо замершего
  /// спиннера. Файлы грузятся пулом ограниченной конкурентности, но в
  /// `imageUrls` попадают строго в порядке выбора.
  Future<Post> createPost({
    required String treeId,
    required String content,
    List<XFile> images = const [],
    bool isPublic = false,
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const [],
    String? circleId,
    List<String>? branchIds,
    String? clientRequestId,
    void Function(MediaUploadProgress progress)? onProgress,
  });

  /// Delete a post by ID.
  Future<void> deletePost(String postId);

  /// Toggle like status for a post and return the server-truth snapshot.
  Future<Post> toggleLike(String postId);

  /// Substring search across post content + author name. Returns
  /// posts the current user can see, ordered newest-first. Default
  /// impl returns empty so older adapters compile without a search
  /// backend.
  Future<List<Post>> searchPosts({
    required String query,
    String? treeId,
    int limit = 50,
  }) async {
    return const <Post>[];
  }

  /// Toggle the current user's emoji reaction on a post. Mirrors the
  /// chat-side `toggleMessageReaction` shape so frontend code can
  /// share the picker UI. Returns the updated reaction summaries
  /// straight from the server (so optimistic clients can reconcile).
  Future<List<ReactionSummary>> togglePostReaction({
    required String postId,
    required String emoji,
  }) {
    throw UnsupportedError('togglePostReaction is not supported');
  }

  /// Toggle the current user's emoji reaction on a comment. Same
  /// shape as [togglePostReaction] but scoped to a comment instead.
  Future<List<ReactionSummary>> toggleCommentReaction({
    required String postId,
    required String commentId,
    required String emoji,
  }) {
    throw UnsupportedError('toggleCommentReaction is not supported');
  }

  /// Fetch comments for a specific post.
  Future<List<Comment>> getComments(String postId);

  /// Add a comment to a post. Pass [parentCommentId] to post a reply
  /// under an existing top-level comment — the server collapses any
  /// reply-to-reply chains onto the canonical top-level parent so the
  /// resulting `parentCommentId` is always either null or a top-level
  /// comment id.
  Future<Comment> addComment(
    String postId,
    String content, {
    String? parentCommentId,
  });

  /// Delete a comment.
  Future<void> deleteComment(String postId, String commentId);
}
