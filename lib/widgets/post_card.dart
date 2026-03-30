import 'package:cached_network_image/cached_network_image.dart';
import 'package:carousel_slider/carousel_slider.dart';
import 'package:flutter/material.dart' hide CarouselController;
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../models/comment.dart';
import '../models/post.dart';
import '../services/post_service.dart';

class PostCard extends StatefulWidget {
  const PostCard({super.key, required this.post});

  final Post post;

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  final PostService _postService = PostService();
  final String? _currentUserId = GetIt.I<AuthServiceInterface>().currentUserId;

  late bool _isLikedByCurrentUser;
  late int _likeCount;
  late int _commentCount;

  @override
  void initState() {
    super.initState();
    _syncLocalState();
  }

  @override
  void didUpdateWidget(covariant PostCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post.id != widget.post.id ||
        oldWidget.post.likeCount != widget.post.likeCount ||
        oldWidget.post.commentCount != widget.post.commentCount ||
        oldWidget.post.likedBy != widget.post.likedBy) {
      _syncLocalState();
    }
  }

  void _syncLocalState() {
    _isLikedByCurrentUser =
        _currentUserId != null && widget.post.likedBy.contains(_currentUserId!);
    _likeCount = widget.post.likeCount;
    _commentCount = widget.post.commentCount;
  }

  Future<void> _toggleLike() async {
    if (_currentUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Войдите, чтобы поставить лайк')),
      );
      return;
    }

    setState(() {
      if (_isLikedByCurrentUser) {
        _likeCount--;
      } else {
        _likeCount++;
      }
      _isLikedByCurrentUser = !_isLikedByCurrentUser;
    });

    try {
      await _postService.toggleLike(widget.post.id);
    } catch (e) {
      setState(() {
        if (_isLikedByCurrentUser) {
          _likeCount--;
        } else {
          _likeCount++;
        }
        _isLikedByCurrentUser = !_isLikedByCurrentUser;
      });
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Ошибка: не удалось ${!_isLikedByCurrentUser ? "поставить" : "убрать"} лайк',
          ),
        ),
      );
    }
  }

  void _openAuthorProfile() {
    if (widget.post.authorId.isEmpty) {
      return;
    }
    if (_currentUserId == widget.post.authorId) {
      context.push('/profile');
      return;
    }
    context.push('/user/${widget.post.authorId}');
  }

  Future<void> _sharePost() async {
    final buffer = StringBuffer()
      ..writeln(widget.post.authorName)
      ..writeln(
        DateFormat('d MMMM yyyy в HH:mm', 'ru').format(widget.post.createdAt),
      );

    if (widget.post.content.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(widget.post.content.trim());
    }

    if (widget.post.imageUrls != null && widget.post.imageUrls!.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Фото: ${widget.post.imageUrls!.join('\n')}');
    }

    await Share.share(buffer.toString().trim());
  }

  Future<void> _showCommentsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        return _PostCommentsSheet(
          post: widget.post,
          onCommentAdded: () {
            if (!mounted) {
              return;
            }
            setState(() {
              _commentCount++;
            });
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPostHeader(),
          if (widget.post.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(widget.post.content),
            ),
          if (widget.post.imageUrls != null &&
              widget.post.imageUrls!.isNotEmpty)
            _buildPostImages(),
          const Divider(height: 1, thickness: 0.5, indent: 16, endIndent: 16),
          _buildPostActions(),
        ],
      ),
    );
  }

  Widget _buildPostHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: _openAuthorProfile,
            child: CircleAvatar(
              radius: 20,
              backgroundImage: widget.post.authorPhotoUrl != null &&
                      widget.post.authorPhotoUrl!.isNotEmpty
                  ? CachedNetworkImageProvider(widget.post.authorPhotoUrl!)
                  : null,
              child: widget.post.authorPhotoUrl == null ||
                      widget.post.authorPhotoUrl!.isEmpty
                  ? const Icon(Icons.person, size: 20, color: Colors.grey)
                  : null,
              backgroundColor: Colors.grey.shade200,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: _openAuthorProfile,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.post.authorName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    DateFormat(
                      'd MMMM yyyy в HH:mm',
                      'ru',
                    ).format(widget.post.createdAt),
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (widget.post.scopeType ==
                          TreeContentScopeType.branches)
                        _PostMetaChip(
                          icon: Icons.alt_route,
                          label: 'Ветки: ${widget.post.anchorPersonIds.length}',
                        ),
                      if (widget.post.isPublic)
                        const _PostMetaChip(
                          icon: Icons.public,
                          label: 'Публично',
                          highlighted: true,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPostImages() {
    final images = widget.post.imageUrls!;
    if (images.length == 1) {
      return Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: CachedNetworkImage(
            imageUrl: images.first,
            fit: BoxFit.contain,
            placeholder: (_, __) => Container(
              color: Colors.grey.shade300,
              child: const Center(child: CircularProgressIndicator()),
            ),
            errorWidget: (_, __, ___) => Container(
              color: Colors.grey.shade300,
              child: const Center(child: Icon(Icons.error)),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: CarouselSlider.builder(
        itemCount: images.length,
        itemBuilder: (context, index, _) {
          return CachedNetworkImage(
            imageUrl: images[index],
            imageBuilder: (_, imageProvider) =>
                Image(image: imageProvider, fit: BoxFit.cover),
            fit: BoxFit.contain,
            placeholder: (_, __) => Container(
              color: Colors.grey.shade300,
              child: const Center(child: CircularProgressIndicator()),
            ),
            errorWidget: (_, __, ___) => Container(
              color: Colors.grey.shade300,
              child: const Center(child: Icon(Icons.error)),
            ),
            width: MediaQuery.of(context).size.width,
          );
        },
        options: CarouselOptions(
          aspectRatio: 16 / 9,
          viewportFraction: 1,
          enableInfiniteScroll: false,
          autoPlay: false,
          enlargeCenterPage: false,
        ),
      ),
    );
  }

  Widget _buildPostActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          TextButton.icon(
            onPressed: _toggleLike,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              minimumSize: const Size(0, 30),
            ),
            icon: Icon(
              _isLikedByCurrentUser ? Icons.favorite : Icons.favorite_border,
              color: _isLikedByCurrentUser
                  ? Colors.redAccent
                  : Colors.grey.shade600,
              size: 20,
            ),
            label: Text(
              _likeCount.toString(),
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ),
          const SizedBox(width: 12),
          TextButton.icon(
            onPressed: _showCommentsSheet,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              minimumSize: const Size(0, 30),
            ),
            icon: Icon(
              Icons.chat_bubble_outline,
              color: Colors.grey.shade600,
              size: 20,
            ),
            label: Text(
              _commentCount.toString(),
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ),
          const SizedBox(width: 12),
          TextButton.icon(
            onPressed: _sharePost,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              minimumSize: const Size(0, 30),
            ),
            icon: Icon(Icons.share_outlined,
                color: Colors.grey.shade600, size: 20),
            label: Text(
              'Поделиться',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ),
        ],
      ),
    );
  }
}

