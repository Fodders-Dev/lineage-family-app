import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart'; // Импортируем Provider
import 'package:get_it/get_it.dart';

import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/blood_relation_capable_family_tree_service.dart';
import '../backend/interfaces/bulk_import_capable_family_tree_service.dart';
import '../backend/interfaces/identity_conflicts_capable_family_tree_service.dart';
import '../backend/interfaces/identity_suggestions_capable_family_tree_service.dart';
import '../backend/interfaces/semya_capable_family_tree_service.dart';
import '../backend/models/blood_relation.dart';
import '../backend/models/semya.dart';
import '../backend/models/identity_field_conflict.dart';
import '../backend/models/identity_suggestion.dart';
import '../models/family_person.dart';
import '../models/family_relation.dart';
import '../models/family_tree.dart';
import '../widgets/identity_conflicts_sheet.dart';
import '../backend/interfaces/extended_network_capable_family_tree_service.dart';
import '../backend/models/extended_network_slice.dart';
import '../providers/extended_network_controller.dart';
import '../widgets/extended_network_empty_state.dart';
import '../widgets/extended_network_filter_sheet.dart';
import '../widgets/extended_network_filter_sidebar.dart';
import '../widgets/extended_network_search_sheet.dart';
import '../widgets/empty_tree_guided_cta.dart';
import '../widgets/relation_picker_sheet.dart';
import '../widgets/extended_network_toggle.dart';
import '../widgets/semya_context_badge.dart';
import '../widgets/foreign_node_sheet.dart';
import '../widgets/interactive_family_tree.dart';
import '../widgets/safe_delete_confirmation_dialog.dart';
import '../widgets/tree_history_sheet.dart';
import '../widgets/tree_person_action_sheet.dart';
import '../widgets/glass_panel.dart';
import 'semya_details_screen.dart';
import '../providers/tree_provider.dart'; // Импортируем TreeProvider
import 'package:go_router/go_router.dart'; // Для навигации
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/chat_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/tree_graph_capable_family_tree_service.dart';

import '../services/app_status_service.dart';
import '../services/custom_api_diagnostics_service.dart';
import '../services/public_tree_link_service.dart';
import '../services/local_storage_service.dart';
import '../services/tree_mutation_history.dart';
import '../services/tree_refresh_coordinator.dart';
import '../models/tree_graph_snapshot.dart';
import '../theme/app_theme.dart';
import '../utils/user_facing_error.dart';
import '../utils/e2e_state_bridge.dart';
import '../utils/photo_url.dart';
import '../utils/relative_details_route.dart';
import '../utils/russian_plural.dart';
import '../utils/snackbar.dart';
import '../widgets/dont_fear_breaking_banner.dart';

part 'tree_view_screen_sections.dart';

enum _TreeToolbarAction {
  refresh,
  openHistory,
  sendDiagnostics,
  openChats,
  createPost,
  // UX-T1.2 FR-c: вторичные контролы (undo/redo/поиск/фильтры) на телефоне
  // переезжают сюда, в overflow «•••», вместо постоянных пилюль топ-бара.
  undo,
  redo,
  openSearch,
  openFilters,
  toggleEditMode,
  toggleSelectionMode,
  openBranchChat,
  openBranchDetails,
  copyPublicLink,
  resetBranchFocus,
  resetLayout,
}

/// Smart-selection options surfaced in the selection toolbar's
/// «Расширить» popup. Each one expands the user's current
/// selection set by walking parent / child edges from the
/// already-picked anchors — turning «one tap on mama» into «mama +
/// all her line».
enum _SelectionExpand {
  ancestors,
  descendants,
  lineage,
}

class SectionTitle extends StatelessWidget {
  final String title;

  const SectionTitle({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w800,
          color: theme.colorScheme.primary,
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

  /// A-CTA: сброс session-dismiss гида между тестами.
  @visibleForTesting
  static void debugResetGuidedCtaDismissal() {
    _TreeViewScreenState._guidedCtaDismissedThisSession = false;
  }

  @override
  State<TreeViewScreen> createState() => _TreeViewScreenState();
}

class _TreeViewScreenState extends State<TreeViewScreen>
    with WidgetsBindingObserver {
  final FamilyTreeServiceInterface _familyService =
      GetIt.I<FamilyTreeServiceInterface>();
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final ChatServiceInterface _chatService = GetIt.I<ChatServiceInterface>();
  final AppStatusService _appStatusService = GetIt.I<AppStatusService>();
  final LocalStorageService _localStorageService =
      GetIt.I<LocalStorageService>();

  // Map<String, dynamic> _graphData = {'nodes': [], 'edges': []}; // Больше не нужно
  bool _isLoading = true;
  String _errorMessage = '';
  // A-CTA: пользователь закрыл блокирующий гид «добавь близких». Static —
  // переживает пересоздание экрана в рамках сессии, сбрасывается рестартом.
  // Закрыт → показываем канвас с FAB вместо гида.
  static bool _guidedCtaDismissedThisSession = false;
  bool _isEditMode = false; // <<< Добавляем состояние режима редактирования
  // Multi-select mode for bulk operations on the canvas — entered
  // via the toolbar action, exited explicitly by the user (or auto-
  // exits when the user opens edit mode, which owns long-press).
  // The set is the source of truth; it survives until the user
  // closes selection mode or completes a bulk action.
  bool _isSelectionMode = false;
  final Set<String> _selectedPersonIds = <String>{};
  TreeProvider? _treeProviderInstance; // Храним экземпляр
  String? _currentTreeId;
  // Auto-refresh wiring (Phase B): coordinator hands us a callback
  // identity so unregister can identity-check ours vs. another
  // screen's. We hold the function reference for the same reason —
  // bound method tear-off would create a fresh closure each access,
  // breaking identical().
  String? _refreshCoordinatorTreeId;
  late final Future<void> Function() _treeRefreshCallback =
      _handleCoordinatorRefresh;
  String? _branchRootPersonId;
  String? _selectedPersonSheetId;
  String? _selectedEditPersonId;
  // After a successful blank-card creation we set this to the new
  // person's id; the InteractiveFamilyTree picks it up via
  // `recenterOnPersonId` and snaps the viewport to center on the
  // newly-dropped card. Without this the user can lose the card
  // when zoomed into another branch.
  String? _recenterOnPersonIdAfterReload;
  // Phase 1.2 voltage-indicator matcher: per-person count of
  // medium+high confidence cross-tree suggestions. Drives the 💡
  // dot on the canvas. Lazily populated after the tree loads —
  // we don't gate the initial render on this.
  Map<String, int> _identitySuggestionCounts = const <String, int>{};
  // Phase 1.3 edit-time conflict surfacing: per-person count of
  // unresolved identity-field conflicts on this tree. Drives the
  // ⚠️ dot. Same loading model as suggestions — fetch in the
  // background, render when ready, no gate on first paint.
  // Cached full conflict list so the tap handler doesn't refetch
  // (one HTTP roundtrip per tree-load instead of per-tap).
  Map<String, int> _identityConflictCounts = const <String, int>{};
  List<IdentityFieldConflict> _identityConflictsCache =
      const <IdentityFieldConflict>[];
  // Reference design pattern: bottom sheet starts collapsed (peek bar with
  // avatar + name + meta + chevron) and expands on tap to reveal action row
  // and full info. Reset to collapsed whenever selection changes.
  bool _personSheetExpanded = false;
  // Compact (mobile) chrome — info card / quick actions / health panel —
  // is collapsed by default so the canvas takes ~85% of the viewport.
  // Tap on the chevron in the top toolbar toggles it open.
  bool _compactChromeCollapsed = true;
  FamilyTree? _currentTreeMeta;
  Map<String, Offset> _manualNodePositions = <String, Offset>{};
  TreeGraphSnapshot? _graphSnapshot;
  // <<< НОВОЕ СОСТОЯНИЕ: Флаг, добавлен ли текущий пользователь в дерево >>>
  bool _currentUserIsInTree = true; // Изначально true, пока не проверили

  bool get _isFriendsTree => _currentTreeMeta?.isFriendsTree == true;

  // ── Ship FE4 (2026-05-26): семя context state ──
  //
  // Resolved при tree load — if active tree bound к семя (per Ship 5
  // tree.semyaId), we fetch SemyaDetails to learn caller's role.
  // Used to gate edit/add/delete UI affordances per ENTITY-DESIGN §2.1
  // role matrix. Null означает либо unbound tree (legacy / personal) либо
  // не yet loaded / fetch failed → треат как owner-equivalent (legacy
  // compat — don't accidentally hide controls для self-owned trees).
  SemyaDetails? _currentSemyaContext;

  /// Ship FE7 (2026-05-26): caller's personally-hidden person IDs
  /// для current семя. Empty list когда tree unbound либо никто
  /// не скрыт. Server filters tree-routes per этой list — поэтому
  /// frontend не re-filters локально (just re-fetches после toggle).
  /// Used к gate «Скрыть / Показывать снова» tile в action sheet.
  List<String> _hiddenPersonIds = const <String>[];

  /// Convenience: caller's role в active семья (null когда unbound).
  SemyaRole? get _callerSemyaRole => _currentSemyaContext?.callerRole;

  /// True when caller has mutation rights (owner либо editor) — либо
  /// tree unbound (legacy/personal trees default to full access).
  bool get _canEditCurrentTree {
    final role = _callerSemyaRole;
    if (role == null) return true; // unbound либо not loaded → legacy full
    return role == SemyaRole.owner || role == SemyaRole.editor;
  }

  /// Convenience flag для viewer-role gating (inverse of edit access).
  bool get _isViewerOnly => !_canEditCurrentTree;

  // Phase 4 chunk 2: per-tree state для mode toggle + filter panel.
  // Создаётся когда tree selected (см. _syncExtendedNetworkController),
  // dispose'ится в State.dispose(). НЕ менять interactive_family_tree
  // — это chunk 3 work.
  ExtendedNetworkController? _extendedNetworkController;

  TreeGraphCapableFamilyTreeService? get _graphTreeService {
    final service = _familyService;
    if (service is TreeGraphCapableFamilyTreeService) {
      return service as TreeGraphCapableFamilyTreeService;
    }
    return null;
  }

  ExtendedNetworkCapableFamilyTreeService? get _extendedNetworkService {
    final service = _familyService;
    if (service is ExtendedNetworkCapableFamilyTreeService) {
      return service as ExtendedNetworkCapableFamilyTreeService;
    }
    return null;
  }

  void _syncExtendedNetworkController(String? treeId) {
    if (treeId == null || treeId.isEmpty) {
      _extendedNetworkController?.removeListener(_onExtendedNetworkChange);
      _extendedNetworkController?.dispose();
      _extendedNetworkController = null;
      return;
    }
    if (_extendedNetworkController?.treeId == treeId) return;
    _extendedNetworkController?.removeListener(_onExtendedNetworkChange);
    _extendedNetworkController?.dispose();
    _extendedNetworkController = ExtendedNetworkController(
      treeId: treeId,
      service: _extendedNetworkService,
    );
    _extendedNetworkController!.addListener(_onExtendedNetworkChange);
  }

  void _onExtendedNetworkChange() {
    // Phase 4 chunk 3a: controller updates (mode / filter / slice
    // fetch result) → tree_view_screen rebuild чтобы пробросить
    // свежие viewMode / networkSlice в InteractiveFamilyTree.
    // Chunk 3a const flag = false; rebuild по сути no-op для canvas.
    // Chunk 3b/3c активирует actual render branching.
    if (!mounted) return;
    setState(() {});
  }

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

  List<FamilyPerson> get _treePeople => _relativesData
      .map((entry) => entry['person'])
      .whereType<FamilyPerson>()
      .toList();

  FamilyPerson? get _selectedEditPerson {
    final selectedId = _selectedEditPersonId;
    if (selectedId == null) {
      return null;
    }
    for (final person in _treePeople) {
      if (person.id == selectedId) {
        return person;
      }
    }
    return null;
  }

  FamilyPerson? get _selectedPersonSheetPerson {
    final selectedId = _selectedPersonSheetId;
    if (selectedId == null) {
      return null;
    }
    for (final person in _treePeople) {
      if (person.id == selectedId) {
        return person;
      }
    }
    return null;
  }

  void _updateSectionState(VoidCallback update) {
    setState(update);
  }

  /// Selection-mode "smart expansion" helpers — used by the toolbar
  /// «Расширить» action. Walking parent/child edges across the
  /// loaded `_relationsData` is enough; we don't need the full
  /// graph snapshot because relations on a single tree are a
  /// closed set. Sibling / spouse / in-law edges are intentionally
  /// IGNORED here — the user's intent in selecting "по маминой
  /// линии" is the blood lineage, and folding spouses in means
  /// the partner's whole family climbs aboard, which is rarely
  /// what they want at this step.
  Set<String> _expandSelectionWithAncestors(Iterable<String> seedIds) {
    final parentsOf = _buildParentEdges();
    final result = <String>{...seedIds};
    final queue = <String>[...seedIds];
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      final parents = parentsOf[current];
      if (parents == null) continue;
      for (final parent in parents) {
        if (result.add(parent)) {
          queue.add(parent);
        }
      }
    }
    return result;
  }

  Set<String> _expandSelectionWithDescendants(Iterable<String> seedIds) {
    final childrenOf = _buildChildEdges();
    final result = <String>{...seedIds};
    final queue = <String>[...seedIds];
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      final children = childrenOf[current];
      if (children == null) continue;
      for (final child in children) {
        if (result.add(child)) {
          queue.add(child);
        }
      }
    }
    return result;
  }

