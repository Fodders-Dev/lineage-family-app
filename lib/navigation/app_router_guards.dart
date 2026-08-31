import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../services/invitation_service.dart';
import '../services/semya_invitation_deep_link_service.dart';

class AppRouterGuards {
  AppRouterGuards({
    required AuthServiceInterface authService,
    required InvitationService invitationService,
  })  : _authService = authService,
        _invitationService = invitationService;

  final AuthServiceInterface _authService;
  final InvitationService _invitationService;

  static const Set<String> authEntryPages = <String>{
    '/login',
    '/password_reset',
    // Deep-link landing page from password-reset emails. The user
    // is by definition not authenticated when they tap the link
    // — we MUST let them through without redirecting to /login,
    // otherwise the token in the query string would get dropped
    // on the redirect.
    '/reset-password',
  };

  static const Set<String> publicInfoPages = <String>{
    '/privacy',
    '/terms',
    '/support',
    '/account-deletion',
  };

  static String buildLoginRedirectTarget(GoRouterState state) {
    final location = state.uri.toString();
    return '/login?from=${Uri.encodeComponent(location)}';
  }

  static String? restoreDeferredLoginTarget(GoRouterState state) {
    final from = state.uri.queryParameters['from'];
    if (from == null || from.isEmpty) {
      return null;
    }

    final restored = Uri.decodeComponent(from);
    if (restored.isEmpty || restored == '/login') {
      return null;
    }
    return restored;
  }

  static bool isAuthEntryPage(String matchedLocation) =>
      authEntryPages.contains(matchedLocation);

  static bool isPublicInfoPage(String matchedLocation) =>
      publicInfoPages.contains(matchedLocation);

  static bool allowsAnonymousAccess(String matchedLocation) =>
      isAuthEntryPage(matchedLocation) || isPublicInfoPage(matchedLocation);

  static bool hasTelegramAuthPayload(Uri uri) =>
      uri.queryParameters.containsKey('telegramAuthCode') ||
      uri.queryParameters.containsKey('telegramAuthError');

  static bool hasVkAuthPayload(Uri uri) =>
      uri.queryParameters.containsKey('vkAuthCode') ||
      uri.queryParameters.containsKey('vkAuthError');

  static bool hasSocialAuthPayload(Uri uri) =>
      hasTelegramAuthPayload(uri) || hasVkAuthPayload(uri);

  /// Дерево — ядро продукта и снова отдельная вкладка (по центру бара),
  /// «Родные» — соседняя вкладка со списком людей. У каждой свой адрес:
  /// переключение — это переключение вкладки, не режима внутри экрана.
  static const String familyListLocation = '/family';
  static const String familyTreeLocation = '/tree';

  /// Gated redirect for the legacy `/relatives` root → «Семья» Список.
  /// Only the bare root folds in; the add/edit/find/requests/
  /// send_request/chat sub-routes keep rendering their own pushed pages.
  static String? resolveRelativesRootRedirect({required Uri uri}) {
    if (uri.path != '/relatives') {
      return null;
    }
    return familyListLocation;
  }

  /// Легаси-ссылки на слитую вкладку: `/family?view=tree` жил ~3 месяца
  /// (пуши, инвайты, чужие скриншоты) — уводим на вкладку «Дерево».
  /// Голый `/family` — это «Родные», редиректить нечего.
  static String? resolveFamilyViewRedirect({required Uri uri}) {
    if (uri.path != '/family') {
      return null;
    }
    if (uri.queryParameters['view'] != 'tree') {
      return null;
    }
    final params = <String>[];
    final treeId = uri.queryParameters['tree'];
    final treeName = uri.queryParameters['name'];
    if (treeId != null && treeId.isNotEmpty) {
      params.add('tree=${Uri.encodeQueryComponent(treeId)}');
    }
    if (treeName != null && treeName.isNotEmpty) {
      params.add('name=${Uri.encodeQueryComponent(treeName)}');
    }
    return params.isEmpty
        ? familyTreeLocation
        : '$familyTreeLocation?${params.join('&')}';
  }

  /// `/tree/view/:id` — deep-link из пушей и приглашений: открыть вкладку
  /// «Дерево» именно на этом дереве, а не на последнем выбранном.
  static String familyTreeViewRedirect({
    required String treeId,
    String? treeName,
  }) {
    final params = <String>[];
    if (treeId.isNotEmpty) {
      params.add('tree=${Uri.encodeQueryComponent(treeId)}');
    }
    if (treeName != null && treeName.isNotEmpty) {
      params.add('name=${Uri.encodeQueryComponent(treeName)}');
    }
    return params.isEmpty
        ? familyTreeLocation
        : '$familyTreeLocation?${params.join('&')}';
  }

