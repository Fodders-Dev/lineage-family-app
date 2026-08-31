import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/backend/interfaces/kinship_check_capable_family_tree_service.dart';
import 'package:rodnya/backend/interfaces/profile_service_interface.dart';
import 'package:rodnya/backend/models/kinship_check.dart';
import 'package:rodnya/models/user_profile.dart';
import 'package:rodnya/screens/discover_relatives/discover_relatives_screen.dart';

class _FakeKinshipService
    implements
        FamilyTreeServiceInterface,
        KinshipCheckCapableFamilyTreeService {
  @override
  Future<List<KinshipCheck>> listIssuedKinshipChecks({
    KinshipCheckStatus? status,
  }) async =>
      const [];

  @override
  Future<List<KinshipCheck>> listReceivedKinshipChecks({
    KinshipCheckStatus? status,
  }) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProfileService implements ProfileServiceInterface {
  @override
  Future<List<UserProfile>> searchUsers(String query, {int limit = 10}) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

GoRouter _router() => GoRouter(
      initialLocation: '/discover',
      routes: [
        GoRoute(
          path: '/discover',
          builder: (context, state) => const DiscoverRelativesScreen(),
        ),
        GoRoute(
          // «Родные» — своя вкладка без ?view=: режимов внутри больше нет.
          path: '/family',
          builder: (context, state) => const Scaffold(
            body: Text('family-tab'),
          ),
        ),
      ],
    );

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    await getIt.reset();
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeKinshipService(),
    );
    getIt.registerSingleton<ProfileServiceInterface>(
      _FakeProfileService(),
    );
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets('объясняет поиск и ведёт к списку семьи', (tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: _router()));
    await tester.pumpAndSettle();

    expect(find.text('Как это работает'), findsOneWidget);
    expect(find.text('Открыть семью'), findsOneWidget);

    await tester.tap(find.text('Открыть семью'));
    await tester.pumpAndSettle();

    expect(find.text('family-tab'), findsOneWidget);
  });

  testWidgets('пустой поиск предлагает добавить человека в дерево',
      (tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: _router()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Несуществующий человек');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('Добавить человека в дерево'), findsOneWidget);
  });
}
