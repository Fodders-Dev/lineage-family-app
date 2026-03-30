import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:lineage/backend/interfaces/auth_service_interface.dart';
import 'package:lineage/backend/interfaces/family_tree_service_interface.dart';
import 'package:lineage/models/family_tree.dart';
import 'package:lineage/screens/public_tree_entry_screen.dart';
import 'package:lineage/services/public_tree_service.dart';

class _FakeAuthService implements AuthServiceInterface {
  _FakeAuthService(this._currentUserId);

  final String? _currentUserId;

  @override
  String? get currentUserId => _currentUserId;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
  _FakeFamilyTreeService(this.trees);

  final List<FamilyTree> trees;

  @override
  Future<List<FamilyTree>> getUserTrees() async => trees;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePublicTreeService implements PublicTreeServiceInterface {
  _FakePublicTreeService(this.preview);

  final PublicTreePreview? preview;

  @override
  Future<PublicTreePreview?> getPublicTreePreview(String publicTreeId) async =>
      preview;

  @override
  Future<PublicTreeSnapshot?> getPublicTreeSnapshot(
          String publicTreeId) async =>
      null;
}

void main() {
  final getIt = GetIt.instance;

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets('guest sees public preview and guest-view CTA', (tester) async {
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService(null));
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService(const <FamilyTree>[]),
    );

    final preview = PublicTreePreview(
      tree: FamilyTree(
        id: 'tree-1',
        name: 'Дом Романовых',
        description: 'Историческое древо',
        creatorId: 'user-1',
        memberIds: const ['user-1'],
        createdAt: DateTime(2024, 1, 1),
        updatedAt: DateTime(2024, 1, 1),
        isPrivate: false,
        members: const ['user-1'],
        publicSlug: 'romanovs',
        isCertified: true,
        certificationNote: 'Проверено редакцией',
      ),
      peopleCount: 12,
      relationsCount: 18,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PublicTreeEntryScreen(
          publicTreeId: 'romanovs',
          publicTreeService: _FakePublicTreeService(preview),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Дом Романовых'), findsOneWidget);
    expect(find.text('Проверено редакцией'), findsOneWidget);
    expect(find.text('Смотреть как гость'), findsOneWidget);
    expect(find.text('Войти в аккаунт'), findsOneWidget);
    expect(find.text('12 человек'), findsOneWidget);
  });

  testWidgets('logged in member sees member-tree CTA', (tester) async {
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService('user-1'));
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService(
        [
          FamilyTree(
            id: 'tree-1',
            name: 'Дом Романовых',
            description: 'Историческое дерево',
            creatorId: 'user-1',
            memberIds: const ['user-1'],
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            isPrivate: false,
            members: const ['user-1'],
            publicSlug: 'romanovs',
            isCertified: true,
            certificationNote: 'Проверено редакцией',
          ),
        ],
      ),
    );

    final preview = PublicTreePreview(
      tree: FamilyTree(
        id: 'tree-1',
        name: 'Дом Романовых',
        description: 'Историческое дерево',
        creatorId: 'user-1',
        memberIds: const ['user-1'],
        createdAt: DateTime(2024, 1, 1),
        updatedAt: DateTime(2024, 1, 1),
        isPrivate: false,
        members: const ['user-1'],
        publicSlug: 'romanovs',
        isCertified: true,
        certificationNote: 'Проверено редакцией',
      ),
      peopleCount: 12,
      relationsCount: 18,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PublicTreeEntryScreen(
          publicTreeId: 'romanovs',
          publicTreeService: _FakePublicTreeService(preview),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Гостевой просмотр'), findsOneWidget);
    expect(find.text('Открыть как участник'), findsOneWidget);
  });
}
