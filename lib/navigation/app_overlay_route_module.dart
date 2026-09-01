import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../models/call_media_mode.dart';
import '../screens/auth_screen.dart';
import '../screens/browse_tree_screen.dart';
import '../screens/complete_profile_screen.dart';
import '../screens/create_story_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/identity_review_screen.dart';
import '../screens/notifications_screen.dart';
import '../screens/discover_relatives/discover_relatives_screen.dart';
import '../screens/onboarding_screen.dart';
import '../screens/onboarding/onboarding_wizard_screen.dart';
import '../screens/password_reset_screen.dart';
import '../screens/reset_password_confirm_screen.dart';
import '../screens/privacy_policy_screen.dart';
import '../screens/public_tree_entry_screen.dart';
import '../screens/qr_login_display_screen.dart';
import '../screens/public_tree_viewer_screen.dart';
import '../screens/relative_details_screen.dart';
import '../screens/semya_invitation_accept_screen.dart';
import '../screens/send_relation_request_screen.dart';
import '../screens/story_viewer_screen.dart';
import 'app_router_shared.dart';

class AppOverlayRouteModule {
  const AppOverlayRouteModule({
    required AuthServiceInterface authService,
  }) : _authService = authService;

  final AuthServiceInterface _authService;

  List<RouteBase> build() {
    return <RouteBase>[
      GoRoute(
        path: '/notifications',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => RodnyaCustomTransitionPage(
          key: state.pageKey,
          constrainWidth: true,
          child: const NotificationsScreen(),
          transitionsBuilder: AppRouteTransitions.slide,
        ),
      ),
      GoRoute(
        path: '/identity/review',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => RodnyaCustomTransitionPage(
          key: state.pageKey,
          constrainWidth: true,
          child: const IdentityReviewScreen(),
          transitionsBuilder: AppRouteTransitions.slide,
        ),
      ),
      GoRoute(
        path: '/stories/create',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => RodnyaCustomTransitionPage(
          key: state.pageKey,
          constrainWidth: true,
          child: const CreateStoryScreen(),
          transitionsBuilder: AppRouteTransitions.slideUp,
        ),
      ),
      GoRoute(
        path: '/stories/view/:treeId/:authorId',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final treeId = state.pathParameters['treeId']?.trim() ?? '';
          final authorId = state.pathParameters['authorId']?.trim() ?? '';
          final child = treeId.isEmpty || authorId.isEmpty
              ? const StoryViewerRouteFallback()
              : StoryViewerEntryScreen(
                  treeId: treeId,
                  authorId: authorId,
                  currentUserId: _authService.currentUserId ?? '',
                );

          if (kIsWeb) {
            return MaterialPage<void>(
              key: state.pageKey,
              child: child,
            );
          }

          return RodnyaCustomTransitionPage(
            key: state.pageKey,
            child: child,
            transitionsBuilder: AppRouteTransitions.slideUp,
          );
        },
      ),
      GoRoute(
        path: '/__e2e__/idle',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => RodnyaCustomTransitionPage(
          key: state.pageKey,
          child: const E2EIdleScreen(),
          transitionsBuilder: AppRouteTransitions.fade,
        ),
      ),
      GoRoute(
        path: '/login',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final redirectAfterLogin = state.uri.queryParameters['from']?.trim();
          return RodnyaCustomTransitionPage(
            key: state.pageKey,
            child: AuthScreen(
              redirectAfterLogin:
                  redirectAfterLogin != null && redirectAfterLogin.isNotEmpty
                      ? redirectAfterLogin
                      : null,
            ),
            transitionsBuilder: AppRouteTransitions.fade,
          );
        },
      ),
      GoRoute(
        path: '/password_reset',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => RodnyaCustomTransitionPage(
          key: state.pageKey,
          child: const PasswordResetScreen(),
          transitionsBuilder: AppRouteTransitions.fade,
        ),
      ),
      // Deep-link target from password-reset emails. The link in the
      // message is `https://rodnya-tree.ru/reset-password?token=...`
      // — the host serves the Flutter web app at that path, GoRouter
      // pulls `?token=` out of `state.uri.queryParameters`, and the
      // confirm screen wires it into `confirmPasswordReset(...)`.
      GoRoute(
        path: '/reset-password',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final token = state.uri.queryParameters['token']?.trim() ?? '';
          return RodnyaCustomTransitionPage(
            key: state.pageKey,
            child: ResetPasswordConfirmScreen(token: token),
            transitionsBuilder: AppRouteTransitions.fade,
          );
        },
      ),
      GoRoute(
        path: '/onboarding',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => RodnyaCustomTransitionPage(
          key: state.pageKey,
          child: const OnboardingScreen(),
          transitionsBuilder: AppRouteTransitions.fade,
        ),
      ),
      // Phase 6 chunk 2: wizard (profile + first-relatives seed).
      // Route name `/setup` чтобы не collide с existing
      // `/onboarding` (Phase 1 welcome tour, different scope).
      GoRoute(
        path: '/setup',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => RodnyaCustomTransitionPage(
          key: state.pageKey,
          child: const OnboardingWizardScreen(),
          transitionsBuilder: AppRouteTransitions.fade,
        ),
      ),
      // Phase 6 chunk 3: «мы родственники?» discover entry. Deep-link
      // params per chunk 4b notification routing:
      //   • ?incoming=<checkId> — auto-opens bilateral-consent action
      //     sheet (target tapped «received» notification).
      //   • ?result=<checkId> — opens result step с chain (initiator
      //     tapped «confirmed» notification).
      GoRoute(
        path: '/discover/relatives',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final incoming = state.uri.queryParameters['incoming']?.trim();
          final result = state.uri.queryParameters['result']?.trim();
          return RodnyaCustomTransitionPage(
            key: state.pageKey,
            constrainWidth: true,
            child: DiscoverRelativesScreen(
              incomingCheckId:
                  incoming != null && incoming.isNotEmpty ? incoming : null,
              resultCheckId:
                  result != null && result.isNotEmpty ? result : null,
            ),
            transitionsBuilder: AppRouteTransitions.slide,
          );
        },
      ),
      GoRoute(
        path: '/complete_profile',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final queryParams = state.uri.queryParameters;
          Map<String, bool> requiredFields = <String, bool>{};
          final fieldsString = queryParams['requiredFields'];
          if (fieldsString != null) {
            try {
              final pairs =
                  fieldsString.replaceAll(RegExp(r'[{}]'), '').split(', ');
              for (final pair in pairs) {
                final parts = pair.split(': ');
                if (parts.length == 2) {
                  requiredFields[parts[0]] = parts[1] == 'true';
                }
              }
            } catch (error) {
              debugPrint('Error parsing requiredFields query param: $error');
              requiredFields = <String, bool>{
                'hasPhoneNumber': false,
                'hasGender': false,
                'hasUsername': false,
                'isComplete': false,
              };
            }
          } else {
            requiredFields = state.extra as Map<String, bool>? ??
                <String, bool>{
                  'hasPhoneNumber': false,
                  'hasGender': false,
                  'hasUsername': false,
                  'isComplete': false,
                };
          }

          return RodnyaCustomTransitionPage(
            key: state.pageKey,
            constrainWidth: true,
            child: CompleteProfileScreen(requiredFields: requiredFields),
            transitionsBuilder: AppRouteTransitions.fade,
          );
        },
      ),
      GoRoute(
        path: '/chats/view/:chatId',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final chatId = state.pathParameters['chatId'] ?? '';
          final title = state.uri.queryParameters['title'] ?? 'Чат';
          final photoUrl = state.uri.queryParameters['photo'];
          final otherUserId = state.uri.queryParameters['userId'];
          final relativeId = state.uri.queryParameters['relativeId'];
          final chatType = state.uri.queryParameters['type'] ?? 'direct';
          // GP2: chats-list «Позвонить» action opens the chat with
          // ?startCall=audio|video to auto-trigger the group-call flow.
          final startCall = state.uri.queryParameters['startCall'];

          return RodnyaCustomTransitionPage(
            key: state.pageKey,
            constrainWidth: true,
            child: ChatScreen(
              chatId: chatId,
              otherUserId: otherUserId,
              title: title,
              photoUrl:
                  photoUrl != null && photoUrl.isNotEmpty ? photoUrl : null,
              relativeId: relativeId != null && relativeId.isNotEmpty
                  ? relativeId
                  : null,
              chatType: chatType,
              autoStartCall: startCall == 'video'
                  ? CallMediaMode.video
                  : (startCall == 'audio' ? CallMediaMode.audio : null),
            ),
            transitionsBuilder: AppRouteTransitions.slide,
          );
        },
      ),
      GoRoute(
        path: '/chat/:userId',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final userId = state.pathParameters['userId'] ?? '';
          final name = state.uri.queryParameters['name'] ?? 'Пользователь';
          final photoUrl = state.uri.queryParameters['photo'];
          final relativeId = state.uri.queryParameters['relativeId'] ?? '';

          if (relativeId.isEmpty) {
            debugPrint('Error: Missing relativeId for chat route');
            return MaterialPage<void>(
              key: state.pageKey,
              child: Scaffold(
                appBar: AppBar(title: const Text('Ошибка')),
                body: const Center(
                  child: Text('Не найден ID родственника для чата.'),
                ),
              ),
            );
          }

          return RodnyaCustomTransitionPage(
            key: state.pageKey,
            constrainWidth: true,
            child: ChatScreen(
              otherUserId: userId,
              title: name,
              photoUrl:
                  photoUrl != null && photoUrl.isNotEmpty ? photoUrl : null,
              relativeId: relativeId,
              chatType: 'direct',
            ),
            transitionsBuilder: AppRouteTransitions.slide,
          );
        },
      ),
      GoRoute(
        path: '/send_relation_request',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final treeId = state.uri.queryParameters['treeId'] ??
              state.uri.queryParameters['userId'] ??
              '';
          return RodnyaCustomTransitionPage(
            key: state.pageKey,
            constrainWidth: true,
            child: SendRelationRequestScreen(treeId: treeId),
            transitionsBuilder: AppRouteTransitions.slide,
          );
        },
      ),
      GoRoute(
        path: '/privacy',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => RodnyaCustomTransitionPage(
          key: state.pageKey,
          constrainWidth: true,
          child: const PrivacyPolicyScreen(),
          transitionsBuilder: AppRouteTransitions.slide,
        ),
      ),
      GoRoute(
        path: '/terms',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => RodnyaCustomTransitionPage(
          key: state.pageKey,
          constrainWidth: true,
          child: const TermsOfUseScreen(),
          transitionsBuilder: AppRouteTransitions.slide,
        ),
      ),
      GoRoute(
        path: '/support',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => RodnyaCustomTransitionPage(
          key: state.pageKey,
          constrainWidth: true,
          child: const SupportScreen(),
          transitionsBuilder: AppRouteTransitions.slide,
        ),
      ),
      GoRoute(
        path: '/account-deletion',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => RodnyaCustomTransitionPage(
          key: state.pageKey,
          constrainWidth: true,
          child: const AccountDeletionInfoScreen(),
          transitionsBuilder: AppRouteTransitions.slide,
        ),
      ),
      GoRoute(
        path: '/invite',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => RodnyaCustomTransitionPage(
          key: state.pageKey,
          child: const SizedBox.shrink(),
          transitionsBuilder: AppRouteTransitions.fade,
        ),
      ),
      // Ship FE3b (2026-05-28): семя invitation deep link с token
      // path. Distinct из legacy `/invite` (Phase 3.4 — treeId+personId
      // query params) — этот route accepts ONE-shot capability token
      // в path segment. Mirror /browse/:token (FE6a) structure.
      // Guard handles logged-out persistence + redirect к /login;
      // screen invokes acceptInvitation on mount.
      GoRoute(
        path: '/invite/:token',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final token = state.pathParameters['token'] ?? '';
          return RodnyaCustomTransitionPage(
            key: state.pageKey,
            child: SemyaInvitationAcceptScreen(token: token),
            transitionsBuilder: AppRouteTransitions.fade,
          );
        },
      ),
      GoRoute(
        path: '/public/tree/:publicTreeId',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final publicTreeId = state.pathParameters['publicTreeId'] ?? '';
          return RodnyaCustomTransitionPage(
            key: state.pageKey,
            child: PublicTreeEntryScreen(publicTreeId: publicTreeId),
            transitionsBuilder: AppRouteTransitions.slide,
          );
        },
      ),
      GoRoute(
        path: '/public/tree/:publicTreeId/view',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final publicTreeId = state.pathParameters['publicTreeId'] ?? '';
          return RodnyaCustomTransitionPage(
            key: state.pageKey,
            child: PublicTreeViewerScreen(publicTreeId: publicTreeId),
            transitionsBuilder: AppRouteTransitions.slide,
          );
        },
      ),
      // Ship FE6a (2026-05-26): browse-token capability route.
      // Mirrors /public/tree/* anonymous-allowed pattern. Anonymous
      // GET — token itself is capability. Auth bypass enforced via
      // app_router_guards.dart prefix check.
      GoRoute(
        path: '/browse/:browseToken',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final browseToken = state.pathParameters['browseToken'] ?? '';
          return RodnyaCustomTransitionPage(
            key: state.pageKey,
            child: BrowseTreeScreen(browseToken: browseToken),
            transitionsBuilder: AppRouteTransitions.slide,
          );
        },
      ),
      GoRoute(
        path: '/auth/qr',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => RodnyaCustomTransitionPage(
          key: state.pageKey,
          constrainWidth: true,
          child: const QrLoginDisplayScreen(),
          transitionsBuilder: AppRouteTransitions.slideUp,
        ),
      ),
      GoRoute(
        path: '/relative/details/:personId',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final personId = state.pathParameters['personId'] ?? '';
          final initialAction = state.uri.queryParameters['action'];
          // P0 (мамин баг): опциональный ?treeId= — точки входа, знающие
          // дерево, прокидывают его, и карточка грузится из него, а не из
          // выбранного. Старые ссылки без параметра работают через
          // резолв на самом экране (кэш → выбранное → обход деревьев).
          final treeId = state.uri.queryParameters['treeId'];
          if (personId.isEmpty) {
            return MaterialPage<void>(
              key: state.pageKey,
              child: const Scaffold(
                body: Center(
                  child: Text('Ошибка: ID родственника не указан'),
                ),
              ),
            );
          }
          return RodnyaCustomTransitionPage(
            key: ValueKey<String>('relative_details_$personId'),
            child: RelativeDetailsScreen(
              personId: personId,
              treeId: (treeId != null && treeId.trim().isNotEmpty)
                  ? treeId.trim()
                  : null,
              initialAction: initialAction,
            ),
            transitionsBuilder: AppRouteTransitions.slide,
          );
        },
      ),
    ];
  }

  Page<void> buildErrorPage(BuildContext context, GoRouterState state) {
    return MaterialPage<void>(
      key: state.pageKey,
      // Friendly 404. Earlier version exposed the raw GoException
      // ("no routes for location: /auth") directly to the user —
      // tech jargon leaking through to Bаба Маша. Now we show a
      // centered card with a friendly icon, an explanation that
      // doesn't mention frameworks, a Назад action, and a Главная
      // fallback. The raw error is logged via debugPrint for
      // engineers but not surfaced.
      child: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          assert(() {
            // ignore: avoid_print
            debugPrint('[router] 404: ${state.uri} — ${state.error}');
            return true;
          }());
          return Scaffold(
            appBar: AppBar(),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.travel_explore_outlined,
                            size: 34,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'Такой страницы нет',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Адрес мог измениться или ссылка устарела.\n'
                          'Вернёмся на главную и продолжим оттуда.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Wrap(
                          spacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            if (Navigator.of(context).canPop())
                              OutlinedButton.icon(
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(Icons.arrow_back_rounded),
                                label: const Text('Назад'),
                              ),
                            FilledButton.icon(
                              onPressed: () => context.go('/'),
                              icon: const Icon(Icons.home_outlined),
                              label: const Text('На главную'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