  Future<String?> redirect(BuildContext context, GoRouterState state) async {
    final isLoggedIn = _authService.currentUserId != null;
    final isAuthEntryRoute = isAuthEntryPage(state.matchedLocation);
    final completingProfile = state.matchedLocation == '/complete_profile';
    // Phase 6 chunk 4a bypass: /setup wizard собирает profile fields сам
    // (displayName / gender / birthDate через wizard's profile step).
    // Без этого exception router guard fires _ensureCompletedProfile →
    // redirects fresh user к /complete_profile, обнуляя wizard entirely.
    final setupWizard = state.matchedLocation == '/setup';
    final invitePage = state.matchedLocation == '/invite';
    // Ship FE3b (2026-05-28): семя invitation token deep link.
    // Distinct from legacy /invite (treeId+personId query params)
    // — token-based capability lives на /invite/:token path. Guard
    // persists token to disk before potential login redirect so
    // OAuth bounces / cold starts don't lose it (mirror legacy
    // InvitationService pattern).
    final semyaInvitationTokenPage =
        state.matchedLocation.startsWith('/invite/') &&
            state.matchedLocation.length > '/invite/'.length;
    final publicTreePage = state.matchedLocation.startsWith('/public/tree/');
    // Ship FE6a (2026-05-26): browse-token capability route — token
    // самo is auth (backend GET /v1/browse/:token works anonymous).
    // Mirror /public/tree/* exemption pattern.
    final browseTokenPage = state.matchedLocation.startsWith('/browse/');
    final e2eIdlePage = state.matchedLocation == '/__e2e__/idle';

    if (e2eIdlePage && BackendRuntimeConfig.current.enableE2e) {
      return null;
    }

    if (invitePage) {
      return _handleInviteRoute(isLoggedIn: isLoggedIn, state: state);
    }

    if (semyaInvitationTokenPage) {
      return _handleSemyaInvitationTokenRoute(
        isLoggedIn: isLoggedIn,
        state: state,
      );
    }

    if (publicTreePage || browseTokenPage) {
      return null;
    }

    if (!isLoggedIn &&
        !allowsAnonymousAccess(state.matchedLocation) &&
        !completingProfile) {
      return buildLoginRedirectTarget(state);
    }

    if (isLoggedIn && isAuthEntryRoute) {
      if (hasSocialAuthPayload(state.uri)) {
        return null;
      }
      final deferredTarget = restoreDeferredLoginTarget(state);
      return deferredTarget ?? '/';
    }

    if (isLoggedIn && !completingProfile && !setupWizard) {
      final profileRedirect = await _ensureCompletedProfile(state);
      if (profileRedirect != null) {
        return profileRedirect;
      }
    }
    return null;
  }

  Future<String?> _handleInviteRoute({
    required bool isLoggedIn,
    required GoRouterState state,
  }) async {
    final treeId = state.uri.queryParameters['treeId'];
    final personId = state.uri.queryParameters['personId'];
    if (treeId != null &&
        treeId.isNotEmpty &&
        personId != null &&
        personId.isNotEmpty) {
      _invitationService.setPendingInvitation(
        treeId: treeId,
        personId: personId,
      );
      if (isLoggedIn) {
        await _authService.processPendingInvitation();
        return '/';
      }
      return '/login';
    }
    return isLoggedIn ? '/' : '/login';
  }

  /// Ship FE3b (2026-05-28): handle deep link `/invite/:token` route
  /// guard. Persists token к disk perед any redirect chain (covers
  /// OAuth round-trips + cold starts). Authed user passes through к
  /// SemyaInvitationAcceptScreen which invokes acceptInvitation.
  /// Unauthed user redirected к /login?from=/invite/{token} —
  /// after login, router re-resolves same path с authed context.
  String? _handleSemyaInvitationTokenRoute({
    required bool isLoggedIn,
    required GoRouterState state,
  }) {
    final token = state.pathParameters['token']?.trim() ?? '';
    if (token.isEmpty) {
      return isLoggedIn ? '/' : '/login';
    }
    SemyaInvitationDeepLinkService().setPendingToken(token);
    if (!isLoggedIn) {
      return buildLoginRedirectTarget(state);
    }
    return null;
  }

  Future<String?> _ensureCompletedProfile(GoRouterState state) async {
    try {
      final profileStatus = await _authService.checkProfileCompleteness();
      if (_authService.currentUserId == null) {
        return buildLoginRedirectTarget(state);
      }
      final isComplete = profileStatus['isComplete'] == true;
      if (!isComplete) {
        return '/complete_profile?requiredFields=${Uri.encodeComponent(profileStatus.toString())}';
      }
    } catch (error) {
      debugPrint('Error checking profile completeness during redirect: $error');
      final normalizedError = error.toString().toLowerCase();
      final looksLikeSessionIssue = _authService.currentUserId == null ||
          normalizedError.contains('null check operator') ||
          normalizedError.contains('session') ||
          normalizedError.contains('сесс') ||
          normalizedError.contains('401') ||
          normalizedError.contains('403');
      if (looksLikeSessionIssue) {
        return buildLoginRedirectTarget(state);
      }
    }
    return null;
  }
}
