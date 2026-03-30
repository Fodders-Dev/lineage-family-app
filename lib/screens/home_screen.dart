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
import '../widgets/post_card.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../services/sync_service.dart';

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

  @override
  void initState() {
    super.initState();
    _supportsLegacyPostFeed = GetIt.I.isRegistered<SyncService>();
    _eventService = EventService();
    if (_supportsLegacyPostFeed) {
      _postService = PostService();
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
          IconButton(
            icon: Icon(Icons.account_tree_outlined),
            tooltip: 'Выбрать дерево',
            onPressed: () => context.go('/tree?selector=1'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          if (_currentTreeId != null) {
            await _loadEvents(_currentTreeId!);
            await _loadBranchPeople(_currentTreeId!);
          }
        },
        child: CustomScrollView(
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
                      backgroundImage: _authService.currentUserPhotoUrl != null
                          ? NetworkImage(_authService.currentUserPhotoUrl!)
                          : null,
                      child: _authService.currentUserPhotoUrl == null
                          ? Icon(Icons.person, size: 30, color: Colors.white)
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
            SliverToBoxAdapter(child: _buildStoriesSection()),
            SliverToBoxAdapter(child: _buildUpcomingEventsSection()),
            ..._buildPostSlivers(),
          ],
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
                  'Лента новостей',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Для текущего backend-режима общая лента дерева ещё не подключена. Профиль, дерево и личные сообщения доступны.',
                  style: Theme.of(context).textTheme.bodyMedium,
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
