import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../services/post_service.dart';
import '../models/post.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../providers/tree_provider.dart';
import '../services/event_service.dart';
import '../models/app_event.dart';
import '../models/family_person.dart';
import '../widgets/event_card.dart';
import 'package:get_it/get_it.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/models/tree_invitation.dart';
import '../widgets/post_card.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../services/sync_service.dart';
import '../services/browser_notification_bridge.dart';
import '../services/custom_api_notification_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final FamilyTreeServiceInterface _familyTreeService =
      GetIt.I<FamilyTreeServiceInterface>();
  late final EventService _eventService;
  PostService? _postService;
  late final bool _supportsLegacyPostFeed;
  List<AppEvent> _upcomingEvents = [];
  List<FamilyPerson> _branchPeople = [];
  bool _isLoadingEvents = true;
  bool _isLoadingBranchPeople = false;
  String? _currentTreeId;
  TreeProvider? _treeProviderInstance;
  String? _selectedFeedBranchPersonId;
  bool _isEnablingBrowserNotifications = false;

  CustomApiNotificationService? get _customNotificationService =>
      GetIt.I.isRegistered<CustomApiNotificationService>()
          ? GetIt.I<CustomApiNotificationService>()
          : null;

  @override
  void initState() {
    super.initState();
    _supportsLegacyPostFeed = GetIt.I.isRegistered<SyncService>();
    _eventService = EventService();
    if (_supportsLegacyPostFeed) {
      _postService = PostService();
    }
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
        _loadBranchPeople(_currentTreeId!);
      } else {
        setState(() {
          _isLoadingEvents = false;
          _branchPeople = [];
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
      print(
        'HomeScreen: Обнаружено изменение дерева с $_currentTreeId на $newTreeId',
      );
      _currentTreeId = newTreeId;
      if (_currentTreeId != null) {
        _loadEvents(_currentTreeId!);
        _loadBranchPeople(_currentTreeId!);
      } else {
        setState(() {
          _isLoadingEvents = false;
          _upcomingEvents = [];
          _branchPeople = [];
          _selectedFeedBranchPersonId = null;
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
      print('Ошибка загрузки событий: $e');
      if (mounted) {
        setState(() {
          _isLoadingEvents = false;
        });
      }
    }
  }

  Future<void> _loadBranchPeople(String treeId) async {
    if (!_supportsLegacyPostFeed || !mounted) {
      return;
    }

    setState(() {
      _isLoadingBranchPeople = true;
      _branchPeople = [];
      _selectedFeedBranchPersonId = null;
    });

    try {
      final people = await _familyTreeService.getRelatives(treeId);
      if (!mounted) {
        return;
      }
      final sortedPeople = List<FamilyPerson>.from(people)
        ..sort(
          (left, right) => left.displayName.toLowerCase().compareTo(
                right.displayName.toLowerCase(),
              ),
        );
      setState(() {
        _branchPeople = sortedPeople;
        _isLoadingBranchPeople = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoadingBranchPeople = false;
        _branchPeople = [];
      });
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
            icon: Icon(Icons.account_tree_outlined),
            tooltip: 'Выбрать дерево',
            onPressed: () => context.go('/tree?selector=1'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _customNotificationService?.refreshUnreadNotificationsCount();
          if (_currentTreeId != null) {
            await _loadEvents(_currentTreeId!);
            await _loadBranchPeople(_currentTreeId!);
          }
        },
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
                          child: _authService.currentUserPhotoUrl == null
                              ? Icon(
                                  Icons.person,
                                  size: 30,
                                  color: Colors.white,
                                )
                              : null,
                          backgroundColor: Theme.of(context).primaryColor,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Привет, ${_authService.currentUserDisplayName ?? 'пользователь'}!',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Добро пожаловать в Родню',
                                style: Theme.of(context).textTheme.bodyMedium,
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
                    child: _buildPendingInvitationsBanner(pendingInvitations),
                  ),
                if (_shouldShowBrowserNotificationPrompt)
                  SliverToBoxAdapter(
                    child: _buildBrowserNotificationsPrompt(),
                  ),
                if (_currentTreeId == null) ...[
                  SliverToBoxAdapter(child: _buildNoTreeSelectedHero()),
                  SliverToBoxAdapter(child: _buildNoTreeSelectedNextSteps()),
                ] else ...[
                  if (_supportsLegacyPostFeed)
                    SliverToBoxAdapter(child: _buildStoriesSection()),
                  SliverToBoxAdapter(child: _buildUpcomingEventsSection()),
                  ..._buildPostSlivers(),
                ],
              ],
            );
          },
        ),
      ),
      floatingActionButton: _supportsLegacyPostFeed
          ? _currentTreeId == null
              ? null
              : FloatingActionButton(
                  onPressed: () {
                    context.push('/post/create');
                  },
                  tooltip: 'Создать пост',
                  child: const Icon(Icons.add_photo_alternate_outlined),
                )
          : null,
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
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: const [
                _HomePill(label: 'События семьи'),
                _HomePill(label: 'Родственники'),
                _HomePill(label: 'Личные связи'),
                _HomePill(label: 'Публичный web-вход'),
              ],
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

  bool get _shouldShowBrowserNotificationPrompt {
    final notificationService = _customNotificationService;
    if (notificationService == null) {
      return false;
    }

    if (!notificationService.notificationsEnabled) {
      return true;
    }

    if (!kIsWeb) {
      return false;
    }

    final permissionStatus = notificationService.browserPermissionStatus;
    if (permissionStatus == BrowserNotificationPermissionStatus.unsupported) {
      return false;
    }

    return permissionStatus != BrowserNotificationPermissionStatus.granted;
  }

  Widget _buildBrowserNotificationsPrompt() {
    final notificationService = _customNotificationService;
    if (notificationService == null) {
      return const SizedBox.shrink();
    }

    final permissionStatus = notificationService.browserPermissionStatus;
    final theme = Theme.of(context);
    final title =
        kIsWeb && permissionStatus == BrowserNotificationPermissionStatus.denied
            ? 'Уведомления в браузере отключены'
            : 'Включите уведомления о семье';
    final description = kIsWeb &&
            permissionStatus == BrowserNotificationPermissionStatus.denied
        ? 'Без разрешения браузера можно пропустить новое сообщение или приглашение в дерево.'
        : 'Родня сможет сразу показать новые сообщения, приглашения в дерево и важные семейные события.';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.notifications_active_outlined,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: TextStyle(
                color: theme.colorScheme.onSecondaryContainer,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _isEnablingBrowserNotifications
                  ? null
                  : _enableBrowserNotifications,
              icon: _isEnablingBrowserNotifications
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.notifications_outlined),
              label: const Text('Включить уведомления'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _enableBrowserNotifications() async {
    final notificationService = _customNotificationService;
    if (notificationService == null) {
      return;
    }

    setState(() {
      _isEnablingBrowserNotifications = true;
    });

    try {
      final enabled = await notificationService.setNotificationsEnabled(
        true,
        promptForBrowserPermission: true,
      );
      if (!mounted) {
        return;
      }

      final message = enabled
          ? 'Уведомления включены. Родня сможет показать новые сообщения и приглашения.'
          : 'Браузер не дал разрешение на уведомления. Это можно изменить позже в настройках браузера.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      setState(() {});
    } finally {
      if (mounted) {
        setState(() {
          _isEnablingBrowserNotifications = false;
        });
      }
    }
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

  Widget _buildStoriesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, top: 16, right: 16),
          child: Text(
            'Истории',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
        SizedBox(height: 8),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.auto_stories_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Истории пока недоступны',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Для текущего backend-режима stories ещё не подключены. Дерево, профиль и чат работают отдельно от этой секции.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Divider(),
      ],
    );
  }

  Widget _buildUpcomingEventsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            'Ближайшие события',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
        _buildEventsSection(),
        Divider(),
      ],
    );
  }

  Widget _buildEventsSection() {
    if (_isLoadingEvents) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_upcomingEvents.isEmpty && _currentTreeId != null) {
      return Container(
        height: 120,
        alignment: Alignment.center,
        child: Text(
          'Нет предстоящих событий',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    if (_upcomingEvents.isEmpty && _currentTreeId == null) {
      return Container(
        height: 120,
        alignment: Alignment.center,
        child: Text(
          'Выберите дерево для просмотра событий',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return SizedBox(
      height: 120,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10.0),
        itemCount: _upcomingEvents.length,
        itemBuilder: (context, index) {
          final event = _upcomingEvents[index];
          return EventCard(event: event);
        },
      ),
    );
  }

  List<Widget> _buildPostSlivers() {
    if (_supportsLegacyPostFeed) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Лента новостей',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  icon: Icon(Icons.add_circle_outline),
                  onPressed: _currentTreeId == null
                      ? null
                      : () async {
                          final result = await context.push('/post/create');
                          if (!mounted) {
                            return;
                          }
                          if (result == true) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text('Публикация создана успешно')),
                            );
                          }
                        },
                ),
              ],
            ),
          ),
        ),
        if (_currentTreeId != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _buildFeedFilterCard(),
            ),
          ),
        _buildPostsFeed(),
      ];
    }

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Главное по семье',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Отсюда удобно переходить в дерево, к родственникам и в личные сообщения.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: () => context.go('/tree'),
                      icon: const Icon(Icons.account_tree_outlined),
                      label: const Text('Открыть дерево'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => context.go('/relatives'),
                      icon: const Icon(Icons.people_alt_outlined),
                      label: const Text('Родные'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => context.go('/chats'),
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('Сообщения'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  Widget _buildPostsFeed() {
    final postService = _postService;
    if (postService == null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    if (_currentTreeId == null) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 50.0),
          child: Center(
            child: Text(
              'Выберите дерево, чтобы увидеть ленту',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ),
      );
    }

    return StreamBuilder<List<Post>>(
      stream: postService.getPostsStream(_currentTreeId!),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SliverToBoxAdapter(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(50.0),
                child: CircularProgressIndicator(),
              ),
            ),
          );
        }
        if (snapshot.hasError) {
          print('Ошибка в StreamBuilder постов: ${snapshot.error}');
          return SliverToBoxAdapter(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Ошибка загрузки ленты: ${snapshot.error}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ),
          );
        }
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const SliverToBoxAdapter(
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 50.0),
                child: Text(
                  'В этом дереве пока нет постов.',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ),
          );
        }

        final posts = _applyBranchFilter(snapshot.data!);
        if (posts.isEmpty) {
          return const SliverToBoxAdapter(
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 50.0),
                child: Text(
                  'Для выбранной ветки публикаций пока нет.',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ),
          );
        }
        return SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            return PostCard(post: posts[index]);
          }, childCount: posts.length),
        );
      },
    );
  }

  List<Post> _applyBranchFilter(List<Post> posts) {
    final selectedBranchPersonId = _selectedFeedBranchPersonId;
    if (selectedBranchPersonId == null || selectedBranchPersonId.isEmpty) {
      return posts;
    }

    return posts.where((post) {
      if (post.scopeType == TreeContentScopeType.wholeTree) {
        return true;
      }
      return post.anchorPersonIds.contains(selectedBranchPersonId);
    }).toList();
  }

  Widget _buildFeedFilterCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Фильтр ленты',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Можно оставить всю ленту дерева или смотреть публикации по выбранной ветке.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          if (_isLoadingBranchPeople)
            const Center(child: CircularProgressIndicator())
          else if (_branchPeople.isEmpty)
            Text(
              'В дереве пока нет веток для отдельной фильтрации.',
              style: Theme.of(context).textTheme.bodyMedium,
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Все ветки'),
                  selected: _selectedFeedBranchPersonId == null,
                  onSelected: (_) {
                    setState(() {
                      _selectedFeedBranchPersonId = null;
                    });
                  },
                ),
                ..._branchPeople.map(
                  (person) => ChoiceChip(
                    label: Text(person.displayName),
                    selected: _selectedFeedBranchPersonId == person.id,
                    onSelected: (_) {
                      setState(() {
                        _selectedFeedBranchPersonId =
                            _selectedFeedBranchPersonId == person.id
                                ? null
                                : person.id;
                      });
                    },
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _HomePill extends StatelessWidget {
  const _HomePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