class _PostCommentsSheet extends StatefulWidget {
  const _PostCommentsSheet({
    required this.post,
    required this.onCommentAdded,
  });

  final Post post;
  final VoidCallback onCommentAdded;

  @override
  State<_PostCommentsSheet> createState() => _PostCommentsSheetState();
}

class _PostCommentsSheetState extends State<_PostCommentsSheet> {
  final PostService _postService = PostService();
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final TextEditingController _commentController = TextEditingController();
  bool _isSending = false;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _submitComment() async {
    final content = _commentController.text.trim();
    if (content.isEmpty) {
      return;
    }
    if (_authService.currentUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Войдите, чтобы оставить комментарий')),
      );
      return;
    }

    setState(() {
      _isSending = true;
    });

    try {
      await _postService.addComment(postId: widget.post.id, content: content);
      _commentController.clear();
      widget.onCommentAdded();
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отправить комментарий: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Row(
                children: [
                  Text(
                    'Комментарии',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<List<Comment>>(
                stream: _postService.getCommentsStream(widget.post.id),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      !snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Не удалось загрузить комментарии.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade700),
                        ),
                      ),
                    );
                  }

                  final comments = snapshot.data ?? const <Comment>[];
                  if (comments.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Комментариев пока нет. Начните обсуждение первым.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade700),
                        ),
                      ),
                    );
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    itemCount: comments.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final comment = comments[index];
                      return _CommentTile(comment: comment);
                    },
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  top: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _commentController,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Напишите комментарий',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _isSending ? null : _submitComment,
                    child: _isSending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.comment});

  final Comment comment;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 18,
          backgroundImage: comment.authorPhotoUrl != null &&
                  comment.authorPhotoUrl!.isNotEmpty
              ? CachedNetworkImageProvider(comment.authorPhotoUrl!)
              : null,
          child:
              comment.authorPhotoUrl == null || comment.authorPhotoUrl!.isEmpty
                  ? const Icon(Icons.person, size: 18)
                  : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  comment.authorName?.trim().isNotEmpty == true
                      ? comment.authorName!
                      : 'Пользователь',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(comment.content),
                const SizedBox(height: 6),
                Text(
                  DateFormat('d MMM в HH:mm', 'ru').format(comment.createdAt),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PostMetaChip extends StatelessWidget {
  const _PostMetaChip({
    required this.icon,
    required this.label,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: highlighted
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 12,
            color: highlighted
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: highlighted
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
