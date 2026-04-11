import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:lineage/models/family_tree.dart';
import 'package:lineage/navigation/app_router.dart';
import 'package:lineage/providers/tree_provider.dart';
import 'package:lineage/services/local_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeLocalStorageService implements LocalStorageService {
  final Map<String, FamilyTree> _treesById;

  _FakeLocalStorageService(List<FamilyTree> trees)
      : _treesById = {for (final tree in trees) tree.id: tree};

  @override
  Future<List<FamilyTree>> getAllTrees() async => _treesById.values.toList();

  @override
  Future<FamilyTree?> getTree(String treeId) async => _treesById[treeId];

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
    getIt.registerSingleton<LocalStorageService>(
      _FakeLocalStorageService([
        _buildTree(id: 'tree-1', name: 'Первое дерево'),
        _buildTree(id: 'tree-2', name: 'Второе дерево'),
      ]),
    );
  });

  tearDown(() async {
    await getIt.reset();
  });

  test('разрешает принудительно открыть selector через /tree?selector=1',
      () async {
    final provider = TreeProvider();
    await provider.selectTree('tree-1', 'Первое дерево');

    final redirect = AppRouter.resolveTreeRootRedirect(
      uri: Uri.parse('/tree?selector=1'),
      treeProvider: provider,
    );

    expect(redirect, isNull);
  });

  test('не перебивает явное открытие /tree/view/:treeId старым выбором',
      () async {
    final provider = TreeProvider();
    await provider.selectTree('tree-1', 'Первое дерево');

    final redirect = AppRouter.resolveTreeRootRedirect(
      uri: Uri.parse(
          '/tree/view/tree-2?name=%D0%92%D1%82%D0%BE%D1%80%D0%BE%D0%B5'),
      treeProvider: provider,
    );

    expect(redirect, isNull);
  });

  test('редиректит /tree на выбранное дерево, если оно уже есть', () async {
    final provider = TreeProvider();
    await provider.selectTree('tree-2', 'Второе дерево');

    final redirect = AppRouter.resolveTreeRootRedirect(
      uri: Uri.parse('/tree'),
      treeProvider: provider,
    );

    expect(redirect,
        '/tree/view/tree-2?name=%D0%92%D1%82%D0%BE%D1%80%D0%BE%D0%B5%20%D0%B4%D0%B5%D1%80%D0%B5%D0%B2%D0%BE');
  });

  test(
      'сохраняет deep link при переходе на login и восстанавливает его после входа',
      () {
    final loginRedirect = AppRouter.buildLoginRedirectTarget(
      _FakeGoRouterState(Uri.parse('/chats?tab=unread')),
    );

    expect(loginRedirect, '/login?from=%2Fchats%3Ftab%3Dunread');

    final restored = AppRouter.restoreDeferredLoginTarget(
      _FakeGoRouterState(Uri.parse('/login?from=%2Fchats%3Ftab%3Dunread')),
    );

    expect(restored, '/chats?tab=unread');
  });
}

class _FakeGoRouterState implements GoRouterState {
  _FakeGoRouterState(this._uri);

  final Uri _uri;

  @override
  Uri get uri => _uri;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
