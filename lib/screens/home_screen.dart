// ignore_for_file: library_private_types_in_public_api
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../providers/tree_provider.dart';
import '../services/event_service.dart';
import '../models/app_event.dart';

import '../widgets/event_card.dart';
import 'package:get_it/get_it.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/models/tree_invitation.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/post_service_interface.dart';
import '../models/post.dart';
import '../widgets/post_card.dart';
import '../widgets/post_card_shimmer.dart';
import '../widgets/empty_state_widget.dart';
import '../services/custom_api_notification_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final FamilyTreeServiceInterface _familyTreeService =
      GetIt.I<FamilyTreeServiceInterface>();
  final PostServiceInterface _postService = GetIt.I<PostServiceInterface>();
  late final EventService _eventService;

  List<AppEvent> _upcomingEvents = [];
  List<Post> _posts = [];
  bool _isLoadingEvents = true;
  bool _isLoadingPosts = false;
  bool _postsUnavailable = false;
  String? _currentTreeId;
  TreeProvider? _treeProviderInstance;

  CustomApiNotificationService? get _customNotificationService =>
      GetIt.I.isRegistered<CustomApiNotificationService>()
          ? GetIt.I<CustomApiNotificationService>()
          : null;

  @override
  void initState() {
    super.initState();
    _eventService = EventService();

    final notificationService = _customNotificationService;
    if (notificationService != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        notificationService.refreshUnreadNotificationsCount();
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _treeProviderInstance = Provider.of<TreeProvider>(context, listen: false);
      _treeProviderInstance!.addListener(_handleTreeChange);
      _currentTreeId = _treeProviderInstance!.selectedTreeId;
      if (_currentTreeId != null) {
        _loadEvents(_currentTreeId!);
        _loadPosts(_currentTreeId!);
      } else {
        setState(() {
          _isLoadingEvents = false;
          _isLoadingPosts = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _treeProviderInstance?.removeListener(_handleTreeChange);
    super.dispose();
  }

  void _handleTreeChange() {
    if (!mounted) return;
    final newTreeId = _treeProviderInstance?.selectedTreeId;
    if (_currentTreeId != newTreeId) {
      _currentTreeId = newTreeId;
      if (_currentTreeId != null) {
        _loadEvents(_currentTreeId!);
        _loadPosts(_currentTreeId!);
      } else {
        setState(() {
          _isLoadingEvents = false;
          _isLoadingPosts = false;
          _upcomingEvents = [];
          _posts = [];
        });
      }
    }
  }

  Future<void> _loadEvents(String treeId) async {
    if (!mounted) return;
    setState(() {
      _isLoadingEvents = true;
      _upcomingEvents = [];
    });
    try {
      final events = await _eventService.getUpcomingEvents(treeId, limit: 5);
      if (mounted) {
        setState(() {
          _upcomingEvents = events;
          _isLoadingEvents = false;
        });
      }
    } catch (e) {
      debugPrint('Ошибка загрузки событий: $e');
      if (mounted) {
        setState(() {
          _isLoadingEvents = false;
        });
      }
    }
  }

  Future<void> _loadPosts(String treeId) async {
    if (!mounted) return;
    setState(() {
      _isLoadingPosts = true;
      _postsUnavailable = false;
    });
    try {
      final posts = await _postService.getPosts(treeId: treeId);
      if (mounted) {
        setState(() {
          _posts = posts;
          _isLoadingPosts = false;
        });
      }
    } catch (e) {
      debugPrint('Ошибка загрузки постов: $e');
      if (mounted) {
        setState(() {
          _postsUnavailable = true;
          _posts = [];
          _isLoadingPosts = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedTreeName = Provider.of<TreeProvider>(
      context,
    ).selectedTreeName;

    return Scaffold(
      appBar: AppBar(
        title: Text(selectedTreeName ?? 'Главная'),
        actions: [
          _buildNotificationsAction(),
          IconButton(
            icon: const Icon(Icons.account_tree_outlined),
            tooltip: 'Выбрать дерево',
            onPressed: () => context.go('/tree?selector=1'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _customNotificationService?.refreshUnreadNotificationsCount();
          if (_currentTreeId != null) {
            await Future.wait([
              _loadEvents(_currentTreeId!),
              _loadPosts(_currentTreeId!),
            ]);
          }
        },
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1400),
            child: StreamBuilder<List<TreeInvitation>>(
              stream: _familyTreeService.getPendingTreeInvitations(),
              builder: (context, snapshot) {
                final pendingInvitations =
                    snapshot.data ?? const <TreeInvitation>[];
                return CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 24,
                        ),
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.05),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 30,
                              backgroundImage:
                                  _authService.currentUserPhotoUrl != null
                                      ? NetworkImage(
                                          _authService.currentUserPhotoUrl!,
                                        )
                                      : null,
                              backgroundColor: Theme.of(context).primaryColor,
                              child: _authService.currentUserPhotoUrl == null
                                  ? const Icon(
                                      Icons.person,
                                      size: 30,
                                      color: Colors.white,
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Привет, ${_authService.currentUserDisplayName ?? 'пользователь'}!',
                                    style:
                                        Theme.of(context).textTheme.titleLarge,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Добро пожаловать в Родню',
                                    style:
                                        Theme.of(context).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (pendingInvitations.isNotEmpty)
                      SliverToBoxAdapter(
                        child:
                            _buildPendingInvitationsBanner(pendingInvitations),
                      ),
                    if (_currentTreeId == null) ...[
                      SliverToBoxAdapter(child: _buildNoTreeSelectedHero()),
                      SliverToBoxAdapter(
                        child: _buildNoTreeSelectedNextSteps(),
                      ),
                    ] else ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                          child: _isWideHomeLayout(context)
                              ? Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: 360,
                                      child: Column(
                                        children: [
                                          _buildUpcomingEventsSection(),
                                          const SizedBox(height: 16),
                                          _buildQuickActionsCard(),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(child: _buildFeedContent()),
                                  ],
                                )
                              : Column(
                                  children: [
                                    _buildUpcomingEventsSection(),
                                    const SizedBox(height: 16),
                                    _buildFeedContent(),
                                  ],
                                ),
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 80)),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
      floatingActionButton: _currentTreeId == null
          ? null
          : FloatingActionButton(
              onPressed: () async {
                final result = await context.push('/post/create');
                if (result == true && _currentTreeId != null) {
                  _loadPosts(_currentTreeId!);
                }
              },
              tooltip: 'Разместить публикацию',
              child: const Icon(Icons.add_comment_outlined),
            ),
    );
  }

  Widget _buildNotificationsAction() {
    final notificationService = _customNotificationService;
    if (notificationService == null) {
      return IconButton(
        icon: const Icon(Icons.notifications_outlined),
        tooltip: 'Активность',
        onPressed: () => context.push('/notifications'),
      );
    }

    return StreamBuilder<int>(
      stream: notificationService.unreadNotificationsCountStream,
      initialData: notificationService.unreadNotificationsCount,
      builder: (context, snapshot) {
        final unreadCount = snapshot.data ?? 0;
        final icon = unreadCount > 0
            ? Badge(
                label: Text(unreadCount > 99 ? '99+' : unreadCount.toString()),
                child: const Icon(Icons.notifications_outlined),
              )
            : const Icon(Icons.notifications_outlined);

        return IconButton(
          icon: icon,
          tooltip:
              unreadCount > 0 ? 'Активность, $unreadCount новых' : 'Активность',
          onPressed: () => context.push('/notifications'),
        );
      },
    );
  }

  bool _isWideHomeLayout(BuildContext context) =>
      MediaQuery.of(context).size.width >= 1180;

  Widget _buildDesktopSideCard({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(18),
  }) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: child,
    );
  }

  Widget _buildFeedContent() {
    if (_isLoadingPosts && _posts.isEmpty) {
      return Column(
        children: List.generate(3, (_) => const PostCardShimmer()),
      );
    }

    if (_posts.isEmpty) {
      return EmptyStateWidget(
        icon: Icons.post_add_outlined,
        title: _postsUnavailable
            ? 'Публикации временно недоступны'
            : 'Здесь пока пусто',
        message: _postsUnavailable
            ? 'Backend ленты пока не отвечает для этого дерева. Основные разделы работают, а публикации нужно восстановить отдельно.'
            : 'Будьте первым, кто поделится историей или новостью в этом семейном дереве!',
        actionLabel: _postsUnavailable ? 'Обновить' : 'Создать публикацию',
        onAction: () async {
          if (_postsUnavailable) {
            if (_currentTreeId != null) {
              _loadPosts(_currentTreeId!);
            }
            return;
          }
          final result = await context.push('/post/create');
          if (result == true && _currentTreeId != null) {
            _loadPosts(_currentTreeId!);
          }
        },
      );
    }

    return Column(
      children: _posts
          .map(
            (post) => PostCard(
              post: post,
              onDeleted: () {
                if (_currentTreeId != null) {
                  _loadPosts(_currentTreeId!);
                }
              },
            ),
          )
          .toList(),
    );
  }

  Widget _buildQuickActionsCard() {
    final theme = Theme.of(context);
    return _buildDesktopSideCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Быстрые действия',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          _buildQuickActionTile(
            icon: Icons.post_add_outlined,
            title: 'Новая публикация',
            subtitle: 'Добавить новость, историю или фотографии семьи.',
            onTap: () => context.push('/post/create'),
          ),
          const SizedBox(height: 10),
          _buildQuickActionTile(
            icon: Icons.people_outline,
            title: 'Раздел родных',
            subtitle: 'Перейти к родственникам и пригласить новых людей.',
            onTap: () => context.go('/relatives'),
          ),
          const SizedBox(height: 10),
          _buildQuickActionTile(
            icon: Icons.account_tree_outlined,
            title: 'Сменить дерево',
            subtitle: 'Быстро переключиться на другое активное дерево.',
            onTap: () => context.go('/tree?selector=1'),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Ink(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.45,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoTreeSelectedHero() {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.primary.withValues(alpha: 0.92),
              theme.colorScheme.primaryContainer,
            ],
          ),
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.primary.withValues(alpha: 0.18),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(
                Icons.account_tree_outlined,
                color: Colors.white,
                size: 28,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Сначала выберите дерево',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'После выбора откроются события семьи, родственники, личные связи и контент дерева. Если дерева ещё нет, создайте новое прямо сейчас.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: Colors.white.withValues(alpha: 0.92),
                height: 1.45,
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () => context.go('/tree?selector=1'),
                  icon: const Icon(Icons.account_tree),
                  label: const Text('Выбрать дерево'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: theme.colorScheme.primary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 16,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => context.push('/trees/create'),
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('Создать дерево'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white38),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 16,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingInvitationsBanner(List<TreeInvitation> invitations) {
    final theme = Theme.of(context);
    final count = invitations.length;
    final firstTreeName = invitations.first.tree.name.trim();
    final title = count == 1
        ? 'Вас ждёт приглашение в дерево'
        : 'У вас $count приглашения в деревья';
    final description = count == 1 && firstTreeName.isNotEmpty
        ? 'Откройте "$firstTreeName", чтобы оно появилось в вашем списке деревьев.'
        : 'Перейдите к приглашениям и примите нужное дерево без лишнего поиска.';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: theme.colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onTertiaryContainer.withValues(
                      alpha: 0.08,
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.mark_email_unread_outlined,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () => context.go('/trees?tab=invitations'),
              icon: const Icon(Icons.arrow_forward),
              label: Text(
                  count == 1 ? 'Открыть приглашение' : 'Открыть приглашения'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoTreeSelectedNextSteps() {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Что будет дальше',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            _buildNextStepRow(
              icon: Icons.event_outlined,
              title: 'Главная наполнится событиями',
              subtitle: 'Ближайшие дни рождения и важные семейные даты.',
            ),
            const SizedBox(height: 10),
            _buildNextStepRow(
              icon: Icons.people_outline,
              title: 'Раздел родных станет активным',
              subtitle: 'Можно будет открывать карточки и расширять дерево.',
            ),
            const SizedBox(height: 10),
            _buildNextStepRow(
              icon: Icons.chat_bubble_outline,
              title: 'Чаты и личные связи останутся под рукой',
              subtitle: 'После выбора дерева проще переходить к нужным людям.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNextStepRow({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: theme.colorScheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildUpcomingEventsSection() {
    return _buildDesktopSideCard(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Ближайшие события',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 6),
          if (_isLoadingEvents)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_upcomingEvents.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('Нет ближайших событий'),
            )
          else
            SizedBox(
              height: 160,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _upcomingEvents.length,
                itemBuilder: (context, index) {
                  return EventCard(event: _upcomingEvents[index]);
                },
              ),
            ),
        ],
      ),
    );
  }
}