  Set<String> _expandSelectionWithLineage(Iterable<String> seedIds) {
    final withAncestors = _expandSelectionWithAncestors(seedIds);
    return _expandSelectionWithDescendants(withAncestors);
  }

  Map<String, Set<String>> _buildParentEdges() {
    final edges = <String, Set<String>>{};
    void link(String childId, String parentId) {
      edges.putIfAbsent(childId, () => <String>{}).add(parentId);
    }

    for (final relation in _relationsData) {
      if (relation.relation1to2 == RelationType.parent) {
        link(relation.person2Id, relation.person1Id);
      } else if (relation.relation1to2 == RelationType.child) {
        link(relation.person1Id, relation.person2Id);
      }
    }
    return edges;
  }

  Map<String, Set<String>> _buildChildEdges() {
    final edges = <String, Set<String>>{};
    void link(String parentId, String childId) {
      edges.putIfAbsent(parentId, () => <String>{}).add(childId);
    }

    for (final relation in _relationsData) {
      if (relation.relation1to2 == RelationType.parent) {
        link(relation.person1Id, relation.person2Id);
      } else if (relation.relation1to2 == RelationType.child) {
        link(relation.person2Id, relation.person1Id);
      }
    }
    return edges;
  }

  void _handleSelectionExpand(_SelectionExpand option) {
    if (_selectedPersonIds.isEmpty) return;
    final beforeCount = _selectedPersonIds.length;
    Set<String> expanded;
    String descriptor;
    switch (option) {
      case _SelectionExpand.ancestors:
        expanded = _expandSelectionWithAncestors(_selectedPersonIds);
        descriptor = 'предки';
        break;
      case _SelectionExpand.descendants:
        expanded = _expandSelectionWithDescendants(_selectedPersonIds);
        descriptor = 'потомки';
        break;
      case _SelectionExpand.lineage:
        expanded = _expandSelectionWithLineage(_selectedPersonIds);
        descriptor = 'вся линия';
        break;
    }
    final added = expanded.length - beforeCount;
    setState(() {
      _selectedPersonIds
        ..clear()
        ..addAll(expanded);
    });
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(
          added > 0
              ? 'Добавлено в выбор ($descriptor): $added'
              : 'Никого нового не нашлось — связи уже выбраны.',
        ),
      ),
    );
  }

  void _selectTreePerson(FamilyPerson person) {
    setState(() {
      if (_selectedPersonSheetId == person.id) {
        // Same node tapped twice — close sheet entirely.
        _selectedPersonSheetId = null;
        _personSheetExpanded = false;
      } else {
        _selectedPersonSheetId = person.id;
        _personSheetExpanded = false; // Always start collapsed.
      }
    });
  }

  void _clearSelectedTreePerson() {
    setState(() {
      _selectedPersonSheetId = null;
      _personSheetExpanded = false;
    });
  }

  void _togglePersonSheetExpansion() {
    setState(() {
      _personSheetExpanded = !_personSheetExpanded;
    });
  }

  void _publishTreeE2EState(String? selectedTreeId) {
    if (!E2EStateBridge.isEnabled) {
      return;
    }

    final people = _treePeople;
    final selectedPerson = _selectedEditPerson;
    final selectedSheetPerson = _selectedPersonSheetPerson;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      E2EStateBridge.publish(
        screen: 'tree',
        state: <String, dynamic>{
          'selectedTreeId': selectedTreeId,
          'currentTreeId': _currentTreeId,
          'treeName': _currentTreeMeta?.name ?? widget.routeTreeName,
          'isLoading': _isLoading,
          'isEditMode': _isEditMode,
          'branchRootPersonId': _branchRootPersonId,
          'selectedPersonSheetId': _selectedPersonSheetId,
          'selectedEditPersonId': _selectedEditPersonId,
          'selectedPersonSheet': selectedSheetPerson == null
              ? null
              : <String, dynamic>{
                  'id': selectedSheetPerson.id,
                  'name': selectedSheetPerson.name,
                  'photoCount': selectedSheetPerson.photoGallery.length,
                  'hasPrimaryPhoto':
                      selectedSheetPerson.primaryPhotoUrl != null,
                },
          'selectedEditPerson': selectedPerson == null
              ? null
              : <String, dynamic>{
                  'id': selectedPerson.id,
                  'name': selectedPerson.name,
                  'photoCount': selectedPerson.photoGallery.length,
                  'hasPrimaryPhoto': selectedPerson.primaryPhotoUrl != null,
                },
          'people': people
              .map(
                (person) => <String, dynamic>{
                  'id': person.id,
                  'name': person.name,
                  'photoCount': person.photoGallery.length,
                  'hasPrimaryPhoto': person.primaryPhotoUrl != null,
                },
              )
              .toList(),
        },
      );
    });
  }

  @override
  void initState() {
    super.initState();
    // Desktop convention — ESC clears the branch-focus / edit-selection
    // state without forcing the user to reach for the toolbar pill.
    // Same HardwareKeyboard pattern as the home / lightbox shortcuts:
    // Focus.onKeyEvent is unreliable on Flutter web's CanvasKit, so we
    // attach to the global handler instead.
    HardwareKeyboard.instance.addHandler(_handleTreeKeyEvent);
    // App-lifecycle hook — on resume we re-request a refresh для
    // currently viewed tree чтобы catch mutations, missed пока app
    // был backgrounded (push delivered, но silent notification
    // handler не ran потому что process suspended).
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _treeProviderInstance = Provider.of<TreeProvider>(context, listen: false);
      _treeProviderInstance!.addListener(_handleTreeChange); // Подписываемся
      _syncTreeFromRouteOrProvider();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleTreeKeyEvent);
    WidgetsBinding.instance.removeObserver(this);
    _syncTreeRefreshSubscription(null);
    _treeProviderInstance?.removeListener(_handleTreeChange); // Отписываемся
    _extendedNetworkController?.removeListener(_onExtendedNetworkChange);
    _extendedNetworkController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Phase B auto-refresh: on resume re-trigger refresh для активного
    // tree. Coordinator's debounce coalesces with any concurrent push
    // arrival, so duplicate work не происходит. No-op если tree не
    // выбран либо subscriber unregistered (например screen в фоне
    // другого route).
    if (state != AppLifecycleState.resumed) return;
    final treeId = _refreshCoordinatorTreeId;
    if (treeId == null || treeId.isEmpty) return;
    TreeRefreshCoordinator.instance.requestRefresh(treeId);
  }

  /// Re-load the currently viewed tree. Called by
  /// [TreeRefreshCoordinator] when a `tree_mutated` push/realtime
  /// event arrives для зарегистрированного treeId. Identity-stable
  /// (single field assignment в State init) so coordinator's
  /// identical()-check unregister works.
  Future<void> _handleCoordinatorRefresh() async {
    if (!mounted) return;
    final treeId = _currentTreeId;
    if (treeId == null || treeId.isEmpty) return;
    await _loadData(treeId);
  }

  /// Re-point the [TreeRefreshCoordinator] subscription to [treeId].
  /// Idempotent — calling с тем же treeId no-op'ит. Passing `null`
  /// just unregisters (used on dispose, or когда tree selection
  /// cleared).
  void _syncTreeRefreshSubscription(String? treeId) {
    final previous = _refreshCoordinatorTreeId;
    if (previous == treeId) return;
    if (previous != null) {
      TreeRefreshCoordinator.instance.unregister(
        previous,
        _treeRefreshCallback,
      );
    }
    _refreshCoordinatorTreeId = null;
    if (treeId != null && treeId.isNotEmpty) {
      TreeRefreshCoordinator.instance.register(treeId, _treeRefreshCallback);
      _refreshCoordinatorTreeId = treeId;
    }
  }

  /// Returns true to consume the event so it doesn't bubble. Handles
  /// three desktop shortcuts:
  ///   * Esc — clear branch focus / edit selection
  ///   * Ctrl+Z (or Cmd+Z) — undo last tree mutation
  ///   * Ctrl+Shift+Z (or Cmd+Shift+Z) — redo
  /// Все три consume жест ТОЛЬКО когда есть что отменять / закрывать,
  /// иначе нормальное поведение клавиш (back gesture, browser-zoom)
  /// сохраняется.
  bool _handleTreeKeyEvent(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent) return false;

    final focused = FocusManager.instance.primaryFocus;
    final inEditable = focused?.context?.widget is EditableText ||
        (focused?.context != null &&
            focused!.context!.findAncestorWidgetOfExactType<EditableText>() !=
                null);
    if (inEditable) return false;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      final hadEditSelection = _selectedEditPersonId != null;
      final hadBranchFocus = _branchRootPersonId != null;
      if (!hadEditSelection && !hadBranchFocus) return false;
      setState(() {
        _selectedEditPersonId = null;
        _branchRootPersonId = null;
      });
      return true;
    }

    final keyZ = LogicalKeyboardKey.keyZ;
    if (event.logicalKey != keyZ) return false;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final hasCmdOrCtrl = keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight) ||
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight);
    if (!hasCmdOrCtrl) return false;
    final hasShift = keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
    if (!GetIt.I.isRegistered<TreeMutationHistory>()) return false;
    if (hasShift) {
      unawaited(_performRedo());
    } else {
      unawaited(_performUndo());
    }
    return true;
  }

  Future<void> _performUndo() async {
    final history = GetIt.I<TreeMutationHistory>();
    if (!history.canUndo) return;
    final desc = await history.undoForUi(_familyService);
    if (!mounted) return;
    if (_currentTreeId != null) {
      await _loadData(_currentTreeId!);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(desc != null ? 'Отменено: $desc' : 'Не удалось отменить'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _performRedo() async {
    final history = GetIt.I<TreeMutationHistory>();
    if (!history.canRedo) return;
    final desc = await history.redoForUi(_familyService);
    if (!mounted) return;
    if (_currentTreeId != null) {
      await _loadData(_currentTreeId!);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text(desc != null ? 'Повторено: $desc' : 'Не удалось повторить'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
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
      _syncExtendedNetworkController(routeTreeId);
      _syncTreeRefreshSubscription(routeTreeId);
      await _loadData(routeTreeId);
      return;
    }

    _currentTreeId = provider.selectedTreeId;
    _syncExtendedNetworkController(_currentTreeId);
    _syncTreeRefreshSubscription(_currentTreeId);
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
      _syncExtendedNetworkController(newTreeId);
      _syncTreeRefreshSubscription(newTreeId);
      if (_currentTreeId != null) {
        _loadData(_currentTreeId!);
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = '';
          _manualNodePositions = <String, Offset>{};
          _selectedPersonSheetId = null;
        });
      }
    }
  }

  // Метод загрузки данных, теперь принимает treeId
  Future<void> _loadData(String treeId) async {
    if (!mounted) return;
    debugPrint('TreeView: Загрузка данных для дерева $treeId');
    final hasCachedTreeData = _currentTreeMeta?.id == treeId &&
        (_relativesData.isNotEmpty || _relationsData.isNotEmpty);
    final graphTreeService = _graphTreeService;
    setState(() {
      _isLoading = !hasCachedTreeData;
      _errorMessage = '';
      _currentUserIsInTree = true;
      if (!hasCachedTreeData) {
        _relativesData = [];
        _relationsData = [];
        _manualNodePositions = <String, Offset>{};
        _graphSnapshot = null;
        _selectedPersonSheetId = null;
      }
    });

    try {
      if (_authService.currentUserId == null) {
        context.go('/login');
        return;
      }
      if (graphTreeService == null) {
        throw StateError(
          'Текущее подключение не поддерживает graph snapshot дерева.',
        );
      }

      late final List<FamilyPerson> relatives;
      late final List<FamilyRelation> relations;
      late final FamilyTree? treeMeta;
      late final SemyaDetails? semyaContext;
      // Ship FE4 (2026-05-26): added семя context fetch к parallel
      // load. Resolves caller's role когда tree bound к семя per
      // tree.semyaId (Ship 5). Result null когда unbound либо
      // capability service incapable — caller defaults к legacy
      // full-access mode.
      final loadResults = await Future.wait<Object?>([
        graphTreeService.getTreeGraphSnapshot(treeId),
        _loadCurrentTreeMeta(treeId),
        _resolveSemyaContextForTree(treeId),
      ]);
      final graphSnapshot = loadResults[0] as TreeGraphSnapshot;
      relatives = graphSnapshot.people;
      relations = graphSnapshot.relations;
      treeMeta = loadResults[1] as FamilyTree?;
      semyaContext = loadResults[2] as SemyaDetails?;
      // Ship FE7 originally fetched caller's hide list before first paint.
      // That made tree reloads feel slow after mutations: the canvas waited
      // for a secondary action-sheet detail. Keep the previous list when the
      // same семя is still active, paint the tree, then refresh hide state in
      // the background.
      final hiddenIds = semyaContext != null &&
              _currentSemyaContext?.semya.id == semyaContext.semya.id
          ? _hiddenPersonIds
          : const <String>[];
      debugPrint(
        'Загружено родственников: ${relatives.length}, связей: ${relations.length}'
        '${semyaContext != null ? '; семя: ${semyaContext.semya.name} '
            '(role: ${semyaContext.callerRole.serverValue})' : '; tree unbound'}',
      );

      if (!mounted) return;

      if (relatives.isEmpty) {
        debugPrint('Дерево $treeId пустое.');
        setState(() {
          _isLoading = false;
          _errorMessage = '';
          _relativesData = [];
          _relationsData = [];
          _currentTreeMeta = treeMeta;
          _currentSemyaContext = semyaContext;
          _hiddenPersonIds = hiddenIds;
          _manualNodePositions = <String, Offset>{};
          _graphSnapshot = graphSnapshot;
          _currentUserIsInTree = graphSnapshot.viewerPersonId != null;
          _selectedPersonSheetId = null;
        });
        unawaited(_refreshHiddenPersonIdsForLoadedSemya(
          treeId: treeId,
          semyaContext: semyaContext,
        ));
        return;
      }

      final List<Map<String, dynamic>> peopleData = [];
      final viewerDescriptors = graphSnapshot.viewerDescriptorByPersonId;
      for (var person in relatives) {
        peopleData.add({
          'person': person,
          'userProfile': null,
          'viewerDescriptor': viewerDescriptors[person.id],
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
        final selectedSheetPersonStillExists = _selectedPersonSheetId == null ||
            relatives.any((person) => person.id == _selectedPersonSheetId);
        setState(() {
          // Сохраняем исходные данные, а не построенный граф
          _relativesData = peopleData;
          _relationsData = relations;
          _currentTreeMeta = treeMeta;
          _currentSemyaContext = semyaContext;
          _hiddenPersonIds = hiddenIds;
          _manualNodePositions = filteredPositions;
          _graphSnapshot = graphSnapshot;
          _isLoading = false;
          _currentUserIsInTree = graphSnapshot.viewerPersonId != null;
          if (!branchRootStillExists) {
            _branchRootPersonId = null;
          }
          if (!selectedEditPersonStillExists) {
            _selectedEditPersonId = null;
          }
          if (!selectedSheetPersonStillExists) {
            _selectedPersonSheetId = null;
          }
        });
        // Phase 1.2 voltage-indicator: kick off cross-tree
        // suggestion fetches in the background. Doesn't block
        // first paint — when responses come in we update the
        // counts state and the canvas re-renders the 💡 dots.
        unawaited(_refreshIdentitySuggestionCounts(treeId, relatives));
        // Phase 1.3 edit-time conflicts: same fire-and-forget
        // pattern. One HTTP call covers every visible card —
        // /v1/trees/:treeId/conflicts is tree-scoped (vs.
        // suggestions, which is per-person — historical).
        unawaited(_refreshIdentityConflictCounts(treeId));
        unawaited(_refreshHiddenPersonIdsForLoadedSemya(
          treeId: treeId,
          semyaContext: semyaContext,
        ));
      }
    } catch (e, s) {
      debugPrint('Ошибка загрузки данных дерева $treeId: $e\\n$s');
      _appStatusService.reportError(
        e,
        fallbackMessage: 'Не удалось загрузить дерево.',
      );
      if (mounted) {
        setState(() {
          _isLoading = false;
          if (!hasCachedTreeData) {
            _errorMessage = e is StateError
                ? 'Этот backend не поддерживает новый graph snapshot дерева.'
                : _appStatusService.isOffline
                    ? 'Нет соединения. Откройте дерево снова, когда интернет вернётся.'
                    : 'Не удалось загрузить данные дерева.';
          }
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
    _publishTreeE2EState(selectedTreeId);
    final selectedTreeName = treeProvider.selectedTreeName ??
        widget.routeTreeName ??
        'Семейное дерево';

    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    if (selectedTreeId == null) {
      // Дерево — ядро продукта, и это первый экран новичка без дерева:
      // «Выберите дерево / Открыть» отправлял его в селектор искать то,
      // чего ещё нет. Без деревьев зовём создать прямо здесь (create-экран
      // сам выбирает новое дерево и возвращает на вкладку); селектор
      // предлагаем только тем, кому есть из чего выбирать.
      final hasTrees = treeProvider.availableTrees.isNotEmpty;
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: PreferredSize(
          preferredSize: Size.fromHeight(AppTheme.topbarHeight(context)),
          child: _buildTreeTopbar(
            theme: theme,
            tokens: tokens,
            selectedTreeId: null,
          ),
        ),
        body: _buildTreeState(
          icon: Icons.account_tree_outlined,
          title: hasTrees ? 'Выберите дерево' : 'Здесь будет ваше дерево',
          message: hasTrees
              ? 'Откройте одно из ваших деревьев.'
              : 'Добавьте себя и близких — схема семьи вырастет сама.',
          actions: hasTrees
              ? [
                  FilledButton.icon(
                    onPressed: () => context.go('/trees'),
                    icon: const Icon(Icons.list_alt),
                    label: const Text('Выбрать дерево'),
                  ),
                ]
              : [
                  FilledButton.icon(
                    key: const Key('tree-empty-create-family'),
                    onPressed: () => context.push('/trees/create'),
                    icon: const Icon(Icons.add),
                    label: const Text('Создать семью'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('tree-empty-create-friends'),
                    onPressed: () =>
                        context.push('/trees/create?kind=friends'),
                    icon: const Icon(Icons.diversity_3_outlined),
                    label: const Text('Круг друзей'),
                  ),
                ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: PreferredSize(
        // Тот же токен, что у пустого состояния выше: хардкод 76 резервировал
        // меньше, чем занимает SafeArea + topbarContentHeight, и на телефонах
        // с высоким статус-баром сжимал заголовок и пилюли.
        preferredSize: Size.fromHeight(AppTheme.topbarHeight(context)),
        child: _buildTreeTopbar(
          theme: theme,
          tokens: tokens,
          selectedTreeId: selectedTreeId,
          treeName: selectedTreeName,
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // The reassurance banner participates in layout instead of
            // covering the canvas toolbar and the first visible generation.
            if (!_isGuidedCtaActive) const DontFearBreakingBanner(),
            Expanded(
              child: _wrapWithExtendedNetworkLayout(
                context,
                _buildTreeBody(selectedTreeId: selectedTreeId),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Phase 4 chunk 2: wrap body в Provider + (optional) sidebar для
  /// wide layout + extended mode. Sidebar показывается ТОЛЬКО когда:
  ///   • controller существует и capable;
  ///   • mode == extended;
  ///   • screen width >= 1500 (== relatives_screen breakpoint).
  ///
  /// Sidebar НЕ менял canvas rendering — это chunk 3. Sidebar
  /// добавляется справа от existing body, занимая 280px.
  Widget _wrapWithExtendedNetworkLayout(BuildContext context, Widget body) {
    final controller = _extendedNetworkController;
    if (controller == null) return body;
    return ChangeNotifierProvider<ExtendedNetworkController>.value(
      value: controller,
      child: Consumer<ExtendedNetworkController>(
        builder: (context, ctrl, _) {
          final isWide = MediaQuery.of(context).size.width >= 1500;
          final showSidebar = isWide &&
              ctrl.isCapable &&
              ctrl.mode == ExtendedNetworkMode.extended;
          final overlayedBody = _maybeOverlayExtendedEmptyState(ctrl, body);
          if (!showSidebar) return overlayedBody;
          return Row(
            children: [
              Expanded(child: overlayedBody),
              const ExtendedNetworkFilterSidebar(
                branchOptions: <BranchFilterOption>[],
              ),
            ],
          );
        },
      ),
    );
  }

  /// Phase 6 chunk 4c (PHASE-6-PROPOSAL.md §2.7): when extended mode
  /// is on + slice loaded + no foreign nodes (`ownerMap.isEmpty`) —
  /// show a future-positive empty-state banner before the tree canvas.
  /// It participates in layout so its CTAs never cover people or controls.
  /// Сессионная память крестика: карточка-заглушка висит ПОВЕРХ канваса
  /// и без дисмисса запирала просмотр дерева (жалоба владельца).
  /// Вернётся после перезапуска приложения — как onboarding-баннер.
  static bool _extendedEmptyDismissedThisSession = false;

  Widget _maybeOverlayExtendedEmptyState(
    ExtendedNetworkController ctrl,
    Widget body,
  ) {
    final slice = ctrl.slice;
    final showBanner = ctrl.isCapable &&
        ctrl.mode == ExtendedNetworkMode.extended &&
        slice != null &&
        slice.ownerMap.isEmpty &&
        !_extendedEmptyDismissedThisSession;
    if (!showBanner) return body;
    return Column(
      children: [
        SafeArea(
          top: false,
          bottom: false,
          child: ExtendedNetworkEmptyState(
            onShareInvitation: _handleShareInvitation,
            onFindRelatives: () => context.push('/discover/relatives'),
            onDismiss: () => setState(
              () => _extendedEmptyDismissedThisSession = true,
            ),
            // Главный «выход»: на телефоне тумблер «Моё дерево|Все»
            // спрятан в фильтрах — даём прямой путь назад.
            onBackToMine: () => ctrl.setMode(ExtendedNetworkMode.mine),
          ),
        ),
        Expanded(child: body),
      ],
    );
  }

  /// Phase 6 chunk 4c: empty-state «invite family» CTA. Routes к
  /// relatives screen (existing invite flow lives там per-person).
  /// Не используем buildInvitationLink здесь — invitation API binds
  /// link к конкретному personId; pick'ить relative requires UI.
  /// Cheaper UX: send user туда where invite flow already polished.
  void _handleShareInvitation() {
    // Вкладка «Родные» — там живёт отточенный per-person invite flow.
    context.go('/family');
  }

  Widget _buildTreeTopbar({
    required ThemeData theme,
    required RodnyaDesignTokens tokens,
    required String? selectedTreeId,
    String? treeName,
  }) {
    // Same Android perf bypass as the other topbars — TreeView is
    // the most expensive screen anyway (canvas physics + many node
    // renders), so dropping the topbar's per-frame blur matters
    // even more here than on lighter screens.
    final useBlur = defaultTargetPlatform != TargetPlatform.android;
    // UX-T1 FR1: на телефоне (<1180) топ-бар несёт компактный icon-сегмент
    // Список/Дерево вместо дублирующего слова «Дерево»; десктоп не трогаем.
    final isPhone = MediaQuery.of(context).size.width < 1180;
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
            padding: const EdgeInsets.fromLTRB(8, 3, 12, 3),
            child: Row(
              children: [
                // Дерево — корень своей вкладки: возвращаться отсюда некуда,
                // поэтому слева не «назад», а честный вход в выбор дерева.
                // Слово «Дерево» в заголовке не дублируем — его несёт
                // подсвеченная вкладка бара, идентичность — пилюля с именем.
                IconButton(
                  key: const Key('tree-topbar-select-tree'),
                  icon: Icon(Icons.account_tree_outlined, color: tokens.ink),
                  tooltip: 'Выбрать дерево',
                  onPressed: () => context.go('/trees'),
                ),
                if (!isPhone)
                  Text(
                    _isFriendsTree ? 'Круг' : 'Дерево',
                    style: AppTheme.serif(
                      color: tokens.ink,
                      fontSize: AppTheme.tabTitleFontSize,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.22,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (treeName != null && treeName.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    // UX-T1.2 FR-a: на телефоне тап по названию дерева тоже
                    // раскрывает/сворачивает панель статов (наряду с handle) —
                    // «тап по названию разворачивает». На десктопе панель —
                    // постоянный сайдбар, поэтому тап не вешаем.
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: isPhone
                          ? () => _updateSectionState(() {
                                _compactChromeCollapsed =
                                    !_compactChromeCollapsed;
                              })
                          : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: tokens.accentSoft,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          treeName,
                          style: AppTheme.sans(
                            color: tokens.accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                // Bug fix (S20 FE: RenderFlex overflowed by 191px on a
                // narrow phone). The trailing action controls now live
                // in a horizontal scroll view, so the topbar never
                // overflows at any width — it degrades to a scroll
                // instead. reverse:true keeps the rightmost «⋮» actions
                // menu in view; lower-priority controls scroll off the
                // left when space is tight.
                Flexible(
                  child: SingleChildScrollView(
                    key: const Key('tree-topbar-actions-scroll'),
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Undo / redo пилюли — на десктопе всегда видны (disabled
                        // если стек пуст), чтобы юзер сразу понимал что эта
                        // функциональность есть. На телефоне (UX-T1.2 FR-c) они
                        // переехали в overflow «•••» ради минимального хрома.
                        // ListenableBuilder подписан на TreeMutationHistory,
                        // перерисовывается на push/pop стека (enabled state
                        // меняется в реальном времени).
                        if (!isPhone &&
                            selectedTreeId != null &&
                            GetIt.I.isRegistered<TreeMutationHistory>())
                          ListenableBuilder(
                            listenable: GetIt.I<TreeMutationHistory>(),
                            builder: (context, _) {
                              final history = GetIt.I<TreeMutationHistory>();
                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(width: 8),
                                  _TreeTopbarPill(
                                    tokens: tokens,
                                    tooltip: history.canUndo
                                        ? 'Отменить · Ctrl+Z'
                                        : 'Нечего отменять',
                                    onTap: history.canUndo
                                        ? () => unawaited(_performUndo())
                                        : null,
                                    child: Icon(
                                      Icons.undo_rounded,
                                      size: 19,
                                      color: history.canUndo
                                          ? tokens.ink
                                          : tokens.inkSecondary
                                              .withValues(alpha: 0.4),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  _TreeTopbarPill(
                                    tokens: tokens,
                                    tooltip: history.canRedo
                                        ? 'Повторить · Ctrl+Shift+Z'
                                        : 'Нечего повторять',
                                    onTap: history.canRedo
                                        ? () => unawaited(_performRedo())
                                        : null,
                                    child: Icon(
                                      Icons.redo_rounded,
                                      size: 19,
                                      color: history.canRedo
                                          ? tokens.ink
                                          : tokens.inkSecondary
                                              .withValues(alpha: 0.4),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        if (selectedTreeId != null &&
                            _extendedNetworkController != null) ...[
                          const SizedBox(width: 8),
                          // Phase 4 chunk 2: mode toggle. Toggle вверху appbar'а —
                          // постоянно видимый «эта функция есть». Скрывается если
                          // backend service не implements capability mixin.
                          ChangeNotifierProvider<
                              ExtendedNetworkController>.value(
                            value: _extendedNetworkController!,
                            child: ExtendedNetworkToggle(compact: isPhone),
                          ),
                        ],
                        // UX-T1.2 FR-c: поиск/фильтры расширенной сети — вторичные,
                        // на телефоне живут в «•••» (см. _buildTreeToolbarMenuItems),
                        // отдельные пилюли показываем только на десктопе.
                        if (!isPhone &&
                            selectedTreeId != null &&
                            _shouldShowSearchButton()) ...[
                          const SizedBox(width: 4),
                          _ExtendedSearchButton(
                            tokens: tokens,
                            onTap: () => _openSearchSheet(),
                          ),
                        ],
                        if (!isPhone &&
                            selectedTreeId != null &&
                            _shouldShowFiltersButton()) ...[
                          const SizedBox(width: 4),
                          ChangeNotifierProvider<
                              ExtendedNetworkController>.value(
                            value: _extendedNetworkController!,
                            child: _FiltersButton(
                              tokens: tokens,
                              onTap: () => _openFilterSheet(),
                            ),
                          ),
                        ],
                        if (selectedTreeId != null &&
                            !_isViewerOnly &&
                            !_isSelectionMode &&
                            !_isEditMode) ...[
                          const SizedBox(width: 8),
                          _TreeTopbarPill(
                            tokens: tokens,
                            tooltip: _isFriendsTree
                                ? 'Добавить человека'
                                : 'Добавить родственника',
                            onTap: () => _startAddRelativeFlow(selectedTreeId),
                            child: Icon(
                              Icons.person_add_alt_1_rounded,
                              size: 19,
                              color: tokens.ink,
                            ),
                          ),
                        ],
                        if (selectedTreeId != null) ...[
                          const SizedBox(width: 8),
                          PopupMenuButton<_TreeToolbarAction>(
                            tooltip: 'Действия дерева',
                            onSelected: (action) => _handleTreeToolbarAction(
                                selectedTreeId, action),
                            itemBuilder: (context) =>
                                _buildTreeToolbarMenuItems(isPhone: isPhone),
                            child: Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: tokens.surfaceStrong,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: tokens.surfaceLine),
                              ),
                              child: Icon(
                                Icons.more_horiz_rounded,
                                size: 19,
                                color: tokens.ink,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
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

  Future<void> _handleTreeToolbarAction(
    String selectedTreeId,
    _TreeToolbarAction action,
  ) async {
    final branchRootPerson = _findBranchRootPerson();

    switch (action) {
      case _TreeToolbarAction.refresh:
        await _loadData(selectedTreeId);
        return;
      case _TreeToolbarAction.openHistory:
        await _showTreeHistorySheet();
        return;
      case _TreeToolbarAction.sendDiagnostics:
        await _sendTreeDiagnostics();
        return;
      case _TreeToolbarAction.openChats:
        context.go('/chats');
        return;
      case _TreeToolbarAction.createPost:
        context.push('/post/create');
        return;
      case _TreeToolbarAction.undo:
        unawaited(_performUndo());
        return;
      case _TreeToolbarAction.redo:
        unawaited(_performRedo());
        return;
      case _TreeToolbarAction.openSearch:
        await _openSearchSheet();
        return;
      case _TreeToolbarAction.openFilters:
        await _openFilterSheet();
        return;
      case _TreeToolbarAction.toggleEditMode:
        if (!mounted) {
          return;
        }
        setState(() {
          _isEditMode = !_isEditMode;
          if (!_isEditMode) {
            _selectedEditPersonId = null;
          }
          // Edit and selection are mutually exclusive — both want
          // long-press / tap. Entering one closes the other.
          if (_isEditMode && _isSelectionMode) {
            _isSelectionMode = false;
            _selectedPersonIds.clear();
          }
        });
        return;
      case _TreeToolbarAction.toggleSelectionMode:
        if (!mounted) {
          return;
        }
        setState(() {
          _isSelectionMode = !_isSelectionMode;
          if (!_isSelectionMode) {
            _selectedPersonIds.clear();
          }
          // Symmetric guard — entering selection closes edit mode.
          if (_isSelectionMode && _isEditMode) {
            _isEditMode = false;
            _selectedEditPersonId = null;
          }
        });
        return;
      case _TreeToolbarAction.openBranchChat:
        await _openBranchChat(selectedTreeId, branchRootPerson);
        return;
      case _TreeToolbarAction.openBranchDetails:
        if (branchRootPerson != null) {
          _openPersonDetails(branchRootPerson);
        }
        return;
      case _TreeToolbarAction.copyPublicLink:
        await _copyPublicTreeLink();
        return;
      case _TreeToolbarAction.resetBranchFocus:
        _resetBranchFocus();
        return;
      case _TreeToolbarAction.resetLayout:
        await _resetManualTreeLayout(selectedTreeId);
        return;
    }
  }

  // Ship Q4 (2026-05-26): action sheet pops on tap (non-edit mode).
  // UX audit 2026-05-25 Critical #4 — make Профиль / Edit / Add /
  // Connect / Delete discoverable from single tap, не через скрытые
  // gestures либо chevron-to-expand peek panel.
  void _showTreePersonActionSheet(FamilyPerson person) {
    final treeId = _currentTreeId;
    if (treeId == null) return;
    // Ship FE7 (2026-05-26): hide-toggle tile gating. Available when:
    //   • tree bound к семя (semyaContext resolved)
    //   • caller is member (any role — viewer can hide too)
    //   • person ≠ caller's own person (don't let user hide self —
    //     would lock them out of their own tree row visibility)
    final semyaContext = _currentSemyaContext;
    final viewerPersonId = _graphSnapshot?.viewerPersonId;
    final canToggleHide = semyaContext != null && person.id != viewerPersonId;
    final isCurrentlyHidden = _hiddenPersonIds.contains(person.id);
    // B3 (FR3): «Добавить второго родителя» — контекстный пункт, видимый
    // только когда у узла РОВНО один родитель. Ведёт в add-флоу
    // (relation: parent, contextPersonId — этот ребёнок) с предвыбранным
    // недостающим полом: пользователь ЯВНО привязывает второго родителя
    // ребром parent→child. Это безопасный путь — после редизайна B3 бэк
    // больше НЕ авто-связывает супруга на браке/backfill (корраптило
    // сводные семьи), так что ручное добавление — единственный путь для
    // повторных браков и починки старых деревьев.
    final parentIds = <String>{};
    for (final relation in _relationsData) {
      if (relation.person2Id == person.id &&
          relation.relation1to2 == RelationType.parent) {
        parentIds.add(relation.person1Id);
      } else if (relation.person1Id == person.id &&
          relation.relation2to1 == RelationType.parent) {
        parentIds.add(relation.person2Id);
      }
    }
    VoidCallback? onAddSecondParent;
    if (!_isViewerOnly && parentIds.length == 1) {
      FamilyPerson? existingParent;
      for (final candidate in _treePeople) {
        if (candidate.id == parentIds.first) {
          existingParent = candidate;
          break;
        }
      }
      final missingGender = existingParent?.gender == Gender.female
          ? Gender.male
          : existingParent?.gender == Gender.male
              ? Gender.female
              : null;
      onAddSecondParent = () => _navigateToAddRelativeWithHint(
            treeId,
            relation: RelationType.parent,
            gender: missingGender,
            contextPersonId: person.id,
          );
    }
    showTreePersonActionSheet(
      context,
      person: person,
      onAddSecondParent: onAddSecondParent,
      // Ship FE4 (2026-05-26): viewer-role gating — only «Открыть профиль»
      // tile surfaces, editorial actions hidden. Backend independently
      // rejects mutations с 403; UI gate just keeps виду cleaner.
      viewerMode: _isViewerOnly,
      isHidden: isCurrentlyHidden,
      onToggleHide: canToggleHide
          ? () => _toggleHidePerson(person, isCurrentlyHidden)
          : null,
      onOpenProfile: () => _openPersonDetails(person),
      // UX-аудит P1: «Спросить историю» с канваса в один тап — экран
      // деталей сам поднимет шит вопросов (initialAction: 'story').
      onAskStory: () => _openPersonDetails(person, action: 'story'),
      onEdit: () {
        context
            .push<dynamic>(
          '/relatives/edit/$treeId/${person.id}',
          extra: person,
        )
            .then((_) {
          if (!mounted) return;
          _loadData(treeId);
        });
      },
      onAddRelative: () {
        // Audit Screen 4.2 (2026-05-28): explicit «Кем приходится?»
        // step ПЕРЕД name form. Picker → push с predefinedRelation
        // extra → AddRelativeScreen reads already-supported param.
        showRelationPickerAndNavigateAdd(
          context,
          treeId: treeId,
          contextPersonId: person.id,
          anchorName: person.name,
        ).then((result) {
          if (!mounted) return;
          if (result == true ||
              (result is Map<String, dynamic> && result['updated'] == true)) {
            _loadData(treeId);
          }
        });
      },
      onConnect: () => _openPersonDetails(person, action: 'relations'),
      onDelete: () => _showDeletePersonConfirmation(person),
    );
  }

  /// Ship FE7 (2026-05-26): toggle person hide state. Hide = add к
  /// caller's hideFilter; unhide = remove. Backend filters tree-routes
  /// per the canonical list, so after toggle we just re-fetch tree (it
  /// auto-applies filter). Snackbar feedback. Errors surface inline.
  Future<void> _toggleHidePerson(
    FamilyPerson person,
    bool isCurrentlyHidden,
  ) async {
    final semyaContext = _currentSemyaContext;
    final treeId = _currentTreeId;
    if (semyaContext == null || treeId == null) return;
    final service = _familyService;
    if (service is! SemyaCapableFamilyTreeService) return;
    final capable = service as SemyaCapableFamilyTreeService;
    try {
      final updated = await capable.updateHideFilter(
        semyaId: semyaContext.semya.id,
        addPersonIds: isCurrentlyHidden ? const <String>[] : [person.id],
        removePersonIds: isCurrentlyHidden ? [person.id] : const <String>[],
      );
      if (!mounted) return;
      setState(() {
        _hiddenPersonIds = updated;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isCurrentlyHidden
                ? '${person.name} снова отображается'
                : '${person.name} скрыт${person.gender == Gender.female ? 'а' : ''} от вас',
          ),
        ),
      );
      // Re-fetch tree — backend now applies filter с updated list.
      await _loadData(treeId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              humanizeError(error, fallback: 'Не удалось изменить видимость.')),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  // Ship Q4: destructive delete с consequence copy (audit recommendation:
  // «Удалить карточку из дерева? Связи с родственниками будут удалены»).
  //
  // Ship 2026-05-26 (Post delete polish): refactored inline dialog к
  // shared SafeDeleteConfirmationDialog widget — same pattern reused
  // для post delete (audit Screen 3.5).
  //
  // Ship Q4a frontend (2026-05-28, Ship 31): backend now soft-deletes
  // через deletedPersons collection с 30-day retention + Settings →
  // Корзина restore. Copy обновлён — «нельзя отменить» был ложью.
  Future<void> _showDeletePersonConfirmation(FamilyPerson person) async {
    final treeId = _currentTreeId;
    if (treeId == null) return;
    final confirmed = await showSafeDeleteConfirmation(
      context,
      title: 'Удалить ${person.name}?',
      body: 'Карточка и связи с родственниками переедут в корзину. '
          'Восстановить можно в течение 30 дней в Настройки → Корзина.',
    );
    if (!confirmed || !mounted) return;
    try {
      await _familyService.deleteRelative(treeId, person.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '${person.name} удалён${person.gender == Gender.female ? 'а' : ''} из дерева'),
        ),
      );
      _clearSelectedTreePerson();
      await _loadData(treeId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(humanizeError(error, fallback: 'Не удалось удалить.')),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  Future<void> _openPersonDetails(
    FamilyPerson person, {
    String? action,
  }) async {
    // P0: канвас знает дерево человека — прокидываем его в карточку.
    final route = relativeDetailsRoute(
      person.id,
      treeId: person.treeId.isNotEmpty ? person.treeId : _currentTreeId,
      action: action,
    );
    // Awaiting the push lets us refresh the tree once the user
    // navigates back. The detail screen edits person fields /
    // photos in place — without this refresh the tree keeps
    // showing the stale avatar / labels until the user hits
    // hard-reload. With this, swipe-back / tap-back transparently
    // pulls the updated state and Phase 1.1 propagation effects
    // (e.g., photos that fanned out to linked records on other
    // trees) come along for the ride.
    await context.push<dynamic>(route);
    if (!mounted) return;
    final treeId = _currentTreeId;
    if (treeId == null) return;
    await _loadData(treeId);
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
          content: Text(
            'Не удалось определить активное дерево. Откройте его заново и повторите действие.',
          ),
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
            });
          }
        });
      }
    });
  }

  // <<< НОВЫЙ МЕТОД-КОЛЛБЭК: Обработка добавления себя из дерева >>>
  // ── Phase 1.2 voltage-indicator matcher handlers ────────────────
  // The canvas reads `_identitySuggestionCounts` to decide where
  // to show the 💡 dot; tap on the dot calls `_handleShowIdentity
  // SuggestionsForPerson` which fetches details, opens a sheet
  // with the suggestion list, dispatches link/dismiss on the
  // service, and refreshes the counts.

  Future<void> _refreshIdentitySuggestionCounts(
    String treeId,
    List<FamilyPerson> relatives,
  ) async {
    final service = _familyService;
    if (service is! IdentitySuggestionsCapableFamilyTreeService) return;
    final capable = service as IdentitySuggestionsCapableFamilyTreeService;
    final newCounts = <String, int>{};
    // Sequential fetch is acceptable here — only a handful of
    // persons typically and the response is tiny. Parallelizing
    // could trigger rate-limits on the auth route.
    for (final person in relatives) {
      try {
        final suggestions = await capable.getIdentitySuggestionsForPerson(
          treeId: treeId,
          personId: person.id,
        );
        if (suggestions.isNotEmpty) {
          newCounts[person.id] = suggestions.length;
        }
      } catch (_) {
        // Suggestion fetch is best-effort — failure on one
        // person shouldn't kill the whole batch.
      }
      if (!mounted || _currentTreeId != treeId) return;
    }
    if (mounted && _currentTreeId == treeId) {
      setState(() {
        _identitySuggestionCounts = newCounts;
      });
    }
  }

  Future<void> _handleShowIdentitySuggestionsForPerson(String personId) async {
    final treeId = _currentTreeId;
    if (treeId == null) return;
    final service = _familyService;
    if (service is! IdentitySuggestionsCapableFamilyTreeService) return;
    final capable = service as IdentitySuggestionsCapableFamilyTreeService;
    List<IdentitySuggestion> suggestions;
    try {
      suggestions = await capable.getIdentitySuggestionsForPerson(
        treeId: treeId,
        personId: personId,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(humanizeError(error,
                fallback: 'Не удалось загрузить подсказки.'))),
      );
      return;
    }
    if (!mounted || suggestions.isEmpty) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _IdentitySuggestionsSheet(
        suggestions: suggestions,
        onConfirm: (suggestion) async {
          Navigator.of(sheetContext).pop();
          await _confirmIdentitySuggestion(suggestion);
        },
        onDismiss: (suggestion) async {
          await _dismissIdentitySuggestion(suggestion);
          // Re-render the sheet without that suggestion. Easiest
          // way: pop and reopen; or hand the sheet a stateful
          // wrapper. For simplicity, just pop — the dot count
          // refresh below will re-show one if others remain.
          if (sheetContext.mounted) {
            Navigator.of(sheetContext).pop();
          }
          // Reload list with remaining suggestions.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await _handleShowIdentitySuggestionsForPerson(personId);
        },
      ),
    );
  }

  Future<void> _confirmIdentitySuggestion(IdentitySuggestion suggestion) async {
    final service = _familyService;
    if (service is! IdentitySuggestionsCapableFamilyTreeService) return;
    final capable = service as IdentitySuggestionsCapableFamilyTreeService;
    try {
      await capable.linkIdentity(
        sourceTreeId: suggestion.sourceTreeId,
        sourcePersonId: suggestion.sourcePersonId,
        targetTreeId: suggestion.targetTreeId,
        targetPersonId: suggestion.targetPersonId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Карточки связаны. Теперь правки в одной автоматически отразятся в другой.',
          ),
          duration: Duration(seconds: 4),
        ),
      );
      // Refresh tree (propagation may have already touched fields)
      // and recompute the 💡 counts (this pair drops out).
      final treeId = _currentTreeId;
      if (treeId != null) {
        await _loadData(treeId);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(humanizeError(error,
                fallback: 'Не удалось связать карточки.'))),
      );
    }
  }

  // ── Phase 1.3 edit-time conflict surfacing handlers ─────────────
  // Tree-level fetch, group-by personId, render ⚠️ badge on each
  // affected card. Tap → resolve sheet, applies user choice,
  // refreshes counts.

  Future<void> _refreshIdentityConflictCounts(String treeId) async {
    final service = _familyService;
    if (service is! IdentityConflictsCapableFamilyTreeService) return;
    final capable = service as IdentityConflictsCapableFamilyTreeService;
    List<IdentityFieldConflict> conflicts;
    try {
      conflicts = await capable.getIdentityConflictsForTree(treeId: treeId);
    } catch (_) {
      // Best-effort — a failed fetch shouldn't kill the tree
      // render. The badge just stays absent until next refresh.
      return;
    }
    if (!mounted || _currentTreeId != treeId) return;
    final counts = <String, int>{};
    for (final conflict in conflicts) {
      counts[conflict.targetPersonId] =
          (counts[conflict.targetPersonId] ?? 0) + 1;
    }
    setState(() {
      _identityConflictCounts = counts;
      _identityConflictsCache = conflicts;
    });
  }

  Future<void> _handleShowIdentityConflictsForPerson(String personId) async {
    final treeId = _currentTreeId;
    if (treeId == null) return;
    final service = _familyService;
    if (service is! IdentityConflictsCapableFamilyTreeService) return;
    final personConflicts = _identityConflictsCache
        .where((c) => c.targetPersonId == personId && !c.isResolved)
        .toList(growable: false);
    if (personConflicts.isEmpty) {
      // Cache stale (already resolved on another device, deleted,
      // etc.) — refresh and bail. The badge will disappear once
      // counts state catches up.
      await _refreshIdentityConflictCounts(treeId);
      return;
    }

    await showIdentityConflictsSheet(
      context: context,
      conflicts: personConflicts,
      onChoice: (sheetContext, conflict, choice) async {
        final capable = service as IdentityConflictsCapableFamilyTreeService;
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
        // overwrite changes the underlying person — pull a fresh
        // tree snapshot so the canvas shows the new canonical
        // value. keep is data-neutral but the refresh below
        // clears the badge either way.
        if (choice == 'overwrite') {
          await _loadData(treeId);
        } else {
          await _refreshIdentityConflictCounts(treeId);
        }
      },
    );
  }

  Future<void> _dismissIdentitySuggestion(IdentitySuggestion suggestion) async {
    final service = _familyService;
    if (service is! IdentitySuggestionsCapableFamilyTreeService) return;
    final capable = service as IdentitySuggestionsCapableFamilyTreeService;
    try {
      await capable.dismissIdentitySuggestion(
        sourceTreeId: suggestion.sourceTreeId,
        sourcePersonId: suggestion.sourcePersonId,
        targetPersonId: suggestion.targetPersonId,
      );
      // Optimistically drop the count by one — a fresh fetch
      // confirms after.
      if (mounted) {
        setState(() {
          final next = Map<String, int>.from(_identitySuggestionCounts);
          final current = next[suggestion.sourcePersonId] ?? 0;
          if (current <= 1) {
            next.remove(suggestion.sourcePersonId);
          } else {
            next[suggestion.sourcePersonId] = current - 1;
          }
          _identitySuggestionCounts = next;
        });
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(humanizeError(error,
                fallback: 'Не удалось скрыть подсказку.'))),
      );
    }
  }

  // Blank-card creator handler. Called when the user tapped the
  // canvas-level "+ Карточка" FAB, filled name + gender in the
  // compact dialog, and pressed Save. We create the person without
  // any relation; the user connects them to the rest of the tree
  // via the edge-first connector. Pairs with the connector to
  // fully replace the form-based add-relative flow.
  Future<void> _handleAddBlankPersonFromTree(
    Map<String, dynamic> personData,
  ) async {
    final treeId = _currentTreeId;
    if (treeId == null) return;
    try {
      // addRelative returns the new person id — we capture it so
      // the tree can auto-center on the new card after the
      // reload (nice UX detail: without this, a freshly-created
      // orphan ends up wherever the layout engine puts it,
      // possibly off-screen if the user is zoomed into another
      // branch).
      final newPersonId = await _familyService.addRelative(treeId, personData);
      if (!mounted) return;
      // Record for undo (this path didn't before) → «Отменить» deletes it.
      if (GetIt.I.isRegistered<TreeMutationHistory>()) {
        GetIt.I<TreeMutationHistory>().recordPersonAdded(
          treeId: treeId,
          personId: newPersonId,
          personData: personData,
        );
      }
      // Stamp the recenter id BEFORE the reload — when _loadData
      // sets peopleData the InteractiveFamilyTree's didUpdateWidget
      // sees both the new data + the new recenter target in one
      // pass and schedules the focus once layout is recomputed.
      setState(() {
        _recenterOnPersonIdAfterReload = newPersonId;
      });
      await _loadData(treeId);
      if (mounted) {
        _showTreeUndoToast(
            'Карточка добавлена. Соедините её длинным нажатием.');
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(humanizeError(error,
                fallback: 'Не удалось добавить карточку.'))),
      );
    }
  }

  // Edge-first connector handler. Called when the user has dragged
  // one card onto another and picked a relation type from the inline
  // 4-icon picker. Skips the AddRelativeScreen form entirely and
  // creates the relation directly via the family-tree service, then
  // reloads the tree so the new edge appears.
  //
  // The picker only offers four relation types (parent, spouse,
  // sibling, other). For "other" we open a small sheet to ask which
  // long-tail relation (cousin / nephew / step-* / etc.) — better
  // than guessing wrong and silently writing a bad edge.
  Future<void> _handleConnectExistingFromTree(
    String sourcePersonId,
    String targetPersonId,
    RelationType relation1to2,
  ) async {
    final treeId = _currentTreeId;
    if (treeId == null) return;
    if (sourcePersonId.isEmpty || targetPersonId.isEmpty) return;
    if (sourcePersonId == targetPersonId) return;

    // For "other" we DON'T have enough info to create a relation —
    // pop the legacy quick-add sheet pre-anchored on the target so
    // the user can pick the specific long-tail type. This is the
    // only branch where the form is still needed.
    if (relation1to2 == RelationType.other) {
      final sourcePerson = _relativesData
          .map((entry) => entry['person'])
          .whereType<FamilyPerson>()
          .firstWhere(
            (person) => person.id == sourcePersonId,
            orElse: () => FamilyPerson(
              id: sourcePersonId,
              treeId: treeId,
              name: '',
              gender: Gender.unknown,
              isAlive: true,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );
      _handleAddRelativeFromTree(sourcePerson, relation1to2);
      return;
    }

    try {
      final created = await _familyService.createRelation(
        treeId: treeId,
        person1Id: sourcePersonId,
        person2Id: targetPersonId,
        relation1to2: relation1to2,
        isConfirmed: true,
      );
      if (GetIt.I.isRegistered<TreeMutationHistory>()) {
        GetIt.I<TreeMutationHistory>().recordRelationCreated(
          treeId: treeId,
          created: created,
        );
      }
      if (!mounted) return;
      // Reload so the new edge renders + layout engine can rebalance.
      await _loadData(treeId);
      if (mounted) _showTreeUndoToast('Связь создана');
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                humanizeError(error, fallback: 'Не удалось создать связь.'))),
      );
    }
  }

  // Phase B polish B: ~10s «Отменить» toast after an add (mama doesn't
  // know Ctrl+Z). «Отменить» → TreeMutationHistory.undoForUi() inverts the
  // most-recent mutation (recordPersonAdded → delete; recordRelationCreated
  // → disconnect) and reloads.
  void _showTreeUndoToast(String message) {
    if (!GetIt.I.isRegistered<TreeMutationHistory>()) {
      showAppSnackBar(context, message);
      return;
    }
    showAppSnackBar(
      context,
      message,
      duration: const Duration(seconds: 10),
      action: SnackBarAction(
        label: 'Отменить',
        onPressed: _undoLastTreeMutation,
      ),
    );
  }

  Future<void> _undoLastTreeMutation() async {
    if (!GetIt.I.isRegistered<TreeMutationHistory>()) return;
    final description =
        await GetIt.I<TreeMutationHistory>().undoForUi(_familyService);
    if (!mounted || description == null) return;
    final treeId = _currentTreeId;
    if (treeId != null) await _loadData(treeId);
    if (mounted) showAppSnackBar(context, 'Отменено: $description');
  }

  Future<void> _handleAddSelfFromTree(
    FamilyPerson targetPerson,
    RelationType relationType,
  ) async {
    if (_currentTreeId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Не удалось определить активное дерево. Откройте его заново и повторите действие.',
          ),
        ),
      );
      return;
    }

    final currentUserId = _authService.currentUserId;
    if (currentUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Сессия завершилась. Войдите снова.')),
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

  Future<void> _showTreeHistorySheet({FamilyPerson? person}) async {
    final treeId = _currentTreeId;
    if (treeId == null) {
      return;
    }

    final historyFuture = _familyService.getTreeHistory(
      treeId: treeId,
      personId: person?.id,
    );
    final sheetTitle = person == null ? 'История дерева' : 'История изменений';
    final sheetSubtitle = person?.name ??
        _currentTreeMeta?.name ??
        widget.routeTreeName ??
        'Текущее дерево';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return TreeHistorySheet(
          historyFuture: historyFuture,
          title: sheetTitle,
          subtitle: sheetSubtitle,
          currentUserId: _authService.currentUserId,
          emptyMessage: person == null
              ? 'В журнале дерева пока нет записей.'
              : 'Для этой карточки пока нет записей в журнале.',
          errorBuilder: (error) => _describeTreeActionError(
            error,
            fallbackMessage: 'Не удалось загрузить историю.',
          ),
          onOpenPerson: (personId) async {
            Navigator.of(sheetContext).pop();
            if (!mounted) return;
            await context.push<dynamic>(
              relativeDetailsRoute(personId, treeId: _currentTreeId),
            );
            if (!mounted) return;
            // Refresh tree on return so edits made on the detail
            // screen (photo, name parts, dates) show up immediately
            // instead of requiring a hard-reload.
            final treeId = _currentTreeId;
            if (treeId != null) {
              await _loadData(treeId);
            }
          },
        );
      },
    );
  }

  Future<void> _showPersonHistorySheet(FamilyPerson person) {
    return _showTreeHistorySheet(person: person);
  }

  /// A-CTA: пользователь закрыл блокирующий гид — на сессию. Канвас с
  /// FAB остаётся доступен; гид не вернётся до перезапуска.
  void _dismissGuidedCta() {
    if (_guidedCtaDismissedThisSession) return;
    setState(() => _guidedCtaDismissedThisSession = true);
  }

  /// A-CTA: занимает ли тело экрана онбординг-гид пустого/только-себя
  /// дерева. Пока он показан, баннер «Не бойся сломать» прятать — он
  /// (а) бессмыслен (ломать ещё нечего) и (б) перекрывал собой верх гида
  /// вместе с крестиком «скрыть». Зеркалит ветки в [_buildTreeBody].
  bool get _isGuidedCtaActive {
    if (_guidedCtaDismissedThisSession) return false;
    if (_isLoading) return false;
    if (_errorMessage.isNotEmpty) return false;
    final isEmptyTree = _relativesData.isEmpty && _relationsData.isEmpty;
    if (isEmptyTree) return true;
    final selfPerson = _findSelfPerson();
    return _relativesData.length == 1 && selfPerson != null && !_isFriendsTree;
  }

  Future<void> _navigateToAddRelative(String treeId) async {
    final result = await context.push('/relatives/add/$treeId');
    if ((result == true ||
            (result is Map<String, dynamic> && result['updated'] == true)) &&
        mounted) {
      await _loadData(treeId);
    }
  }

  /// Чанк C: единый вход generic-добавления с канваса — раньше FAB вёл в
  /// пикер «Кем приходится?», а toolbar-кнопка в прямую форму (два разных
  /// флоу на одно действие путали). Семья → пикер; Круг → сразу форма
  /// (ролей родства в круге нет — как в empty-state). После успешного
  /// добавления канвас перечитывается.
  Future<void> _startAddRelativeFlow(String treeId) async {
    if (_isFriendsTree) {
      await _navigateToAddRelative(treeId);
      return;
    }
    final result = await showRelationPickerAndNavigateAdd(
      context,
      treeId: treeId,
    );
    if ((result == true ||
            (result is Map<String, dynamic> && result['updated'] == true)) &&
        mounted) {
      await _loadData(treeId);
    }
  }

  /// Ship 2026-05-26 (UX audit Screen 4.1): relation-first guided CTA
  /// dispatch. Caller (EmptyTreeGuidedCta) passes RelationType +
  /// optional Gender + optional contextPersonId (self person when
  /// tree уже has caller's card). AddRelativeScreen reads extras
  /// и pre-fills relation dropdown + gender selector.
  Future<void> _navigateToAddRelativeWithHint(
    String treeId, {
    required RelationType relation,
    Gender? gender,
    String? contextPersonId,
  }) async {
    final extra = <String, dynamic>{
      'relationType': relation,
      'quickAddMode': true,
      if (gender != null) 'prefilledGender': gender,
      if (contextPersonId != null) 'contextPersonId': contextPersonId,
    };
    final result = await context.push(
      '/relatives/add/$treeId',
      extra: extra,
    );
    if (!mounted) return;
    if (result == true ||
        (result is Map<String, dynamic> && result['updated'] == true)) {
      await _loadData(treeId);
    }
  }

  /// Ship FE4 (2026-05-26): resolves семя binding for active tree (if
  /// any) using SemyaListController.semyi as lookup (already loaded
  /// app-wide). Reverse-match via Semya.treeId == treeId. Then fetches
  /// SemyaDetails to learn caller's role.
  ///
  /// Returns null когда:
  ///   • Tree not bound к семя (no Semya entry с matching treeId)
  ///   • Capability service unavailable (legacy backend)
  ///   • findSemyaById fails либо returns null (network / 403)
  ///
  /// Caller treats null as «unbound / legacy» — full mutation rights
  /// preserved для personal trees.
  /// Ship FE7 (2026-05-26): fetch caller's hide-filter list для семя.
  /// Best-effort — failures return empty list (action sheet's hide
  /// tile still works, default «Скрыть»; PATCH endpoint will accept
  /// либо surface error). Backend filters tree-routes по the canonical
  /// store list regardless of local state, so frontend can degrade
  /// gracefully.
  Future<List<String>> _fetchHiddenPersonIds(String semyaId) async {
    final service = _familyService;
    if (service is! SemyaCapableFamilyTreeService) return const <String>[];
    final capable = service as SemyaCapableFamilyTreeService;
    try {
      return await capable.listHiddenPersonIds(semyaId: semyaId);
    } catch (_) {
      return const <String>[];
    }
  }

  Future<void> _refreshHiddenPersonIdsForLoadedSemya({
    required String treeId,
    required SemyaDetails? semyaContext,
  }) async {
    final semyaId = semyaContext?.semya.id;
    if (semyaId == null || semyaId.isEmpty) {
      if (!mounted || _currentTreeId != treeId) return;
      if (_hiddenPersonIds.isNotEmpty) {
        setState(() {
          _hiddenPersonIds = const <String>[];
        });
      }
      return;
    }
    final hiddenIds = await _fetchHiddenPersonIds(semyaId);
    if (!mounted ||
        _currentTreeId != treeId ||
        _currentSemyaContext?.semya.id != semyaId) {
      return;
    }
    setState(() {
      _hiddenPersonIds = hiddenIds;
    });
  }

  Future<SemyaDetails?> _resolveSemyaContextForTree(String treeId) async {
    final service = _familyService;
    if (service is! SemyaCapableFamilyTreeService) return null;
    final capable = service as SemyaCapableFamilyTreeService;
    try {
      // Pull all семья caller belongs to и reverse-match by treeId.
      // SemyaListController caches this list app-wide; calling listMySemya
      // directly keeps tree_view_screen independent от Provider plumbing
      // плюс ensures we have fresh data (any семя created after app boot
      // would still be visible since listMySemya hits backend).
      final mySemyi = await capable.listMySemya();
      Semya? bound;
      for (final entry in mySemyi) {
        if (entry.treeId == treeId) {
          bound = entry;
          break;
        }
      }
      if (bound == null) return null;
      // Found семя — fetch details (includes caller's membership row).
      return await capable.findSemyaById(bound.id);
    } catch (_) {
      // Graceful degradation — на network failure treат tree as unbound
      // (legacy full-access). Backend mutation gates still enforce
      // serverside per ship pattern, поэтому viewer случайно
      // не сломает чужое дерево даже если UI ошибочно показал кнопки.
      return null;
    }
  }

  /// Returns current user's person card in the active tree, либо null
  /// when not present. Used by empty-tree guided CTA to determine
  /// «only self» state (≠ truly empty tree).
  FamilyPerson? _findSelfPerson() {
    final currentUserId = _authService.currentUserId;
    if (currentUserId == null) return null;
    for (final entry in _relativesData) {
      final person = entry['person'];
      if (person is FamilyPerson && person.userId == currentUserId) {
        return person;
      }
    }
    return null;
  }

  Set<String> _buildBranchVisiblePersonIds(String branchRootPersonId) {
    final graphSnapshot = _graphSnapshot;
    final personIds = _relativesData
        .map((entry) => entry['person'])
        .whereType<FamilyPerson>()
        .map((person) => person.id)
        .toSet();
    if (graphSnapshot != null) {
      final branchBlock =
          graphSnapshot.findBranchBlockForPerson(branchRootPersonId);
      if (branchBlock != null) {
        return branchBlock.memberPersonIds.toSet();
      }
    }
    return personIds;
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
      _selectedPersonSheetId = person.id;
    });
  }

  // ── Phase 4: «Кем мы приходимся?» ──────────────────────────────────
  // Walks the unified-graph blood-relation path from the viewer's
  // own card to the selected person and shows a sheet with the
  // Russian relationship label + the chain of intermediate people
  // ("you → mom → her brother → his daughter"). Tap on the action
  // chip in the person sheet — _showTreePersonBloodRelation — wires
  // straight into this.
  Future<void> _showTreePersonBloodRelation(FamilyPerson person) async {
    final viewerPersonId = _graphSnapshot?.viewerPersonId;
    if (viewerPersonId == null) {
      _showSnack(
        'Чтобы найти родство, добавьте свою карточку в дерево.',
      );
      return;
    }
    if (viewerPersonId == person.id) {
      _showSnack('Это вы.');
      return;
    }
    final viewerPerson = _treePeople.firstWhere(
      (p) => p.id == viewerPersonId,
      orElse: () => person, // unreachable — viewerPersonId is in tree
    );
    final viewerIdentityId = _personIdentityIdFor(viewerPerson);
    final targetIdentityId = _personIdentityIdFor(person);
    if (viewerIdentityId == null || targetIdentityId == null) {
      _showSnack(
        'Карточки ещё не синхронизированы с графом — попробуйте через минуту.',
      );
      return;
    }

    final service = _familyService;
    if (service is! BloodRelationCapableFamilyTreeService) {
      _showSnack('Эта функция пока недоступна на бэкенде.');
      return;
    }
    final capable = service as BloodRelationCapableFamilyTreeService;

    BloodRelation? relation;
    try {
      relation = await capable.findBloodRelation(
        fromGraphPersonId: viewerIdentityId,
        toGraphPersonId: targetIdentityId,
      );
    } catch (error) {
      if (!mounted) return;
      _showSnack(humanizeError(error, fallback: 'Не удалось найти родство.'));
      return;
    }
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _BloodRelationSheet(
        target: person,
        relation: relation!,
      ),
    );
  }

  String? _personIdentityIdFor(FamilyPerson person) {
    final identityId = person.identityId;
    if (identityId != null && identityId.trim().isNotEmpty) {
      return identityId.trim();
    }
    return null;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _resetBranchFocus() {
    if (!mounted) {
      return;
    }
    setState(() {
      _branchRootPersonId = null;
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

    final graphBranchBlock =
        _graphSnapshot?.findBranchBlockForPerson(branchRootPerson.id);
    final title = graphBranchBlock?.label ?? 'Ветка ${branchRootPerson.name}';
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

  Future<void> _sendTreeDiagnostics() async {
    final payload = _buildTreeDiagnosticPayload();
    final encodedPayload = const JsonEncoder.withIndent('  ').convert(payload);
    await Clipboard.setData(ClipboardData(text: encodedPayload));

    String? eventId;
    if (GetIt.I.isRegistered<CustomApiDiagnosticsService>()) {
      eventId = await GetIt.I<CustomApiDiagnosticsService>().capture(
        type: 'tree_layout_snapshot',
        message: 'Диагностика раскладки дерева',
        context: payload,
      );
    }

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          eventId == null
              ? 'Диагностика дерева скопирована. Отправка на сервер недоступна.'
              : 'Диагностика дерева отправлена и скопирована.',
        ),
      ),
    );
  }

  Map<String, dynamic> _buildTreeDiagnosticPayload() {
    final mediaQuery = MediaQuery.maybeOf(context);
    final snapshot = _graphSnapshot;
    return <String, dynamic>{
      'kind': 'tree_layout_snapshot',
      'createdAt': DateTime.now().toIso8601String(),
      'tree': <String, dynamic>{
        'treeId': _currentTreeId,
        'treeName': _currentTreeMeta?.name,
        'isFriendsTree': _isFriendsTree,
        'branchRootPersonId': _branchRootPersonId,
      },
      'viewer': <String, dynamic>{
        'userId': _authService.currentUserId,
        'viewerPersonId': snapshot?.viewerPersonId,
        'currentUserIsInTree': _currentUserIsInTree,
        'role': _callerSemyaRole?.name,
        'viewerOnly': _isViewerOnly,
      },
      'uiState': <String, dynamic>{
        'selectedPersonSheetId': _selectedPersonSheetId,
        'selectedEditPersonId': _selectedEditPersonId,
        'selectedPersonIds': _selectedPersonIds.toList()..sort(),
        'isEditMode': _isEditMode,
        'isSelectionMode': _isSelectionMode,
        'manualPositionCount': _manualNodePositions.length,
      },
      'viewport': mediaQuery == null
          ? null
          : <String, dynamic>{
              'width': mediaQuery.size.width,
              'height': mediaQuery.size.height,
              'devicePixelRatio': mediaQuery.devicePixelRatio,
              'padding': <String, dynamic>{
                'left': mediaQuery.padding.left,
                'top': mediaQuery.padding.top,
                'right': mediaQuery.padding.right,
                'bottom': mediaQuery.padding.bottom,
              },
            },
      'people': _treePeople.map(_personDiagnosticPayload).toList(),
      'relations': _relationsData.map(_relationDiagnosticPayload).toList(),
      'manualNodePositions': _manualNodePositions.map(
        (id, position) => MapEntry(
          id,
          <String, dynamic>{
            'dx': position.dx,
            'dy': position.dy,
          },
        ),
      ),
      'graphSnapshot': snapshot == null
          ? null
          : <String, dynamic>{
              'treeId': snapshot.treeId,
              'viewerPersonId': snapshot.viewerPersonId,
              'familyUnits': snapshot.familyUnits
                  .map(_familyUnitDiagnosticPayload)
                  .toList(),
              'branchBlocks': snapshot.branchBlocks
                  .map(_branchBlockDiagnosticPayload)
                  .toList(),
              'generationRows': snapshot.generationRows
                  .map(_generationRowDiagnosticPayload)
                  .toList(),
              'viewerDescriptors': snapshot.viewerDescriptors
                  .map(_viewerDescriptorDiagnosticPayload)
                  .toList(),
              'warnings':
                  snapshot.warnings.map(_warningDiagnosticPayload).toList(),
            },
    };
  }

  Map<String, dynamic> _personDiagnosticPayload(FamilyPerson person) {
    return <String, dynamic>{
      'id': person.id,
      'treeId': person.treeId,
      'identityId': person.identityId,
      'name': person.name,
      'maidenName': person.maidenName,
      'gender': person.gender.name,
      'birthDate': person.birthDate?.toIso8601String(),
      'birthDatePrecision': person.birthDatePrecision,
      'deathDate': person.deathDate?.toIso8601String(),
      'deathDatePrecision': person.deathDatePrecision,
      'isAlive': person.isAlive,
      'relation': person.relation,
      'hasLinkedUser': (person.userId ?? '').trim().isNotEmpty,
      'parentIds': person.parentIds ?? const <String>[],
      'childrenIds': person.childrenIds ?? const <String>[],
      'spouseId': person.spouseId,
      'siblingIds': person.siblingIds ?? const <String>[],
    };
  }

  Map<String, dynamic> _relationDiagnosticPayload(FamilyRelation relation) {
    return <String, dynamic>{
      'id': relation.id,
      'treeId': relation.treeId,
      'person1Id': relation.person1Id,
      'person2Id': relation.person2Id,
      'relation1to2': relation.relation1to2.name,
      'relation2to1': relation.relation2to1.name,
      'isConfirmed': relation.isConfirmed,
      'parentSetId': relation.parentSetId,
      'parentSetType': relation.parentSetType,
      'isPrimaryParentSet': relation.isPrimaryParentSet,
      'unionId': relation.unionId,
      'unionType': relation.unionType,
      'unionStatus': relation.unionStatus,
      'marriageDate': relation.marriageDate?.toIso8601String(),
      'divorceDate': relation.divorceDate?.toIso8601String(),
    };
  }

  Map<String, dynamic> _familyUnitDiagnosticPayload(
    TreeGraphFamilyUnit unit,
  ) {
    return <String, dynamic>{
      'id': unit.id,
      'rootParentSetId': unit.rootParentSetId,
      'adultIds': unit.adultIds,
      'childIds': unit.childIds,
      'relationIds': unit.relationIds,
      'unionId': unit.unionId,
      'unionType': unit.unionType,
      'unionStatus': unit.unionStatus,
      'parentSetType': unit.parentSetType,
      'isPrimaryParentSet': unit.isPrimaryParentSet,
      'label': unit.label,
    };
  }

  Map<String, dynamic> _branchBlockDiagnosticPayload(
    TreeGraphBranchBlock block,
  ) {
    return <String, dynamic>{
      'id': block.id,
      'rootUnitId': block.rootUnitId,
      'label': block.label,
      'memberPersonIds': block.memberPersonIds,
    };
  }

  Map<String, dynamic> _generationRowDiagnosticPayload(
    TreeGraphGenerationRow row,
  ) {
    return <String, dynamic>{
      'row': row.row,
      'label': row.label,
      'personIds': row.personIds,
      'familyUnitIds': row.familyUnitIds,
    };
  }

  Map<String, dynamic> _viewerDescriptorDiagnosticPayload(
    TreeGraphViewerDescriptor descriptor,
  ) {
    return <String, dynamic>{
      'personId': descriptor.personId,
      'primaryRelationLabel': descriptor.primaryRelationLabel,
      'isBlood': descriptor.isBlood,
      'alternatePathCount': descriptor.alternatePathCount,
      'pathSummary': descriptor.pathSummary,
      'primaryPathPersonIds': descriptor.primaryPathPersonIds,
    };
  }

  Map<String, dynamic> _warningDiagnosticPayload(TreeGraphWarning warning) {
    return <String, dynamic>{
      'id': warning.id,
      'code': warning.code,
      'severity': warning.severity,
      'message': warning.message,
      'hint': warning.hint,
      'personIds': warning.personIds,
      'familyUnitIds': warning.familyUnitIds,
      'relationIds': warning.relationIds,
    };
  }

  // ── Phase 4 chunk 2: filter button helpers ───────────────────────

  bool _shouldShowFiltersButton() {
    final controller = _extendedNetworkController;
    if (controller == null || !controller.isCapable) return false;
    // Кнопку «Фильтры» показываем только если юзер в extended mode'е
    // (mine mode controls не нужны).
    return controller.mode == ExtendedNetworkMode.extended;
  }

  // ── Phase 4 chunk 4a: foreign node tap handler ──────────────────

  Future<void> _handleForeignNodeTap(FamilyPerson person) async {
    final controller = _extendedNetworkController;
    if (controller == null) return;
    final slice = controller.slice;
    if (slice == null) return;
    final bloodService = _familyService;
    if (bloodService is! BloodRelationCapableFamilyTreeService) return;
    final blood = bloodService as BloodRelationCapableFamilyTreeService;
    await showForeignNodeSheet(
      context,
      person: person,
      slice: slice,
      bloodRelationService: blood,
      onOpenCard: () {
        if (!mounted) return;
        // P0: foreign-узел живёт в чужом дереве — person.treeId указывает
        // именно его; read-доступ гейтится бэком (Phase 3.2).
        context.push(
          relativeDetailsRoute(
            person.id,
            treeId: person.treeId.isNotEmpty ? person.treeId : null,
          ),
        );
      },
      onWriteToOwner: (ownerUserId) async {
        if (!mounted) return;
        try {
          final chatId = await _chatService.getOrCreateChat(ownerUserId);
          if (chatId == null || chatId.isEmpty) {
            throw StateError('Не удалось открыть чат');
          }
          if (!mounted) return;
          // Найти display name из slice ownerMap для title.
          final ownerInfo = slice.getOwnerInfo(person.identityId ?? person.id);
          final title = ownerInfo?.displayName?.trim().isNotEmpty == true
              ? ownerInfo!.displayName!
              : 'Чат';
          context.push(
            '/chats/view/$chatId?type=direct&title=${Uri.encodeComponent(title)}&userId=$ownerUserId',
          );
        } catch (error) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _describeTreeActionError(
                  error,
                  fallbackMessage: 'Не удалось открыть чат.',
                ),
              ),
            ),
          );
        }
      },
    );
  }

  // ── Phase 4 chunk 4b: search sheet handler ──────────────────────

  bool _shouldShowSearchButton() {
    final controller = _extendedNetworkController;
    if (controller == null || !controller.isCapable) return false;
    // Search only meaningful в extended mode когда slice non-empty.
    return controller.mode == ExtendedNetworkMode.extended &&
        controller.slice != null &&
        controller.slice!.graphPersons.isNotEmpty;
  }

  Future<void> _openSearchSheet() async {
    final controller = _extendedNetworkController;
    if (controller == null) return;
    final slice = controller.slice;
    if (slice == null) return;
    await showExtendedNetworkSearchSheet(
      context,
      slice: slice,
      onPersonSelected: _handleSearchResult,
    );
  }

  void _handleSearchResult(String graphPersonId) {
    // graphPersonId = identityId per slice. Route depending on
    // foreign-ness:
    //   • foreign → fabricate FamilyPerson + open foreign sheet.
    //   • own → lookup actual FamilyPerson в _treePeople +
    //     select + recenter canvas via existing flow.
    final controller = _extendedNetworkController;
    final slice = controller?.slice;
    if (slice == null) return;
    if (slice.isForeignNode(graphPersonId)) {
      final preview = slice.graphPersons.firstWhere(
        (p) => p.id == graphPersonId,
        orElse: () => const ExtendedNetworkPerson(
          id: '',
          name: '?',
          gender: null,
          birthDate: null,
          deathDate: null,
          photoUrl: null,
          isAlive: true,
          hopDistance: 0,
        ),
      );
      // Fabricate FamilyPerson из preview — foreign sheet uses
      // только identityId/name/photoUrl/dates/isAlive (see chunk 4a).
      final fabricated = FamilyPerson(
        id: preview.id,
        treeId: '', // foreign — no specific tree from current viewer scope
        userId: null,
        identityId: preview.id,
        name: preview.name ?? '',
        gender: _genderFromString(preview.gender),
        isAlive: preview.isAlive,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      unawaited(_handleForeignNodeTap(fabricated));
      return;
    }
    // Own: find tree person by identityId (graphPersonId).
    FamilyPerson? ownPerson;
    for (final p in _treePeople) {
      if (p.identityId == graphPersonId) {
        ownPerson = p;
        break;
      }
    }
    if (ownPerson == null) return; // Defensive — slice mismatch.
    final resolved = ownPerson;
    setState(() {
      _recenterOnPersonIdAfterReload = resolved.id;
    });
    _selectTreePerson(resolved);
  }

  Gender _genderFromString(String? raw) {
    switch (raw) {
      case 'male':
        return Gender.male;
      case 'female':
        return Gender.female;
      default:
        return Gender.unknown;
    }
  }

  Future<void> _openFilterSheet() async {
    final controller = _extendedNetworkController;
    if (controller == null) return;
    // На narrow — bottom sheet; на wide layout sidebar и так persistent,
    // но кнопка всё равно открывает sheet (часть пользователей предпочитает
    // bottom sheet'ы). Не реквесь UX consistency сверх меры.
    await showExtendedNetworkFilterSheet(
      context,
      controller: controller,
      // v1 — branch options пустые (placeholder для Phase 4.1+
      // cross-branch). Текущая модель — branch === tree, и tree уже
      // выбран; chip «Все» один без content'а.
      branchOptions: const <BranchFilterOption>[],
    );
  }
}

class _ExtendedSearchButton extends StatelessWidget {
  const _ExtendedSearchButton({required this.tokens, required this.onTap});

  final RodnyaDesignTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: tokens.surfaceStrong,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: tokens.surfaceLine),
        ),
        child: Tooltip(
          message: 'Поиск в расширенной сети',
          child: Icon(
            Icons.search_rounded,
            size: 19,
            color: tokens.ink,
          ),
        ),
      ),
    );
  }
}

class _FiltersButton extends StatelessWidget {
  const _FiltersButton({required this.tokens, required this.onTap});

  final RodnyaDesignTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: tokens.surfaceStrong,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: tokens.surfaceLine),
        ),
        child: Tooltip(
          message: 'Фильтры расширенной сети',
          child: Icon(
            Icons.tune_rounded,
            size: 19,
            color: tokens.ink,
          ),
        ),
      ),
    );
  }
}

