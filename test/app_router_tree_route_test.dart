import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rodnya/navigation/app_router.dart';
import 'package:rodnya/navigation/app_router_shared.dart';
import 'package:rodnya/navigation/app_shell_route_module.dart';

void main() {
  // ── the merged route tree is structurally valid ──

  test('production shell + legacy redirect routes build a valid GoRouter', () {
    // Constructing a GoRouter runs go_router's RouteConfiguration
    // validation over the whole tree (unique paths, every route has a
    // builder/pageBuilder or redirect, parentNavigatorKey resolves). Это
    // прод-проводка: ветки StatefulShellRoute (включая вернувшуюся вкладку
    // «Дерево») плюс легаси-редиректы — дойти до expect значит, что
    // таблица маршрутов не сломалась.
    const shell = AppShellRouteModule();
    final router = GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: '/family',
      routes: <RouteBase>[
        ...shell.buildLegacyFamilyRedirectRoutes(),
        shell.build(),
      ],
    );
    addTearDown(router.dispose);

    final routes = router.configuration.routes;
    final legacyRelativesIndex = routes
        .indexWhere((route) => route is GoRoute && route.path == '/relatives');
    final shellIndex =
        routes.indexWhere((route) => route is StatefulShellRoute);

    expect(legacyRelativesIndex, isNonNegative);
    expect(shellIndex, isNonNegative);
    expect(
      legacyRelativesIndex,
      lessThan(shellIndex),
      reason:
          'legacy /relatives must redirect before the shell can retain the previous branch',
    );

    final topLevelPaths = router.configuration.routes
        .whereType<GoRoute>()
        .map((route) => route.path)
        .toList();
    // Селектор деревьев переехал на /trees: сам /tree теперь ветка-вкладка.
    expect(topLevelPaths, containsAll(<String>['/relatives', '/trees']));
    expect(
      topLevelPaths,
      isNot(contains('/tree')),
      reason: 'верхнеуровневый /tree перехватывал бы вкладку «Дерево»',
    );
  });

  test('вкладка «Дерево» — отдельная ветка шелла, по центру бара', () {
    const shell = AppShellRouteModule();
    final shellRoute = shell.build() as StatefulShellRoute;
    final branchPaths = shellRoute.branches
        .map((branch) => (branch.routes.first as GoRoute).path)
        .toList();

    expect(
      branchPaths,
      <String>['/', '/family', '/tree', '/chats', '/profile'],
      reason: 'порядок веток = порядок вкладок; дерево третье из пяти = центр',
    );
    expect(
      branchPaths.indexOf('/tree'),
      (branchPaths.length - 1) ~/ 2,
      reason: 'ядро продукта стоит ровно посередине бара',
    );
  });

  // ── дерево вернулось во вкладку; легаси-ссылки ведут туда же ──

  test('легаси /family?view=tree уводит на вкладку «Дерево»', () {
    expect(
      AppRouter.resolveFamilyViewRedirect(uri: Uri.parse('/family?view=tree')),
      '/tree',
    );
  });

  test('легаси /family?view=tree сохраняет дерево и имя', () {
    expect(
      AppRouter.resolveFamilyViewRedirect(
        uri: Uri.parse('/family?view=tree&tree=tree-2&name=%D0%94%D0%BE%D0%BC'),
      ),
      '/tree?tree=tree-2&name=${Uri.encodeQueryComponent('Дом')}',
    );
  });

  test('голый /family — это «Родные», редиректа нет', () {
    expect(
      AppRouter.resolveFamilyViewRedirect(uri: Uri.parse('/family')),
      isNull,
    );
    expect(
      AppRouter.resolveFamilyViewRedirect(uri: Uri.parse('/family?view=list')),
      isNull,
    );
  });

  test('/tree/view/:id уносит дерево и имя на вкладку «Дерево»', () {
    expect(
      AppRouter.familyTreeViewRedirect(
        treeId: 'tree-2',
        treeName: 'Второе дерево',
      ),
      '/tree?tree=tree-2'
      '&name=${Uri.encodeQueryComponent('Второе дерево')}',
    );
  });

  test('/tree/view/:id без имени уносит только дерево', () {
    expect(
      AppRouter.familyTreeViewRedirect(treeId: 'tree-2'),
      '/tree?tree=tree-2',
    );
  });

  test('голый /relatives редиректит на вкладку «Родные»', () {
    expect(
      AppRouter.resolveRelativesRootRedirect(uri: Uri.parse('/relatives')),
      '/family',
    );
  });

  test('саб-роуты /relatives сохраняют свои страницы (нет редиректа)', () {
    expect(
      AppRouter.resolveRelativesRootRedirect(
        uri: Uri.parse('/relatives/add/tree-1'),
      ),
      isNull,
    );
    expect(
      AppRouter.resolveRelativesRootRedirect(
        uri: Uri.parse('/relatives/find/tree-1?profileCode=abc'),
      ),
      isNull,
    );
  });

  // ── auth / deep-link guards (unchanged) ──

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

  test('публичные legal/support маршруты доступны без авторизации', () {
    expect(AppRouter.allowsAnonymousAccess('/privacy'), isTrue);
    expect(AppRouter.allowsAnonymousAccess('/terms'), isTrue);
    expect(AppRouter.allowsAnonymousAccess('/support'), isTrue);
    expect(AppRouter.allowsAnonymousAccess('/account-deletion'), isTrue);
  });

  test('legal/support маршруты не считаются auth entry страницами', () {
    expect(AppRouter.isAuthEntryPage('/privacy'), isFalse);
    expect(AppRouter.isAuthEntryPage('/terms'), isFalse);
    expect(AppRouter.isAuthEntryPage('/support'), isFalse);
    expect(AppRouter.isAuthEntryPage('/account-deletion'), isFalse);
    expect(AppRouter.isAuthEntryPage('/login'), isTrue);
    expect(AppRouter.isAuthEntryPage('/password_reset'), isTrue);
  });

  test('telegram auth callback query не должен теряться на /login', () {
    expect(
      AppRouter.hasTelegramAuthPayload(
        Uri.parse('/login?telegramAuthCode=abc123'),
      ),
      isTrue,
    );
    expect(
      AppRouter.hasTelegramAuthPayload(
        Uri.parse('/login?telegramAuthError=failed'),
      ),
      isTrue,
    );
    expect(
      AppRouter.hasTelegramAuthPayload(
        Uri.parse('/login?from=%2Fprofile'),
      ),
      isFalse,
    );
  });

  test('vk auth callback query не должен теряться на /login', () {
    expect(
      AppRouter.hasVkAuthPayload(
        Uri.parse('/login?vkAuthCode=abc123'),
      ),
      isTrue,
    );
    expect(
      AppRouter.hasVkAuthPayload(
        Uri.parse('/login?vkAuthError=failed'),
      ),
      isTrue,
    );
    expect(
      AppRouter.hasSocialAuthPayload(
        Uri.parse('/login?vkAuthCode=abc123'),
      ),
      isTrue,
    );
    expect(
      AppRouter.hasSocialAuthPayload(
        Uri.parse('/login?from=%2Fprofile'),
      ),
      isFalse,
    );
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
