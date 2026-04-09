import 'package:cached_network_image/cached_network_image.dart';
import 'package:carousel_slider/carousel_slider.dart';
import 'package:flutter/material.dart' hide CarouselController;
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/post_service_interface.dart';
import '../models/post.dart';
import 'comment_sheet.dart';

class PostCard extends StatefulWidget {
  const PostCard({super.key, required this.post, this.onDeleted});

  final Post post;
  final VoidCallback? onDeleted;

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard>
    with SingleTickerProviderStateMixin {
  final String? _currentUserId = GetIt.I<AuthServiceInterface>().currentUserId;
  final PostServiceInterface _postService = GetIt.I<PostServiceInterface>();

  late bool _isLikedByCurrentUser;
  late int _likeCount;
  late int _commentCount;

  late AnimationController _likeAnimationController;
  late Animation<double> _likeScaleAnimation;

  @override
  void initState() {
    super.initState();
    _syncLocalState();
    _likeAnimationController = AnimationController(
        duration: const Duration(milliseconds: 200), vsync: this);
    _likeScaleAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.3), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.3, end: 1.0), weight: 50),
    ]).animate(CurvedAnimation(
        parent: _likeAnimationController, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _likeAnimationController.dispose();
    super.dispose();
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
    if (_currentUserId == null) return;

    final wasLiked = _isLikedByCurrentUser;
    setState(() {
      _isLikedByCurrentUser = !wasLiked;
      _likeCount += wasLiked ? -1 : 1;
    });

    if (!wasLiked) {
      _likeAnimationController.forward(from: 0);
    }

    try {
      await _postService.toggleLike(widget.post.id);
    } catch (e) {
      // Revert on error
      setState(() {
        _isLikedByCurrentUser = wasLiked;
        _likeCount = wasLiked ? _likeCount + 1 : _likeCount - 1;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка при лайке: $e')),
        );
      }
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
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => CommentSheet(post: widget.post),
    );

    if (result == true) {
      // If comments were added/deleted, we might want to refresh counts
      // For now, we assume the parent feed will refresh or we just keep local count if possible
    }
  }

  Future<void> _deletePost() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить публикацию?'),
        content: const Text('Это действие нельзя будет отменить.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _postService.deletePost(widget.post.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Публикация удалена')),
          );
          if (widget.onDeleted != null) {
            widget.onDeleted!();
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ошибка при удалении: $e')),
          );
        }
      }
    }
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
              backgroundColor: Colors.grey.shade200,
              child: widget.post.authorPhotoUrl == null ||
                      widget.post.authorPhotoUrl!.isEmpty
                  ? const Icon(Icons.person, size: 20, color: Colors.grey)
                  : null,
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
          if (_currentUserId == widget.post.authorId)
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, color: Colors.grey.shade600),
              onSelected: (value) {
                if (value == 'delete') {
                  _deletePost();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline, color: Colors.red, size: 20),
                      SizedBox(width: 8),
                      Text('Удалить', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ],
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
            icon: ScaleTransition(
              scale: _likeScaleAnimation,
              child: Icon(
                _isLikedByCurrentUser ? Icons.favorite : Icons.favorite_border,
                color: _isLikedByCurrentUser
                    ? Colors.redAccent
                    : Colors.grey.shade600,
                size: 20,
              ),
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
