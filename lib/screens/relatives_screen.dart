import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'package:get_it/get_it.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../models/family_tree.dart';
import '../models/family_person.dart';
import '../models/family_relation.dart';
import '../models/chat_preview.dart';
import '../providers/tree_provider.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/chat_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/invitation_link_service_interface.dart';

class _ContactStatus {
  const _ContactStatus({
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;
}

String _countLabel(
  int count, {
  required String one,
  required String few,
  required String many,
}) {
  final mod10 = count % 10;
  final mod100 = count % 100;
  if (mod10 == 1 && mod100 != 11) {
    return '$count $one';
  }
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return '$count $few';
  }
  return '$count $many';
}

class RelativesScreen extends StatefulWidget {
  const RelativesScreen({super.key});

  @override
  State<RelativesScreen> createState() => _RelativesScreenState();
}

class _RelativesScreenState extends State<RelativesScreen> {
  final FamilyTreeServiceInterface _familyService =
      GetIt.I<FamilyTreeServiceInterface>();
  final ChatServiceInterface _chatService = GetIt.I<ChatServiceInterface>();
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final InvitationLinkServiceInterface _invitationLinkService =
      GetIt.I<InvitationLinkServiceInterface>();

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
    });
  }

  @override
  void dispose() {
    _cancelSubscriptions();
    _treeProviderInstance?.removeListener(_handleTreeChange);
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
      cancelOnError: false,
    );

    _relationsSubscription = _familyService.getRelationsStream(treeId).listen(
      (relations) {
        if (mounted) {
          setState(() {
            _relations = relations;
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
      cancelOnError: false,
    );

    _chatsSubscription = _chatService.getUserChatsStream(currentUserId).listen(
      (chatPreviews) {
        if (mounted) {
          setState(() {
            _chatPreviews = chatPreviews;
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
      }
    } catch (e, stackTrace) {
      debugPrint('Ошибка или таймаут при ожидании данных: $e');
      debugPrint('Error: $e\n$stackTrace');
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

  bool _isWideLayout(BuildContext context) =>
      MediaQuery.of(context).size.width >= 1180;

  bool _isFriendsTree(TreeProvider provider) =>
      provider.selectedTreeKind == TreeKind.friends;

  String _graphAddLabel(TreeProvider provider) =>
      _isFriendsTree(provider) ? 'Добавить человека' : 'Добавить родственника';

  String _graphFindLabel(TreeProvider provider) =>
      _isFriendsTree(provider) ? 'Найти человека' : 'Найти родственника';

  @override
  Widget build(BuildContext context) {
    final treeProvider = Provider.of<TreeProvider>(context);
    final selectedTreeId = treeProvider.selectedTreeId;
    final selectedTreeName = treeProvider.selectedTreeName ??
        (_isFriendsTree(treeProvider) ? 'Круг друзей' : 'Родственники');
    final isFriendsTree = _isFriendsTree(treeProvider);

    // --- ФИЛЬТРАЦИЯ СПИСКОВ ---
    final String currentUserId = _authService.currentUserId ?? '';
    final List<FamilyPerson> visibleRelatives =
        _allRelatives.where((p) => p.userId != currentUserId).toList();
    final chatReadyCount =
        visibleRelatives.where((person) => _canStartChat(person)).length;
    final inviteReadyCount =
        visibleRelatives.where((person) => _canInviteRelative(person)).length;
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
                tooltip: isFriendsTree
                    ? 'Запросы на связи ($_pendingRequestsCount)'
                    : 'Запросы на родство ($_pendingRequestsCount)',
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
                  treeProvider.selectedTreeName ??
                      (_isFriendsTree(treeProvider)
                          ? 'Дерево друзей'
                          : 'Семейное дерево'),
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
                  title: Text(_graphAddLabel(treeProvider)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem<String>(
                value: 'create_tree',
                child: ListTile(
                  leading: Icon(Icons.add_circle_outline),
                  title: Text(
                    isFriendsTree
                        ? 'Создать новый круг'
                        : 'Создать новое дерево',
                  ),
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
                      isFriendsTree
                          ? 'Запросы на связи ($_pendingRequestsCount)'
                          : 'Запросы на родство ($_pendingRequestsCount)',
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              PopupMenuItem<String>(
                value: 'find',
                enabled: selectedTreeId != null,
                child: ListTile(
                  leading: Icon(Icons.search),
                  title: Text(_graphFindLabel(treeProvider)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: selectedTreeId == null
          ? _buildNoTreeSelected()
          : _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _errorMessage.isNotEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Text(_errorMessage, textAlign: TextAlign.center),
                      ),
                    )
                  : Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1420),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                          child: _isWideLayout(context)
                              ? Column(
                                  children: [
                                    _buildGraphContextBanner(
                                      treeName: selectedTreeName,
                                      isFriendsTree: isFriendsTree,
                                      relativesCount: visibleRelatives.length,
                                    ),
                                    const SizedBox(height: 16),
                                    Expanded(
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            flex: 3,
                                            child: _buildRelativesList(
                                              key: ValueKey(
                                                'relatives_$selectedTreeId',
                                              ),
                                              relativesForTab: visibleRelatives,
                                              isOnlineTab: false,
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          SizedBox(
                                            width: 320,
                                            child: _buildRelativesSidePanel(
                                              relativesCount:
                                                  visibleRelatives.length,
                                              chatReadyCount: chatReadyCount,
                                              inviteReadyCount:
                                                  inviteReadyCount,
                                              treeName: selectedTreeName,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                )
                              : Column(
                                  children: [
                                    _buildGraphContextBanner(
                                      treeName: selectedTreeName,
                                      isFriendsTree: isFriendsTree,
                                      relativesCount: visibleRelatives.length,
                                    ),
                                    const SizedBox(height: 12),
                                    Expanded(
                                      child: _buildRelativesList(
                                        key: ValueKey(
                                          'relatives_$selectedTreeId',
                                        ),
                                        relativesForTab: visibleRelatives,
                                        isOnlineTab: false,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
      floatingActionButton: selectedTreeId == null
          ? null
          : FloatingActionButton(
              heroTag: 'add_relative_fab',
              onPressed: () {
                context.push('/relatives/add/$selectedTreeId');
              },
              tooltip: _graphAddLabel(treeProvider),
              child: Icon(Icons.add),
            ),
    );
  }

  Widget _buildNoTreeSelected() {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.info_outline, size: 60, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'Граф не выбран',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Нажмите на иконку дерева вверху, чтобы выбрать семейное дерево или круг друзей',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            SizedBox(height: 20),
            FilledButton.icon(
              icon: Icon(Icons.account_tree_outlined),
              label: Text('Выбрать граф'),
              onPressed: () => context.go('/tree?selector=1'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Открыть мои графы'),
              onPressed: () => context.go('/trees'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRelativesSidePanel({
    required int relativesCount,
    required int chatReadyCount,
    required int inviteReadyCount,
    required String treeName,
  }) {
    final theme = Theme.of(context);
    final treeProvider = Provider.of<TreeProvider>(context, listen: false);
    final isFriendsTree = _isFriendsTree(treeProvider);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isFriendsTree ? 'Сводка по кругу' : 'Сводка по дереву',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isFriendsTree
                      ? Icons.diversity_3_outlined
                      : Icons.account_tree_outlined,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    treeName,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            isFriendsTree
                ? 'Всего людей в круге: $relativesCount'
                : 'Всего родственников: $relativesCount',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildSideStatChip(
                icon: Icons.people_outline,
                label:
                    '$relativesCount ${isFriendsTree ? 'в круге' : 'в дереве'}',
              ),
              _buildSideStatChip(
                icon: Icons.chat_bubble_outline,
                label: _countLabel(
                  _chatPreviews.length,
                  one: 'чат',
                  few: 'чата',
                  many: 'чатов',
                ),
              ),
              _buildSideStatChip(
                icon: Icons.notifications_none,
                label: _pendingRequestsCount > 0
                    ? _countLabel(
                        _pendingRequestsCount,
                        one: 'запрос',
                        few: 'запроса',
                        many: 'запросов',
                      )
                    : 'Без запросов',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            isFriendsTree
                ? 'На desktop удобнее держать людей из круга отдельно, а действия по связям и приглашениям в боковой колонке.'
                : 'На desktop удобнее держать список родственников отдельно, а действия по дереву и запросам на родство в боковой колонке.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Быстрые действия',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _currentTreeId == null
                ? null
                : () => context.push('/relatives/add/${_currentTreeId!}'),
            icon: const Icon(Icons.person_add_alt_1_outlined),
            label: Text(_graphAddLabel(treeProvider)),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => context.go('/tree'),
            icon: const Icon(Icons.account_tree_outlined),
            label: const Text('Открыть дерево'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _currentTreeId == null
                ? null
                : () => context.push('/relatives/find/${_currentTreeId!}'),
            icon: const Icon(Icons.search),
            label: Text(_graphFindLabel(treeProvider)),
          ),
          const SizedBox(height: 16),
          Text(
            'Состояние контактов',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          _buildStatusLine(
            color: Colors.green.shade700,
            label: isFriendsTree
                ? 'Можно начать чат с ${_countLabel(chatReadyCount, one: 'человеком', few: 'людьми', many: 'людьми')}'
                : 'Можно написать ${_countLabel(chatReadyCount, one: 'родственнику', few: 'родственникам', many: 'родственникам')}',
          ),
          const SizedBox(height: 8),
          _buildStatusLine(
            color: Colors.orange.shade700,
            label: inviteReadyCount > 0
                ? (isFriendsTree
                    ? 'Ждут приглашения: ${_countLabel(inviteReadyCount, one: 'человек', few: 'человека', many: 'человек')}'
                    : 'Нужно пригласить: ${_countLabel(inviteReadyCount, one: 'родственника', few: 'родственников', many: 'родственников')}')
                : (isFriendsTree
                    ? 'Все добавленные люди уже в приложении или только для просмотра'
                    : 'Все добавленные родственники уже в приложении или только для просмотра'),
          ),
          if (_pendingRequestsCount > 0) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _currentTreeId == null
                  ? null
                  : () =>
                      context.push('/relatives/requests/${_currentTreeId!}'),
              icon: const Icon(Icons.mark_email_unread_outlined),
              label: Text(
                isFriendsTree ? 'Открыть запросы на связи' : 'Открыть запросы',
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusLine({
    required Color color,
    required String label,
  }) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 10,
          height: 10,
          margin: const EdgeInsets.only(top: 5),
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSideStatChip({
    required IconData icon,
    required String label,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGraphContextBanner({
    required String treeName,
    required bool isFriendsTree,
    required int relativesCount,
  }) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSecondaryContainer
                  .withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              isFriendsTree
                  ? Icons.diversity_3_outlined
                  : Icons.account_tree_outlined,
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isFriendsTree
                      ? 'Активен круг друзей'
                      : 'Активно семейное дерево',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  isFriendsTree
                      ? '"$treeName" содержит $relativesCount человек. Здесь удобно поддерживать связи, приглашать новых людей и быстро переходить в чат.'
                      : '"$treeName" содержит $relativesCount родственников. Здесь удобно поддерживать связи, приглашать новых людей и быстро переходить в чат.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
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
      final treeProvider = Provider.of<TreeProvider>(context, listen: false);
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
                isOnlineTab
                    ? 'Нет доступных чатов'
                    : _isFriendsTree(Provider.of<TreeProvider>(
                        context,
                        listen: false,
                      ))
                        ? 'Пока нет людей в круге'
                        : 'Нет родственников',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text(
                isOnlineTab
                    ? 'Здесь появятся чаты с родственниками, использующими приложение'
                    : _isFriendsTree(Provider.of<TreeProvider>(
                        context,
                        listen: false,
                      ))
                        ? 'Добавьте друзей, коллег или близкий круг вручную либо отправьте приглашение'
                        : 'Добавьте родственников вручную или пригласите их присоединиться',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600]),
              ),
              if (!isOnlineTab) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _currentTreeId == null
                      ? null
                      : () => context.push('/relatives/add/${_currentTreeId!}'),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: Text(_graphAddLabel(treeProvider)),
                ),
              ],
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

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Theme.of(context)
              .colorScheme
              .outlineVariant
              .withValues(alpha: 0.45),
        ),
      ),
      child: ListView.builder(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 8),
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
            final DateTime? lastMessageTimestamp = chatPreview?.lastMessageTime;
            final int unreadCount = chatPreview?.unreadCount ?? 0;
            final bool isLastMessageFromMe =
                chatPreview?.lastMessageSenderId == _currentUserId;
            final bool canStartChat = _canStartChat(relative);
            final bool canInvite = _canInviteRelative(relative);
            final contactStatus = _getContactStatus(relative);

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
                  backgroundImage: (relative.photoUrl != null &&
                          relative.photoUrl!.isNotEmpty)
                      ? NetworkImage(relative.photoUrl!)
                      : null,
                  child: (relative.photoUrl == null ||
                          relative.photoUrl!.isEmpty)
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
                  color:
                      unreadCount > 0 ? Theme.of(context).primaryColor : null,
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
                  if (!isOnlineTab)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: contactStatus.color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            contactStatus.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: contactStatus.color,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
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
                                  color:
                                      Theme.of(context).colorScheme.onPrimary,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                      ],
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (canStartChat)
                          IconButton(
                            icon: const Icon(Icons.message_outlined),
                            tooltip: 'Написать ${relative.displayName}',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _openChatWithRelative(relative),
                          ),
                        if (canInvite)
                          IconButton(
                            icon: const Icon(Icons.person_add_alt_1_outlined),
                            tooltip: 'Пригласить ${relative.displayName}',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _shareInviteForRelative(relative),
                          ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
              onTap: () {
                if (isOnlineTab) {
                  if (canStartChat) {
                    _openChatWithRelative(relative);
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
      ),
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
      final relationLabel = FamilyRelation.getRelationName(
        relevantRelationType,
        relative.gender,
      );
      if (relationLabel.isNotEmpty &&
          relationLabel !=
              FamilyRelation.getGenericRelationTypeStringRu(
                RelationType.other,
              )) {
        return relationLabel;
      }
    }

    final treeProvider = _treeProviderInstance;
    if (treeProvider?.selectedTreeKind == TreeKind.friends) {
      return 'Связь';
    }
    return 'Родственник';
  }

  bool _canStartChat(FamilyPerson relative) {
    final userId = relative.userId;
    return userId != null &&
        userId.isNotEmpty &&
        userId != _authService.currentUserId;
  }

  bool _canInviteRelative(FamilyPerson relative) {
    final userId = relative.userId;
    return (userId == null || userId.isEmpty) &&
        relative.id != _currentUserPersonId &&
        _currentTreeId != null;
  }

  _ContactStatus _getContactStatus(FamilyPerson relative) {
    if (_canStartChat(relative)) {
      return _ContactStatus(
        label: 'Можно написать',
        color: Colors.green.shade700,
      );
    }

    if (_canInviteRelative(relative)) {
      return _ContactStatus(
        label: 'Нужно пригласить',
        color: Colors.orange.shade700,
      );
    }

    return _ContactStatus(
      label: 'Только просмотр',
      color: Colors.grey.shade600,
    );
  }

  void _openChatWithRelative(FamilyPerson relative) {
    final userId = relative.userId;
    if (userId == null || userId.isEmpty) {
      return;
    }

    final nameParam = Uri.encodeComponent(relative.displayName);
    final photoParam =
        (relative.photoUrl != null && relative.photoUrl!.isNotEmpty)
            ? Uri.encodeComponent(relative.photoUrl!)
            : '';
    debugPrint(
      'Navigating to chat with ${relative.displayName} (ID: $userId)',
    );
    context.push(
      '/relatives/chat/$userId?name=$nameParam&photo=$photoParam&relativeId=${relative.id}',
    );
  }

  Future<void> _shareInviteForRelative(FamilyPerson relative) async {
    if (!_canInviteRelative(relative) || _currentTreeId == null) {
      return;
    }

    try {
      final inviteUrl = _invitationLinkService.buildInvitationLink(
        treeId: _currentTreeId!,
        personId: relative.id,
      );
      await Share.share(
        (_treeProviderInstance?.selectedTreeKind == TreeKind.friends)
            ? 'Присоединяйтесь к нашему кругу друзей в Родне: ${inviteUrl.toString()}'
            : 'Присоединяйтесь к нашему семейному древу в Родне: ${inviteUrl.toString()}',
        subject: _treeProviderInstance?.selectedTreeKind == TreeKind.friends
            ? 'Приглашение в круг друзей'
            : 'Приглашение в Родню',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось подготовить приглашение.'),
        ),
      );
    }
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
    debugPrint('Ошибка при загрузке данных: $error\n$stackTrace');
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
