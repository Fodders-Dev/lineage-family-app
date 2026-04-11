import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:get_it/get_it.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../services/local_storage_service.dart';
import '../models/family_tree.dart';

class TreeProvider with ChangeNotifier {
  String? _selectedTreeId;
  String? _selectedTreeName;
  TreeKind? _selectedTreeKind;

  final LocalStorageService _localStorageService =
      GetIt.I<LocalStorageService>();

  static const _treeIdKey = 'selected_tree_id';
  static const _treeNameKey = 'selected_tree_name';
  static const _treeKindKey = 'selected_tree_kind';

  String? get selectedTreeId => _selectedTreeId;
  String? get selectedTreeName => _selectedTreeName;
  TreeKind? get selectedTreeKind => _selectedTreeKind;
  FamilyTreeServiceInterface? get _familyTreeService =>
      GetIt.I.isRegistered<FamilyTreeServiceInterface>()
          ? GetIt.I<FamilyTreeServiceInterface>()
          : null;

  Future<FamilyTree?> _resolveTree(String treeId) async {
    final familyTreeService = _familyTreeService;
    if (familyTreeService != null) {
      try {
        final backendTrees = await familyTreeService.getUserTrees();
        for (final tree in backendTrees) {
          if (tree.id == treeId) {
            return tree;
          }
        }
      } catch (e) {
        debugPrint('TreeProvider: Error resolving tree from backend: $e');
      }
    }

    return _localStorageService.getTree(treeId);
  }

  Future<void> loadInitialTree() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final loadedId = prefs.getString(_treeIdKey);
      final familyTreeService = _familyTreeService;
      List<FamilyTree>? backendTrees;

      if (familyTreeService != null) {
        try {
          backendTrees = await familyTreeService.getUserTrees();
        } catch (e) {
          debugPrint('TreeProvider: Error loading trees from backend: $e');
        }
      }

      if (loadedId != null) {
        debugPrint(
          'TreeProvider: Found tree ID $loadedId in SharedPreferences. Verifying...',
        );
        final FamilyTree? existingTree =
            backendTrees?.cast<FamilyTree?>().firstWhere(
                      (tree) => tree?.id == loadedId,
                      orElse: () => null,
                    ) ??
                await _localStorageService.getTree(loadedId);
        if (existingTree != null) {
          _selectedTreeId = loadedId;
          _selectedTreeName = existingTree.name;
          _selectedTreeKind = existingTree.kind;
          debugPrint(
            'TreeProvider: Verified. Loaded initial tree ID: $_selectedTreeId, Name: $_selectedTreeName',
          );
          notifyListeners();
        } else {
          debugPrint(
            'TreeProvider: Tree ID $loadedId from SharedPreferences not found in cache. Clearing selection.',
          );
          _selectedTreeId = null;
          _selectedTreeName = null;
          _selectedTreeKind = treeKindFromRaw(prefs.getString(_treeKindKey));
          await prefs.remove(_treeIdKey);
          await prefs.remove(_treeNameKey);
          await prefs.remove(_treeKindKey);
        }
      } else {
        debugPrint('TreeProvider: No tree selected in SharedPreferences.');
        _selectedTreeKind = treeKindFromRaw(prefs.getString(_treeKindKey));
      }

      await selectDefaultTreeIfNeeded(preloadedTrees: backendTrees);
    } catch (e) {
      debugPrint(
        'TreeProvider: Error loading initial tree from SharedPreferences: $e',
      );
    }
  }

  Future<void> selectTree(
    String? treeId,
    String? treeName, {
    TreeKind? treeKind,
  }) async {
    final resolvedKind =
        treeId == null ? null : treeKind ?? (await _resolveTree(treeId))?.kind;

    if (_selectedTreeId != treeId ||
        _selectedTreeName != treeName ||
        _selectedTreeKind != resolvedKind) {
      _selectedTreeId = treeId;
      _selectedTreeName = treeName;
      _selectedTreeKind = resolvedKind;
      debugPrint(
        'TreeProvider: Selected tree ID: $_selectedTreeId, Name: $_selectedTreeName',
      );
      notifyListeners();
      try {
        final prefs = await SharedPreferences.getInstance();
        if (treeId == null) {
          await prefs.remove(_treeIdKey);
          await prefs.remove(_treeNameKey);
          await prefs.remove(_treeKindKey);
          debugPrint(
              'TreeProvider: Cleared tree selection in SharedPreferences');
        } else {
          await prefs.setString(_treeIdKey, treeId);
          if (treeName != null) {
            await prefs.setString(_treeNameKey, treeName);
          } else {
            await prefs.remove(_treeNameKey);
          }
          if (resolvedKind != null) {
            await prefs.setString(_treeKindKey, resolvedKind.name);
          } else {
            await prefs.remove(_treeKindKey);
          }
          debugPrint('TreeProvider: Saved tree selection to SharedPreferences');
        }
      } catch (e) {
        debugPrint(
          'TreeProvider: Error saving tree selection to SharedPreferences: $e',
        );
      }
    }
  }

  Future<void> clearSelection() async {
    await selectTree(null, null);
  }

  Future<void> selectDefaultTreeIfNeeded(
      {List<FamilyTree>? preloadedTrees}) async {
    if (_selectedTreeId == null) {
      debugPrint(
        'TreeProvider: No tree currently selected. Checking cache for defaults...',
      );
      try {
        var availableTrees = preloadedTrees ?? const <FamilyTree>[];
        final familyTreeService = _familyTreeService;
        if (availableTrees.isEmpty && familyTreeService != null) {
          try {
            availableTrees = await familyTreeService.getUserTrees();
          } catch (e) {
            debugPrint('TreeProvider: Error loading trees from backend: $e');
          }
        }
        if (availableTrees.isEmpty) {
          availableTrees = await _localStorageService.getAllTrees();
        }

        if (availableTrees.isNotEmpty) {
          final defaultTree = availableTrees.first;
          debugPrint(
            'TreeProvider: Found ${availableTrees.length} trees in cache. Selecting first one as default: ${defaultTree.id}',
          );
          await selectTree(
            defaultTree.id,
            defaultTree.name,
            treeKind: defaultTree.kind,
          );
        } else {
          debugPrint('TreeProvider: No available trees found in cache.');
        }
      } catch (e) {
        debugPrint('TreeProvider: Error selecting default tree: $e');
      }
    }
  }
}