class _TreeTopbarPill extends StatelessWidget {
  const _TreeTopbarPill({
    required this.tokens,
    required this.child,
    required this.tooltip,
    required this.onTap,
  });

  final RodnyaDesignTokens tokens;
  final Widget child;
  final String tooltip;

  /// `null` означает disabled-state — пилюля всё ещё видна
  /// (приглушенный фон, серая рамка), но не реагирует на тап.
  /// Нужно для undo/redo кнопок которые всегда должны быть в
  /// топбаре, чтобы юзер видел что функциональность есть.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isEnabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: tokens.surfaceStrong.withValues(alpha: isEnabled ? 1.0 : 0.5),
        shape: RoundedRectangleBorder(
          side: BorderSide(
            color: tokens.surfaceLine.withValues(alpha: isEnabled ? 1.0 : 0.4),
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 38,
            height: 38,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet shown when the user taps the 💡 voltage-indicator
/// dot on a card. Lists each suggestion with target person + tree
/// origin + match reasons + confirm/dismiss buttons.
class _IdentitySuggestionsSheet extends StatelessWidget {
  const _IdentitySuggestionsSheet({
    required this.suggestions,
    required this.onConfirm,
    required this.onDismiss,
  });

  final List<IdentitySuggestion> suggestions;
  final Future<void> Function(IdentitySuggestion suggestion) onConfirm;
  final Future<void> Function(IdentitySuggestion suggestion) onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.tertiaryContainer.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.lightbulb_outline_rounded,
                    color: scheme.tertiary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Возможные дубликаты',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        suggestions.length == 1
                            ? 'Кажется, этот человек уже есть в одном из ваших деревьев. Связать карточки?'
                            : 'Кажется, этот человек уже есть в ${suggestions.length} ваших деревьях. Связать?',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            for (final suggestion in suggestions) ...[
              _SuggestionRow(
                suggestion: suggestion,
                onConfirm: () => onConfirm(suggestion),
                onDismiss: () => onDismiss(suggestion),
              ),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.suggestion,
    required this.onConfirm,
    required this.onDismiss,
  });

  final IdentitySuggestion suggestion;
  final Future<void> Function() onConfirm;
  final Future<void> Function() onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final reasons = suggestion.reasons.join(' · ');
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundImage: suggestion.targetPhotoUrl != null &&
                        suggestion.targetPhotoUrl!.isNotEmpty
                    ? NetworkImage(suggestion.targetPhotoUrl!)
                    : null,
                backgroundColor: scheme.surfaceContainer,
                child: suggestion.targetPhotoUrl == null
                    ? Text(
                        suggestion.targetDisplayName.isNotEmpty
                            ? suggestion.targetDisplayName[0]
                            : '?',
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      suggestion.targetDisplayName,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (suggestion.targetTreeName.isNotEmpty)
                      Text(
                        'Из «${suggestion.targetTreeName}»',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: suggestion.confidence == 'high'
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${(suggestion.score * 100).round()}%',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: suggestion.confidence == 'high'
                        ? scheme.onPrimaryContainer
                        : scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (reasons.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              reasons,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('Не он'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onConfirm,
                  icon: const Icon(Icons.link_rounded, size: 18),
                  label: const Text('Связать'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Phase 3.4 chunk 5: _IdentityConflictsSheet + _ConflictRow +
// _ConflictSide + _kIdentityConflictFieldLabels / helpers
// extracted into [`lib/widgets/identity_conflicts_sheet.dart`]
// (reusable across canvas + relative_details + relatives_screen).
// Behavior-preserving move; old test'ы tree_view_screen зелёные.

// ── Phase 4: «Кем мы приходимся?» result sheet ─────────────────────
// Header with the relationship label, then a horizontal strip of
// avatars connecting the viewer to the target person, with arrows
// between cards showing the edge direction (UP/DOWN/LATERAL).
class _BloodRelationSheet extends StatelessWidget {
  const _BloodRelationSheet({
    required this.target,
    required this.relation,
  });

  final FamilyPerson target;
  final BloodRelation relation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.account_tree_rounded,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        relation.found
                            ? 'Это ваш${_genderEnding(target.gender.name)} ${relation.label}'
                            : 'Родство не найдено',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (relation.found)
                        Text(
                          'Степень родства: ${relation.degree}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        )
                      else
                        Text(
                          'Между вами и ${target.displayName} нет общего предка в дереве. Возможно, нужно добавить пропущенного родственника.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.35,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (relation.found && relation.chain.length > 1) ...[
              const SizedBox(height: 16),
              SizedBox(
                height: 120,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: relation.chain.length * 2 - 1,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (context, index) {
                    if (index.isOdd) {
                      // Edge arrow between two avatars.
                      final edgeIndex = (index - 1) ~/ 2;
                      final edge = relation.edges.length > edgeIndex
                          ? relation.edges[edgeIndex]
                          : '';
                      return _BloodRelationArrow(edgeType: edge);
                    }
                    final personIndex = index ~/ 2;
                    final preview = relation.chain[personIndex];
                    return _BloodRelationAvatar(
                      preview: preview,
                      isSelf: personIndex == 0,
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _genderEnding(String? gender) {
    final g = (gender ?? '').toLowerCase();
    if (g == 'female') return 'а';
    return '';
  }
}

class _BloodRelationAvatar extends StatelessWidget {
  const _BloodRelationAvatar({required this.preview, required this.isSelf});

  final BloodRelationPersonPreview preview;
  final bool isSelf;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasPhoto = preview.photoUrl != null && preview.photoUrl!.isNotEmpty;
    final initial = (preview.name?.isNotEmpty == true)
        ? preview.name!.substring(0, 1).toUpperCase()
        : '?';
    return SizedBox(
      width: 90,
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              CircleAvatar(
                radius: 30,
                backgroundColor: scheme.surfaceContainerHigh,
                backgroundImage:
                    hasPhoto ? NetworkImage(preview.photoUrl!) : null,
                child: hasPhoto ? null : Text(initial),
              ),
              if (isSelf)
                Positioned(
                  bottom: -2,
                  right: -2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'Вы',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            preview.name ?? '—',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _BloodRelationArrow extends StatelessWidget {
  const _BloodRelationArrow({required this.edgeType});

  /// `parent` — walker is the parent going DOWN to a child.
  /// `child`  — walker is the child going UP to a parent.
  /// `sibling` — lateral.
  final String edgeType;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    IconData icon;
    String hint;
    switch (edgeType) {
      case 'parent':
        icon = Icons.south_rounded; // going down to descendant
        hint = 'ребёнок';
        break;
      case 'child':
        icon = Icons.north_rounded; // going up to ancestor
        hint = 'родитель';
        break;
      case 'sibling':
        icon = Icons.east_rounded; // lateral
        hint = 'брат/сестра';
        break;
      default:
        icon = Icons.east_rounded;
        hint = '';
    }
    return SizedBox(
      width: 32,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(height: 2),
          Text(
            hint,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontSize: 9,
            ),
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
