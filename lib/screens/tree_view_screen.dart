import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart'; // Импортируем Provider
import 'package:get_it/get_it.dart';

import '../backend/backend_runtime_config.dart';
import '../models/family_person.dart';
import '../models/family_relation.dart';
import '../models/family_tree.dart';
import '../widgets/interactive_family_tree.dart';
import '../providers/tree_provider.dart'; // Импортируем TreeProvider
import 'package:go_router/go_router.dart'; // Для навигации
import '../models/user_profile.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/chat_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';

import '../services/public_tree_link_service.dart';
import '../services/local_storage_service.dart';
import '../utils/user_facing_error.dart';

class SectionTitle extends StatelessWidget {
  final String title;

  const SectionTitle({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).primaryColor,
        ),
      ),
    );
  }
}

class TreeViewScreen extends StatefulWidget {
  final String? routeTreeId;
  final String? routeTreeName;

  const TreeViewScreen({
    super.key,
    this.routeTreeId,
    this.routeTreeName,
  });

  @override
  State<TreeViewScreen> createState() => _TreeViewScreenState();
}

class _TreeViewScreenState extends State<TreeViewScreen> {
  final FamilyTreeServiceInterface _familyService =
      GetIt.I<FamilyTreeServiceInterface>();
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final ChatServiceInterface _chatService = GetIt.I<ChatServiceInterface>();
  final LocalStorageService _localStorageService =
      GetIt.I<LocalStorageService>();

  // Map<String, dynamic> _graphData = {'nodes': [], 'edges': []}; // Больше не нужно
  bool _isLoading = true;
  String _errorMessage = '';
  bool _isEditMode = false; // <<< Добавляем состояние режима редактирования
  TreeProvider? _treeProviderInstance; // Храним экземпляр
  String? _currentTreeId;
  String? _branchRootPersonId;
  String? _branchRootName;
  String? _selectedEditPersonId;
  String? _selectedEditPersonName;
  FamilyTree? _currentTreeMeta;
  Map<String, Offset> _manualNodePositions = <String, Offset>{};
  // <<< НОВОЕ СОСТОЯНИЕ: Флаг, добавлен ли текущий пользователь в дерево >>>
  bool _currentUserIsInTree = true; // Изначально true, пока не проверили

  bool get _isFriendsTree => _currentTreeMeta?.isFriendsTree == true;
  String get _treeLabel => _isFriendsTree ? 'Дерево друзей' : 'Семейное дерево';
  String get _peopleLabel => _isFriendsTree ? 'людей' : 'человек';
  String get _branchLabel => _isFriendsTree ? 'кругов' : 'веток семьи';
  int get _graphClusterCount => _isFriendsTree
      ? _estimateGraphCircleCount()
      : _estimateFamilyBranchCount();

