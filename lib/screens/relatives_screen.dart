import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:ui';
import 'package:get_it/get_it.dart';
import 'package:intl/intl.dart';
import '../utils/date_parser.dart';
import '../utils/invitation_share.dart';

import '../theme/app_theme.dart';
import '../models/family_tree.dart';
import '../models/family_person.dart';
import '../models/family_relation.dart';
import '../models/chat_preview.dart';
import '../providers/tree_provider.dart';
import '../widgets/glass_panel.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/chat_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/identity_conflicts_capable_family_tree_service.dart';
import '../backend/interfaces/invitation_link_service_interface.dart';
import '../backend/models/identity_field_conflict.dart';
import '../services/app_status_service.dart';
import '../utils/photo_url.dart';
import '../utils/relative_details_route.dart';
import '../utils/snackbar.dart';
import '../utils/user_facing_error.dart';
import '../widgets/branch_switcher_chip.dart';
import '../widgets/identity_conflicts_badge.dart';
import '../widgets/identity_conflicts_sheet.dart';
import '../widgets/relation_picker_sheet.dart';

part 'relatives_screen_sections.dart';

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

  /// F3: сброс session-состояния свёртки «Нужно пригласить» между
  /// тестами (паттерн session-dismiss баннеров).
  @visibleForTesting
  static void debugResetPendingSectionState() {
    _RelativesScreenState._pendingSectionExpandedThisSession = false;
  }

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
  final AppStatusService _appStatusService = GetIt.I<AppStatusService>();

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
  bool _isRelationsReady = false;
  bool _isChatsReady = false;
  bool _isPendingRequestsLoading = true;
  String _searchQuery = '';
  late final TextEditingController _searchController;
  // Мобильный поиск живёт в топбаре за иконкой (как в чатах) и
  // раскрывается на месте заголовка — отдельной строки поиска нет.
  final FocusNode _searchFocusNode = FocusNode();
  bool _isSearchOpen = false;

  // F3: «Нужно пригласить» свёрнута по умолчанию; решение пользователя
  // живёт сессию (static — переживает переключение вкладок/экранов).
  static bool _pendingSectionExpandedThisSession = false;
  // Phase 3.4 chunk 5: per-row + header conflict badges.
  // `_conflictCounts` keyed by personId → unresolved count.
  // `_treeConflictsCache` — flat list для sheet'а (filtered by
  // targetPersonId при открытии).
  Map<String, int> _conflictCounts = const <String, int>{};
  List<IdentityFieldConflict> _treeConflictsCache =
      const <IdentityFieldConflict>[];

  @override
  void initState() {
    super.initState();

    debugPrint('[_RelativesScreenState initState] called');

    _searchController = TextEditingController();
    _searchController.addListener(() {
      final next = _searchController.text;
      if (next != _searchQuery) {
        setState(() => _searchQuery = next);
      }
    });

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
      // Объясняющий диалог «Проверить родство» при первом входе убран
      // (02.09.2026): подсказку несёт tooltip самой кнопки, а модалка
      // перекрывала список людей в первую же секунду.
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
    _searchController.dispose();
    _searchFocusNode.dispose();
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
      _isRelationsReady = false;
      _isChatsReady = false;
      _isPendingRequestsLoading = true;
      _conflictCounts = const <String, int>{};
      _treeConflictsCache = const <IdentityFieldConflict>[];
    });

    unawaited(_checkPendingRequests(treeId));
    unawaited(_refreshConflictCounts(treeId));
    try {
      await _setupDataListeners(treeId, _currentUserId!);
    } catch (e) {
      debugPrint('Ошибка при инициализации данных для дерева $treeId: $e');
      _appStatusService.reportError(
        e,
        fallbackMessage: 'Не удалось загрузить список родных.',
      );
      if (mounted) {
        setState(() {
          _isLoading = false;
          if (_allRelatives.isEmpty) {
            _errorMessage = _appStatusService.isOffline
                ? 'Нет соединения. Родные появятся, когда интернет вернётся.'
                : 'Ошибка загрузки данных дерева.';
          }
        });
      }
    }
  }

  /// Phase 3.4 chunk 5: best-effort fetch identity conflicts на
  /// текущем tree'е. Сlient fail-safe: при ошибке cache stays
  /// empty, badge'ов нет. Backend без capability — silently
  /// skip'аем (старый сервер).
  Future<void> _refreshConflictCounts(String treeId) async {
    final service = _familyService;
    if (service is! IdentityConflictsCapableFamilyTreeService) return;
    final capable = service as IdentityConflictsCapableFamilyTreeService;
    List<IdentityFieldConflict> conflicts;
    try {
      conflicts = await capable.getIdentityConflictsForTree(treeId: treeId);
    } catch (_) {
      return;
    }
    if (!mounted || _currentTreeId != treeId) return;
    final unresolved =
        conflicts.where((c) => !c.isResolved).toList(growable: false);
    final counts = <String, int>{};
    for (final conflict in unresolved) {
      counts[conflict.targetPersonId] =
          (counts[conflict.targetPersonId] ?? 0) + 1;
    }
    setState(() {
      _conflictCounts = counts;
      _treeConflictsCache = unresolved;
    });
  }

  /// Открывает sheet с conflicts конкретного person'а — тот же
  /// reusable widget что и на canvas.
  Future<void> _showConflictsSheet(String personId) async {
    final treeId = _currentTreeId;
    final service = _familyService;
    if (treeId == null ||
        service is! IdentityConflictsCapableFamilyTreeService) {
      return;
    }
    final personConflicts = _treeConflictsCache
        .where((c) => c.targetPersonId == personId && !c.isResolved)
        .toList(growable: false);
    if (personConflicts.isEmpty) {
      // Cache stale — refresh и выходим (badge исчезнет на следующем
      // setState).
      await _refreshConflictCounts(treeId);
      return;
    }
    final capable = service as IdentityConflictsCapableFamilyTreeService;
    await showIdentityConflictsSheet(
      context: context,
      conflicts: personConflicts,
      onChoice: (sheetContext, conflict, choice) async {
        try {
          await capable.resolveIdentityConflict(
            treeId: treeId,
            conflictId: conflict.id,
            choice: choice,
          );
        } catch (error) {
          if (sheetContext.mounted) {
            ScaffoldMessenger.of(sheetContext).showSnackBar(
              SnackBar(
                  content: Text(humanizeError(error,
                      fallback: 'Не удалось применить выбор.'))),
            );
          }
          return;
        }
        if (sheetContext.mounted) {
          Navigator.of(sheetContext).pop();
        }
        await _refreshConflictCounts(treeId);
      },
    );
  }

  /// Открывает summary sheet'е со ВСЕМИ unresolved conflict'ами
  /// дерева — без разбивки по person'у. Используется header
  /// banner'ом «N карточек требуют внимания».
  Future<void> _showAllTreeConflicts() async {
    final treeId = _currentTreeId;
    final service = _familyService;
    if (treeId == null ||
        service is! IdentityConflictsCapableFamilyTreeService ||
        _treeConflictsCache.isEmpty) {
      return;
    }
    final capable = service as IdentityConflictsCapableFamilyTreeService;
    await showIdentityConflictsSheet(
      context: context,
      conflicts: _treeConflictsCache,
      onChoice: (sheetContext, conflict, choice) async {
        try {
          await capable.resolveIdentityConflict(
            treeId: treeId,
            conflictId: conflict.id,
            choice: choice,
          );
        } catch (error) {
          if (sheetContext.mounted) {
            ScaffoldMessenger.of(sheetContext).showSnackBar(
              SnackBar(
                  content: Text(humanizeError(error,
                      fallback: 'Не удалось применить выбор.'))),
            );
          }
          return;
        }
        if (sheetContext.mounted) {
          Navigator.of(sheetContext).pop();
        }
        await _refreshConflictCounts(treeId);
      },
    );
  }

  /// Phase 3.4 chunk 5: tree-level summary banner. Возвращает
  /// SizedBox.shrink если conflict'ов нет — caller's wrap'ы
  /// padding'и schum'ятся autoMagic'ом (banner сам decide'ит).
  Widget _maybeConflictTreeBanner() {
    if (_conflictCounts.isEmpty || _treeConflictsCache.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: IdentityConflictsHeaderBanner(
        count: _conflictCounts.length,
        onTap: _showAllTreeConflicts,
        scope: ConflictBannerScope.tree,
      ),
    );
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
      _appStatusService.reportError(
        e,
        fallbackMessage: 'Не удалось обновить запросы по дереву.',
      );
    } finally {
      if (mounted) {
        setState(() {
          _isPendingRequestsLoading = false;
        });
      }
    }
  }

  Future<void> _setupDataListeners(String treeId, String currentUserId) async {
    _cancelSubscriptions();

    final completerRelatives = Completer<void>();

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
            _isLoading = false;
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
            _isRelationsReady = true;
          });
        }
      },
      onError: (error, stackTrace) {
        if (mounted) {
          debugPrint('Ошибка в Stream связей: $error');
          _handleStreamError(
            error,
            stackTrace,
            'RelationsStreamError',
            null,
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
            _isChatsReady = true;
          });
        }
      },
      onError: (error, stackTrace) {
        if (mounted) {
          debugPrint('Ошибка в Stream чатов: $error');
          _handleStreamError(
            error,
            stackTrace,
            'ChatsStreamError',
            null,
          );
        }
      },
      cancelOnError: false,
    );

    try {
      await completerRelatives.future.timeout(const Duration(seconds: 10));
    } catch (e, stackTrace) {
      debugPrint('Ошибка или таймаут при ожидании данных: $e');
      debugPrint('Error: $e\n$stackTrace');
      if (mounted && _isLoading) {
        setState(() {
          _isLoading = false;
          _errorMessage = _appStatusService.isOffline
              ? 'Нет соединения. Проверьте интернет и попробуйте ещё раз.'
              : 'Не удалось загрузить список родных. Попробуйте ещё раз.';
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
      MediaQuery.of(context).size.width >= 1500;

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
    final List<FamilyPerson> baseRelatives =
        _allRelatives.where((p) => p.userId != currentUserId).toList();
    final String trimmedQuery = _searchQuery.trim().toLowerCase();
    final List<FamilyPerson> visibleRelatives = trimmedQuery.isEmpty
        ? baseRelatives
        : baseRelatives.where((p) {
            final name = p.displayName.toLowerCase();
            final relation = (p.relation ?? '').toLowerCase();
            return name.contains(trimmedQuery) ||
                relation.contains(trimmedQuery);
          }).toList();
    final chatReadyCount =
        visibleRelatives.where((person) => _canStartChat(person)).length;
    final inviteReadyCount =
        visibleRelatives.where((person) => _canInviteRelative(person)).length;
    // -------------------------

    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    final isWideLayout = _isWideLayout(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(AppTheme.topbarHeight(context)),
        child: _buildRelativesTopbar(
          theme: theme,
          tokens: tokens,
          treeProvider: treeProvider,
          selectedTreeId: selectedTreeId,
          isFriendsTree: isFriendsTree,
        ),
      ),
      body: selectedTreeId == null
          ? _buildNoTreeSelected()
          : _isLoading
              ? _buildLoadingState()
              : _errorMessage.isNotEmpty && _allRelatives.isEmpty
                  ? _buildErrorState(selectedTreeId)
                  : Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1420),
                        child: Padding(
                          // На телефоне список идёт сразу под шапкой:
                          // строка поиска переехала в топбар.
                          padding: isWideLayout
                              ? const EdgeInsets.fromLTRB(16, 12, 16, 16)
                              : const EdgeInsets.fromLTRB(10, 0, 10, 8),
                          child: isWideLayout
                              ? Column(
                                  children: [
                                    _buildGraphContextBanner(
                                      treeName: selectedTreeName,
                                      isFriendsTree: isFriendsTree,
                                      relativesCount: visibleRelatives.length,
                                    ),
                                    _maybeConflictTreeBanner(),
                                    if (_showSecondaryLoadingStrip) ...[
                                      const SizedBox(height: 12),
                                      _buildSecondaryLoadingStrip(),
                                    ],
                                    const SizedBox(height: 12),
                                    _buildRelativesSearchField(
                                      theme: theme,
                                      tokens: tokens,
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
                                              isFriendsTree: isFriendsTree,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                )
                              : PopScope(
                                  canPop: !_isSearchOpen,
                                  onPopInvokedWithResult: (didPop, _) {
                                    if (!didPop) _closeSearch();
                                  },
                                  child: Column(
                                  children: [
                                    _maybeConflictTreeBanner(),
                                    if (_showSecondaryLoadingStrip) ...[
                                      const SizedBox(height: 10),
                                      _buildSecondaryLoadingStrip(),
                                    ],
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
                    ),
      // On phones the actions occupy their own row below the list. The old
      // stacked FABs covered a relative card and competed with the shell nav.
      // Wide layout keeps using the labelled actions in its side panel.
      bottomNavigationBar: selectedTreeId == null || isWideLayout
          ? null
          : _buildRelativesPrimaryActionBar(selectedTreeId, treeProvider),
    );
  }

  Widget _buildRelativesPrimaryActionBar(
    String selectedTreeId,
    TreeProvider treeProvider,
  ) {
    final tokens = AppTheme.tokensOf(context);
    return Material(
      key: const Key('relatives-primary-action-bar'),
      color: tokens.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Row(
            children: [
              if (!_isFriendsTree(treeProvider)) ...[
                IconButton.outlined(
                  key: const Key('discover-relatives-action'),
                  onPressed: () => context.push('/discover/relatives'),
                  tooltip: 'Проверить родство с человеком',
                  icon: const Icon(Icons.travel_explore_rounded),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: FilledButton.icon(
                    key: const Key('add-relative-action'),
                    onPressed: () {
                      unawaited(_startAddRelativeFlow(selectedTreeId));
                    },
                    icon: const Icon(Icons.add),
                    label: Text(_graphAddLabel(treeProvider)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _showSecondaryLoadingStrip =>
      !_isRelationsReady || !_isChatsReady || _isPendingRequestsLoading;

  Widget _buildLoadingState() {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassPanel(
          padding: const EdgeInsets.all(24),
          borderRadius: BorderRadius.circular(30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'Загружаем родных',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Сначала подтянем список, остальное догрузим следом.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState(String selectedTreeId) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: GlassPanel(
            padding: const EdgeInsets.all(24),
            borderRadius: BorderRadius.circular(30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _appStatusService.isOffline
                      ? Icons.cloud_off_outlined
                      : Icons.people_outline_rounded,
                  size: 40,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 14),
                Text(
                  _appStatusService.isOffline
                      ? 'Нет соединения'
                      : 'Родные временно недоступны',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _errorMessage,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: () {
                    _appStatusService.requestRetry();
                    unawaited(_loadDataForSelectedTree(selectedTreeId));
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Повторить'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSecondaryLoadingStrip() {
    final theme = Theme.of(context);
    final labels = <String>[
      if (!_isRelationsReady) 'связи',
      if (!_isChatsReady) 'чаты',
      if (_isPendingRequestsLoading) 'запросы',
    ];
    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      borderRadius: BorderRadius.circular(22),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Догружаем: ${labels.join(', ')}.',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoTreeSelected() {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: GlassPanel(
          padding: const EdgeInsets.all(24),
          borderRadius: BorderRadius.circular(30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.account_tree_outlined,
                size: 42,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 14),
              Text(
                'Выберите дерево',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Здесь появятся люди и действия.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                icon: const Icon(Icons.account_tree_outlined),
                label: const Text('Открыть'),
                onPressed: () => context.go('/trees'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRelativesSidePanel({
    required int relativesCount,
    required int chatReadyCount,
    required int inviteReadyCount,
    required String treeName,
    required bool isFriendsTree,
  }) {
    final treeProvider = Provider.of<TreeProvider>(context, listen: false);
    final isFriendsTree = _isFriendsTree(treeProvider);
    final peopleLabel = isFriendsTree ? 'в круге' : 'в дереве';
    return GlassPanel(
      padding: const EdgeInsets.all(16),
      borderRadius: BorderRadius.circular(30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildSideStatChip(
                icon: isFriendsTree
                    ? Icons.diversity_3_outlined
                    : Icons.account_tree_outlined,
                label: treeName,
              ),
              _buildSideStatChip(
                icon: Icons.people_outline,
                label: '$relativesCount $peopleLabel',
              ),
              if (chatReadyCount > 0)
                _buildSideStatChip(
                  icon: Icons.chat_bubble_outline,
                  label: _countLabel(
                    chatReadyCount,
                    one: 'чат',
                    few: 'чата',
                    many: 'чатов',
                  ),
                ),
              if (inviteReadyCount > 0)
                _buildSideStatChip(
                  icon: Icons.person_add_alt_1_outlined,
                  label: 'Пригласить $inviteReadyCount',
                ),
              if (_pendingRequestsCount > 0)
                _buildSideStatChip(
                  icon: Icons.notifications_none,
                  label: 'Запросы $_pendingRequestsCount',
                ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: _currentTreeId == null
                    ? null
                    : () => unawaited(_startAddRelativeFlow(_currentTreeId!)),
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: const Text('Добавить'),
              ),
              OutlinedButton.icon(
                onPressed: _currentTreeId == null
                    ? null
                    : () => context.push('/relatives/find/${_currentTreeId!}'),
                icon: const Icon(Icons.search),
                label: const Text('Найти'),
              ),
              if (!isFriendsTree)
                OutlinedButton.icon(
                  onPressed: () => context.push('/discover/relatives'),
                  icon: const Icon(Icons.travel_explore_rounded),
                  label: const Text('Проверить родство'),
                ),
              if (_pendingRequestsCount > 0)
                OutlinedButton.icon(
                  onPressed: _currentTreeId == null
                      ? null
                      : () => context
                          .push('/relatives/requests/${_currentTreeId!}'),
                  icon: const Icon(Icons.mark_email_unread_outlined),
                  label: const Text('Запросы'),
                ),
            ],
          ),
        ],
      ),
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

  void _openSearch() {
    if (_isSearchOpen) return;
    setState(() => _isSearchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  void _closeSearch() {
    if (!_isSearchOpen) return;
    _searchFocusNode.unfocus();
    _searchController.clear();
    setState(() => _isSearchOpen = false);
  }

  /// Раскрытый поиск в топбаре: стрелка «назад» + поле во всю ширину.
  List<Widget> _buildTopbarSearchRow(RodnyaDesignTokens tokens) {
    return [
      IconButton(
        tooltip: 'Закрыть поиск',
        icon: const Icon(Icons.arrow_back),
        onPressed: _closeSearch,
      ),
      Expanded(
        child: TextField(
          key: const ValueKey<String>('relatives-search-field'),
          controller: _searchController,
          focusNode: _searchFocusNode,
          autofocus: true,
          textAlignVertical: TextAlignVertical.center,
          style: AppTheme.sans(
            color: tokens.ink,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
          cursorColor: tokens.accent,
          decoration: InputDecoration(
            isCollapsed: true,
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
            hintText: 'Поиск среди родных',
            hintStyle: AppTheme.sans(
              color: tokens.inkMuted,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    tooltip: 'Очистить поиск',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: _searchController.clear,
                  )
                : null,
          ),
        ),
      ),
    ];
  }

  Widget _buildRelativesSearchField({
    required ThemeData theme,
    required RodnyaDesignTokens tokens,
  }) {
    // Reference styles.css `.card.flat`: surface bg, 14px h-padding, 46 height,
    // search icon at left, no shadow.
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tokens.surfaceLine),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 18, color: tokens.inkMuted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                hintText: 'Поиск среди родных',
                hintStyle: AppTheme.sans(
                  color: tokens.inkMuted,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              style: AppTheme.sans(
                color: tokens.ink,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              cursorColor: tokens.accent,
            ),
          ),
          if (_searchQuery.isNotEmpty)
            // MouseRegion + GestureDetector reads as a clickable icon on
            // desktop; an InkWell ripple inside a tight search row looks
            // out of place, so we just light up the cursor. Wrapped in
            // a 44dp SizedBox — гайдлайновый минимум тап-таргета (2c;
            // раньше 36dp «компактный край» — старшим мало).
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Semantics(
                button: true,
                label: 'Очистить поиск',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _searchController.clear();
                  },
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: tokens.inkMuted,
                    ),
                  ),
                ),
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
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final inAppCount = _allRelatives.where((p) {
      final id = p.userId;
      return id != null && id.isNotEmpty;
    }).length;

    return Container(
      decoration: BoxDecoration(
        color: tokens.surfaceStrong,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tokens.surfaceLine),
        boxShadow: tokens.panelShadow(theme.brightness),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: tokens.accentSoft,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              isFriendsTree
                  ? Icons.diversity_3_outlined
                  : Icons.account_tree_outlined,
              color: tokens.accent,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isFriendsTree ? 'АКТИВНЫЙ КРУГ' : 'АКТИВНОЕ ДЕРЕВО',
                  style: AppTheme.sans(
                    color: tokens.inkMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  treeName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.serif(
                    color: tokens.ink,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.18,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$inAppCount из $relativesCount в приложении',
                  style: AppTheme.sans(
                    color: tokens.inkMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
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
      // Пустой ПОИСК ≠ пустое дерево: «Родных пока нет / Добавьте
      // первого человека» при 40 родных и неудачном запросе вводило в
      // заблуждение (смоук 2026-07-04).
      final searchQuery = _searchQuery.trim();
      if (searchQuery.isNotEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: GlassPanel(
              padding: const EdgeInsets.all(16),
              borderRadius: BorderRadius.circular(22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.search_off_rounded,
                    size: 32,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Никого не нашли',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'По запросу «$searchQuery» совпадений нет.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: GlassPanel(
            padding: const EdgeInsets.all(16),
            borderRadius: BorderRadius.circular(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isOnlineTab
                      ? Icons.chat_bubble_outline
                      : Icons.people_outline,
                  size: 32,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 10),
                Text(
                  isOnlineTab
                      ? 'Чатов нет'
                      : _isFriendsTree(Provider.of<TreeProvider>(
                          context,
                          listen: false,
                        ))
                          ? 'Людей пока нет'
                          : 'Родных пока нет',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                if (!isOnlineTab) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Добавьте первого человека.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _currentTreeId == null
                        ? null
                        : () =>
                            unawaited(_startAddRelativeFlow(_currentTreeId!)),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.person_add_alt_1_outlined),
                    label: Text(_graphAddLabel(treeProvider)),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    int byName(FamilyPerson a, FamilyPerson b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());

    final pendingPeople = <FamilyPerson>[];
    final joinedPeople = <FamilyPerson>[];
    for (final relative in relativesForTab) {
      if (_canInviteRelative(relative)) {
        pendingPeople.add(relative);
      } else {
        joinedPeople.add(relative);
      }
    }
    pendingPeople.sort(byName);
    joinedPeople.sort(byName);

    // F3: живые пользователи — первыми («с ними взаимодействуют»),
    // «Нужно пригласить» — ниже и свёрнута по умолчанию. Поиск ищет по
    // всем: при непустом запросе секция раскрывается, чтобы совпадения
    // не пропали за свёрткой.
    final bool searchActive = _searchQuery.trim().isNotEmpty;
    final bool pendingExpanded =
        _pendingSectionExpandedThisSession || searchActive;

    final List<dynamic> flatList = [];
    if (joinedPeople.isNotEmpty) {
      flatList.add(_RelativesSectionHeader(
        title: isOnlineTab ? 'Чаты' : 'В приложении',
      ));
      flatList.addAll(joinedPeople);
    }
    if (!isOnlineTab && pendingPeople.isNotEmpty) {
      // Если зарегистрированных нет вовсе, сворачивать нечего — список
      // приглашений и есть весь экран.
      final bool collapsible = joinedPeople.isNotEmpty;
      final bool expanded = !collapsible || pendingExpanded;
      flatList.add(_RelativesSectionHeader(
        title: 'Нужно пригласить',
        count: pendingPeople.length,
        collapsible: collapsible,
        expanded: expanded,
        onToggle: collapsible
            ? () {
                setState(() {
                  _pendingSectionExpandedThisSession = !pendingExpanded;
                });
              }
            : null,
      ));
      if (expanded) {
        flatList.addAll(pendingPeople);
      }
    }
    if (!isOnlineTab && pendingPeople.isEmpty && joinedPeople.isEmpty) {
      flatList.addAll(relativesForTab);
    }

    // Pull-to-refresh: данные экрана — one-shot fetch без realtime, а
    // родню добавляют и ДРУГИЕ члены семьи, пока экран открыт. Паттерн
    // как у home_screen/chats_list.
    return RefreshIndicator(
      onRefresh: () async {
        final treeId = _currentTreeId;
        if (treeId != null) {
          await _loadDataForSelectedTree(treeId);
        }
      },
      child: ListView.builder(
        key: key,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 2, bottom: 12),
        itemCount: flatList.length,
        itemBuilder: (context, index) {
          final item = flatList[index];

          if (item is _RelativesSectionHeader) {
            final theme = Theme.of(context);
            final tokens = theme.extension<RodnyaDesignTokens>() ??
                (theme.brightness == Brightness.dark
                    ? RodnyaDesignTokens.dark
                    : RodnyaDesignTokens.light);
            final headerRow = Row(
              children: [
                Expanded(
                  child: Text(
                    item.title,
                    style: AppTheme.serif(
                      color: tokens.ink,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.18,
                    ),
                  ),
                ),
                if (item.count != null && item.count! > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: tokens.warmSoft,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${item.count}',
                      style: AppTheme.sans(
                        color: tokens.warm,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                // F3: шеврон у сворачиваемой секции — видно, что строка
                // нажимается и что внутри ещё есть люди.
                if (item.collapsible) ...[
                  const SizedBox(width: 6),
                  Icon(
                    item.expanded ? Icons.expand_less : Icons.expand_more,
                    size: 22,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ],
            );
            if (item.collapsible && item.onToggle != null) {
              return InkWell(
                key: const Key('relatives-pending-section-toggle'),
                borderRadius: BorderRadius.circular(12),
                onTap: item.onToggle,
                child: Padding(
                  // ≥44dp тап-цель: 18+8 вертикальных отступов + строка.
                  padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
                  child: headerRow,
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
              child: headerRow,
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
            final int photoCount = relative.photoGallery.length;
            final bool hasGallery = photoCount > 0;
            final avatarImage =
                buildAvatarImageProvider(relative.primaryPhotoUrl);

            final theme = Theme.of(context);
            // Плотность (02.09.2026): строка списка — не карточка. Рамка,
            // скругление 24 и вертикальные поля давали ~100dp на человека;
            // плоская строка с волосяным разделителем — как в списке чатов
            // и в Telegram — вмещает в полтора раза больше родных на экран.
            return DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.35),
                    width: 0.6,
                  ),
                ),
              ),
              child: Padding(
                padding: EdgeInsets.zero,
                child: ListTile(
                  visualDensity: const VisualDensity(vertical: -1),
                  leading: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () {
                        debugPrint(
                          'Avatar tapped for ${relative.displayName}, navigating to details...',
                        );
                        context.push(
                          relativeDetailsRoute(
                            relative.id,
                            treeId: relative.treeId,
                          ),
                        );
                      },
                      child: CircleAvatar(
                        radius: 22,
                        backgroundImage: avatarImage,
                        child: avatarImage == null
                            ? Text(relative.initials,
                                style: TextStyle(fontSize: 16))
                            : null,
                      ),
                    ),
                  ),
                  title: Text(
                    relative.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      color: unreadCount > 0
                          ? Theme.of(context).primaryColor
                          : null,
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
                      if (!isOnlineTab || hasGallery)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              // Skip the per-tile invite-status chip for the
                              // pending section since the section header already
                              // says "Нужно пригласить". Keep "Можно написать"
                              // and "Только просмотр" so chat-ready and view-only
                              // states stay scannable per row.
                              if (!isOnlineTab && !canInvite)
                                _buildRelativeInfoChip(
                                  context,
                                  icon: Icons.circle,
                                  label: contactStatus.label,
                                  color: contactStatus.color,
                                  iconSize: 8,
                                ),
                              if (hasGallery)
                                _buildRelativeInfoChip(
                                  context,
                                  icon: Icons.photo_library_outlined,
                                  label: _countLabel(
                                    photoCount,
                                    one: 'фото',
                                    few: 'фото',
                                    many: 'фото',
                                  ),
                                  color:
                                      Theme.of(context).colorScheme.secondary,
                                ),
                              // Чип «Основное фото» убран: наличие фото и так
                              // видно по аватару, а чип добавлял третью
                              // строку каждому человеку с фотографией.
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
                                  backgroundColor:
                                      Theme.of(context).primaryColor,
                                  child: Text(
                                    unreadCount.toString(),
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onPrimary,
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
                            // Phase 3.4 chunk 5: per-row conflict
                            // badge. Compact = icon-only (число
                            // уходит в Semantics label, чтобы не
                            // загромождать строку). Tap → sheet
                            // конкретного person'а.
                            if ((_conflictCounts[relative.id] ?? 0) > 0)
                              IdentityConflictsBadge(
                                count: _conflictCounts[relative.id]!,
                                compact: true,
                                onTap: () => _showConflictsSheet(relative.id),
                              ),
                            if (canStartChat)
                              IconButton(
                                icon: const Icon(Icons.message_outlined),
                                tooltip: 'Написать ${relative.displayName}',
                                visualDensity: VisualDensity.compact,
                                onPressed: () =>
                                    _openChatWithRelative(relative),
                              ),
                            if (canInvite)
                              IconButton(
                                icon:
                                    const Icon(Icons.person_add_alt_1_outlined),
                                tooltip: 'Пригласить ${relative.displayName}',
                                visualDensity: VisualDensity.compact,
                                onPressed: () =>
                                    _shareInviteForRelative(relative),
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
                        context.push(
                          relativeDetailsRoute(
                            relative.id,
                            treeId: relative.treeId,
                          ),
                        );
                      }
                    } else {
                      debugPrint(
                        'Offline tab, navigating to details for ${relative.displayName}',
                      );
                      context.push(
                        relativeDetailsRoute(
                          relative.id,
                          treeId: relative.treeId,
                        ),
                      );
                    }
                  },
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 4,
                  ),
                  // Плоская строка: ink без скругления, как у чатов.
                  shape: const RoundedRectangleBorder(),
                ),
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

  Widget _buildRelativeInfoChip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    double iconSize = 14,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: iconSize, color: color),
          const SizedBox(width: 6),
          // Flexible+ellipsis: на узких строках (A50, 412dp) чип
          // «Можно написать» переполнял слот на 3px — текст обязан
          // сжиматься, а не рисовать striped-полосу.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
        ],
      ),
    );
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
    final photoUrl = relative.primaryPhotoUrl;
    final photoParam = (photoUrl != null && photoUrl.isNotEmpty)
        ? Uri.encodeComponent(photoUrl)
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
      final isFriendsTree =
          _treeProviderInstance?.selectedTreeKind == TreeKind.friends;
      if (!mounted) return;
      await showInviteShareSheet(
        context,
        inviteUrl: inviteUrl,
        message: isFriendsTree
            ? 'Присоединяйтесь к нашему кругу друзей в Родне: ${inviteUrl.toString()}'
            : 'Присоединяйтесь к нашему семейному древу в Родне: ${inviteUrl.toString()}',
        subject:
            isFriendsTree ? 'Приглашение в круг друзей' : 'Приглашение в Родню',
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

  /// Смоук 2026-07-04 (дважды): «Сохранено ✓», а карточки в списке нет
  /// до полной перезагрузки. Данные экрана — one-shot fetch
  /// (getRelativesStream = Stream.fromFuture), а все точки «Добавить»
  /// выбрасывали результат add-флоу. Паттерн tree_view_screen: ждём
  /// результат и перезагружаем. Перезагружаем и на null-результате
  /// (back из quick-add цикла сохраняет людей БЕЗ pop-результата —
  /// лишний fetch на отмене безвреден, пропущенная карточка — нет).
  Future<void> _startAddRelativeFlow(String treeId) async {
    final isFriendsCircle =
        context.read<TreeProvider>().selectedTreeKind == TreeKind.friends;
    await showRelationPickerAndNavigateAdd(
      context,
      treeId: treeId,
      isFriendsCircle: isFriendsCircle,
    );
    if (!mounted) {
      return;
    }
    await _loadDataForSelectedTree(treeId);
  }

  String _formatTimestamp(DateTime rawDateTime) {
    // Таймзоны: серверные метки — UTC-режим; display обязан локализовать
    // (см. date_parser контракт; смоук 2026-07-04 показывал 13:25 вместо
    // 16:25 в превью чата).
    final DateTime dateTime = toLocalForDisplay(rawDateTime);
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
    Completer<void>? completer,
  ) {
    debugPrint('Ошибка при загрузке данных: $error\n$stackTrace');
    _appStatusService.reportError(
      error,
      fallbackMessage: 'Не удалось обновить данные на экране родных.',
    );
    if (mounted) {
      setState(() {
        if (reason == 'RelationsStreamError') {
          _isRelationsReady = true;
        }
        if (reason == 'ChatsStreamError') {
          _isChatsReady = true;
        }
        if (_allRelatives.isNotEmpty) {
          return;
        }
        _errorMessage = describeUserFacingError(
          authService: _authService,
          error: error,
          fallbackMessage: 'Ошибка при загрузке данных ($reason).',
        );
      });
    }
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
  }

  Widget _buildRelativesTopbar({
    required ThemeData theme,
    required RodnyaDesignTokens tokens,
    required TreeProvider treeProvider,
    required String? selectedTreeId,
    required bool isFriendsTree,
  }) {
    // Skip BackdropFilter on Android (perf) — same pattern as
    // home/profile/chats topbars.
    final useBlur = defaultTargetPlatform != TargetPlatform.android;
    final body = Container(
      decoration: BoxDecoration(
        color: tokens.surface.withValues(
          alpha: theme.brightness == Brightness.dark
              ? (useBlur ? 0.74 : 0.96)
              : (useBlur ? 0.78 : 0.97),
        ),
        border: Border(
          bottom: BorderSide(
            color: tokens.surfaceLine.withValues(alpha: 0.5),
            width: 0.6,
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: AppTheme.topbarContentHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 3, 4, 3),
            child: Row(
              children: [
                if (_isSearchOpen && !_isWideLayout(context))
                  ..._buildTopbarSearchRow(tokens)
                else ...[
                  // Заголовок и чип дерева — во вложенном Row внутри
                  // Expanded: рядом со Spacer два Flexible делили бы
                  // свободное место на троих, и заголовок резался в «Родн…».
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            isFriendsTree ? 'Круг' : 'Родные',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTheme.serif(
                              color: tokens.ink,
                              fontSize: AppTheme.tabTitleFontSize,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.22,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Phase 6.1: branch switcher chip in the relatives
                        // top bar so the user can flip "родители папа /
                        // папина / семья жены" without leaving the screen.
                        const Flexible(child: BranchSwitcherChip()),
                      ],
                    ),
                  ),
                  ..._buildRelativesAppBarActions(
                    treeProvider: treeProvider,
                    selectedTreeId: selectedTreeId,
                    isFriendsTree: isFriendsTree,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (!useBlur) return body;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: body,
      ),
    );
  }
}

class _RelativesSectionHeader {
  const _RelativesSectionHeader({
    required this.title,
    this.count,
    this.collapsible = false,
    this.expanded = true,
    this.onToggle,
  });

  final String title;
  final int? count;

  /// F3: секция «Нужно пригласить» сворачивается — заголовок-строка с
  /// количеством и шевроном, чтобы живые пользователи были сверху.
  final bool collapsible;
  final bool expanded;
  final VoidCallback? onToggle;
}
