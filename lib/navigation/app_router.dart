import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../services/invitation_service.dart';
import 'app_overlay_route_module.dart';
import 'app_router_guards.dart';
import 'app_router_shared.dart';
import 'app_shell_route_module.dart';

class AuthState extends ChangeNotifier {
  AuthState(this._authService) {
    _subscription = _authService.authStateChanges.listen((_) {
      notifyListeners();
    });
  }

  final AuthServiceInterface _authService;
  late final StreamSubscription<String?> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

class AppRouter {
  AppRouter({
    AuthServiceInterface? authService,
    InvitationService? invitationService,
  })  : _authService = authService ?? GetIt.I<AuthServiceInterface>(),
        _guards = AppRouterGuards(
          authService: authService ?? GetIt.I<AuthServiceInterface>(),
          invitationService: invitationService ?? GetIt.I<InvitationService>(),
        ),
        _shellRoutes = const AppShellRouteModule(),
        _overlayRoutes = AppOverlayRouteModule(
          authService: authService ?? GetIt.I<AuthServiceInterface>(),
        ) {
    authState = AuthState(_authService);
  }

  final AuthServiceInterface _authService;
  final AppRouterGuards _guards;
  final AppShellRouteModule _shellRoutes;
  final AppOverlayRouteModule _overlayRoutes;
  late final AuthState authState;

  static String buildLoginRedirectTarget(GoRouterState state) =>
      AppRouterGuards.buildLoginRedirectTarget(state);

  static String? restoreDeferredLoginTarget(GoRouterState state) =>
      AppRouterGuards.restoreDeferredLoginTarget(state);

  static bool isAuthEntryPage(String matchedLocation) =>
      AppRouterGuards.isAuthEntryPage(matchedLocation);

  static bool isPublicInfoPage(String matchedLocation) =>
      AppRouterGuards.isPublicInfoPage(matchedLocation);

  static bool allowsAnonymousAccess(String matchedLocation) =>
      AppRouterGuards.allowsAnonymousAccess(matchedLocation);

  static bool hasTelegramAuthPayload(Uri uri) =>
      AppRouterGuards.hasTelegramAuthPayload(uri);

  static bool hasVkAuthPayload(Uri uri) =>
      AppRouterGuards.hasVkAuthPayload(uri);

  static bool hasSocialAuthPayload(Uri uri) =>
      AppRouterGuards.hasSocialAuthPayload(uri);

  static String? resolveFamilyViewRedirect({required Uri uri}) =>
      AppRouterGuards.resolveFamilyViewRedirect(uri: uri);

  static String? resolveRelativesRootRedirect({required Uri uri}) =>
      AppRouterGuards.resolveRelativesRootRedirect(uri: uri);

  static String familyTreeViewRedirect({
    required String treeId,
    String? treeName,
  }) =>
      AppRouterGuards.familyTreeViewRedirect(
        treeId: treeId,
        treeName: treeName,
      );

  late final GoRouter router = GoRouter(
    navigatorKey: rootNavigatorKey,
    debugLogDiagnostics: kDebugMode,
    initialLocation: '/',
    refreshListenable: authState,
    redirect: _guards.redirect,
    routes: <RouteBase>[
      // Легаси /relatives живёт на верхнем уровне и редиректит во вкладку
      // «Родные». Держим его ПЕРЕД StatefulShellRoute: иначе go_router
      // может удержать текущую ветку шелла, когда легаси hash-URL вводят
      // после in-shell роута — URL уже /relatives, а на экране старая ветка.
      ..._shellRoutes.buildLegacyFamilyRedirectRoutes(),
      _shellRoutes.build(),
      ..._overlayRoutes.build(),
    ],
    errorPageBuilder: _overlayRoutes.buildErrorPage,
  );
}