  String _describeTreeActionError(
    Object error, {
    required String fallbackMessage,
  }) {
    return describeUserFacingError(
      authService: _authService,
      error: error,
      fallbackMessage: fallbackMessage,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _treeProviderInstance = Provider.of<TreeProvider>(context, listen: false);
      _treeProviderInstance!.addListener(_handleTreeChange); // Подписываемся
      _syncTreeFromRouteOrProvider();
    });
  }

  @override
  void dispose() {
    _treeProviderInstance?.removeListener(_handleTreeChange); // Отписываемся
    super.dispose();
  }

  Future<void> _syncTreeFromRouteOrProvider() async {
    final routeTreeId = widget.routeTreeId;
    final routeTreeName = widget.routeTreeName;
    final provider = _treeProviderInstance;
    if (provider == null) {
      return;
    }

    if (routeTreeId != null && routeTreeId.isNotEmpty) {
      final currentId = provider.selectedTreeId;
      final currentName = provider.selectedTreeName;
      final needsSync = currentId != routeTreeId ||
          ((routeTreeName?.isNotEmpty ?? false) &&
              currentName != routeTreeName);

      if (needsSync) {
        await provider.selectTree(routeTreeId, routeTreeName);
        return;
      }

      _currentTreeId = routeTreeId;
      await _loadData(routeTreeId);
      return;
    }

    _currentTreeId = provider.selectedTreeId;
    if (_currentTreeId != null) {
      await _loadData(_currentTreeId!);
    } else {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // Метод-обработчик изменений
  void _handleTreeChange() {
    if (!mounted) return;
    final newTreeId = _treeProviderInstance?.selectedTreeId;
    if (_currentTreeId != newTreeId) {
      debugPrint(
        'TreeView: Обнаружено изменение дерева с $_currentTreeId на $newTreeId',
      );
      _currentTreeId = newTreeId;
      if (_currentTreeId != null) {
        _loadData(_currentTreeId!);
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = '';
          _manualNodePositions = <String, Offset>{};
        });
      }
    }
  }

  // Метод загрузки данных, теперь принимает treeId
  Future<void> _loadData(String treeId) async {
    if (!mounted) return;
    debugPrint('TreeView: Загрузка данных для дерева $treeId');
    setState(() {
      _isLoading = true;
      _errorMessage = '';
      // Сбрасываем флаг перед проверкой
      _currentUserIsInTree = true;
    });

    try {
      if (_authService.currentUserId == null) {
        context.go('/login');
        return;
      }

      // Загружаем родственников и связи
      List<FamilyPerson> relatives = await _familyService.getRelatives(treeId);
      List<FamilyRelation> relations = await _familyService.getRelations(
        treeId,
      );
      final treeMeta = await _loadCurrentTreeMeta(treeId);
      debugPrint(
        'Загружено родственников: ${relatives.length}, связей: ${relations.length}',
      );

      if (!mounted) return;

      if (relatives.isEmpty) {
        debugPrint('Дерево $treeId пустое.');
        setState(() {
          _isLoading = false;
          _errorMessage = 'В этом дереве еще нет людей.';
          _manualNodePositions = <String, Offset>{};
        });
        return;
      }

      // <<< НОВАЯ ПРОВЕРКА: Есть ли текущий пользователь в дереве >>>
      bool userInTree = await _familyService.isCurrentUserInTree(treeId);
      if (!mounted) return;
      setState(() {
        _currentUserIsInTree = userInTree;
        debugPrint(
          'Текущий пользователь ${_authService.currentUserId} ${_currentUserIsInTree ? "" : "НЕ "}найден в дереве $treeId',
        );
      });
      // <<< КОНЕЦ ПРОВЕРКИ >>>

      // Собираем данные для peopleData (добавляем userProfile, если он есть)
      // TODO: Оптимизировать загрузку профилей, если это будет тормозить
      List<Map<String, dynamic>> peopleData = [];
      for (var person in relatives) {
        // Попытка загрузить UserProfile, если есть userId
        UserProfile? userProfile;
        if (person.userId != null) {
          // Здесь нужен ProfileService, но чтобы не усложнять, пока пропустим
          // userProfile = await _profileService.getUserProfile(person.userId!);
        }
        peopleData.add({
          'person': person,
          'userProfile': userProfile, // Будет null, если профиль не загружен
        });
      }

      final savedPositions = await _localStorageService.getTreeNodePositions(
        treeId,
      );
      final visiblePersonIds = relatives.map((person) => person.id).toSet();
      final filteredPositions = <String, Offset>{};
      for (final entry in savedPositions.entries) {
        if (visiblePersonIds.contains(entry.key)) {
          filteredPositions[entry.key] = entry.value;
        }
      }

      // Сохраняем данные в состоянии для передачи в виджет
      if (mounted) {
        final branchRootStillExists = _branchRootPersonId == null ||
            relatives.any((person) => person.id == _branchRootPersonId);
        final selectedEditPersonStillExists = _selectedEditPersonId == null ||
            relatives.any((person) => person.id == _selectedEditPersonId);
        setState(() {
          // Сохраняем исходные данные, а не построенный граф
          _relativesData = peopleData;
          _relationsData = relations;
          _currentTreeMeta = treeMeta;
          _manualNodePositions = filteredPositions;
          _isLoading = false;
          if (!branchRootStillExists) {
            _branchRootPersonId = null;
            _branchRootName = null;
          }
          if (!selectedEditPersonStillExists) {
            _selectedEditPersonId = null;
            _selectedEditPersonName = null;
          }
        });
      }
    } catch (e, s) {
      debugPrint('Ошибка загрузки данных дерева $treeId: $e\\n$s');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Не удалось загрузить данные дерева.';
        });
      }
    }
  }

  // Добавляем переменные состояния для хранения данных
  List<Map<String, dynamic>> _relativesData = [];
  List<FamilyRelation> _relationsData = [];

  @override
  Widget build(BuildContext context) {
    final treeProvider = Provider.of<TreeProvider>(context);
    final selectedTreeId = treeProvider.selectedTreeId ?? widget.routeTreeId;
    final selectedTreeName = treeProvider.selectedTreeName ??
        widget.routeTreeName ??
        'Семейное дерево';

    if (selectedTreeId == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Семейное дерево'),
          leading: context.canPop()
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => context.pop(),
                )
              : null,
          actions: [
            IconButton(
              icon: const Icon(Icons.account_tree_outlined),
              tooltip: 'Выбрать дерево',
              onPressed: () => context.go('/tree?selector=1'),
            ),
          ],
        ),
        body: _buildTreeState(
          icon: Icons.account_tree_outlined,
          title: 'Дерево не выбрано',
          message:
              'Откройте список деревьев и выберите нужное. После этого здесь появится интерактивная схема семьи.',
          actions: [
            FilledButton.icon(
              onPressed: () => context.go('/tree?selector=1'),
              icon: const Icon(Icons.list_alt),
              label: const Text('Открыть список деревьев'),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(selectedTreeName),
        leading: context.canPop()
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.pop(),
              )
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.account_tree_outlined),
            tooltip: 'Выбрать другое дерево',
            onPressed: () => context.go('/tree?selector=1'),
          ),
          IconButton(
            icon: Icon(
              _isEditMode ? Icons.edit_off_outlined : Icons.edit_outlined,
            ),
            tooltip: _isEditMode
                ? 'Выйти из режима редактирования'
                : 'Редактировать дерево',
            onPressed: () {
              if (!mounted) return;
              setState(() {
                _isEditMode = !_isEditMode;
                if (!_isEditMode) {
                  _selectedEditPersonId = null;
                  _selectedEditPersonName = null;
                }
              });
            },
          ),
        ],
      ),
      body: SafeArea(
        child: _buildTreeBody(
          selectedTreeId: selectedTreeId,
          selectedTreeName: selectedTreeName,
        ),
      ),
    );
  }

  Widget _buildTreeBody({
    required String selectedTreeId,
    required String selectedTreeName,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 600;
        final isWideDesktop = constraints.maxWidth >= 1180;

        if (_isLoading) {
          return _buildTreeState(
            icon: Icons.sync,
            title: 'Загружаем дерево',
            message: 'Подтягиваем людей, связи и текущее состояние дерева.',
            showProgress: true,
          );
        }

        if (_errorMessage.isNotEmpty) {
          final isEmptyTree = _relativesData.isEmpty && _relationsData.isEmpty;
          return _buildTreeState(
            icon: isEmptyTree ? Icons.account_tree : Icons.error_outline,
            title: isEmptyTree
                ? 'Дерево пока пустое'
                : 'Не удалось загрузить дерево',
            message: isEmptyTree
                ? 'Добавьте первого человека, чтобы начать собирать структуру семьи.'
                : _errorMessage,
            actions: [
              if (isEmptyTree)
                FilledButton.icon(
                  onPressed: () => _navigateToAddRelative(selectedTreeId),
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Добавить первого человека'),
                ),
              OutlinedButton.icon(
                onPressed: () => _loadData(selectedTreeId),
                icon: const Icon(Icons.refresh),
                label: const Text('Повторить'),
              ),
            ],
          );
        }

        final overviewCard = isCompact
            ? _buildOverviewCard(
                selectedTreeId,
                selectedTreeName,
                compact: true,
              )
            : _buildOverviewCard(
                selectedTreeId,
                selectedTreeName,
                compact: false,
              );

        final treeCanvas = _buildTreeCanvas();

        if (isWideDesktop) {
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1520),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  children: [
                    _buildTreeHeroBanner(selectedTreeName),
                    const SizedBox(height: 16),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: 372,
                            child: SingleChildScrollView(child: overviewCard),
                          ),
                          const SizedBox(width: 16),
                          Expanded(child: treeCanvas),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return Column(
          children: [
            Flexible(
              fit: FlexFit.loose,
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  children: [
                    Padding(
                      padding:
                          EdgeInsets.fromLTRB(16, isCompact ? 10 : 16, 16, 12),
                      child: _buildTreeHeroBanner(selectedTreeName),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                      child: overviewCard,
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: treeCanvas,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTreeCanvas() {
    final theme = Theme.of(context);
    final canvasAccent =
        _isFriendsTree ? const Color(0xFF0F9D8A) : theme.colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.surface,
            canvasAccent.withValues(alpha: _isFriendsTree ? 0.04 : 0.02),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: canvasAccent.withValues(alpha: 0.18),
        ),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withValues(alpha: 0.06),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: InteractiveFamilyTree(
          peopleData: _relativesData,
          relations: _relationsData,
          currentUserId: _authService.currentUserId,
          branchRootPersonId: _branchRootPersonId,
          onBranchFocusCleared: _resetBranchFocus,
          onPersonTap: (person) {
            debugPrint('Нажатие на узел: ${person.name} (${person.id})');
            context.push('/relative/details/${person.id}');
          },
          onBranchFocusRequested: _focusBranch,
          isEditMode: _isEditMode,
          selectedEditPersonId: _selectedEditPersonId,
          onEditPersonSelected: (person) {
            setState(() {
              _selectedEditPersonId = person.id;
              _selectedEditPersonName = person.name;
            });
          },
          manualNodePositions: _manualNodePositions,
          onNodePositionsChanged: (positions) {
            _handleNodePositionsChanged(positions);
          },
          showGenerationGuides: !_isFriendsTree,
          enableClusterHighlights: !_isFriendsTree,
          graphLabel: _isFriendsTree ? 'дружеского графа' : 'дерева',
          hasManualLayout: _manualNodePositions.isNotEmpty,
          onResetLayout:
              _manualNodePositions.isNotEmpty && _currentTreeId != null
                  ? () => _resetManualTreeLayout(_currentTreeId!)
                  : null,
          onAddRelativeTapWithType: _handleAddRelativeFromTree,
          currentUserIsInTree: _currentUserIsInTree,
          onAddSelfTapWithType: _handleAddSelfFromTree,
        ),
      ),
    );
  }

  Widget _buildTreeHeroBanner(String selectedTreeName) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final accent =
        _isFriendsTree ? const Color(0xFF0F9D8A) : colorScheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.18),
            colorScheme.surfaceContainerHighest.withValues(alpha: 0.75),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              _isFriendsTree
                  ? Icons.diversity_3_outlined
                  : Icons.account_tree_outlined,
              color: accent,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isFriendsTree
                      ? 'Активен дружеский граф'
                      : 'Активно семейное дерево',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _isFriendsTree
                      ? '"$selectedTreeName" сейчас открыт для ручной композиции, быстрых переходов по людям и чатов внутри круга.'
                      : '"$selectedTreeName" сейчас открыт для ручной композиции, быстрых переходов по веткам и семейных чатов.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
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

  Widget _buildOverviewCard(
    String selectedTreeId,
    String selectedTreeName, {
    required bool compact,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final branchRootPerson = _findBranchRootPerson();
    final branchCount = _graphClusterCount;

    if (compact) {
      final compactPrimaryAction =
          _currentUserIsInTree ? 'Добавить' : 'Добавить себя';
      final canOpenBranchChat = branchRootPerson != null;
      final branchChatLabel =
          _isFriendsTree ? 'Написать кругу' : 'Написать ветке';

      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isEditMode
                  ? 'Режим редактирования включён'
                  : 'Граф готов к просмотру',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${_relativesData.length} $_peopleLabel, ${_relationsData.length} связей, $branchCount $_branchLabel.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _isFriendsTree
                  ? 'Это свободный граф друзей: карточки лучше раскладывать вручную, а связи сохраняются и перестраиваются прямо на полотне.'
                  : 'В edit mode карточки можно двигать вручную: связи сохраняются и перестраиваются прямо на полотне.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => _navigateToAddRelative(selectedTreeId),
                  icon: const Icon(Icons.person_add_alt_1),
                  label: Text(compactPrimaryAction),
                ),
                if (canOpenBranchChat)
                  OutlinedButton.icon(
                    onPressed: () =>
                        _openBranchChat(selectedTreeId, branchRootPerson),
                    icon: const Icon(Icons.forum_outlined),
                    label: Text(branchChatLabel),
                  ),
                OutlinedButton.icon(
                  onPressed: () => context.go('/tree?selector=1'),
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Сменить'),
                ),
                if (_branchRootPersonId != null)
                  OutlinedButton.icon(
                    onPressed: _resetBranchFocus,
                    icon: const Icon(Icons.clear_all),
                    label: Text(
                      _isFriendsTree ? 'Сбросить круг' : 'Сбросить ветку',
                    ),
                  ),
                if (_manualNodePositions.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => _resetManualTreeLayout(selectedTreeId),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Сбросить layout'),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildInfoChip(
                  icon: _isEditMode ? Icons.edit : Icons.visibility_outlined,
                  label: _isEditMode ? 'Редактирование' : 'Просмотр',
                ),
                if (_currentTreeMeta != null)
                  _buildInfoChip(
                    icon: _currentTreeMeta!.isPrivate
                        ? Icons.lock_outline
                        : Icons.public,
                    label:
                        _currentTreeMeta!.isPrivate ? 'Приватное' : 'Публичное',
                  ),
                _buildInfoChip(
                  icon: _currentUserIsInTree
                      ? Icons.verified_user_outlined
                      : Icons.person_add_alt_1,
                  label: _currentUserIsInTree
                      ? 'Вы в дереве'
                      : 'Вы ещё не добавлены',
                  highlighted: !_currentUserIsInTree,
                ),
                if (_branchRootName != null)
                  _buildInfoChip(
                    icon: Icons.alt_route,
                    label:
                        '${_isFriendsTree ? 'Круг' : 'Ветка'}: $_branchRootName',
                    highlighted: true,
                  ),
                if (_selectedEditPersonName != null && _isEditMode)
                  _buildInfoChip(
                    icon: Icons.ads_click_outlined,
                    label: 'Выбрано: $_selectedEditPersonName',
                    highlighted: true,
                  ),
                if (_manualNodePositions.isNotEmpty)
                  _buildInfoChip(
                    icon: Icons.open_with,
                    label: 'Ручной layout активен',
                    highlighted: true,
                  ),
                _buildInfoChip(
                  icon: Icons.diversity_3_outlined,
                  label: _isFriendsTree
                      ? 'Режим друзей включён'
                      : 'Дерево друзей: доступно',
                ),
              ],
            ),
          ],
        ),
      );
    }

    final branchChatLabel =
        _isFriendsTree ? 'Написать кругу' : 'Написать ветке';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            selectedTreeName,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _treeLabel,
            style: theme.textTheme.labelLarge?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _isEditMode
                ? _isFriendsTree
                    ? 'Режим редактирования включён. Это свободный граф друзей: тяните карточки по полотну, чтобы собрать свой круг вручную.'
                    : 'Режим редактирования включён. Нажмите на карточку человека, чтобы открыть быстрые действия, или тяните её по полотну для ручной композиции дерева.'
                : _isFriendsTree
                    ? 'Открывайте карточки, чтобы смотреть детали. В режиме друзей поколенческая сетка скрыта, а акцент сделан на свободную сеть связей.'
                    : 'Открывайте карточки людей, чтобы смотреть детали. Для правок включите режим редактирования. Долгое нажатие или плашка «Ветка» фокусируют схему на нужной семье.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildInfoChip(
                icon: Icons.people_alt_outlined,
                label: '${_relativesData.length} $_peopleLabel',
              ),
              _buildInfoChip(
                icon: Icons.hub_outlined,
                label: '${_relationsData.length} связей',
              ),
              _buildInfoChip(
                icon: Icons.group_work_outlined,
                label: '$branchCount $_branchLabel',
              ),
              _buildInfoChip(
                icon: Icons.unfold_more_outlined,
                label: 'Drag, zoom, + / - / 0',
              ),
              if (_manualNodePositions.isNotEmpty)
                _buildInfoChip(
                  icon: Icons.open_with,
                  label: 'Ручной layout сохранён',
                  highlighted: true,
                ),
              _buildInfoChip(
                icon: _isEditMode ? Icons.edit : Icons.visibility_outlined,
                label: _isEditMode ? 'Редактирование' : 'Просмотр',
              ),
              if (_selectedEditPersonName != null && _isEditMode)
                _buildInfoChip(
                  icon: Icons.ads_click_outlined,
                  label: 'Выбрано: $_selectedEditPersonName',
                  highlighted: true,
                ),
              if (_currentTreeMeta != null)
                _buildInfoChip(
                  icon: _currentTreeMeta!.isPrivate
                      ? Icons.lock_outline
                      : Icons.public,
                  label:
                      _currentTreeMeta!.isPrivate ? 'Приватное' : 'Публичное',
                ),
              if (_currentTreeMeta?.isCertified == true)
                _buildInfoChip(
                  icon: Icons.verified_outlined,
                  label: 'Сертифицировано',
                  highlighted: true,
                ),
              if (_branchRootName != null)
                _buildInfoChip(
                  icon: Icons.alt_route,
                  label:
                      '${_isFriendsTree ? 'Круг' : 'Ветка'}: $_branchRootName',
                  highlighted: true,
                ),
              _buildInfoChip(
                icon: _currentUserIsInTree
                    ? Icons.verified_user_outlined
                    : Icons.person_add_alt_1,
                label: _currentUserIsInTree
                    ? 'Вы уже в дереве'
                    : 'Вы ещё не добавлены',
                highlighted: !_currentUserIsInTree,
              ),
              _buildInfoChip(
                icon: Icons.diversity_3_outlined,
                label: _isFriendsTree
                    ? 'Дружеский граф'
                    : 'Можно создать дерево друзей',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildLegendChip(
                color: Colors.blue.shade300,
                label: 'Мужчины',
              ),
              _buildLegendChip(
                color: Colors.pink.shade300,
                label: 'Женщины',
              ),
              _buildLegendChip(
                color: colorScheme.primary,
                label: 'Вы в дереве',
              ),
              if (_isFriendsTree)
                _buildLegendChip(
                  color: Colors.teal.shade400,
                  label: 'Свободная сеть',
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (_currentTreeMeta?.certificationNote != null &&
              _currentTreeMeta!.certificationNote!.trim().isNotEmpty) ...[
            Text(
              _currentTreeMeta!.certificationNote!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 14),
          ],
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: () => context.go('/tree?selector=1'),
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Сменить дерево'),
              ),
              FilledButton.icon(
                onPressed: () => context.go('/relatives'),
                icon: const Icon(Icons.people_outline),
                label:
                    Text(_isFriendsTree ? 'Открыть связи' : 'Открыть родных'),
              ),
              FilledButton.icon(
                onPressed: () => context.go('/chats'),
                icon: const Icon(Icons.forum_outlined),
                label: const Text('Открыть чаты'),
              ),
              FilledButton.icon(
                onPressed: () => context.push('/post/create'),
                icon: const Icon(Icons.post_add_outlined),
                label: Text(_isFriendsTree ? 'Пост в круг' : 'Новый пост'),
              ),
              if (_branchRootPersonId != null)
                OutlinedButton.icon(
                  onPressed: _resetBranchFocus,
                  icon: const Icon(Icons.account_tree_outlined),
                  label: Text(_isFriendsTree
                      ? 'Показать весь граф'
                      : 'Показать всё дерево'),
                ),
              if (branchRootPerson != null)
                OutlinedButton.icon(
                  onPressed: () =>
                      _openBranchChat(selectedTreeId, branchRootPerson),
                  icon: const Icon(Icons.forum_outlined),
                  label: Text(branchChatLabel),
                ),
              if (branchRootPerson != null)
                OutlinedButton.icon(
                  onPressed: () =>
                      context.push('/relative/details/${branchRootPerson.id}'),
                  icon: const Icon(Icons.open_in_new),
                  label: Text(
                    _isFriendsTree
                        ? 'Открыть карточку круга'
                        : 'Открыть карточку ветки',
                  ),
                ),
              if (_currentTreeMeta?.isPublic == true)
                OutlinedButton.icon(
                  onPressed: _copyPublicTreeLink,
                  icon: const Icon(Icons.link_outlined),
                  label: const Text('Скопировать публичную ссылку'),
                ),
              OutlinedButton.icon(
                onPressed: () => _navigateToAddRelative(selectedTreeId),
                icon: const Icon(Icons.person_add_alt_1),
                label: Text(
                    _isFriendsTree ? 'Добавить в круг' : 'Добавить человека'),
              ),
              OutlinedButton.icon(
                onPressed: () => _loadData(selectedTreeId),
                icon: const Icon(Icons.refresh),
                label: const Text('Обновить'),
              ),
              if (_manualNodePositions.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () => _resetManualTreeLayout(selectedTreeId),
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Сбросить layout'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoChip({
    required IconData icon,
    required String label,
    bool highlighted = false,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: highlighted ? colorScheme.primaryContainer : colorScheme.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: highlighted ? colorScheme.primary : colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegendChip({
    required Color color,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildTreeState({
    required IconData icon,
    required String title,
    required String message,
    List<Widget> actions = const [],
    bool showProgress = false,
  }) {
    final theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.45,
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showProgress)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 20),
                    child: CircularProgressIndicator(),
                  )
                else
                  Icon(icon, size: 56, color: theme.colorScheme.primary),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 10,
                    runSpacing: 10,
                    children: actions,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // === НОВЫЙ МЕТОД-КОЛЛБЭК для InteractiveFamilyTree ===
  Future<void> _handleNodePositionsChanged(
    Map<String, Offset> updatedPositions,
  ) async {
    final treeId = _currentTreeId;
    if (treeId == null) {
      return;
    }

    setState(() {
      _manualNodePositions = updatedPositions;
    });
    await _localStorageService.saveTreeNodePositions(treeId, updatedPositions);
  }

  Future<void> _resetManualTreeLayout(String treeId) async {
    await _localStorageService.clearTreeNodePositions(treeId);
    if (!mounted) {
      return;
    }
    setState(() {
      _manualNodePositions = <String, Offset>{};
    });
    await _loadData(treeId);
  }

  void _handleAddRelativeFromTree(FamilyPerson person, RelationType type) {
    if (_currentTreeId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Ошибка: Не удается определить текущее дерево.'),
        ),
      );
      return;
    }
    debugPrint(
      'Добавление родственника типа $type к ${person.name} (${person.id}) в дереве $_currentTreeId',
    );

    // Переходим на экран добавления, передавая контекст
    // AddRelativeScreen должен будет обработать эти параметры в 'extra'
    context.push(
      '/relatives/add/$_currentTreeId',
      extra: {
        'contextPersonId': person.id, // К кому добавляем
        'relationType':
            type, // Какого типа родственника добавляем (относительно contextPersonId)
        'quickAddMode': true,
      },
    ).then((result) {
      if (!mounted) {
        return;
      }
      if (result == true) {
        debugPrint('Возврат с экрана добавления (из дерева), перезагрузка...');
        _loadData(_currentTreeId!);
        return;
      }
      if (result is Map<String, dynamic> && result['updated'] == true) {
        final focusPersonId = result['focusPersonId']?.toString();
        _loadData(_currentTreeId!).then((_) {
          if (!mounted || focusPersonId == null) {
            return;
          }
          final focusedPerson = _relativesData
              .map((entry) => entry['person'])
              .whereType<FamilyPerson>()
              .firstWhere(
                (candidate) => candidate.id == focusPersonId,
                orElse: () => FamilyPerson.empty,
              );
          if (focusedPerson != FamilyPerson.empty) {
            setState(() {
              _selectedEditPersonId = focusedPerson.id;
              _selectedEditPersonName = focusedPerson.name;
            });
          }
        });
      }
    });
  }

  // <<< НОВЫЙ МЕТОД-КОЛЛБЭК: Обработка добавления себя из дерева >>>
  Future<void> _handleAddSelfFromTree(
    FamilyPerson targetPerson,
    RelationType relationType,
  ) async {
    if (_currentTreeId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Ошибка: Не удается определить текущее дерево.'),
        ),
      );
      return;
    }

    final currentUserId = _authService.currentUserId;
    if (currentUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: Пользователь не авторизован.')),
      );
      context.go('/login'); // Перенаправляем на логин
      return;
    }

    // Показываем индикатор загрузки
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return Dialog(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text("Добавляем вас в дерево..."),
              ],
            ),
          ),
        );
      },
    );

    try {
      debugPrint(
        'Добавление ТЕКУЩЕГО ПОЛЬЗОВАТЕЛЯ ($currentUserId) типа $relationType к ${targetPerson.name} (${targetPerson.id}) в дереве $_currentTreeId',
      );

      // Вызываем новый метод сервиса
      await _familyService.addCurrentUserToTree(
        treeId: _currentTreeId!,
        targetPersonId: targetPerson.id,
        relationType: relationType,
      );
      if (!mounted) return;

      // Закрываем диалог загрузки
      Navigator.pop(context);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Вы успешно добавлены в дерево!'),
          duration: Duration(seconds: 2),
        ),
      );

      // Обновляем данные дерева, чтобы отобразить изменения и скрыть кнопку
      debugPrint('Перезагрузка дерева после добавления себя...');
      setState(() {
        _currentUserIsInTree = true;
      });
      await _loadData(_currentTreeId!);
    } catch (e, s) {
      // Закрываем диалог загрузки в случае ошибки
      if (mounted) Navigator.pop(context);

      debugPrint('Ошибка при добавлении себя в дерево: $e\\n$s');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _describeTreeActionError(
                e,
                fallbackMessage:
                    'Не удалось добавить вас в дерево. Попробуйте ещё раз.',
              ),
            ),
            duration: Duration(seconds: 5),
          ),
        );
      }
      debugPrint('Error in handleAddSelfFromTree: $e\n$s');
    }
  }

  // =============================================================

  Future<void> _navigateToAddRelative(String treeId) async {
    final result = await context.push('/relatives/add/$treeId');
    if ((result == true ||
            (result is Map<String, dynamic> && result['updated'] == true)) &&
        mounted) {
      await _loadData(treeId);
    }
  }

  int _estimateFamilyBranchCount() {
    final parentToChildren = <String, Set<String>>{};
    final spousesByPerson = <String, Set<String>>{};

    for (final relation in _relationsData) {
      final parentId = _parentIdFromRelation(relation);
      final childId = _childIdFromRelation(relation);
      if (parentId != null && childId != null) {
        parentToChildren.putIfAbsent(parentId, () => <String>{}).add(childId);
      }
      if (_isSpouseRelation(relation)) {
        spousesByPerson
            .putIfAbsent(relation.person1Id, () => <String>{})
            .add(relation.person2Id);
        spousesByPerson
            .putIfAbsent(relation.person2Id, () => <String>{})
            .add(relation.person1Id);
      }
    }

    final processed = <String>{};
    var count = 0;
    for (final entry in _relativesData) {
      final person = entry['person'];
      if (person is! FamilyPerson) {
        continue;
      }
      final familyGroup = <String>{person.id};
      final queue = <String>[person.id];
      while (queue.isNotEmpty) {
        final currentId = queue.removeAt(0);
        for (final spouseId in spousesByPerson[currentId] ?? const <String>{}) {
          if (familyGroup.add(spouseId)) {
            queue.add(spouseId);
          }
        }
      }
      final groupKey = familyGroup.toList();
      groupKey.sort();
      final groupKeyString = groupKey.join('::');
      if (!processed.add(groupKeyString)) {
        continue;
      }
      final hasChildren = familyGroup.any(
        (memberId) =>
            (parentToChildren[memberId] ?? const <String>{}).isNotEmpty,
      );
      if (familyGroup.length > 1 || hasChildren) {
        count++;
      }
    }

    return count == 0 && _relativesData.isNotEmpty ? 1 : count;
  }

  int _estimateGraphCircleCount() {
    final personIds = _relativesData
        .map((entry) => entry['person'])
        .whereType<FamilyPerson>()
        .map((person) => person.id)
        .toSet();
    if (personIds.isEmpty) {
      return 0;
    }

    final adjacency = <String, Set<String>>{
      for (final id in personIds) id: <String>{},
    };
    for (final relation in _relationsData) {
      if (!personIds.contains(relation.person1Id) ||
          !personIds.contains(relation.person2Id)) {
        continue;
      }
      adjacency
          .putIfAbsent(relation.person1Id, () => <String>{})
          .add(relation.person2Id);
      adjacency
          .putIfAbsent(relation.person2Id, () => <String>{})
          .add(relation.person1Id);
    }

    final visited = <String>{};
    var count = 0;
    for (final personId in personIds) {
      if (!visited.add(personId)) {
        continue;
      }
      count++;
      final queue = <String>[personId];
      while (queue.isNotEmpty) {
        final currentId = queue.removeLast();
        for (final neighbour in adjacency[currentId] ?? const <String>{}) {
          if (visited.add(neighbour)) {
            queue.add(neighbour);
          }
        }
      }
    }

    return count;
  }

  bool _isSpouseRelation(FamilyRelation relation) {
    return relation.relation1to2 == RelationType.spouse ||
        relation.relation2to1 == RelationType.spouse ||
        relation.relation1to2 == RelationType.partner ||
        relation.relation2to1 == RelationType.partner;
  }

  String? _parentIdFromRelation(FamilyRelation relation) {
    if (relation.relation1to2 == RelationType.parent ||
        relation.relation2to1 == RelationType.child) {
      return relation.person1Id;
    }
    if (relation.relation2to1 == RelationType.parent ||
        relation.relation1to2 == RelationType.child) {
      return relation.person2Id;
    }
    return null;
  }

  String? _childIdFromRelation(FamilyRelation relation) {
    if (relation.relation1to2 == RelationType.parent ||
        relation.relation2to1 == RelationType.child) {
      return relation.person2Id;
    }
    if (relation.relation2to1 == RelationType.parent ||
        relation.relation1to2 == RelationType.child) {
      return relation.person1Id;
    }
    return null;
  }

  Set<String> _buildBranchVisiblePersonIds(String branchRootPersonId) {
    final personIds = _relativesData
        .map((entry) => entry['person'])
        .whereType<FamilyPerson>()
        .map((person) => person.id)
        .toSet();
    if (!personIds.contains(branchRootPersonId)) {
      return personIds;
    }

    final childrenByParent = <String, Set<String>>{};
    final spousesByPerson = <String, Set<String>>{};
    for (final relation in _relationsData) {
      final parentId = _parentIdFromRelation(relation);
      final childId = _childIdFromRelation(relation);
      if (parentId != null && childId != null) {
        childrenByParent.putIfAbsent(parentId, () => <String>{}).add(childId);
      }
      if (_isSpouseRelation(relation)) {
        spousesByPerson
            .putIfAbsent(relation.person1Id, () => <String>{})
            .add(relation.person2Id);
        spousesByPerson
            .putIfAbsent(relation.person2Id, () => <String>{})
            .add(relation.person1Id);
      }
    }

    final visibleIds = <String>{branchRootPersonId};
    final queue = <String>[branchRootPersonId];
    while (queue.isNotEmpty) {
      final currentId = queue.removeAt(0);
      for (final spouseId in spousesByPerson[currentId] ?? const <String>{}) {
        if (visibleIds.add(spouseId)) {
          queue.add(spouseId);
        }
      }
      for (final childId in childrenByParent[currentId] ?? const <String>{}) {
        if (visibleIds.add(childId)) {
          queue.add(childId);
        }
      }
    }

    return visibleIds;
  }

  List<String> _buildBranchChatParticipantIds(String branchRootPersonId) {
    final participantIds = <String>{};
    final currentUserId = _authService.currentUserId;
    if (currentUserId != null && currentUserId.isNotEmpty) {
      participantIds.add(currentUserId);
    }

    final visibleIds = _buildBranchVisiblePersonIds(branchRootPersonId);
    for (final entry in _relativesData) {
      final person = entry['person'];
      if (person is! FamilyPerson || !visibleIds.contains(person.id)) {
        continue;
      }
      final linkedUserId = person.userId?.trim();
      if (linkedUserId != null && linkedUserId.isNotEmpty) {
        participantIds.add(linkedUserId);
      }
    }

    final sortedIds = participantIds.toList();
    sortedIds.sort();
    return sortedIds;
  }

  Future<FamilyTree?> _loadCurrentTreeMeta(String treeId) async {
    try {
      final trees = await _familyService.getUserTrees();
      for (final tree in trees) {
        if (tree.id == treeId) {
          return tree;
        }
      }
    } catch (_) {}
    return _currentTreeMeta?.id == treeId ? _currentTreeMeta : null;
  }

  void _focusBranch(FamilyPerson person) {
    if (!mounted) {
      return;
    }
    setState(() {
      _branchRootPersonId = person.id;
      _branchRootName = person.name;
    });
  }

  void _resetBranchFocus() {
    if (!mounted) {
      return;
    }
    setState(() {
      _branchRootPersonId = null;
      _branchRootName = null;
    });
  }

  FamilyPerson? _findBranchRootPerson() {
    final branchRootPersonId = _branchRootPersonId;
    if (branchRootPersonId == null) {
      return null;
    }

    for (final entry in _relativesData) {
      final person = entry['person'];
      if (person is FamilyPerson && person.id == branchRootPersonId) {
        return person;
      }
    }
    return null;
  }

  Future<void> _openBranchChat(
    String treeId,
    FamilyPerson? branchRootPerson,
  ) async {
    if (branchRootPerson == null) {
      return;
    }

    final participantIds = _buildBranchChatParticipantIds(branchRootPerson.id);
    if (participantIds.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('В этой ветке пока некому писать в общий чат.'),
        ),
      );
      return;
    }

    final title = 'Ветка ${branchRootPerson.name}';
    try {
      final chatId = await _chatService.createBranchChat(
        treeId: treeId,
        branchRootPersonIds: <String>[branchRootPerson.id],
        title: title,
      );
      if (!mounted) {
        return;
      }
      if (chatId == null || chatId.isEmpty) {
        throw StateError('Не удалось создать чат ветки');
      }

      context.push(
        '/chats/view/$chatId?type=branch&title=${Uri.encodeComponent(title)}',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _describeTreeActionError(
              error,
              fallbackMessage: 'Не удалось открыть чат ветки.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _copyPublicTreeLink() async {
    final treeMeta = _currentTreeMeta;
    if (treeMeta == null || !treeMeta.isPublic) {
      return;
    }

    final publicUri = PublicTreeLinkService.buildPublicTreeUri(
      treeMeta.publicRouteId,
      publicAppUrl: BackendRuntimeConfig.current.publicAppUrl,
    );

    await Clipboard.setData(ClipboardData(text: publicUri.toString()));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Публичная ссылка скопирована.')),
    );
  }
}
