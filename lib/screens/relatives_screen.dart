import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'package:get_it/get_it.dart';
import 'package:intl/intl.dart';

import '../models/family_person.dart';
import '../models/family_relation.dart';
import '../models/chat_preview.dart';
import '../providers/tree_provider.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/chat_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../services/crashlytics_service.dart';

class RelativesScreen extends StatefulWidget {
  const RelativesScreen({super.key});

  @override
  State<RelativesScreen> createState() => _RelativesScreenState();
}

class _RelativesScreenState extends State<RelativesScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final FamilyTreeServiceInterface _familyService =
      GetIt.I<FamilyTreeServiceInterface>();
  final ChatServiceInterface _chatService = GetIt.I<ChatServiceInterface>();
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final CrashlyticsService _crashlyticsService = CrashlyticsService();

  StreamSubscription? _relativesSubscription;
  StreamSubscription? _relationsSubscription;
  StreamSubscription? _chatsSubscription;
  TreeProvider? _treeProviderInstance;

  bool _isLoading = true;
  String? _currentTreeId;
  String? _currentUserId;
  String _errorMessage = '';
  int _pendingRequestsCount = 0;
  List<FamilyPerson> _allRelatives = [];
  List<FamilyRelation> _relations = [];
  String? _currentUserPersonId;
  List<ChatPreview> _chatPreviews = [];

  @override
  void initState() {
    super.initState();

    debugPrint('[_RelativesScreenState initState] called');
    _tabController = TabController(length: 2, vsync: this);
    debugPrint(
      '[_RelativesScreenState initState] TabController initialized: ${_tabController.length} tabs',
    );

    _currentUserId = _authService.currentUserId;
    debugPrint(
      '[_RelativesScreenState initState] Current User ID: $_currentUserId',
    );

    if (_currentUserId == null) {
      debugPrint('Ошибка: Пользователь не аутентифицирован!');
      setState(() {
        _isLoading = false;
        _errorMessage = 'Пользователь не аутентифицирован.';
      });
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _treeProviderInstance = Provider.of<TreeProvider>(context, listen: false);
      _treeProviderInstance!.addListener(_handleTreeChange);
      _currentTreeId = _treeProviderInstance!.selectedTreeId;
      if (_currentTreeId != null) {
        _loadDataForSelectedTree(_currentTreeId!);
      } else {
        setState(() {
          _isLoading = false;
        });
      }
      debugPrint(
        '[_RelativesScreenState initState] TabController initialized: ${_tabController.length} tabs',
      );
    });
  }

  @override
  void dispose() {
    _cancelSubscriptions();
    _treeProviderInstance?.removeListener(_handleTreeChange);
    _tabController.dispose();
    super.dispose();
  }

  void _handleTreeChange() {
    if (!mounted) return;
    final newTreeId = _treeProviderInstance?.selectedTreeId;
    if (_currentTreeId != newTreeId) {
      _currentTreeId = newTreeId;
      _cancelSubscriptions();
      if (_currentTreeId != null) {
        _loadDataForSelectedTree(_currentTreeId!);
      } else {
        setState(() {
          _isLoading = false;
          _allRelatives = [];
          _relations = [];
          _currentUserPersonId = null;
          _chatPreviews = [];
          _pendingRequestsCount = 0;
          _errorMessage = '';
        });
      }
    }
  }

  Future<void> _loadDataForSelectedTree(String treeId) async {
    if (!mounted || _currentUserId == null) return;
    debugPrint('RelativesScreen: Загрузка данных для дерева $treeId');
    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _allRelatives = [];
      _relations = [];
      _currentUserPersonId = null;
      _chatPreviews = [];
      _pendingRequestsCount = 0;
    });

    try {
      await Future.wait([
        _checkPendingRequests(treeId),
        _setupDataListeners(treeId, _currentUserId!),
      ]);
    } catch (e) {
      debugPrint('Ошибка при инициализации данных для дерева $treeId: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Ошибка загрузки данных дерева.';
        });
      }
    }
  }

  Future<void> _checkPendingRequests(String treeId) async {
    try {
      final requests = await _familyService.getRelationRequests(treeId: treeId);
      if (mounted) {
        setState(() {
          _pendingRequestsCount = requests.length;
        });
      }
    } catch (e) {
      debugPrint('Ошибка проверки запросов: $e');
    }
  }

  Future<void> _setupDataListeners(String treeId, String currentUserId) async {
    _cancelSubscriptions();

    debugPrint('RelativesScreen: Настройка слушателей для дерева $treeId');

    final completerRelatives = Completer<void>();
    final completerRelations = Completer<void>();
    final completerChats = Completer<void>();

    _relativesSubscription = _familyService.getRelativesStream(treeId).listen(
      (relatives) {
        String? currentUserPersonId;
        for (final person in relatives) {
          if (person.userId == _currentUserId) {
            currentUserPersonId = person.id;
            break;
          }
        }

        if (mounted) {
          setState(() {
            _allRelatives = relatives;
            _currentUserPersonId = currentUserPersonId;
            _errorMessage = '';
            debugPrint('Получено родственников: ${relatives.length}');
          });
          if (!completerRelatives.isCompleted) completerRelatives.complete();
        }
      },
      onError: (error, stackTrace) {
        if (mounted) {
          _handleStreamError(
            error,
            stackTrace,
            'RelativesStreamError',
            completerRelatives,
          );
        }
      },
      onDone: () => debugPrint('Stream родственников завершен'),
      cancelOnError: false,
    );

    _relationsSubscription = _familyService.getRelationsStream(treeId).listen(
      (relations) {
        if (mounted) {
          setState(() {
            _relations = relations;
            debugPrint('Получено связей: ${relations.length}');
          });
          if (!completerRelations.isCompleted) completerRelations.complete();
        }
      },
      onError: (error, stackTrace) {
        if (mounted) {
          debugPrint('Ошибка в Stream связей: $error');
          _handleStreamError(
            error,
            stackTrace,
            'RelationsStreamError',
            completerRelations,
          );
        }
      },
      onDone: () => debugPrint('Stream связей завершен'),
      cancelOnError: false,
    );

    _chatsSubscription = _chatService.getUserChatsStream(currentUserId).listen(
      (chatPreviews) {
        if (mounted) {
          setState(() {
            _chatPreviews = chatPreviews;
            debugPrint('Получено превью чатов: ${chatPreviews.length}');
          });
          if (!completerChats.isCompleted) completerChats.complete();
        }
      },
      onError: (error, stackTrace) {
        if (mounted) {
          debugPrint('Ошибка в Stream чатов: $error');
          _handleStreamError(
            error,
            stackTrace,
            'ChatsStreamError',
            completerChats,
          );
        }
      },
      onDone: () => debugPrint('Stream чатов завершен'),
      cancelOnError: false,
    );

    try {
      await Future.wait([
        completerRelatives.future,
        completerRelations.future,
        completerChats.future,
      ]).timeout(const Duration(seconds: 20));
      if (mounted && _isLoading) {
        setState(() {
          _isLoading = false;
        });
        debugPrint('Все данные загружены (Future.wait успешно завершен).');
      }
    } catch (e, stackTrace) {
      debugPrint('Ошибка или таймаут при ожидании данных: $e');
      _crashlyticsService.logError(
        e,
        stackTrace,
        reason: 'DataListenersTimeoutOrError',
      );
      if (mounted && _isLoading) {
        setState(() {
          _isLoading = false;
          if (_errorMessage.isEmpty) {
            _errorMessage =
                'Не удалось загрузить все данные. Проверьте соединение.';
          }
        });
      }
    }
  }

  void _cancelSubscriptions() {
    _relativesSubscription?.cancel();
    _relationsSubscription?.cancel();
    _chatsSubscription?.cancel();
    _relativesSubscription = null;
    _relationsSubscription = null;
    _chatsSubscription = null;
    debugPrint('RelativesScreen: Подписки на данные отменены');
  }

  @override
  Widget build(BuildContext context) {
    final treeProvider = Provider.of<TreeProvider>(context);
    final selectedTreeId = treeProvider.selectedTreeId;
    final selectedTreeName = treeProvider.selectedTreeName ?? 'Родственники';

    // --- ФИЛЬТРАЦИЯ СПИСКОВ ---
    final String currentUserId = _authService.currentUserId ?? '';
    final List<FamilyPerson> visibleRelatives =
        _allRelatives.where((p) => p.userId != currentUserId).toList();
    final List<FamilyPerson> onlineRelatives = _allRelatives
        .where((p) => p.userId != null && p.userId != currentUserId)
        .toList();
    // -------------------------

    return Scaffold(
      appBar: AppBar(
        title: Text(selectedTreeName),
        actions: [
          IconButton(
            icon: Icon(Icons.account_tree_outlined),
            tooltip: 'Выбрать другое дерево',
            onPressed: () {
              context.go('/tree?selector=1');
            },
          ),
          if (_pendingRequestsCount > 0)
            Badge(
              label: Text(_pendingRequestsCount.toString()),
              child: IconButton(
                icon: Icon(Icons.notifications_none),
                tooltip: 'Запросы на родство ($_pendingRequestsCount)',
                onPressed: selectedTreeId == null
                    ? null
                    : () {
                        context.push('/relatives/requests/$selectedTreeId');
                      },
              ),
            ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (selectedTreeId == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Сначала выберите дерево')),
                );
                return;
              }

              if (value == 'add') {
                context.push('/relatives/add/$selectedTreeId');
              } else if (value == 'find') {
                context.push('/relatives/find/$selectedTreeId');
              } else if (value == 'tree_view') {
                final nameParam = Uri.encodeComponent(
                  treeProvider.selectedTreeName ?? 'Семейное дерево',
                );
                context.push('/tree/view/$selectedTreeId?name=$nameParam');
              } else if (value == 'create_tree') {
                context.push('/trees/create').then((result) {
                  // Можно опционально перейти на новый экран дерева после создания
                });
              } else if (value == 'requests_menu') {
                context.push('/relatives/requests/$selectedTreeId');
              }
            },
            itemBuilder: (BuildContext context) => [
              PopupMenuItem<String>(
                value: 'add',
                enabled: selectedTreeId != null,
                child: ListTile(
                  leading: Icon(Icons.person_add),
                  title: Text('Добавить родственника'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem<String>(
                value: 'create_tree',
                child: ListTile(
                  leading: Icon(Icons.add_circle_outline),
                  title: Text('Создать новое дерево'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem<String>(
                value: 'tree_view',
                enabled: selectedTreeId != null,
                child: ListTile(
                  leading: Icon(Icons.account_tree),
                  title: Text('Просмотр дерева'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (_pendingRequestsCount > 0)
                PopupMenuItem<String>(
                  value: 'requests_menu',
                  enabled: selectedTreeId != null,
                  child: ListTile(
                    leading: Icon(Icons.notifications),
                    title: Text(
                      'Запросы на родство ($_pendingRequestsCount)',
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              PopupMenuItem<String>(
                value: 'find',
                enabled: selectedTreeId != null,
                child: ListTile(
                  leading: Icon(Icons.search),
                  title: Text('Найти родственника'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: Theme.of(context).primaryColorLight,
            child: TabBar(
              controller: _tabController,
              labelColor: Theme.of(context).primaryColorDark,
              unselectedLabelColor: Colors.grey[600],
              indicatorColor: Theme.of(context).primaryColor,
              tabs: const [
                Tab(text: 'Чаты'),
                Tab(text: 'Все родственники'),
              ],
            ),
          ),
          Expanded(
            child: selectedTreeId == null
                ? _buildNoTreeSelected()
                : _isLoading
                    ? Center(child: CircularProgressIndicator())
                    : _errorMessage.isNotEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Text(_errorMessage,
                                  textAlign: TextAlign.center),
                            ),
                          )
                        : TabBarView(
                            controller: _tabController,
                            children: [
                              _buildRelativesList(
                                key: ValueKey('online_tab_$selectedTreeId'),
                                relativesForTab: onlineRelatives,
                                isOnlineTab: true,
                              ),
                              _buildRelativesList(
                                key: ValueKey('offline_tab_$selectedTreeId'),
                                relativesForTab: visibleRelatives,
                                isOnlineTab: false,
                              ),
                            ],
                          ),
          ),
        ],
      ),
      floatingActionButton: selectedTreeId == null
          ? null
          : FloatingActionButton(
              heroTag: 'add_relative_fab',
              onPressed: () {
                context.push('/relatives/add/$selectedTreeId');
              },
              tooltip: 'Добавить родственника',
              child: Icon(Icons.add),
            ),
    );
  }

  Widget _buildNoTreeSelected() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.info_outline, size: 60, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'Дерево не выбрано',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              'Нажмите на иконку дерева вверху, чтобы выбрать или создать новое',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600]),
            ),
            SizedBox(height: 20),
            ElevatedButton.icon(
              icon: Icon(Icons.account_tree_outlined),
              label: Text('Выбрать/Создать дерево'),
              onPressed: () => context.go('/tree?selector=1'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRelativesList({
    required Key key,
    required List<FamilyPerson> relativesForTab,
    required bool isOnlineTab,
  }) {
    debugPrint(
      '[_buildRelativesList called] isOnlineTab: $isOnlineTab, relatives count: ${relativesForTab.length}',
    );

    if (relativesForTab.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isOnlineTab ? Icons.chat_bubble_outline : Icons.people_outline,
                size: 60,
                color: Colors.grey,
              ),
              SizedBox(height: 16),
              Text(
                isOnlineTab ? 'Нет доступных чатов' : 'Нет родственников',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text(
                isOnlineTab
                    ? 'Здесь появятся чаты с родственниками, использующими приложение'
                    : 'Добавьте родственников вручную или пригласите их присоединиться',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      );
    }

    Map<String, List<FamilyPerson>> groupedRelatives = {};
    for (var relative in relativesForTab) {
      String nameToSort = relative.displayName.trim();
      String firstLetter = nameToSort.isNotEmpty
          ? nameToSort.substring(0, 1).toUpperCase()
          : '#';
      if (!RegExp(r'[А-ЯA-Z]', caseSensitive: false).hasMatch(firstLetter)) {
        firstLetter = '#';
      }
      groupedRelatives.putIfAbsent(firstLetter, () => []).add(relative);
    }

    List<String> sortedKeys = groupedRelatives.keys.toList()
      ..sort((a, b) {
        if (a == '#') return 1;
        if (b == '#') return -1;
        const russianAlphabet = 'АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ';
        final indexA = russianAlphabet.indexOf(a);
        final indexB = russianAlphabet.indexOf(b);

        if (indexA != -1 && indexB != -1) {
          return indexA.compareTo(indexB);
        } else if (indexA != -1) {
          return -1;
        } else if (indexB != -1) {
          return 1;
        } else {
          return a.compareTo(b);
        }
      });

    groupedRelatives.forEach((key, list) {
      list.sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );
    });

    List<dynamic> flatList = [];
    for (var key in sortedKeys) {
      flatList.add(key);
      flatList.addAll(groupedRelatives[key]!);
    }

    return ListView.builder(
      key: key,
      itemCount: flatList.length,
      itemBuilder: (context, index) {
        final item = flatList[index];

        if (item is String) {
          return Padding(
            padding: const EdgeInsets.only(
              left: 16.0,
              top: 16.0,
              bottom: 8.0,
              right: 16.0,
            ),
            child: Text(
              item,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).primaryColor,
              ),
            ),
          );
        } else if (item is FamilyPerson) {
          final relative = item;
          final relationDescription = _getRelationDescription(relative);

          ChatPreview? chatPreview;
          if (isOnlineTab && relative.userId != null) {
            try {
              chatPreview = _chatPreviews.firstWhere(
                (preview) => preview.otherUserId == relative.userId,
              );
            } catch (e) {
              chatPreview = null;
            }
          }

          final String lastMessageText = chatPreview?.lastMessage ?? '';
          final DateTime? lastMessageTimestamp =
              chatPreview?.lastMessageTime.toDate();
          final int unreadCount = chatPreview?.unreadCount ?? 0;
          final bool isLastMessageFromMe =
              chatPreview?.lastMessageSenderId == _currentUserId;

          return ListTile(
            leading: GestureDetector(
              onTap: () {
                debugPrint(
                  'Avatar tapped for ${relative.displayName}, navigating to details...',
                );
                context.push('/relative/details/${relative.id}');
              },
              child: CircleAvatar(
                radius: 25,
                backgroundImage:
                    (relative.photoUrl != null && relative.photoUrl!.isNotEmpty)
                        ? NetworkImage(relative.photoUrl!)
                        : null,
                child: (relative.photoUrl == null || relative.photoUrl!.isEmpty)
                    ? Text(relative.initials, style: TextStyle(fontSize: 18))
                    : null,
              ),
            ),
            title: Text(
              relative.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                color: unreadCount > 0 ? Theme.of(context).primaryColor : null,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  relationDescription,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.grey[600], fontSize: 13),
                ),
                if (isOnlineTab && lastMessageText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2.0),
                    child: Row(
                      children: [
                        if (isLastMessageFromMe)
                          Text(
                            'Вы: ',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[600],
                            ),
                          ),
                        Expanded(
                          child: Text(
                            lastMessageText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: unreadCount > 0
                                  ? Colors.black87
                                  : Colors.black54,
                              fontWeight: unreadCount > 0
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (isOnlineTab &&
                    lastMessageText.isEmpty &&
                    relative.userId != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2.0),
                    child: Text(
                      'Нет сообщений',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[500],
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
            trailing: isOnlineTab && lastMessageTimestamp != null
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _formatTimestamp(lastMessageTimestamp),
                        style: TextStyle(
                          fontSize: 12,
                          color: unreadCount > 0
                              ? Theme.of(context).primaryColor
                              : Colors.grey,
                          fontWeight: unreadCount > 0
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      if (unreadCount > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: CircleAvatar(
                            radius: 9,
                            backgroundColor: Theme.of(context).primaryColor,
                            child: Text(
                              unreadCount.toString(),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onPrimary,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  )
                : null,
            onTap: () {
              if (isOnlineTab) {
                final userId = relative.userId;
                if (userId != null && userId != _authService.currentUserId) {
                  final nameParam = Uri.encodeComponent(relative.displayName);
                  final photoParam = (relative.photoUrl != null &&
                          relative.photoUrl!.isNotEmpty)
                      ? Uri.encodeComponent(relative.photoUrl!)
                      : '';
                  debugPrint(
                    'Navigating to chat with ${relative.displayName} (ID: $userId)',
                  );
                  context.push(
                    '/relatives/chat/$userId?name=$nameParam&photo=$photoParam&relativeId=${relative.id}',
                  );
                } else {
                  debugPrint(
                    'Cannot chat with self or invalid user, navigating to details for ${relative.displayName}',
                  );
                  context.push('/relative/details/${relative.id}');
                }
              } else {
                debugPrint(
                  'Offline tab, navigating to details for ${relative.displayName}',
                );
                context.push('/relative/details/${relative.id}');
              }
            },
            contentPadding: EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
          );
        }
        return SizedBox.shrink();
      },
    );
  }

  String _getRelationDescription(FamilyPerson relative) {
    final currentUserPersonId = _currentUserPersonId;
    if (_currentUserId == null || currentUserPersonId == null) {
      return 'Родственник';
    }

    if (relative.id == currentUserPersonId) {
      return 'Вы';
    }

    final directRelation = _relations.firstWhere(
      (r) =>
          (r.person1Id == currentUserPersonId && r.person2Id == relative.id) ||
          (r.person1Id == relative.id && r.person2Id == currentUserPersonId),
      orElse: () => FamilyRelation(
        id: '',
        person1Id: '',
        person2Id: '',
        relation1to2: RelationType.other,
        relation2to1: RelationType.other,
        treeId: _currentTreeId ?? '',
        isConfirmed: false,
        createdAt: DateTime(0),
      ),
    );

    if (directRelation.id.isNotEmpty) {
      final bool userIsPerson1 =
          directRelation.person1Id == currentUserPersonId;
      final RelationType relevantRelationType = userIsPerson1
          ? directRelation.relation2to1
          : directRelation.relation1to2;

      switch (relevantRelationType) {
        case RelationType.spouse:
        case RelationType.partner:
          return 'Супруг(а)/Партнер';
        case RelationType.parent:
          return 'Родитель';
        case RelationType.child:
          return 'Ребенок';
        case RelationType.sibling:
          return 'Брат/Сестра';
        default:
          return 'Родственник';
      }
    }

    return 'Родственник';
  }

  String _formatTimestamp(DateTime dateTime) {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime yesterday = today.subtract(const Duration(days: 1));

    final DateTime messageDate = DateTime(
      dateTime.year,
      dateTime.month,
      dateTime.day,
    );

    if (messageDate == today) {
      return DateFormat.Hm('ru').format(dateTime);
    } else if (messageDate == yesterday) {
      return 'Вчера';
    } else if (now.difference(dateTime).inDays < 7) {
      return DateFormat.E('ru').format(dateTime);
    } else {
      return DateFormat('dd.MM.yyyy', 'ru').format(dateTime);
    }
  }

  void _handleStreamError(
    dynamic error,
    StackTrace stackTrace,
    String reason,
    Completer completer,
  ) {
    _crashlyticsService.logError(error, stackTrace, reason: reason);
    if (_errorMessage.isEmpty && mounted) {
      setState(() {
        _errorMessage = 'Ошибка при загрузке данных ($reason).';
      });
    }
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
  }
}
