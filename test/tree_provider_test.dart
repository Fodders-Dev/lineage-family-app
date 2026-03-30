import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:lineage/backend/interfaces/family_tree_service_interface.dart';
import 'package:lineage/models/family_tree.dart';
import 'package:lineage/providers/tree_provider.dart';
import 'package:lineage/services/local_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeLocalStorageService implements LocalStorageService {
  _FakeLocalStorageService(List<FamilyTree> trees)
      : _treesById = {for (final tree in trees) tree.id: tree};

  final Map<String, FamilyTree> _treesById;

  @override
  Future<List<FamilyTree>> getAllTrees() async => _treesById.values.toList();

  @override
  Future<FamilyTree?> getTree(String treeId) async => _treesById[treeId];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
  _FakeFamilyTreeService(this._trees);

  final List<FamilyTree> _trees;

  @override
  Future<List<FamilyTree>> getUserTrees() async => _trees;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FamilyTree _buildTree({
  required String id,
  required String name,
}) {
  final now = DateTime(2024, 1, 1);
  return FamilyTree(
    id: id,
    name: name,
    description: '',
    creatorId: 'user-1',
    memberIds: const ['user-1'],
    createdAt: now,
    updatedAt: now,
    isPrivate: true,
    members: const ['user-1'],
  );
}

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await getIt.reset();
  });

  tearDown(() async {
    await getIt.reset();
  });

  test('подхватывает первое дерево с backend, если локальный выбор отсутствует',
      () async {
    final fallbackTree = _buildTree(id: 'tree-1', name: 'Дерево из backend');
    getIt.registerSingleton<LocalStorageService>(
      _FakeLocalStorageService(const []),
    );
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService([fallbackTree]),
    );

    final provider = TreeProvider();
    await provider.loadInitialTree();

    expect(provider.selectedTreeId, fallbackTree.id);
    expect(provider.selectedTreeName, fallbackTree.name);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('selected_tree_id'), fallbackTree.id);
    expect(prefs.getString('selected_tree_name'), fallbackTree.name);
  });

  test('если сохранённое дерево устарело, откатывается на первое доступное',
      () async {
    SharedPreferences.setMockInitialValues({
      'selected_tree_id': 'missing-tree',
      'selected_tree_name': 'Старое дерево',
    });

    final fallbackTree = _buildTree(id: 'tree-2', name: 'Актуальное дерево');
    getIt.registerSingleton<LocalStorageService>(
      _FakeLocalStorageService(const []),
    );
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService([fallbackTree]),
    );

    final provider = TreeProvider();
    await provider.loadInitialTree();

    expect(provider.selectedTreeId, fallbackTree.id);
    expect(provider.selectedTreeName, fallbackTree.name);
  });
}
