import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:lineage/backend/interfaces/family_tree_service_interface.dart';
import 'package:lineage/screens/family_tree/create_tree_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
  String? createdName;
  String? createdDescription;
  bool? createdIsPrivate;

  @override
  Future<String> createTree({
    required String name,
    String description = '',
    bool isPrivate = true,
  }) async {
    createdName = name;
    createdDescription = description;
    createdIsPrivate = isPrivate;
    return 'tree-99';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

  testWidgets('CreateTreeScreen держит форму короткой и открывает новое дерево',
      (tester) async {
    final familyTreeService = _FakeFamilyTreeService();
    getIt.registerSingleton<FamilyTreeServiceInterface>(familyTreeService);

    final router = GoRouter(
      initialLocation: '/trees/create',
      routes: [
        GoRoute(
          path: '/trees/create',
          builder: (context, state) => const CreateTreeScreen(),
        ),
        GoRoute(
          path: '/tree/view/:treeId',
          builder: (context, state) => Scaffold(
            body: Center(
              child: Text(
                'opened ${state.pathParameters['treeId']} ${state.uri.queryParameters['name']}',
              ),
            ),
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('Новое дерево'), findsOneWidget);
    expect(find.text('С чего начнём?'), findsOneWidget);
    expect(find.text('Создать и открыть'), findsOneWidget);
    expect(
      find.text('Добавьте информацию о вашем семейном дереве'),
      findsNothing,
    );

    await tester.enterText(
      find.byType(TextFormField).first,
      'Семья Смирновых',
    );
    await tester.tap(find.text('Создать и открыть'));
    await tester.pumpAndSettle();

    expect(familyTreeService.createdName, 'Семья Смирновых');
    expect(familyTreeService.createdDescription, '');
    expect(familyTreeService.createdIsPrivate, isTrue);
    expect(
      find.text('opened tree-99 Семья Смирновых'),
      findsOneWidget,
    );
  });
}
