import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';

import '../backend/backend_provider_config.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/models/auth_providers_availability.dart';
import '../backend/models/email_provider_mismatch.dart';
import '../backend/models/google_account_preview.dart';
import '../providers/tree_provider.dart';
import '../services/app_status_service.dart';
import '../services/custom_api_auth_service.dart';
import '../services/onboarding_service.dart';
import 'package:app_links/app_links.dart';

import '../theme/app_theme.dart';
import '../utils/user_facing_error.dart';
import '../widgets/dismiss_keyboard.dart';
import '../widgets/email_provider_mismatch_dialog.dart';
import '../widgets/glass_panel.dart';
import '../widgets/google_account_confirm_dialog.dart';
import '../widgets/google_sign_in_action.dart';
import '../widgets/offline_indicator.dart';
import 'privacy_policy_screen.dart' show kLegalDocsVersion;

class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
    this.redirectAfterLogin,
  });

  final String? redirectAfterLogin;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _emailFocusNode = FocusNode();
  final _nameFocusNode = FocusNode();

  bool _isLogin = true;
  bool _isLoading = false;
  // Согласие при регистрации: обязательный чекбокс — без него кнопка
  // «Создать аккаунт» неактивна; версия документов уходит на бэк.
  bool _acceptedTerms = false;
  late final TapGestureRecognizer _termsLinkRecognizer =
      TapGestureRecognizer()
        ..onTap = () => GoRouter.of(context).push('/terms');
  late final TapGestureRecognizer _privacyLinkRecognizer =
      TapGestureRecognizer()
        ..onTap = () => GoRouter.of(context).push('/privacy');
  bool _isGoogleLoading = false;
  bool _isTelegramLoading = false;
  bool _isVkLoading = false;
  bool _isMaxLoading = false;
  bool _hasSubmitted = false;
  late final bool _supportsGoogleAuth;
  // Ship Q3a (2026-05-26): backend-driven capability flags for VK/
  // Telegram/MAX (and confirms Google). Null когда capability data
  // не loaded yet (in-flight либо legacy server без /health authProviders
  // field) → render «as-is» fallback (Telegram/VK/MAX show, Google
  // already gated by _supportsGoogleAuth). Non-null → gate per flag.
  AuthProvidersAvailability? _providersAvailability;
  StreamSubscription<void>? _googleWebAuthenticationSubscription;
  StreamSubscription<Uri>? _appLinkSubscription;
  String? _pendingTelegramLinkCode;
  String? _pendingTelegramMessage;
  String? _pendingVkLinkCode;
  String? _pendingVkMessage;
  String? _pendingMaxLinkCode;
  String? _pendingMaxMessage;

  final List<_AuthFeature> _mvpHighlights = const [
    _AuthFeature(
      icon: Icons.account_tree_outlined,
      title: 'Дерево',
      description: 'Родные и связи в одном месте.',
    ),
    _AuthFeature(
      icon: Icons.people_alt_outlined,
      title: 'Родные',
      description: 'Карточки людей и профиль без лишних шагов.',
    ),
    _AuthFeature(
      icon: Icons.chat_bubble_outline,
      title: 'Чат',
      description: 'Личные диалоги с родными.',
    ),
    _AuthFeature(
      icon: Icons.circle_outlined,
      title: 'Stories',
      description: 'Короткие семейные обновления.',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _emailController.addListener(_handleAuthInputChanged);
    _passwordController.addListener(_handleAuthInputChanged);
    _nameController.addListener(_handleAuthInputChanged);
    final authService = _authService;
    _supportsGoogleAuth = authService is CustomApiAuthService
        ? authService.isGoogleSignInConfigured
        : BackendProviderConfig.current.authProvider !=
            BackendProviderKind.customApi;
    if (kIsWeb && authService is CustomApiAuthService && _supportsGoogleAuth) {
      _googleWebAuthenticationSubscription =
          authService.googleWebAuthenticationEvents.listen((_) {
        if (!mounted || _isGoogleLoading) {
          return;
        }
        unawaited(_signInWithGoogle());
      });
      unawaited(authService.initializeGoogleWebAuthentication());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_handleSocialRedirectResults());
    });
    _bindAppLinksListener();
    // Ship Q3a (2026-05-26): fetch backend provider availability.
    // Fire-and-forget — UI initially renders fallback (как раньше);
    // when data arrives, setState triggers re-render с gated buttons.
    unawaited(_loadProvidersAvailability());
  }

  Future<void> _loadProvidersAvailability() async {
    final result = await _authService.fetchAuthProvidersAvailability();
    if (!mounted || result == null) return;
    setState(() {
      _providersAvailability = result;
    });
  }

  /// Ship Q3a: helpers gate each social button. Когда availability
  /// not yet loaded (либо backend incapable) — return true для
  /// preserved legacy behavior, except Google which сохраняет existing
  /// client-side _supportsGoogleAuth check.
  ///
  /// MAX chip not currently rendered в provider chip row (audit обозначил
  /// что MAX hidden пока OAuth flow не shipped), поэтому MAX gate not
  /// needed here — _providersAvailability.max остаётся accessible
  /// caller'у когда / если MAX button gets reintroduced.
  bool get _showGoogleButton =>
      _supportsGoogleAuth &&
      (_providersAvailability?.google ?? true);
  bool get _showTelegramButton => _providersAvailability?.telegram ?? true;
  bool get _showVkButton => _providersAvailability?.vk ?? true;

  /// Subscribe to deep-link OAuth callbacks (Android opens the system
  /// browser for the OAuth dance, the backend redirects to
  /// rodnya://oauth/callback?xxxAuthCode=... when finalRedirect is
  /// set, app_links picks the URI up via the manifest intent-filter
  /// and routes it here). Web runs the same handlers via Uri.base.
  Future<void> _bindAppLinksListener() async {
    if (kIsWeb) return;
    try {
      final appLinks = AppLinks();
      // Cold-start case: the app was launched by tapping the deep
      // link → fetch initial URI and dispatch.
      final initial = await appLinks.getInitialLink();
      if (initial != null) {
        unawaited(_dispatchOauthDeepLink(initial));
      }
      _appLinkSubscription = appLinks.uriLinkStream.listen((uri) {
        unawaited(_dispatchOauthDeepLink(uri));
      });
    } catch (error) {
      debugPrint('Failed to bind app_links listener: $error');
    }
  }

  Future<void> _dispatchOauthDeepLink(Uri uri) async {
    // Accept BOTH the legacy custom-scheme callback and the
    // verified https App Link path. The custom scheme stays for
    // backward compat with older installs / devices that haven't
    // picked up the verified intent filter; the https path is the
    // only one another app can't intercept (Digital Asset Links
    // gives us exclusive ownership of /oauth/* on rodnya-tree.ru).
    final isCustomScheme =
        uri.scheme == 'rodnya' && uri.host == 'oauth';
    final isVerifiedHttps = uri.scheme == 'https' &&
        uri.host == 'rodnya-tree.ru' &&
        uri.path.startsWith('/oauth/');
    if (!isCustomScheme && !isVerifiedHttps) return;
    if (!mounted) return;
    setState(() => _pendingDeepLinkUri = uri);
    try {
      await _handleSocialRedirectResults();
    } finally {
      if (mounted) {
        setState(() => _pendingDeepLinkUri = null);
      }
    }
  }

  @override
  void dispose() {
    _emailController.removeListener(_handleAuthInputChanged);
    _passwordController.removeListener(_handleAuthInputChanged);
    _nameController.removeListener(_handleAuthInputChanged);
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _googleWebAuthenticationSubscription?.cancel();
    _appLinkSubscription?.cancel();
    _emailFocusNode.dispose();
    _nameFocusNode.dispose();
    _termsLinkRecognizer.dispose();
    _privacyLinkRecognizer.dispose();
    super.dispose();
  }

  bool get _isAnySocialLoading =>
      _isGoogleLoading || _isTelegramLoading || _isVkLoading || _isMaxLoading;

  Future<void> _submit() async {
    _clearSessionIssue();
    setState(() {
      _hasSubmitted = true;
    });

    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      if (_isLogin) {
        await _authService.loginWithEmail(
          _emailController.text.trim(),
          _passwordController.text,
        );
      } else {
        await _authService.registerWithEmail(
          email: _emailController.text.trim(),
          password: _passwordController.text,
          name: _nameController.text.trim(),
          // Чекбокс обязателен (кнопка без него неактивна) — фиксируем
          // версию принятых документов; момент ставит бэк.
          consentDocVersion: kLegalDocsVersion,
        );
      }

      if (_authService.currentUserId != null) {
        final linkedTelegram = await _tryLinkPendingTelegramIdentity();
        final linkedVk = await _tryLinkPendingVkIdentity();
        final linkedMax = await _tryLinkPendingMaxIdentity();
        if (GetIt.I.isRegistered<TreeProvider>()) {
          await GetIt.I<TreeProvider>().loadInitialTree();
        }

        if (!mounted) {
          return;
        }

        // Brand-new email registrations get the onboarding tour first —
        // gives them a quick orientation before being dropped into an
        // empty home feed. Existing users (login) skip straight to the
        // resolved target. We still gate by hasSeen() so a returning user
        // who happens to register on a second device doesn't re-watch.
        final shouldShowOnboarding = !_isLogin &&
            !linkedTelegram &&
            !linkedVk &&
            !linkedMax &&
            !(await OnboardingService.instance.hasSeen());

        if (!mounted) {
          return;
        }

        // Phase 6 chunk 4a: wizard takes precedence over Phase 1 carousel.
        // requiresOnboarding=true → /setup (functional account setup).
        // Carousel stays as fallback для legacy/login paths без flag.
        if (_authService.currentRequiresOnboarding) {
          context.go('/setup');
        } else if (shouldShowOnboarding) {
          context.go('/onboarding');
        } else {
          context.go(_resolvePostAuthRedirect());
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              (linkedTelegram || linkedVk || linkedMax)
                  ? '${[
                      if (linkedTelegram) 'Telegram',
                      if (linkedVk) 'VK ID',
                      if (linkedMax) 'MAX',
                    ].join(', ')} привязан. Вход выполнен успешно.'
                  : _isLogin
                      ? 'Вход выполнен успешно.'
                      : 'Регистрация успешна. Добро пожаловать в Родню.',
            ),
            backgroundColor: Colors.green,
          ),
        );
        return;
      }

      throw Exception('Ошибка авторизации: пользователь не найден');
    } catch (e) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _authError(
              e,
              fallbackMessage: 'Не удалось войти. Попробуйте ещё раз.',
            ),
          ),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _signInWithGoogle() => _runGoogleSignIn();

  /// [consentDocVersion] is set on the retry after the consent modal — a
  /// brand-new Google account needs affirmative consent (152-ФЗ). On that
  /// retry the account is already chosen, so we skip the confirm dialog.
  Future<void> _runGoogleSignIn({String? consentDocVersion}) async {
    _clearSessionIssue();
    setState(() {
      _isGoogleLoading = true;
    });

    final isConsentRetry = consentDocVersion != null;
    try {
      // Ship Q2 (2026-05-25): surface confirm dialog после Google
      // chooser returns account info, ПЕРЕД backend session exchange.
      // Captures «silent wrong-account» case (Артёма mama hit это on
      // his old phone — Google chooser showed только his account,
      // she tapped reflex, landed в его production).
      final result = await _authService.signInWithGoogle(
        confirm: isConsentRetry
            ? null
            : (preview) async {
                if (!mounted) return GoogleAccountConfirmDecision.cancel;
                return showGoogleAccountConfirmDialog(context, preview);
              },
        consentDocVersion: consentDocVersion,
      );
      if (!mounted) return;

      // New social account → backend asked for consent. Show the consent
      // step and retry the SAME Google flow with the accepted doc version.
      if (result is SocialConsentRequired) {
        final accepted = await _showSocialConsentSheet('Google');
        if (!mounted || !accepted) return;
        await _runGoogleSignIn(consentDocVersion: kLegalDocsVersion);
        return;
      }

      if (_authService.currentUserId != null) {
        context.go(_resolvePostAuthRedirect());
      }
    } on EmailProviderMismatchException catch (mismatch) {
      // Ship Bug B (2026-05-26): cross-provider email collision blocked
      // by backend. Show disambig modal so user can log in via existing
      // identity вместо silent-merge.
      if (!mounted) return;
      await _handleEmailProviderMismatch(mismatch.payload);
    } catch (e) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _authError(
              e,
              fallbackMessage: 'Не удалось войти через Google.',
            ),
          ),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isGoogleLoading = false;
        });
      }
    }
  }

  /// Consent step for a brand-new social account (152-ФЗ). Mirrors the
  /// email-registration checkbox: same Соглашение + ПДН texts and the same
  /// link recognizers. Returns true if the user affirmatively accepts.
  Future<bool> _showSocialConsentSheet(String providerLabel) async {
    final theme = Theme.of(context);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Согласие на обработку данных'),
          content: Text.rich(
            TextSpan(
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
              children: [
                TextSpan(
                  text: 'Чтобы создать аккаунт через $providerLabel, примите ',
                ),
                TextSpan(
                  text: 'Пользовательское соглашение',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                  recognizer: _termsLinkRecognizer,
                ),
                const TextSpan(text: ' и дайте '),
                TextSpan(
                  text: 'согласие на обработку персональных данных',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                  recognizer: _privacyLinkRecognizer,
                ),
                const TextSpan(
                  text: ' в соответствии с Политикой конфиденциальности.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Принимаю'),
            ),
          ],
        );
      },
    );
    return accepted ?? false;
  }

  Future<void> _startTelegramSignIn() async {
    final authService = _authService;
    if (authService is! CustomApiAuthService) {
      _showPlannedSocialAuthMessage('Telegram');
      return;
    }

    _clearSessionIssue();
    setState(() {
      _isTelegramLoading = true;
    });

    try {
      final telegramStartUrl =
          await authService.resolveTelegramLoginStartUrl();
      final started = await launchUrl(
        Uri.parse(telegramStartUrl),
        mode: LaunchMode.platformDefault,
        webOnlyWindowName: '_self',
      );
      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось открыть вход через Telegram.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isTelegramLoading = false;
        });
      }
    }
  }

  Future<void> _startVkSignIn({String? consentDocVersion}) async {
    final authService = _authService;
    if (authService is! CustomApiAuthService) {
      _showPlannedSocialAuthMessage('VK ID');
      return;
    }

    _clearSessionIssue();
    setState(() {
      _isVkLoading = true;
    });

    try {
      // consentDocVersion is set on the re-start after the consent modal so a
      // brand-new VK account can be created with recorded consent (152-ФЗ).
      final vkStartUrl = await authService.resolveVkLoginStartUrl(
        consentDocVersion: consentDocVersion,
      );
      final started = await launchUrl(
        Uri.parse(vkStartUrl),
        mode: LaunchMode.platformDefault,
        webOnlyWindowName: '_self',
      );
      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось открыть вход через VK ID.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isVkLoading = false;
        });
      }
    }
  }

  Future<void> _handleSocialRedirectResults() async {
    await _handleTelegramRedirectResult();
    await _handleVkRedirectResult();
    await _handleMaxRedirectResult();
  }

  Future<void> _handleTelegramRedirectResult() async {
    final intent = _socialQueryParameter('telegramIntent');
    final isLinkIntent = intent == 'link';
    final error = _socialQueryParameter('telegramAuthError');
    if (error != null && error.isNotEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }

    final code = _socialQueryParameter('telegramAuthCode');
    if (code == null || code.isEmpty) {
      return;
    }

    final authService = _authService;
    if (authService is! CustomApiAuthService) {
      return;
    }

    setState(() {
      _isTelegramLoading = true;
    });

    try {
      final completion = await authService.exchangeTelegramAuthCode(code);
      if (!mounted) {
        return;
      }

      if (completion.isAuthenticated) {
        if (GetIt.I.isRegistered<TreeProvider>()) {
          await GetIt.I<TreeProvider>().loadInitialTree();
        }
        if (!mounted) {
          return;
        }
        context.go(_resolvePostAuthRedirect());
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Вход через Telegram выполнен успешно.'),
            backgroundColor: Colors.green,
          ),
        );
        return;
      }

      if (completion.isAlreadyLinked) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              completion.message ??
                  'Этот Telegram уже привязан к аккаунту Родни.',
            ),
          ),
        );
        if (isLinkIntent) {
          context.go('/profile/edit');
        }
        return;
      }

      if (isLinkIntent && authService.currentUserId != null) {
        final linkCode = completion.linkCode;
        if (linkCode == null || linkCode.isEmpty) {
          throw const CustomApiException(
            'Telegram link code не был получен для привязки',
          );
        }
        await authService.linkPendingTelegramIdentity(linkCode);
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Telegram привязан к текущему аккаунту.'),
            backgroundColor: Colors.green,
          ),
        );
        context.go('/profile/edit');
        return;
      }

      final displayName = [
        completion.firstName?.trim() ?? '',
        completion.lastName?.trim() ?? '',
      ].where((part) => part.isNotEmpty).join(' ');
      if (displayName.isNotEmpty && _nameController.text.trim().isEmpty) {
        _nameController.text = displayName;
      }

      // Don't force _isLogin=true — that traps a brand-new user
      // (no Rodnya account yet) in the login form they can't satisfy.
      // If we got a name from Telegram, default to register mode so
      // the user just picks an email + password and the link runs
      // automatically inside _submit() via _tryLinkPendingTelegramIdentity.
      // The mode toggle stays visible so existing users can flip
      // back to login and the link still attaches afterwards.
      setState(() {
        if (displayName.isNotEmpty) {
          _isLogin = false;
        }
        _pendingTelegramLinkCode = completion.linkCode;
        _pendingTelegramMessage = completion.message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Telegram подтверждён. Войдите в аккаунт или создайте новый — '
            'Telegram привяжется автоматически.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _authError(
              e,
              fallbackMessage: 'Не удалось завершить вход через Telegram.',
            ),
          ),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isTelegramLoading = false;
        });
      }
    }
  }

  Future<void> _handleVkRedirectResult() async {
    final intent = _socialQueryParameter('vkIntent');
    final isLinkIntent = intent == 'link';
    final error = _socialQueryParameter('vkAuthError');
    if (error != null && error.isNotEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }

    final code = _socialQueryParameter('vkAuthCode');
    if (code == null || code.isEmpty) {
      return;
    }

    final authService = _authService;
    if (authService is! CustomApiAuthService) {
      return;
    }

    setState(() {
      _isVkLoading = true;
    });

    try {
      final completion = await authService.exchangeVkAuthCode(code);
      if (!mounted) {
        return;
      }

      if (completion.isAuthenticated) {
        if (GetIt.I.isRegistered<TreeProvider>()) {
          await GetIt.I<TreeProvider>().loadInitialTree();
        }
        if (!mounted) {
          return;
        }
        context.go(_resolvePostAuthRedirect());
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Вход через VK ID выполнен успешно.'),
            backgroundColor: Colors.green,
          ),
        );
        return;
      }

      if (completion.isAlreadyLinked) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              completion.message ?? 'Этот VK ID уже привязан к аккаунту Родни.',
            ),
          ),
        );
        if (isLinkIntent) {
          context.go('/profile/edit');
        }
        return;
      }

      // New VK account → backend asked for consent. Show the consent step and
      // re-run the VK flow with the accepted doc version (the VK code is
      // one-time, so we restart the provider flow rather than reuse a token).
      if (completion.isRequiresConsent) {
        final accepted = await _showSocialConsentSheet('VK ID');
        if (!mounted || !accepted) return;
        await _startVkSignIn(consentDocVersion: kLegalDocsVersion);
        return;
      }

      if (isLinkIntent && authService.currentUserId != null) {
        final linkCode = completion.linkCode;
        if (linkCode == null || linkCode.isEmpty) {
          throw const CustomApiException(
            'VK ID link code не был получен для привязки',
          );
        }
        await authService.linkPendingVkIdentity(linkCode);
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('VK ID привязан к текущему аккаунту.'),
            backgroundColor: Colors.green,
          ),
        );
        context.go('/profile/edit');
        return;
      }

      final displayName = [
        completion.firstName?.trim() ?? '',
        completion.lastName?.trim() ?? '',
      ].where((part) => part.isNotEmpty).join(' ');
      if (displayName.isNotEmpty && _nameController.text.trim().isEmpty) {
        _nameController.text = displayName;
      }

      // See _exchangeTelegramAuthCode for the rationale — same
      // pattern: don't trap a new user in login mode if we got
      // a usable name from VK ID.
      setState(() {
        if (displayName.isNotEmpty) {
          _isLogin = false;
        }
        _pendingVkLinkCode = completion.linkCode;
        _pendingVkMessage = completion.message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'VK ID подтверждён. Войдите в аккаунт или создайте новый — '
            'VK ID привяжется автоматически.',
          ),
        ),
      );
    } on EmailProviderMismatchException catch (mismatch) {
      // Ship Bug B (2026-05-26): cross-provider email collision arrived
      // through VK handoff payload (exchangeVkAuthCode throws когда
      // backend returns status='email_provider_mismatch'). Same modal
      // pattern как Google.
      if (!mounted) return;
      await _handleEmailProviderMismatch(mismatch.payload);
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _authError(
              e,
              fallbackMessage: 'Не удалось завершить вход через VK ID.',
            ),
          ),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isVkLoading = false;
        });
      }
    }
  }

  /// Ship Bug B (2026-05-26): central handler для 409
  /// EMAIL_PROVIDER_MISMATCH. Shows disambig modal — user picks
  /// existing provider, мы dispatch к correct flow.
  Future<void> _handleEmailProviderMismatch(
    EmailProviderMismatch payload,
  ) async {
    final picked = await showEmailProviderMismatchDialog(context, payload);
    if (!mounted || picked == null) return;
    switch (picked) {
      case 'password':
        // Switch to login mode + pre-fill email so user знает что
        // ввести именно его password.
        _setMode(true);
        _emailController.text = payload.email;
        _focusPrimaryField();
        break;
      case 'google':
        if (_showGoogleButton) await _signInWithGoogle();
        break;
      case 'vk':
        if (_showVkButton) await _startVkSignIn();
        break;
      case 'telegram':
        if (_showTelegramButton) await _startTelegramSignIn();
        break;
      // 'max' currently не has UI entry-point (chip absent); skip.
    }
  }

  // ignore: unused_element
  Future<void> _startMaxSignIn() async {
    final authService = _authService;
    if (authService is! CustomApiAuthService) {
      _showPlannedSocialAuthMessage('MAX');
      return;
    }

    _clearSessionIssue();
    setState(() {
      _isMaxLoading = true;
    });

    try {
      final maxStartUrl = await authService.resolveMaxLoginStartUrl();
      final started = await launchUrl(
        Uri.parse(maxStartUrl),
        mode: LaunchMode.platformDefault,
        webOnlyWindowName: '_self',
      );
      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось открыть вход через MAX.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isMaxLoading = false;
        });
      }
    }
  }

  Future<void> _handleMaxRedirectResult() async {
    final intent = _socialQueryParameter('maxIntent');
    final isLinkIntent = intent == 'link';
    final error = _socialQueryParameter('maxAuthError');
    if (error != null && error.isNotEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }

    final code = _socialQueryParameter('maxAuthCode');
    if (code == null || code.isEmpty) {
      return;
    }

    final authService = _authService;
    if (authService is! CustomApiAuthService) {
      return;
    }

    setState(() {
      _isMaxLoading = true;
    });

    try {
      final completion = await authService.exchangeMaxAuthCode(code);
      if (!mounted) {
        return;
      }

      if (completion.isAuthenticated) {
        if (GetIt.I.isRegistered<TreeProvider>()) {
          await GetIt.I<TreeProvider>().loadInitialTree();
        }
        if (!mounted) {
          return;
        }
        context.go(_resolvePostAuthRedirect());
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Вход через MAX выполнен успешно.'),
            backgroundColor: Colors.green,
          ),
        );
        return;
      }

      if (completion.isAlreadyLinked) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              completion.message ?? 'Этот MAX уже привязан к аккаунту Родни.',
            ),
          ),
        );
        if (isLinkIntent) {
          context.go('/profile/edit');
        }
        return;
      }

      if (isLinkIntent && authService.currentUserId != null) {
        final linkCode = completion.linkCode;
        if (linkCode == null || linkCode.isEmpty) {
          throw const CustomApiException(
            'MAX link code не был получен для привязки',
          );
        }
        await authService.linkPendingMaxIdentity(linkCode);
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('MAX привязан к текущему аккаунту.'),
            backgroundColor: Colors.green,
          ),
        );
        context.go('/profile/edit');
        return;
      }

      final displayName = [
        completion.firstName?.trim() ?? '',
        completion.lastName?.trim() ?? '',
      ].where((part) => part.isNotEmpty).join(' ');
      if (displayName.isNotEmpty && _nameController.text.trim().isEmpty) {
        _nameController.text = displayName;
      }

      // Same pattern as Telegram / VK ID — see _exchangeTelegramAuthCode
      // for rationale.
      setState(() {
        if (displayName.isNotEmpty) {
          _isLogin = false;
        }
        _pendingMaxLinkCode = completion.linkCode;
        _pendingMaxMessage = completion.message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'MAX подтверждён. Войдите в аккаунт или создайте новый — '
            'MAX привяжется автоматически.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _authError(
              e,
              fallbackMessage: 'Не удалось завершить вход через MAX.',
            ),
          ),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isMaxLoading = false;
        });
      }
    }
  }

  /// When a deep-link OAuth callback fires (Android: app_links picks up
  /// rodnya://oauth/callback?...), we set [_pendingDeepLinkUri] so the
  /// _socialQueryParameter helper reads from there instead of Uri.base
  /// (which is the web-page URL and meaningless on mobile).
  Uri? _pendingDeepLinkUri;

  String? _socialQueryParameter(String name) {
    final overrideUri = _pendingDeepLinkUri;
    if (overrideUri != null) {
      final fromOverride = overrideUri.queryParameters[name];
      if (fromOverride != null && fromOverride.isNotEmpty) {
        return fromOverride;
      }
      // Some deep links carry the params in the fragment (#...).
      final fragment = overrideUri.fragment;
      if (fragment.isNotEmpty && fragment.contains('?')) {
        final queryPart = fragment.split('?').skip(1).join('?');
        final fromFragment = Uri.splitQueryString(queryPart)[name];
        if (fromFragment != null && fromFragment.isNotEmpty) {
          return fromFragment;
        }
      }
    }
    final directValue = Uri.base.queryParameters[name];
    if (directValue != null && directValue.isNotEmpty) {
      return directValue;
    }

    final fragment = Uri.base.fragment;
    if (fragment.isEmpty || !fragment.contains('?')) {
      return null;
    }

    final queryPart = fragment.split('?').skip(1).join('?');
    return Uri.splitQueryString(queryPart)[name];
  }

  Future<bool> _tryLinkPendingTelegramIdentity() async {
    final code = _pendingTelegramLinkCode;
    final authService = _authService;
    if (code == null || code.isEmpty || authService is! CustomApiAuthService) {
      return false;
    }

    await authService.linkPendingTelegramIdentity(code);
    if (!mounted) {
      return true;
    }

    setState(() {
      _pendingTelegramLinkCode = null;
      _pendingTelegramMessage = null;
    });
    return true;
  }

  Future<bool> _tryLinkPendingVkIdentity() async {
    final code = _pendingVkLinkCode;
    final authService = _authService;
    if (code == null || code.isEmpty || authService is! CustomApiAuthService) {
      return false;
    }

    await authService.linkPendingVkIdentity(code);
    if (!mounted) {
      return true;
    }

    setState(() {
      _pendingVkLinkCode = null;
      _pendingVkMessage = null;
    });
    return true;
  }

  Future<bool> _tryLinkPendingMaxIdentity() async {
    final code = _pendingMaxLinkCode;
    final authService = _authService;
    if (code == null || code.isEmpty || authService is! CustomApiAuthService) {
      return false;
    }

    await authService.linkPendingMaxIdentity(code);
    if (!mounted) {
      return true;
    }

    setState(() {
      _pendingMaxLinkCode = null;
      _pendingMaxMessage = null;
    });
    return true;
  }

  void _showPlannedSocialAuthMessage(String providerLabel) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$providerLabel появится после подключения ключей провайдера.',
        ),
      ),
    );
  }


  String _authError(Object error, {required String fallbackMessage}) {
    return describeUserFacingError(
      authService: _authService,
      error: error,
      fallbackMessage: fallbackMessage,
    );
  }

  void _setMode(bool isLogin) {
    _clearSessionIssue();
    setState(() {
      _isLogin = isLogin;
      _hasSubmitted = false;
    });
  }

  void _handleAuthInputChanged() {
    if (_emailController.text.isEmpty &&
        _passwordController.text.isEmpty &&
        _nameController.text.isEmpty) {
      return;
    }
    _clearSessionIssue();
  }

  void _clearSessionIssue() {
    if (!GetIt.I.isRegistered<AppStatusService>()) {
      return;
    }
    GetIt.I<AppStatusService>().clearSessionIssue();
  }

  void _focusPrimaryField() {
    final focusNode = _isLogin ? _emailFocusNode : _nameFocusNode;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      focusNode.requestFocus();
    });
  }

  String _resolvePostAuthTarget() {
    final from = widget.redirectAfterLogin;
    if (from == null || from.isEmpty || from == '/login') {
      return '/';
    }
    return from;
  }

  /// Phase 6 chunk 4a (DECISIONS 2026-05-14 «post-signup redirect
  /// Option A»): `requiresOnboarding` от backend → redirect к
  /// `/setup` wizard. Иначе следуем pre-Phase-6 logic (redirectAfter
  /// либо `/`). Carousel branch `/onboarding` обрабатывается
  /// отдельно в email-submit path (только для пользователей
  /// без requiresOnboarding flag).
  String _resolvePostAuthRedirect() {
    if (_authService.currentRequiresOnboarding) {
      return '/setup';
    }
    return _resolvePostAuthTarget();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: DismissKeyboardOnTap(
        child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.primary.withValues(alpha: 0.14),
              const Color(0xFFF7F2E8),
              theme.colorScheme.secondary.withValues(alpha: 0.08),
            ],
          ),
        ),
        child: SafeArea(
          // UX audit 2026-05-25 Screen 1.1 (ed62ba6): Samsung S20 FE с
          // active Android call/status pill clip'ил hero — user видел
          // только «...дерево.» tail of headline. Default SafeArea
          // полагается на MediaQuery.padding, который на Android при
          // call-pill активном иногда reports lower than actual safe
          // area. `minimum: EdgeInsets.only(top: 12)` устанавливает
          // floor — даже если system padding несоответствует, hero
          // получает breathing room above. Bottom intentionally
          // omitted — keyboard / nav bar handled другими mechanisms.
          minimum: const EdgeInsets.only(top: 12),
          child: Column(
            children: [
              const OfflineIndicator(),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isWide = constraints.maxWidth >= 960;
                    return Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: isWide ? 1260 : 520,
                        ),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: isWide ? 24 : 16,
                            // Compact bumped 16 → 20 — extra breathing
                            // perч после SafeArea minimum (per Audit
                            // 1.1). Wide unchanged — большой viewport
                            // не has the same clip risk.
                            vertical: isWide ? 28 : 20,
                          ),
                          child: isWide
                              ? _buildWideLayout(theme)
                              : _buildCompactLayout(theme),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildWideLayout(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          flex: 10,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.only(right: 24),
              child: _buildHeroPanel(theme, compact: false),
            ),
          ),
        ),
        Expanded(
          flex: 9,
          child: SingleChildScrollView(
            child: _buildAuthCard(theme, compact: false),
          ),
        ),
      ],
    );
  }

  Widget _buildCompactLayout(ThemeData theme) {
    // User-reported: «Зеленый блок выглядит острым ... надо бы
    // дизайн переделать фонов этих». Hero used to span edge-to-edge
    // with sharp side corners, dark forest gradient bottoming out in
    // a hard horizontal line. Now it's a floating card — 12 dp side
    // margins, all-rounded 28 dp corners, softer sage gradient that
    // doesn't crush into deep forest at the bottom — sitting on the
    // scaffold's cream background. The auth card below is also a
    // floating card with the same 12 dp side margin so the pair
    // visually breathe.
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: _buildHeroPanel(theme, compact: true),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: _buildAuthCard(theme, compact: true),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroPanel(ThemeData theme, {required bool compact}) {
    final colorScheme = theme.colorScheme;
    // Reference hero: sage gradient + decorative tree silhouette, the big
    // Lora tagline anchored to the bottom-left. Compact layout drops the
    // feature inventory — the sheet below has all the action surface.
    return Container(
      key: const Key('auth-hero-panel'),
      width: double.infinity,
      // Density chunk 18: compact hero used to force a 320dp floor —
      // a third of a 412×915 phone screen before any actionable
      // content. Headline shrunk to 2 lines (see below), so the hero
      // now sizes to its (much smaller) content; 150dp keeps it from
      // ever looking collapsed on very short strings.
      constraints: compact
          ? const BoxConstraints(minHeight: 150)
          : const BoxConstraints(),
      padding: EdgeInsets.fromLTRB(
        compact ? 22 : 28,
        compact ? 18 : 28,
        compact ? 22 : 28,
        compact ? 18 : 28,
      ),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment(-0.6, -1.0),
          end: Alignment(0.4, 1.0),
          colors: [
            Color(0xFF5A9778), // softer sage top
            Color(0xFF3F8265), // mid forest
            Color(0xFF2F6753), // deep but not crushed
          ],
        ),
        // Both compact AND wide get all-rounded corners now — the
        // hero is a floating card on cream, not a fused header.
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: colorScheme.primary.withValues(alpha: compact ? 0.14 : 0.18),
            blurRadius: compact ? 24 : 30,
            offset: Offset(0, compact ? 12 : 18),
            spreadRadius: -4,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          // Decorative tree silhouette per reference. Painted at low
          // opacity behind the text so the gradient still owns the eye.
          if (compact)
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0.18,
                  child: CustomPaint(painter: const _AuthHeroTreePainter()),
                ),
              ),
            ),
          // Soft warm + sage glows in the corners, also from reference.
          if (compact) ...[
            Positioned(
              top: -60,
              right: -50,
              child: IgnorePointer(
                child: Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        const Color(0xFFEBC678).withValues(alpha: 0.40),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.7],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: -80,
              left: -60,
              child: IgnorePointer(
                child: Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        const Color(0xFF9DD8B5).withValues(alpha: 0.36),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.7],
                    ),
                  ),
                ),
              ),
            ),
          ],
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.eco_outlined,
                      size: 18, color: Colors.white),
                  const SizedBox(width: 8),
                  Text(
                    'РОДНЯ',
                    style: AppTheme.sans(
                      color: Colors.white.withValues(alpha: 0.92),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2.0,
                    ),
                  ),
                ],
              ),
              SizedBox(height: compact ? 10 : 24),
              // Density chunk 18: compact hero used to stack "Семья —" /
              // "это живое" / "дерево." as three separate block-level
              // lines at 38sp (~130dp just for the headline) — a third
              // of the phone screen before any actionable content. The
              // first two pieces now share a row so the whole headline
              // reads in 2 lines at a smaller size; wide/desktop keeps
              // the original 3-line 38sp treatment untouched.
              if (compact) ...[
                // FittedBox/scaleDown — "Семья — это живое" at 25sp
                // fits ≥390dp phones as-is; on narrower devices (320dp
                // class) it scales down instead of overflowing the
                // RenderFlex (mainAxisSize.min doesn't wrap on its own).
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        'Семья —',
                        style: AppTheme.serif(
                          color: Colors.white,
                          fontSize: 25,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.3,
                          height: 1.05,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: 'это ',
                              style: AppTheme.serif(
                                color: Colors.white,
                                fontSize: 25,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.3,
                                height: 1.05,
                              ),
                            ),
                            TextSpan(
                              text: 'живое',
                              style: AppTheme.serif(
                                color: const Color(0xFFE9C273),
                                fontSize: 25,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.3,
                                height: 1.05,
                              ).copyWith(fontStyle: FontStyle.italic),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  'дерево.',
                  style: AppTheme.serif(
                    color: Colors.white,
                    fontSize: 25,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Истории, лица и даты — всё в одном месте.',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.sans(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                  ),
                ),
              ] else ...[
                Text(
                  'Семья —',
                  style: AppTheme.serif(
                    color: Colors.white,
                    fontSize: 38,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.4,
                    height: 1.05,
                  ),
                ),
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: 'это ',
                        style: AppTheme.serif(
                          color: Colors.white,
                          fontSize: 38,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.4,
                          height: 1.05,
                        ),
                      ),
                      TextSpan(
                        text: 'живое',
                        style: AppTheme.serif(
                          color: const Color(0xFFE9C273),
                          fontSize: 38,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.4,
                          height: 1.05,
                        ).copyWith(fontStyle: FontStyle.italic),
                      ),
                    ],
                  ),
                ),
                Text(
                  'дерево.',
                  style: AppTheme.serif(
                    color: Colors.white,
                    fontSize: 38,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.4,
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Истории, голоса, лица и даты\nв одном пространстве для своих.',
                  style: AppTheme.sans(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    height: 1.5,
                  ),
                ),
              ],
              if (!compact) ...[
                const SizedBox(height: 18),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: _mvpHighlights
                      .map(
                        (feature) => _FeatureCard(
                          feature: feature,
                          compact: true,
                        ),
                      )
                      .toList(),
                ),
              ],
              if (!compact) ...[
                const SizedBox(height: 22),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: _isLoading || _isAnySocialLoading
                          ? null
                          : () {
                              _setMode(true);
                              _focusPrimaryField();
                            },
                      icon: const Icon(Icons.login),
                      label: const Text('Войти'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: colorScheme.primary,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 16,
                        ),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _isLoading || _isAnySocialLoading
                          ? null
                          : () {
                              _setMode(false);
                              _focusPrimaryField();
                            },
                      icon: const Icon(Icons.family_restroom_outlined),
                      label: const Text('Создать аккаунт'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white38),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAuthCard(ThemeData theme, {required bool compact}) {
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = isDark
        ? theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.96)
        : Colors.white.withValues(alpha: 0.86);
    final secondaryTextColor =
        isDark ? theme.colorScheme.onSurfaceVariant : Colors.grey[700];

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 500),
      child: GlassPanel(
        padding: EdgeInsets.all(compact ? 20 : 28),
        borderRadius: BorderRadius.circular(28),
        clipBehavior: kIsWeb ? Clip.none : Clip.antiAlias,
        color: cardColor,
        borderColor: isDark
            ? theme.colorScheme.outlineVariant.withValues(alpha: 0.9)
            : AppTheme.warmLine.withValues(alpha: 0.72),
        child: Form(
          key: _formKey,
          // Ship Q3 (2026-05-26): form-level autovalidate disabled —
          // per-field gating via TextFormField.autovalidateMode below.
          // UX audit 2026-05-25 Critical #2: form-level
          // onUserInteraction triggered ALL validators on EVERY
          // keystroke, so typing в «Имя» surfaced empty-email error
          // под Email field (visually adjacent → looked like wrong-
          // field mapping). Per-field mode validates only the field
          // user is interacting with; submit still runs Form.validate()
          // через все validators.
          autovalidateMode: AutovalidateMode.disabled,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_pendingTelegramLinkCode != null ||
                  _pendingVkLinkCode != null ||
                  _pendingMaxLinkCode != null) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.link_outlined,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _pendingTelegramLinkCode != null
                              ? (_pendingTelegramMessage ??
                                  'Telegram подтверждён. Войдите в аккаунт, чтобы привязать его.')
                              : _pendingVkLinkCode != null
                                  ? (_pendingVkMessage ??
                                      'VK ID подтверждён. Войдите в аккаунт, чтобы привязать его.')
                                  : (_pendingMaxMessage ??
                                      'MAX подтверждён. Войдите в аккаунт, чтобы привязать его.'),
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              // Density chunk 18: the mode toggle right below already
              // says «Вход» / «Регистрация» — a second, much bigger
              // «Вход»/«Новый аккаунт» headline + caption underneath it
              // was a literal duplicate (~80dp of card height for
              // nothing new). Compact keeps a single caption line;
              // wide/desktop is untouched (toggle sits below there, so
              // the headline is the only mode indicator visible yet).
              if (compact) ...[
                _buildModeToggle(theme),
                const SizedBox(height: 10),
                Text(
                  _isLogin ? 'Откройте семью.' : 'Начните за минуту.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: secondaryTextColor,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
              ] else ...[
                Text(
                  _isLogin ? 'Вход' : 'Новый аккаунт',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _isLogin ? 'Откройте семью.' : 'Начните за минуту.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: secondaryTextColor,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 22),
                _buildModeToggle(theme),
                const SizedBox(height: 22),
              ],
              if (!_isLogin) ...[
                TextFormField(
                  controller: _nameController,
                  focusNode: _nameFocusNode,
                  decoration: _fieldDecoration(
                    theme,
                    label: 'Имя',
                    icon: Icons.person_outline,
                  ),
                  keyboardType: TextInputType.name,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  // Ship Q3: per-field autovalidate. Validator никогда
                  // не surface'ит email-related errors здесь.
                  autovalidateMode: _hasSubmitted
                      ? AutovalidateMode.onUserInteraction
                      : AutovalidateMode.disabled,
                  validator: (value) {
                    if (!_isLogin &&
                        (value == null || value.trim().length < 2)) {
                      return 'Имя должно содержать не менее 2 символов';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 10),
              ],
              TextFormField(
                controller: _emailController,
                focusNode: _emailFocusNode,
                decoration: _fieldDecoration(
                  theme,
                  label: 'Email',
                  icon: Icons.alternate_email,
                ),
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                // Ship Q3: per-field autovalidate (см. Form-level комментарий).
                autovalidateMode: _hasSubmitted
                    ? AutovalidateMode.onUserInteraction
                    : AutovalidateMode.disabled,
                validator: (value) {
                  if (value == null ||
                      !value.contains('@') ||
                      !value.contains('.')) {
                    return 'Введите корректный email адрес';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 10),
              if (_isLogin)
                // Inline "забыли?" link sits flush-right above the password
                // field — the same pattern the reference uses, so the
                // standalone "Пароль" link below the providers can go.
                Padding(
                  padding: const EdgeInsets.only(bottom: 6, right: 4),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: InkWell(
                      onTap: _isLoading || _isAnySocialLoading
                          ? null
                          : () => context.push('/password_reset'),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        child: Text(
                          'Забыли?',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 13,
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              TextFormField(
                controller: _passwordController,
                decoration: _fieldDecoration(
                  theme,
                  label: 'Пароль',
                  icon: Icons.lock_outline,
                ),
                obscureText: true,
                textInputAction:
                    _isLogin ? TextInputAction.done : TextInputAction.next,
                onFieldSubmitted: (_) {
                  if (_isLogin) {
                    _submit();
                  }
                },
                // Ship Q3: per-field autovalidate (см. Form-level комментарий).
                autovalidateMode: _hasSubmitted
                    ? AutovalidateMode.onUserInteraction
                    : AutovalidateMode.disabled,
                validator: (value) {
                  if (value == null || value.length < 6) {
                    return 'Пароль должен содержать не менее 6 символов';
                  }
                  return null;
                },
              ),
              if (!_isLogin) ...[
                const SizedBox(height: 12),
                // Обязательное согласие (тексты — docs/legal/SOGLASIE_PDN.md):
                // вся строка — тап-цель чекбокса, ссылки открывают документы.
                InkWell(
                  key: const Key('auth-consent-toggle'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () =>
                      setState(() => _acceptedTerms = !_acceptedTerms),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: Checkbox(
                            value: _acceptedTerms,
                            onChanged: (checked) => setState(
                              () => _acceptedTerms = checked ?? false,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text.rich(
                              TextSpan(
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 13,
                                  color: secondaryTextColor,
                                  height: 1.35,
                                ),
                                children: [
                                  const TextSpan(text: 'Я принимаю '),
                                  TextSpan(
                                    text: 'Пользовательское соглашение',
                                    style: TextStyle(
                                      color: theme.colorScheme.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    recognizer: _termsLinkRecognizer,
                                  ),
                                  const TextSpan(text: ' и даю '),
                                  TextSpan(
                                    text:
                                        'согласие на обработку моих персональных данных',
                                    style: TextStyle(
                                      color: theme.colorScheme.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    recognizer: _privacyLinkRecognizer,
                                  ),
                                  const TextSpan(
                                    text:
                                        ' в соответствии с Политикой конфиденциальности.',
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('auth-submit'),
                onPressed: _isLoading ||
                        _isAnySocialLoading ||
                        (!_isLogin && !_acceptedTerms)
                    ? null
                    : _submit,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(_isLogin ? 'Войти' : 'Создать аккаунт'),
              ),
              // The inline «Забыли?» link above the password field
              // already covers password reset; the second one below
              // the submit button was a duplicate (user-reported:
              // «нахуя нам два забыли?»). Removed.
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'Быстрый вход',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: secondaryTextColor,
                      ),
                    ),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),
              const SizedBox(height: 12),
              // Google web button is a fixed-width native pill (242x40).
              // Kept on its own centered row above the chip row — mixing
              // a 40dp-tall native pill into the compact chip row below
              // would force every chip to that height.
              // Ship Q3 (2026-05-26): UX audit 2026-05-25 Critical #3 —
              // «advertised-but-broken» Google login (snackbar «Google
              // появится после подключения ключей провайдера») gone.
              // Render Google button ONLY when capability check passes;
              // unconfigured environments просто не показывают кнопку.
              // Ship Q3a (2026-05-26): additionally gated by backend
              // authProviders.google flag — covers case когда client has
              // ID но backend has not enabled the provider.
              if (kIsWeb && _showGoogleButton) ...[
                Center(
                  child: buildGoogleSignInAction(
                    theme: theme,
                    isLoading: _isGoogleLoading,
                    enabled: !_isLoading &&
                        !_isTelegramLoading &&
                        !_isVkLoading,
                    onPressed: _signInWithGoogle,
                    useNativeWebButton: true,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              // Density chunk 18: social chips + the QR-login entry used
              // to be a 60dp-circle-plus-label row (~86dp) FOLLOWED by a
              // separate centered QR text-button row (~50dp with its
              // gaps) — ~136dp of "быстрый вход" surface. Both are now
              // one Wrap of compact 46dp pill chips (icon + label side
              // by side); wraps to a second line only on very narrow
              // devices instead of always reserving two rows.
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: [
                  // Ship Q3 (2026-05-26): см. kIsWeb branch выше — кнопка
                  // показывается только когда provider configured.
                  // Ship Q3a (2026-05-26): + backend capability gate.
                  if (!kIsWeb && _showGoogleButton)
                    _SocialAuthChip(
                      label: 'Google',
                      icon: Icons.g_mobiledata_rounded,
                      isLoading: _isGoogleLoading,
                      onTap: () {
                        if (_isLoading ||
                            _isTelegramLoading ||
                            _isVkLoading) {
                          return;
                        }
                        _signInWithGoogle();
                      },
                    ),
                  // Ship Q3a: Telegram/VK gated by backend availability.
                  // Null availability (legacy server либо load in-flight)
                  // → render (legacy behavior preserved).
                  if (_showTelegramButton)
                    _SocialAuthChip(
                      label: 'Telegram',
                      icon: Icons.send_rounded,
                      isLoading: _isTelegramLoading,
                      onTap: _isLoading || _isAnySocialLoading
                          ? null
                          : _startTelegramSignIn,
                    ),
                  if (_showVkButton)
                    _SocialAuthChip(
                      label: 'VK ID',
                      icon: Icons.alternate_email_rounded,
                      isLoading: _isVkLoading,
                      onTap: _isLoading || _isAnySocialLoading
                          ? null
                          : _startVkSignIn,
                    ),
                  // The mode toggle above already switches to register, and
                  // "Забыли?" sits inline with the password field, so the
                  // old duplicate "Создать аккаунт / У меня уже есть вход"
                  // and standalone "Пароль" links are gone — QR login is
                  // just another chip in this row, login-mode only.
                  if (_isLogin)
                    _SocialAuthChip(
                      label: 'QR-код',
                      icon: Icons.qr_code_2_rounded,
                      isLoading: false,
                      semanticsLabel: 'Войти по QR-коду',
                      onTap: _isLoading
                          ? null
                          : () => context.push('/auth/qr'),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              // При регистрации согласие — явный чекбокс выше; пассивная
              // строка остаётся только для входа.
              if (_isLogin)
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'Продолжая, вы соглашаетесь с ',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 14,
                      color: secondaryTextColor,
                    ),
                  ),
                  TextButton(
                    onPressed: () => GoRouter.of(context).push('/privacy'),
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(fontSize: 14),
                    ),
                    child: const Text('Политикой'),
                  ),
                  Text(
                    ' и ',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 14,
                      color: secondaryTextColor,
                    ),
                  ),
                  TextButton(
                    onPressed: () => GoRouter.of(context).push('/terms'),
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(fontSize: 14),
                    ),
                    child: const Text('Условиями'),
                  ),
                  Text(
                    '.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 14,
                      color: secondaryTextColor,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration(
    ThemeData theme, {
    required String label,
    required IconData icon,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      filled: true,
      fillColor:
          theme.colorScheme.surfaceContainerLowest.withValues(alpha: 0.9),
      // UX audit 2026-05-25 Screen 1.2 (ed62ba6): validation error
      // («Пароль должен содержать не менее 6 символов») truncated
      // на narrow screens к «Пароль должен содержать не мене...».
      // Flutter default `errorMaxLines: 1` причина. Allow до 2-х
      // строк wrap так every validator message helper читается
      // полностью (longest current is password message at ~42 chars
      // в Cyrillic, fits 2 lines comfortably на любом mobile width).
      errorMaxLines: 2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
        borderSide: BorderSide(
          color: theme.colorScheme.primary.withValues(alpha: 0.32),
        ),
      ),
    );
  }

  Widget _buildModeToggle(ThemeData theme) {
    // User-reported: «Вход / Регистрация tabs выезжают за rounded
    // edges». The outer pill had no clipBehavior, so the inner
    // active-tab AnimatedContainer painted over the parent's
    // rounded corners on the left and right edges. Clip the parent
    // so the active pill is bounded by the same stadium shape.
    return Container(
      padding: const EdgeInsets.all(4),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: BoxDecoration(
                color:
                    _isLogin ? theme.colorScheme.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: TextButton(
                onPressed: _isLoading ||
                        _isGoogleLoading ||
                        _isTelegramLoading ||
                        _isVkLoading ||
                        _isMaxLoading
                    ? null
                    : () {
                        _setMode(true);
                        _focusPrimaryField();
                      },
                child: Text(
                  'Вход',
                  style: TextStyle(
                    color: _isLogin ? Colors.white : theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: BoxDecoration(
                color:
                    !_isLogin ? theme.colorScheme.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: TextButton(
                onPressed: _isLoading ||
                        _isGoogleLoading ||
                        _isTelegramLoading ||
                        _isVkLoading ||
                        _isMaxLoading
                    ? null
                    : () {
                        _setMode(false);
                        _focusPrimaryField();
                      },
                child: Text(
                  'Регистрация',
                  style: TextStyle(
                    color: !_isLogin ? Colors.white : theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.feature,
    required this.compact,
  });

  final _AuthFeature feature;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 16,
        vertical: compact ? 12 : 14,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: compact ? 0.1 : 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(feature.icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(
            feature.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthFeature {
  const _AuthFeature({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;
}

/// Decorative tree silhouette painted into the auth hero, behind the
/// tagline. Lifted from the reference jsx SVG path: a single trunk that
/// branches in symmetric pairs upward, with small dots marking the
/// branch terminals — reads as a stylized family graph.
class _AuthHeroTreePainter extends CustomPainter {
  const _AuthHeroTreePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // Reference uses a 360x380 viewbox aligned to the bottom-center.
    // Project that into our actual canvas.
    final cx = w * 0.5;
    final baseY = h;
    final trunkTop = h * 0.37;

    final stroke = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final dot = Paint()..color = Colors.white;

    // Main trunk.
    canvas.drawLine(Offset(cx, baseY), Offset(cx, trunkTop), stroke);

    // Three pairs of branches, each going further up + outward.
    // pair 1 — wide spread, lowest branch fork
    final l1 = Offset(cx - w * 0.25, h * 0.42);
    final r1 = Offset(cx + w * 0.25, h * 0.42);
    canvas.drawPath(
      Path()
        ..moveTo(cx, h * 0.58)
        ..cubicTo(cx - w * 0.08, h * 0.53, l1.dx + w * 0.04, l1.dy + 12, l1.dx,
            l1.dy),
      stroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx, h * 0.58)
        ..cubicTo(cx + w * 0.08, h * 0.53, r1.dx - w * 0.04, r1.dy + 12, r1.dx,
            r1.dy),
      stroke,
    );

    // pair 2
    final l2 = Offset(cx - w * 0.17, h * 0.29);
    final r2 = Offset(cx + w * 0.17, h * 0.29);
    canvas.drawPath(
      Path()
        ..moveTo(cx, h * 0.45)
        ..cubicTo(cx - w * 0.06, h * 0.40, l2.dx + w * 0.03, l2.dy + 10, l2.dx,
            l2.dy),
      stroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx, h * 0.45)
        ..cubicTo(cx + w * 0.06, h * 0.40, r2.dx - w * 0.03, r2.dy + 10, r2.dx,
            r2.dy),
      stroke,
    );

    // pair 3 — top
    final l3 = Offset(cx - w * 0.085, h * 0.24);
    final r3 = Offset(cx + w * 0.085, h * 0.24);
    canvas.drawPath(
      Path()
        ..moveTo(cx, trunkTop)
        ..cubicTo(cx - w * 0.04, h * 0.33, l3.dx + w * 0.015, l3.dy + 8, l3.dx,
            l3.dy),
      stroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx, trunkTop)
        ..cubicTo(cx + w * 0.04, h * 0.33, r3.dx - w * 0.015, r3.dy + 8, r3.dx,
            r3.dy),
      stroke,
    );

    // Branch terminal dots.
    for (final node in [l1, r1, l2, r2, l3, r3, Offset(cx, trunkTop)]) {
      canvas.drawCircle(node, 5, dot);
    }
  }

  @override
  bool shouldRepaint(covariant _AuthHeroTreePainter oldDelegate) => false;
}

/// Horizontal icon+label pill used on the auth-screen "Быстрый вход"
/// row. Density chunk 18: replaces the old 60dp-circle-with-label-
/// below chip (~86dp tall, its own row) plus a separate "Войти по QR"
/// text button below it — that pair ate ~136dp for what is now one
/// 46dp-tall `Wrap` of these pills (icon + label side by side, single
/// line each, so labels never break into vertical letter columns the
/// way the pre-circle `OutlinedButton.icon` row used to).
class _SocialAuthChip extends StatelessWidget {
  const _SocialAuthChip({
    required this.label,
    required this.icon,
    required this.isLoading,
    required this.onTap,
    this.semanticsLabel,
  });

  final String label;
  final IconData icon;
  final bool isLoading;
  final VoidCallback? onTap;

  /// Override for the a11y announcement when [label] alone doesn't read
  /// naturally after "Войти через …" (e.g. QR-код → "Войти по QR-коду").
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final disabled = onTap == null;
    final ringColor = disabled
        ? scheme.outlineVariant.withValues(alpha: 0.45)
        : scheme.outlineVariant;
    final iconColor = disabled
        ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
        : scheme.onSurface;
    final textColor = disabled
        ? scheme.onSurfaceVariant.withValues(alpha: 0.6)
        : scheme.onSurface;
    return Semantics(
      label: semanticsLabel ?? 'Войти через $label',
      button: true,
      child: Material(
        color: Colors.transparent,
        shape: StadiumBorder(side: BorderSide(color: ringColor, width: 1.2)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                isLoading
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.primary,
                        ),
                      )
                    : Icon(icon, size: 20, color: iconColor),
                const SizedBox(width: 8),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 13,
                    color: textColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
