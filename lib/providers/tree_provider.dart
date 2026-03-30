import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:get_it/get_it.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../services/local_storage_service.dart';
import '../models/family_tree.dart';

class TreeProvider with ChangeNotifier {
  String? _selectedTreeId;
  String? _selectedTreeName;

  final LocalStorageService _localStorageService =
      GetIt.I<LocalStorageService>();

  static const _treeIdKey = 'selected_tree_id';
  static const _treeNameKey = 'selected_tree_name';

  String? get selectedTreeId => _selectedTreeId;
  String? get selectedTreeName => _selectedTreeName;
  FamilyTreeServiceInterface? get _familyTreeService =>
      GetIt.I.isRegistered<FamilyTreeServiceInterface>()
          ? GetIt.I<FamilyTreeServiceInterface>()
          : null;

  Future<void> loadInitialTree() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final loadedId = prefs.getString(_treeIdKey);

      if (loadedId != null) {
        debugPrint(
          'TreeProvider: Found tree ID $loadedId in SharedPreferences. Verifying...',
        );
        final FamilyTree? existingTree = await _localStorageService.getTree(
          loadedId,
        );
        if (existingTree != null) {
          _selectedTreeId = loadedId;
          _selectedTreeName = existingTree.name;
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
          await prefs.remove(_treeIdKey);
          await prefs.remove(_treeNameKey);
        }
      } else {
        debugPrint('TreeProvider: No tree selected in SharedPreferences.');
      }

      await selectDefaultTreeIfNeeded();
    } catch (e) {
      debugPrint(
        'TreeProvider: Error loading initial tree from SharedPreferences: $e',
      );
    }
  }

  Future<void> selectTree(String? treeId, String? treeName) async {
    if (_selectedTreeId != treeId || _selectedTreeName != treeName) {
      _selectedTreeId = treeId;
      _selectedTreeName = treeName;
      debugPrint(
        'TreeProvider: Selected tree ID: $_selectedTreeId, Name: $_selectedTreeName',
      );
      notifyListeners();
      try {
        final prefs = await SharedPreferences.getInstance();
        if (treeId == null) {
          await prefs.remove(_treeIdKey);
          await prefs.remove(_treeNameKey);
          debugPrint(
              'TreeProvider: Cleared tree selection in SharedPreferences');
        } else {
          await prefs.setString(_treeIdKey, treeId);
          if (treeName != null) {
            await prefs.setString(_treeNameKey, treeName);
          } else {
            await prefs.remove(_treeNameKey);
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

  Future<void> selectDefaultTreeIfNeeded() async {
    if (_selectedTreeId == null) {
      debugPrint(
        'TreeProvider: No tree currently selected. Checking cache for defaults...',
      );
      try {
        var availableTrees = await _localStorageService.getAllTrees();
        final familyTreeService = _familyTreeService;
        if (availableTrees.isEmpty && familyTreeService != null) {
          try {
            availableTrees = await familyTreeService.getUserTrees();
          } catch (e) {
            debugPrint('TreeProvider: Error loading trees from backend: $e');
          }
        }

        if (availableTrees.isNotEmpty) {
          final defaultTree = availableTrees.first;
          debugPrint(
            'TreeProvider: Found ${availableTrees.length} trees in cache. Selecting first one as default: ${defaultTree.id}',
          );
          await selectTree(defaultTree.id, defaultTree.name);
        } else {
          debugPrint('TreeProvider: No available trees found in cache.');
        }
      } catch (e) {
        debugPrint('TreeProvider: Error selecting default tree: $e');
      }
    }
  }
}
