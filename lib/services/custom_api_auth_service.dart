import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../backend/models/user_facing_exception.dart';
import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/models/auth_providers_availability.dart';
import '../backend/models/custom_api_session.dart';
import '../backend/models/email_provider_mismatch.dart';
import '../backend/models/google_account_preview.dart';
import 'app_status_service.dart';
import 'invitation_service.dart';
import 'secure_session_storage.dart';
import '../utils/client_instance_id.dart';
import '../utils/device_descriptor.dart';
import '../utils/url_utils.dart';

class CustomApiException implements UserFacingApiException {
  const CustomApiException(this.message, {this.statusCode});

  @override
  final String message;
  @override
  final int? statusCode;

  @override
  String toString() => message;
}

class TelegramAuthCompletion {
  const TelegramAuthCompletion._({
    required this.status,
    this.linkCode,
    this.message,
    this.firstName,
    this.lastName,
    this.username,
    this.photoUrl,
  });

  const TelegramAuthCompletion.authenticated()
      : this._(status: TelegramAuthCompletionStatus.authenticated);

  const TelegramAuthCompletion.pendingLink({
    required String linkCode,
    String? message,
    String? firstName,
    String? lastName,
    String? username,
    String? photoUrl,
  }) : this._(
          status: TelegramAuthCompletionStatus.pendingLink,
          linkCode: linkCode,
          message: message,
          firstName: firstName,
          lastName: lastName,
          username: username,
          photoUrl: photoUrl,
        );

  const TelegramAuthCompletion.alreadyLinked({
    String? message,
  }) : this._(
          status: TelegramAuthCompletionStatus.alreadyLinked,
          message: message,
        );

  final TelegramAuthCompletionStatus status;
  final String? linkCode;
  final String? message;
  final String? firstName;
  final String? lastName;
  final String? username;
  final String? photoUrl;

  bool get isAuthenticated =>
      status == TelegramAuthCompletionStatus.authenticated;

  bool get isAlreadyLinked =>
      status == TelegramAuthCompletionStatus.alreadyLinked;
}

enum TelegramAuthCompletionStatus {
  authenticated,
  pendingLink,
  alreadyLinked,
}

class VkAuthCompletion {
  const VkAuthCompletion._({
    required this.status,
    this.linkCode,
    this.message,
    this.firstName,
    this.lastName,
    this.email,
    this.phoneNumber,
    this.photoUrl,
  });

  const VkAuthCompletion.authenticated()
      : this._(status: VkAuthCompletionStatus.authenticated);

  const VkAuthCompletion.pendingLink({
    required String linkCode,
    String? message,
    String? firstName,
    String? lastName,
    String? email,
    String? phoneNumber,
    String? photoUrl,
  }) : this._(
          status: VkAuthCompletionStatus.pendingLink,
          linkCode: linkCode,
          message: message,
          firstName: firstName,
          lastName: lastName,
          email: email,
          phoneNumber: phoneNumber,
          photoUrl: photoUrl,
        );

  const VkAuthCompletion.alreadyLinked({
    String? message,
  }) : this._(
          status: VkAuthCompletionStatus.alreadyLinked,
          message: message,
        );

  final VkAuthCompletionStatus status;
  final String? linkCode;
  final String? message;
  final String? firstName;
  final String? lastName;
  final String? email;
  final String? phoneNumber;
  final String? photoUrl;

  const VkAuthCompletion.requiresConsent()
      : this._(status: VkAuthCompletionStatus.requiresConsent);

  bool get isAuthenticated => status == VkAuthCompletionStatus.authenticated;

  bool get isAlreadyLinked => status == VkAuthCompletionStatus.alreadyLinked;

  bool get isRequiresConsent =>
      status == VkAuthCompletionStatus.requiresConsent;
}

enum VkAuthCompletionStatus {
  authenticated,
  pendingLink,
  alreadyLinked,
  requiresConsent,
}

/// Returned by a social sign-in when the backend refuses to create a BRAND-NEW
/// account without affirmative consent (152-ФЗ). The caller shows the consent
/// step and retries the same provider flow with `consentDocVersion`.
class SocialConsentRequired {
  const SocialConsentRequired({required this.provider});

  final String provider;
}

class MaxAuthCompletion {
  const MaxAuthCompletion._({
    required this.status,
    this.linkCode,
    this.message,
    this.firstName,
    this.lastName,
    this.username,
    this.photoUrl,
  });

  const MaxAuthCompletion.authenticated()
      : this._(status: MaxAuthCompletionStatus.authenticated);

  const MaxAuthCompletion.pendingLink({
    required String linkCode,
    String? message,
    String? firstName,
    String? lastName,
    String? username,
    String? photoUrl,
  }) : this._(
          status: MaxAuthCompletionStatus.pendingLink,
          linkCode: linkCode,
          message: message,
          firstName: firstName,
          lastName: lastName,
          username: username,
          photoUrl: photoUrl,
        );

  const MaxAuthCompletion.alreadyLinked({
    String? message,
  }) : this._(
          status: MaxAuthCompletionStatus.alreadyLinked,
          message: message,
        );

  final MaxAuthCompletionStatus status;
  final String? linkCode;
  final String? message;
  final String? firstName;
  final String? lastName;
  final String? username;
  final String? photoUrl;

  bool get isAuthenticated => status == MaxAuthCompletionStatus.authenticated;

  bool get isAlreadyLinked => status == MaxAuthCompletionStatus.alreadyLinked;
}

enum MaxAuthCompletionStatus {
  authenticated,
  pendingLink,
  alreadyLinked,
}

class CustomApiAuthService implements AuthServiceInterface {
  static const String _defaultTelegramBotUsername = 'RodnyaFamilyBot';

  CustomApiAuthService._({
    required http.Client httpClient,
    required SharedPreferences preferences,
    required BackendRuntimeConfig runtimeConfig,
    required InvitationService invitationService,
    AppStatusService? appStatusService,
    SecureSessionStorage? sessionStorage,
  })  : _httpClient = httpClient,
        _runtimeConfig = runtimeConfig,
        _invitationService = invitationService,
        _appStatusService = appStatusService,
        _sessionStorage = sessionStorage ??
            SecureSessionStorage(fallbackPreferences: preferences);

  final http.Client _httpClient;
  final BackendRuntimeConfig _runtimeConfig;
  final InvitationService _invitationService;
  final AppStatusService? _appStatusService;
  final SecureSessionStorage _sessionStorage;
  final StreamController<String?> _authStateController =
      StreamController<String?>.broadcast();

  CustomApiSession? _session;
  bool _isRefreshing = false;
  Future<void>? _refreshTask;

  /// 7.x replaced the `GoogleSignIn(...)` constructor with a singleton
  /// + a single `initialize(...)` call. We cache the init future so
  /// every concurrent caller awaits the same handshake instead of
  /// kicking off multiple inits.
  Future<void>? _googleInitFuture;

  /// Latest user the Google plugin reported via the authenticationEvents
  /// stream. There's no `currentUser` getter in 7.x — apps must subscribe
  /// to events and remember the last sign-in. Cleared on sign-out.
  GoogleSignInAccount? _lastGoogleAccount;
  StreamController<void>? _googleWebAuthenticationController;

  /// Hooks fired AFTER the backend has been told the user is signing
  /// out, but BEFORE the local session is cleared. Lets services
  /// like push registration drop their backend records while they
  /// still have a valid access token to authenticate the call.
  /// `unregisterAllPushDevicesForSignOut()` is the canonical hook.
  final List<Future<void> Function()> _preSignOutHooks =
      <Future<void> Function()>[];

  /// Register a pre-sign-out hook. Hooks run sequentially before
  /// `_clearSession`; failures in one hook do not block the others.
  void registerPreSignOutHook(Future<void> Function() hook) {
    if (!_preSignOutHooks.contains(hook)) {
      _preSignOutHooks.add(hook);
    }
  }

  void unregisterPreSignOutHook(Future<void> Function() hook) {
    _preSignOutHooks.remove(hook);
  }

  StreamSubscription<GoogleSignInAuthenticationEvent>?
      _googleWebAccountSubscription;

  static Future<CustomApiAuthService> create({
    http.Client? httpClient,
    SharedPreferences? preferences,
    BackendRuntimeConfig? runtimeConfig,
    InvitationService? invitationService,
    AppStatusService? appStatusService,
  }) async {
    final service = CustomApiAuthService._(
      httpClient: httpClient ?? http.Client(),
      preferences: preferences ?? await SharedPreferences.getInstance(),
      runtimeConfig: runtimeConfig ?? BackendRuntimeConfig.current,
      invitationService: invitationService ?? InvitationService(),
      appStatusService: appStatusService,
    );
    await service.restoreSession();
    return service;
  }

  String? get accessToken => _session?.accessToken;

  @override
  String? get currentUserId => _session?.userId;

  @override
  String? get currentUserEmail => _session?.email;

  @override
  String? get currentUserDisplayName => _session?.displayName;

  @override
  String? get currentUserPhotoUrl =>
      UrlUtils.normalizeImageUrl(_session?.photoUrl);

  @override
  List<String> get currentProviderIds => _session?.providerIds ?? const [];

  @override
  bool get currentRequiresOnboarding => _session?.requiresOnboarding ?? false;

  /// Ship Q1 (2026-05-25): mark local session's requiresOnboarding=false
  /// после wizard skip. Called by OnboardingController после successful
  /// POST /v1/me/onboarding-state/skip. Без этой mutation app router
  /// guards continue redirect'ить к /setup пока next session refresh
  /// (login/refresh) не подтянет updated value от backend.
  ///
  /// Persists через _saveSession чтобы restoreSession после app
  /// relaunch не undo'нет skip.
  @override
  Future<void> markOnboardingSkipped() async {
    final current = _session;
    if (current == null) return;
    if (!current.requiresOnboarding) return; // already cleared
    await _saveSession(
      current.copyWith(requiresOnboarding: false),
    );
    // Broadcast so UI subscribers (resume banner, router) re-evaluate.
    _authStateController.add(current.userId);
  }

  bool get isGoogleSignInConfigured =>
      _runtimeConfig.googleWebClientId.trim().isNotEmpty;

  /// Ship Q3a (2026-05-26): fetch backend provider availability flags.
  /// Hits public /health endpoint (no auth header). Result null → caller
  /// renders ВСЕ buttons (legacy server без authProviders field).
  @override
  Future<AuthProvidersAvailability?> fetchAuthProvidersAvailability() async {
    try {
      final response = await _httpClient.get(
        _buildUri('/health'),
      );
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) return null;
      return AuthProvidersAvailability.fromHealthJson(json);
    } catch (_) {
      return null;
    }
  }

  Stream<void> get googleWebAuthenticationEvents {
    _googleWebAuthenticationController ??= StreamController<void>.broadcast();
    _ensureGoogleWebAuthenticationListener();
    return _googleWebAuthenticationController!.stream;
  }

  Future<void> initializeGoogleWebAuthentication() async {
    if (!kIsWeb || !isGoogleSignInConfigured) {
      return;
    }
    _ensureGoogleWebAuthenticationListener();
    // 7.x dropped `isSignedIn()`. The corresponding kick-the-tires
    // call is `attemptLightweightAuthentication()` — it wakes up the
    // platform side and either restores an existing session via FedCM
    // (returning a Future) or returns null when the platform handles
    // the lifecycle via events. We don't care about the result here,
    // only that initialization runs.
    await _ensureGoogleInitialized();
    await GoogleSignIn.instance.attemptLightweightAuthentication();
  }

  Future<void> resetGoogleSelection() async {
    if (_googleInitFuture == null) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
    _lastGoogleAccount = null;
  }

  @override
  Stream<String?> get authStateChanges => _authStateController.stream;

  Future<void> restoreSession() async {
    try {
      final rawValue = await _sessionStorage.read();
      if (rawValue == null || rawValue.isEmpty) {
        _session = null;
        return;
      }

      final json = jsonDecode(rawValue);
      if (json is Map<String, dynamic>) {
        final session = CustomApiSession.fromJson(json);
        _session = session.userId.isEmpty ? null : session;
        if (_session != null) {
          _authStateController.add(_session!.userId);
        }
      }
    } catch (_) {
      _session = null;
      await _sessionStorage.delete();
    }
  }

  Future<void>? refreshSession() async {
    if (_isRefreshing) {
      return _refreshTask;
    }

    final refreshToken = _session?.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      await _clearSession(sessionExpired: true);
      throw const CustomApiException('Нет refresh token для обновления сессии');
    }

    _isRefreshing = true;
    _refreshTask = _performRefresh(refreshToken);

    try {
      await _refreshTask;
    } finally {
      _isRefreshing = false;
      _refreshTask = null;
    }
  }

  Future<void> _performRefresh(String refreshToken) async {
    try {
      final refreshPayload = await _withDeviceInfo({
        'refreshToken': refreshToken,
      });
      final response = await _httpClient.post(
        _buildUri('/v1/auth/refresh'),
        headers: _jsonHeaders(authenticated: false),
        body: jsonEncode(refreshPayload),
      );

      if (response.statusCode == 401 || response.statusCode == 403) {
        await _clearSession(sessionExpired: true);
        throw const CustomApiException('Сессия истекла. Войдите заново.');
      }

      final body = _decodeResponse(response);
      final newSession = _sessionFromResponse(body);
      await _saveSession(newSession);
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<Object?> registerWithEmail({
    required String email,
    required String password,
    required String name,
    String? consentDocVersion,
  }) {
    return _authenticate(
      path: '/v1/auth/register',
      payload: {
        'email': email,
        'password': password,
        'displayName': name,
        if (consentDocVersion != null && consentDocVersion.isNotEmpty)
          'consentDocVersion': consentDocVersion,
      },
    );
  }

  @override
  Future<Object?> loginWithEmail(String email, String password) {
    return _authenticate(
      path: '/v1/auth/login',
      payload: {
        'email': email,
        'password': password,
      },
    );
  }

  @override
  Future<Object?> signInWithGoogle({
    GoogleAccountConfirmCallback? confirm,
    String? consentDocVersion,
  }) {
    if (!isGoogleSignInConfigured) {
      throw const CustomApiException(
        'Google sign-in не настроен. Нужен RODNYA_GOOGLE_WEB_CLIENT_ID.',
      );
    }

    return _signInWithResolvedGoogleAccount(
      confirm: confirm,
      consentDocVersion: consentDocVersion,
    );
  }

  Future<void> linkGoogleIdentity() async {
    if (!isGoogleSignInConfigured) {
      throw const CustomApiException(
        'Google sign-in не настроен. Нужен RODNYA_GOOGLE_WEB_CLIENT_ID.',
      );
    }

    final account = kIsWeb
        ? await _resolveCurrentGoogleAccountForTokenExchange(
            interactiveCancelledMessage: 'Выберите Google-аккаунт.',
          )
        : await _resolveGoogleAccountForTokenExchange(
            interactiveCancelledMessage: 'Привязка Google отменена.',
          );
    final idToken = await _resolveGoogleIdToken(account);
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/auth/google/link',
      authenticated: true,
      body: {
        'idToken': idToken,
      },
    );
    final userJson = _extractUserJson(response);
    final providerIds = (userJson['providerIds'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .toList();
    if (providerIds.isNotEmpty) {
      await updateCachedSession(providerIds: providerIds);
    }
  }

  Future<Object?> _signInWithResolvedGoogleAccount({
    GoogleAccountConfirmCallback? confirm,
    String? consentDocVersion,
  }) async {
    final account = kIsWeb
        ? await _resolveCurrentGoogleAccountForTokenExchange(
            interactiveCancelledMessage: 'Выберите Google-аккаунт.',
          )
        : await _resolveGoogleAccountForTokenExchange(
            interactiveCancelledMessage: 'Вход через Google отменён.',
          );
    // Ship Q2 (2026-05-25): surface confirm dialog before backend
    // exchange. Артёма mama hit «silent wrong-account» — Google chooser
    // showed только Артёма's account, she tapped reflex, landed в его
    // production. Confirmation в нашем UI voice gives a chance to
    // catch this before session creation.
    if (confirm != null) {
      final preview = GoogleAccountPreview(
        email: (account.email).trim(),
        displayName: account.displayName?.trim().isNotEmpty == true
            ? account.displayName!.trim()
            : (account.email).trim(),
        photoUrl: account.photoUrl,
      );
      final decision = await confirm(preview);
      switch (decision) {
        case GoogleAccountConfirmDecision.confirm:
          break;
        case GoogleAccountConfirmDecision.switchAccount:
          // Force chooser: clear Google session + cached account so
          // next attempt prompts fresh. Recursive call respects same
          // confirm callback так пользователь сможет confirm второй
          // pick.
          try {
            await GoogleSignIn.instance.signOut();
          } catch (_) {
            // Best-effort — proceed even if signOut fails.
          }
          _lastGoogleAccount = null;
          return _signInWithResolvedGoogleAccount(
            confirm: confirm,
            consentDocVersion: consentDocVersion,
          );
        case GoogleAccountConfirmDecision.cancel:
          throw const CustomApiException('Вход через Google отменён.');
      }
    }
    final idToken = await _resolveGoogleIdToken(account);
    return _authenticate(
      path: '/v1/auth/google',
      payload: {
        'idToken': idToken,
        // This build understands a requiresConsent response, so it opts INTO
        // the consent gate. Old clients omit this flag and are not gated
        // (rollout safety). On the consent retry consentDocVersion is also set.
        'consentCapable': true,
        if (consentDocVersion != null && consentDocVersion.isNotEmpty)
          'consentDocVersion': consentDocVersion,
      },
    );
  }

  Future<GoogleSignInAccount> _resolveCurrentGoogleAccountForTokenExchange({
    required String interactiveCancelledMessage,
  }) async {
    _ensureGoogleWebAuthenticationListener();
    await _ensureGoogleInitialized();
    final cached = _lastGoogleAccount;
    if (cached != null) {
      return cached;
    }

    // 7.x replaced signInSilently with attemptLightweightAuthentication.
    // It can return null synchronously when the platform delivers
    // results via the events stream rather than the future (FedCM on
    // web behaves this way). In that case the caller should fall back
    // to interactive auth — same as the old `signInSilently` returning
    // null.
    final pending = GoogleSignIn.instance.attemptLightweightAuthentication();
    if (pending == null) {
      throw CustomApiException(interactiveCancelledMessage);
    }
    final account = await pending;
    if (account == null) {
      throw CustomApiException(interactiveCancelledMessage);
    }
    _lastGoogleAccount = account;
    return account;
  }

  Future<GoogleSignInAccount> _resolveGoogleAccountForTokenExchange({
    required String interactiveCancelledMessage,
  }) async {
    await _ensureGoogleInitialized();
    // On web, the cached account's id-token is short-lived and tied to
    // the active GIS session — re-using it leads to silent
    // "missing idToken" failures when the user picks Google on a stale
    // tab. Force a fresh sign-out + interactive flow there. On mobile
    // the cached account remains valid until the user explicitly signs
    // out, so we keep the fast path.
    if (kIsWeb) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {
        // Best-effort sign-out; continue even if it fails.
      }
      _lastGoogleAccount = null;
    } else {
      final cached = _lastGoogleAccount;
      if (cached != null) {
        return cached;
      }
    }

    try {
      // `authenticate` is the 7.x replacement for `signIn()`. It throws
      // on cancel rather than returning null, and the user's ID token
      // is obtained via `account.authentication` (now sync).
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: const ['email'],
      );
      _lastGoogleAccount = account;
      return account;
    } on GoogleSignInException catch (error, stackTrace) {
      // Verbose diagnostics for on-device verification — once we ship
      // 7.x to real users we want logs that pinpoint why a sign-in
      // failed without dumping a full stack into the UI. The `code`
      // tells us which path: canceled = user dismissed; interrupted =
      // OS killed it; uiUnavailable = platform isn't ready (web FedCM
      // not loaded yet, Android Play services missing); everything
      // else is a config/server problem we want to know about.
      debugPrint(
        '[GoogleSignIn 7.x] authenticate() failed — code=${error.code}, '
        'description=${error.description}',
      );
      if (error.code == GoogleSignInExceptionCode.canceled ||
          error.code == GoogleSignInExceptionCode.interrupted ||
          error.code == GoogleSignInExceptionCode.uiUnavailable) {
        throw CustomApiException(interactiveCancelledMessage);
      }
      // Fall-through → rethrow with stack so the upstream
      // `_appStatusService.reportError` path captures it.
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<String> _resolveGoogleIdToken(GoogleSignInAccount account) async {
    // 7.x made `account.authentication` a synchronous getter — drop
    // the historical `await`.
    final authentication = account.authentication;
    final idToken = authentication.idToken?.trim() ?? '';
    if (idToken.isEmpty) {
      // Distinct cases for on-device diagnostics:
      //  * web: usually means GIS hasn't been initialized with a
      //    matching client_id, OR the user is signed into Google
      //    in a way that doesn't yield an id_token (e.g. "use
      //    Continue As" without granting email scope).
      //  * mobile: serverClientId mismatch with backend audience
      //    is the #1 cause. Backend-side
      //    `verifyIdToken({audience: serverClientId})` will reject
      //    a token issued to the WEB client.
      debugPrint(
        '[GoogleSignIn 7.x] account.authentication returned an empty '
        'idToken — kIsWeb=$kIsWeb, '
        'configuredWebClientId=${_runtimeConfig.googleWebClientId.isNotEmpty}, '
        'accountId=${account.id}, accountEmail=${account.email}',
      );
      throw const CustomApiException(
        'Google не вернул idToken. Проверьте Web client ID и OAuth clients.',
      );
    }
    return idToken;
  }

  /// Lazily initialize the Google singleton. Idempotent — every caller
  /// awaits the same future. Must be called before any other
  /// GoogleSignIn.instance method per the 7.x contract.
  Future<void> _ensureGoogleInitialized() {
    return _googleInitFuture ??= GoogleSignIn.instance.initialize(
      // clientId: web-side client that the GIS library authenticates
      // with. serverClientId is not supported by google_sign_in_web,
      // so web obtains the idToken only through GIS authentication
      // events / renderButton. On mobile, serverClientId carries our
      // backend's expected audience for the id-token verification.
      clientId: kIsWeb ? _runtimeConfig.googleWebClientId : null,
      serverClientId: kIsWeb ? null : _runtimeConfig.googleWebClientId,
    );
  }

  void _ensureGoogleWebAuthenticationListener() {
    if (!kIsWeb || !isGoogleSignInConfigured) {
      return;
    }
    _googleWebAuthenticationController ??= StreamController<void>.broadcast();
    if (_googleWebAccountSubscription != null) return;
    // Kick the platform side awake and subscribe to the events stream
    // it produces on sign-in / sign-out. Replaces `onCurrentUserChanged`.
    unawaited(_ensureGoogleInitialized());
    _googleWebAccountSubscription =
        GoogleSignIn.instance.authenticationEvents.listen((event) {
      // The event is sealed but its sign-in subclass carries a
      // required `user` field — pattern-matching with an empty
      // parens form (`case ...SignIn():`) confuses the analyzer
      // about the constructor arity. Plain `is`-checks read the
      // same and avoid the analyzer noise.
      if (event is GoogleSignInAuthenticationEventSignIn) {
        _lastGoogleAccount = event.user;
        _googleWebAuthenticationController?.add(null);
      } else if (event is GoogleSignInAuthenticationEventSignOut) {
        _lastGoogleAccount = null;
      }
    });
  }

  String get telegramLoginStartUrl => buildTelegramStartUrl();

  String get telegramLinkStartUrl => buildTelegramStartUrl(linkMode: true);

  String get vkLoginStartUrl => buildVkStartUrl();

  String get vkLinkStartUrl => buildVkStartUrl(linkMode: true);

  String get maxLoginStartUrl => buildMaxStartUrl();

  String get maxLinkStartUrl => buildMaxStartUrl(linkMode: true);

  String buildTelegramStartUrl({bool linkMode = false}) {
    final appUri = Uri.parse(_runtimeConfig.publicAppUrl);
    final callbackUrl = _buildUri(
      '/v1/auth/telegram/callback',
      queryParameters: linkMode ? const {'intent': 'link'} : null,
    ).toString();
    return appUri.replace(
      path: '/telegram_login.html',
      queryParameters: <String, String>{
        'bot': _defaultTelegramBotUsername,
        'authUrl': callbackUrl,
      },
    ).toString();
  }

  String buildVkStartUrl({bool linkMode = false}) {
    return _buildUri(
      '/v1/auth/vk/start',
      queryParameters: linkMode ? const {'intent': 'link'} : null,
    ).toString();
  }

  String buildMaxStartUrl({bool linkMode = false}) {
    return _buildUri(
      '/v1/auth/max/start',
      queryParameters: linkMode ? const {'intent': 'link'} : null,
    ).toString();
  }

  /// Async variants that pre-resolve the device descriptor and embed it as
  /// query parameters on the OAuth start URL.  The OAuth in-app browser does
  /// not carry the X-Client-Instance-Id header that the Flutter HTTP client
  /// adds, so without these params the resulting session would have no
  /// device metadata and would land in /v1/auth/sessions as "Безымянное
  /// устройство".
  /// On Android the OAuth handshake opens the system browser, so the
  /// app needs the backend to redirect to a URL that the app's
  /// app_links listener picks up.
  ///
  /// We use the verified-https path
  /// (`https://rodnya-tree.ru/oauth/callback`) rather than the
  /// custom `rodnya://` scheme:
  ///
  ///   * On installs that have completed Verified App Links
  ///     handshake — i.e. Android pulled
  ///     `https://rodnya-tree.ru/.well-known/assetlinks.json` post-
  ///     install and matched our SHA-256 fingerprint — the OS
  ///     intercepts BEFORE the browser ever loads the URL. No
  ///     chooser dialog appears, no other app can register a
  ///     competing filter for the same `https://rodnya-tree.ru/oauth/*`
  ///     prefix. That's the OAuth deep-link spoofing fix.
  ///   * On installs that haven't picked up the verification (older
  ///     Android, fresh-install before the post-install handshake,
  ///     or a corrupted assetlinks fetch), the browser loads our
  ///     bridge page at `web/oauth/callback/index.html`. That page
  ///     auto-attempts a hop to the legacy `rodnya://oauth/callback?...`
  ///     custom scheme and renders an explicit "Open in Родня" /
  ///     "Install from RuStore" UI. The custom scheme intent filter
  ///     stays registered in the manifest as a safety net.
  ///
  /// On web we leave it null so the backend keeps using the public
  /// web URL.
  static const String _mobileOauthCallback =
      'https://rodnya-tree.ru/oauth/callback';
  String? _resolveOauthFinalRedirect() => kIsWeb ? null : _mobileOauthCallback;

  Future<String> resolveTelegramLoginStartUrl({bool linkMode = false}) async {
    final descriptor = await _resolveOauthDeviceDescriptor();
    final finalRedirect = _resolveOauthFinalRedirect();
    final appUri = Uri.parse(_runtimeConfig.publicAppUrl);
    final callbackUrl = _buildUri(
      '/v1/auth/telegram/callback',
      queryParameters: <String, String>{
        if (linkMode) 'intent': 'link',
        if (finalRedirect != null) 'finalRedirect': finalRedirect,
        ...descriptor,
      },
    ).toString();
    return appUri.replace(
      path: '/telegram_login.html',
      queryParameters: <String, String>{
        'bot': _defaultTelegramBotUsername,
        'authUrl': callbackUrl,
      },
    ).toString();
  }

  Future<String> resolveVkLoginStartUrl({
    bool linkMode = false,
    String? consentDocVersion,
  }) async {
    final descriptor = await _resolveOauthDeviceDescriptor();
    final finalRedirect = _resolveOauthFinalRedirect();
    return _buildUri(
      '/v1/auth/vk/start',
      queryParameters: <String, String>{
        if (linkMode) 'intent': 'link',
        if (finalRedirect != null) 'finalRedirect': finalRedirect,
        // This build understands the requires_consent handoff → opts into the
        // gate. Old clients omit this and are not gated (rollout safety).
        'consentCapable': 'true',
        // Set only on the re-start after the consent modal; carried through
        // the redirect dance so the callback can write it on account creation.
        if (consentDocVersion != null && consentDocVersion.isNotEmpty)
          'consentDocVersion': consentDocVersion,
        ...descriptor,
      },
    ).toString();
  }

  Future<String> resolveMaxLoginStartUrl({bool linkMode = false}) async {
    final descriptor = await _resolveOauthDeviceDescriptor();
    final finalRedirect = _resolveOauthFinalRedirect();
    return _buildUri(
      '/v1/auth/max/start',
      queryParameters: <String, String>{
        if (linkMode) 'intent': 'link',
        if (finalRedirect != null) 'finalRedirect': finalRedirect,
        ...descriptor,
      },
    ).toString();
  }

  Future<Map<String, String>> _resolveOauthDeviceDescriptor() async {
    final result = <String, String>{
      'instanceId': ClientInstanceId.current,
    };
    try {
      final descriptor = await DeviceDescriptorBuilder.resolve();
      result['deviceName'] = descriptor.deviceName;
      result['platform'] = descriptor.platform;
      result['appVersion'] = descriptor.appVersion;
    } catch (_) {
      // Fall through with just instanceId — backend will tolerate the rest
      // being null.
    }
    return result;
  }

  Future<TelegramAuthCompletion> exchangeTelegramAuthCode(String code) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/auth/telegram/exchange',
      body: {'code': code},
    );

    final status = response['status']?.toString() ?? '';
    if (status == 'authenticated') {
      final authPayload = response['auth'];
      if (authPayload is! Map<String, dynamic>) {
        throw const CustomApiException(
          'Telegram auth backend не вернул корректную сессию',
        );
      }
      final session = _sessionFromResponse(authPayload);
      await _saveSession(session);
      _authStateController.add(session.userId);
      await processPendingInvitation();
      return const TelegramAuthCompletion.authenticated();
    }

    if (status == 'pending_link') {
      final profile = response['telegramProfile'];
      final profileMap =
          profile is Map<String, dynamic> ? profile : const <String, dynamic>{};
      final linkCode = response['linkCode']?.toString() ?? '';
      if (linkCode.isEmpty) {
        throw const CustomApiException(
          'Telegram link code не был получен от backend',
        );
      }
      return TelegramAuthCompletion.pendingLink(
        linkCode: linkCode,
        message: response['message']?.toString(),
        firstName: profileMap['firstName']?.toString(),
        lastName: profileMap['lastName']?.toString(),
        username: profileMap['username']?.toString(),
        photoUrl: profileMap['photoUrl']?.toString(),
      );
    }

    if (status == 'already_linked') {
      return TelegramAuthCompletion.alreadyLinked(
        message: response['message']?.toString(),
      );
    }

    throw const CustomApiException(
      'Telegram auth backend вернул неизвестный статус',
    );
  }

  Future<void> linkPendingTelegramIdentity(String code) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/auth/telegram/link',
      authenticated: true,
      body: {'code': code},
    );
    final userJson = _extractUserJson(response);
    final providerIds = (userJson['providerIds'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .toList();
    if (providerIds.isNotEmpty) {
      await updateCachedSession(providerIds: providerIds);
    }
  }

  Future<VkAuthCompletion> exchangeVkAuthCode(String code) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/auth/vk/exchange',
      body: {'code': code},
    );

    final status = response['status']?.toString() ?? '';
    if (status == 'authenticated') {
      final authPayload = response['auth'];
      if (authPayload is! Map<String, dynamic>) {
        throw const CustomApiException(
          'VK ID auth backend не вернул корректную сессию',
        );
      }
      final session = _sessionFromResponse(authPayload);
      await _saveSession(session);
      _authStateController.add(session.userId);
      await processPendingInvitation();
      return const VkAuthCompletion.authenticated();
    }

    if (status == 'pending_link') {
      final profile = response['vkProfile'];
      final profileMap =
          profile is Map<String, dynamic> ? profile : const <String, dynamic>{};
      final linkCode = response['linkCode']?.toString() ?? '';
      if (linkCode.isEmpty) {
        throw const CustomApiException(
          'VK ID link code не был получен от backend',
        );
      }
      return VkAuthCompletion.pendingLink(
        linkCode: linkCode,
        message: response['message']?.toString(),
        firstName: profileMap['firstName']?.toString(),
        lastName: profileMap['lastName']?.toString(),
        email: profileMap['email']?.toString(),
        phoneNumber: profileMap['phoneNumber']?.toString(),
        photoUrl: profileMap['photoUrl']?.toString(),
      );
    }

    if (status == 'already_linked') {
      return VkAuthCompletion.alreadyLinked(
        message: response['message']?.toString(),
      );
    }

    // 152-ФЗ: brand-new VK account needs consent. Caller shows the consent
    // modal and re-runs the VK flow with consentDocVersion (code is one-time).
    if (status == 'requires_consent') {
      return const VkAuthCompletion.requiresConsent();
    }

    // Ship Bug B (2026-05-26): cross-provider email collision routed
    // через handoff payload (VK не returns 409 inline — flow is
    // browser-redirect + handoff exchange). Convert к same typed
    // exception as Google's 409 path so caller catches uniformly.
    if (status == 'email_provider_mismatch') {
      final mismatch = EmailProviderMismatch.fromJson(<String, dynamic>{
        'error': 'EMAIL_PROVIDER_MISMATCH',
        'email': response['email'],
        'existingProviders': response['existingProviders'],
        'message': response['message'],
      });
      if (mismatch != null) {
        throw EmailProviderMismatchException(mismatch);
      }
    }

    throw const CustomApiException(
      'VK ID auth backend вернул неизвестный статус',
    );
  }

  Future<void> linkPendingVkIdentity(String code) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/auth/vk/link',
      authenticated: true,
      body: {'code': code},
    );
    final userJson = _extractUserJson(response);
    final providerIds = (userJson['providerIds'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .toList();
    if (providerIds.isNotEmpty) {
      await updateCachedSession(providerIds: providerIds);
    }
  }

  Future<MaxAuthCompletion> exchangeMaxAuthCode(String code) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/auth/max/exchange',
      body: {'code': code},
    );

    final status = response['status']?.toString() ?? '';
    if (status == 'authenticated') {
      final authPayload = response['auth'];
      if (authPayload is! Map<String, dynamic>) {
        throw const CustomApiException(
          'MAX auth backend не вернул корректную сессию',
        );
      }
      final session = _sessionFromResponse(authPayload);
      await _saveSession(session);
      _authStateController.add(session.userId);
      await processPendingInvitation();
      return const MaxAuthCompletion.authenticated();
    }

    if (status == 'pending_link') {
      final profile = response['maxProfile'];
      final profileMap =
          profile is Map<String, dynamic> ? profile : const <String, dynamic>{};
      final linkCode = response['linkCode']?.toString() ?? '';
      if (linkCode.isEmpty) {
        throw const CustomApiException(
          'MAX link code не был получен от backend',
        );
      }
      return MaxAuthCompletion.pendingLink(
        linkCode: linkCode,
        message: response['message']?.toString(),
        firstName: profileMap['firstName']?.toString(),
        lastName: profileMap['lastName']?.toString(),
        username: profileMap['username']?.toString(),
        photoUrl: profileMap['photoUrl']?.toString(),
      );
    }

    if (status == 'already_linked') {
      return MaxAuthCompletion.alreadyLinked(
        message: response['message']?.toString(),
      );
    }

    throw const CustomApiException(
      'MAX auth backend вернул неизвестный статус',
    );
  }

  Future<void> linkPendingMaxIdentity(String code) async {
    final response = await _requestJson(
      method: 'POST',
      path: '/v1/auth/max/link',
      authenticated: true,
      body: {'code': code},
    );
    final userJson = _extractUserJson(response);
    final providerIds = (userJson['providerIds'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .toList();
    if (providerIds.isNotEmpty) {
      await updateCachedSession(providerIds: providerIds);
    }
  }

  @override
  Future<void> signOut() async {
    final currentToken = accessToken;

    // Run any pre-sign-out hooks WHILE we still have a valid access
    // token. Push-device cleanup is the canonical case: without
    // this the backend keeps the token registered forever and pushes
    // for the previous user keep landing on this device.
    for (final hook in List<Future<void> Function()>.from(_preSignOutHooks)) {
      try {
        await hook();
      } catch (error, stackTrace) {
        debugPrint('Pre-sign-out hook failed: $error\n$stackTrace');
      }
    }

    if (currentToken != null && currentToken.isNotEmpty) {
      try {
        await _httpClient.post(
          _buildUri('/v1/auth/logout'),
          headers: _jsonHeaders(authenticated: true),
        );
      } catch (_) {}
    }

    // Sign the Google singleton out only if we ever initialized it —
    // the 7.x contract forbids any other method call before
    // `initialize` resolves.
    if (_googleInitFuture != null) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {}
    }
    _lastGoogleAccount = null;

    await _clearSession();
  }

  Future<void> clearSessionLocally({bool sessionExpired = false}) async {
    await _clearSession(sessionExpired: sessionExpired);
  }

  @override
  Future<void> resetPassword(String email) async {
    await _requestJson(
      method: 'POST',
      path: '/v1/auth/password-reset/request',
      body: {'email': email},
    );
  }

  @override
  Future<void> confirmPasswordReset({
    required String token,
    required String newPassword,
  }) async {
    await _requestJson(
      method: 'POST',
      path: '/v1/auth/password-reset/confirm',
      body: {
        'token': token,
        'password': newPassword,
      },
    );
  }

  @override
  Future<void> deleteAccount([String? password]) async {
    await _requestJson(
      method: 'DELETE',
      path: '/v1/auth/account',
      authenticated: true,
      body: {
        if (password != null && password.isNotEmpty) 'password': password,
      },
    );
    await _clearSession();
  }

  @override
  Future<Map<String, dynamic>> checkProfileCompleteness() async {
    final session = _session;
    if (session == null) {
      return _signedOutProfileStatus();
    }

    try {
      final response = await _requestJson(
        method: 'GET',
        path: '/v1/auth/session',
        authenticated: true,
      );
      final refreshedSession = _sessionFromResponse(response);
      await _saveSession(refreshedSession);
      return _profileStatusMap(refreshedSession);
    } on CustomApiException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        await _clearSession(sessionExpired: true);
        return _signedOutProfileStatus();
      }
      final cachedSession = _session;
      if (cachedSession == null) {
        return _signedOutProfileStatus();
      }
      return _profileStatusMap(cachedSession);
    } catch (_) {
      final cachedSession = _session;
      if (cachedSession == null) {
        return _signedOutProfileStatus();
      }
      return _profileStatusMap(cachedSession);
    }
  }

  @override
  Future<void> processPendingInvitation() async {
    // Может ещё ничего не загрузилось с диска (cold-start после
    // OAuth-возврата). Подождём первого чтения, чтобы не
    // пропустить приглашение, которое только что вернулось из
    // персистного стора.
    await _invitationService.ready;

    if (_session == null || !_invitationService.hasPendingInvitation) {
      return;
    }

    final treeId = _invitationService.pendingTreeId;
    final personId = _invitationService.pendingPersonId;

    try {
      final response = await _requestJson(
        method: 'POST',
        path: '/v1/invitations/pending/process',
        authenticated: true,
        body: {
          'treeId': treeId,
          'personId': personId,
        },
      );

      String? treeName;
      final tree = response['tree'];
      if (tree is Map) {
        final raw = tree['name']?.toString().trim();
        if (raw != null && raw.isNotEmpty) {
          treeName = raw;
        }
      }

      _invitationService.clearPendingInvitation();
      _invitationService.emitOutcome(
        InvitationProcessOutcome.success(
          treeId: treeId ?? '',
          treeName: treeName ?? 'Семейная ветка',
          personId: personId ?? '',
        ),
      );
    } on CustomApiException catch (error) {
      // Ошибки больше не глушим в `catch (_) {}`. Если backend
      // вернул 404 («Профиль приглашения не найден») или 409 («Этот
      // профиль уже связан с другим пользователем»), юзеру важно
      // это видеть — иначе он, как Степа в чате, тапает по ссылке
      // и не понимает, почему ничего не происходит.
      debugPrint(
        '[CustomApiAuthService] processPendingInvitation API error: '
        'status=${error.statusCode}, message=${error.message}',
      );
      // Сохраняем pending для возможной повторной попытки на 5xx
      // (transient). На 4xx чистим, чтобы не повторять заведомо
      // невозможную операцию на каждом /-redirect'е.
      final isClientError =
          (error.statusCode ?? 0) >= 400 && (error.statusCode ?? 0) < 500;
      if (isClientError) {
        _invitationService.clearPendingInvitation();
      }
      _invitationService.emitOutcome(
        InvitationProcessOutcome.failure(
          errorCode: error.statusCode != null
              ? 'http_${error.statusCode}'
              : 'http_unknown',
          errorMessage: error.message,
          treeId: treeId,
          personId: personId,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[CustomApiAuthService] processPendingInvitation unexpected: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
      _invitationService.emitOutcome(
        InvitationProcessOutcome.failure(
          errorCode: 'unknown',
          errorMessage:
              'Не удалось обработать приглашение. Попробуйте ещё раз.',
          treeId: treeId,
          personId: personId,
        ),
      );
    }
  }

  @override
  Future<void> updateDisplayName(String displayName) async {
    final response = await _requestJson(
      method: 'PATCH',
      path: '/v1/profile/me',
      authenticated: true,
      body: {
        'displayName': displayName.trim(),
      },
    );

    final user = _extractUserJson(response);
    if (_session != null) {
      await updateCachedSession(
        displayName: user['displayName']?.toString() ?? displayName.trim(),
      );
    }
  }

  Future<void> updateCachedSession({
    String? email,
    String? displayName,
    String? photoUrl,
    List<String>? providerIds,
    bool? isProfileComplete,
    List<String>? missingFields,
  }) async {
    final currentSession = _session;
    if (currentSession == null) {
      return;
    }

    await _saveSession(
      currentSession.copyWith(
        email: email ?? currentSession.email,
        displayName: displayName ?? currentSession.displayName,
        photoUrl: photoUrl ?? currentSession.photoUrl,
        providerIds: providerIds ?? currentSession.providerIds,
        isProfileComplete:
            isProfileComplete ?? currentSession.isProfileComplete,
        missingFields: missingFields ?? currentSession.missingFields,
      ),
    );
  }

  Future<Object?> _authenticate({
    required String path,
    required Map<String, dynamic> payload,
  }) async {
    final enrichedPayload = await _withDeviceInfo(payload);
    final response = await _requestJson(
      method: 'POST',
      path: path,
      body: enrichedPayload,
    );
    // 152-ФЗ: backend refused to create a new social account without consent.
    // Surface a marker (not a session) so the caller shows the consent step
    // and retries with consentDocVersion. HTTP was 200, so no error was thrown.
    if (response['requiresConsent'] == true) {
      return SocialConsentRequired(
        provider: response['provider']?.toString() ?? '',
      );
    }
    final session = _sessionFromResponse(response);
    await _saveSession(session);
    _authStateController.add(session.userId);
    await processPendingInvitation();
    return session;
  }

  /// Adopt an auth payload that was minted server-side via QR login (or any
  /// other handoff): persist the session, fire auth-state listeners, and run
  /// post-login bookkeeping. Used by [QrLoginDisplayScreen] when the polled
  /// QR-login response flips to "approved".
  Future<void> acceptAuthPayload(Map<String, dynamic> authPayload) async {
    final session = _sessionFromResponse(authPayload);
    await _saveSession(session);
    _authStateController.add(session.userId);
    await processPendingInvitation();
  }

  Future<Map<String, dynamic>> _withDeviceInfo(
    Map<String, dynamic> payload,
  ) async {
    try {
      final descriptor = await DeviceDescriptorBuilder.resolve();
      return {
        ...payload,
        'deviceInfo': descriptor.toJson(),
      };
    } catch (error) {
      // Auth must keep working even if the platform channel hiccups; the
      // backend will simply lack device metadata for this row.
      return payload;
    }
  }

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    bool authenticated = false,
    Map<String, dynamic>? body,
  }) async {
    final uri = _buildUri(path);
    try {
      return await _executeRequest(method, uri, authenticated, body);
    } on CustomApiException catch (e) {
      if (authenticated && (e.statusCode == 401 || e.statusCode == 403)) {
        if (_session?.refreshToken != null) {
          try {
            await refreshSession();
            return await _executeRequest(method, uri, authenticated, body);
          } on CustomApiException {
            // Refresh hop reached the backend and got an HTTP error
            // back (any status). The original behavior here was to
            // unconditionally clear the session, and the existing
            // test fleet relies on that — preserve it.
            //
            // _performRefresh already calls _clearSession on its
            // 401/403 path; calling again here is a no-op for those
            // and a defensible "kick out on persistent backend
            // failure" for everything else (404 / 500 / 503 etc).
            await _clearSession(sessionExpired: true);
            rethrow;
          } catch (refreshError) {
            // Genuine network failure (SocketException / TimeoutException /
            // any non-CustomApi exception): refresh never reached the
            // backend, so we have NO signal that the session is
            // actually invalid. Keep the local session so the user
            // doesn't get bounced to the login screen the moment
            // their connection drops. The next online retry will
            // re-attempt refresh.
            debugPrint(
              'Token refresh failed without backend response — '
              'keeping session: $refreshError',
            );
            rethrow;
          }
        } else {
          await _clearSession(sessionExpired: true);
        }
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _executeRequest(
    String method,
    Uri uri,
    bool authenticated,
    Map<String, dynamic>? body,
  ) async {
    late http.Response response;
    final headers = _jsonHeaders(authenticated: authenticated);

    switch (method) {
      case 'GET':
        response = await _httpClient.get(uri, headers: headers);
        break;
      case 'POST':
        response = await _httpClient.post(
          uri,
          headers: headers,
          body: jsonEncode(body ?? const {}),
        );
        break;
      case 'PATCH':
        response = await _httpClient.patch(
          uri,
          headers: headers,
          body: jsonEncode(body ?? const {}),
        );
        break;
      case 'DELETE':
        final request = http.Request('DELETE', uri)
          ..headers.addAll(headers)
          ..body = jsonEncode(body ?? const {});
        final streamedResponse = await _httpClient.send(request);
        response = await http.Response.fromStream(streamedResponse);
        break;
      default:
        throw CustomApiException('Неподдерживаемый HTTP-метод: $method');
    }

    return _decodeResponse(response);
  }

  Future<void> _saveSession(CustomApiSession session) async {
    _session = session;
    await _sessionStorage.write(jsonEncode(session.toJson()));
    _appStatusService?.clearSessionIssue();
  }

  Future<void> _clearSession({bool sessionExpired = false}) async {
    _session = null;
    await _sessionStorage.delete();
    _authStateController.add(null);
    if (sessionExpired) {
      _appStatusService?.reportSessionExpired();
    } else {
      _appStatusService?.clearSessionIssue();
    }
  }

  Uri _buildUri(String path, {Map<String, String>? queryParameters}) {
    var base = _runtimeConfig.apiBaseUrl.replaceAll(
      RegExp(r'/$'),
      '',
    );
    final shouldForceHttps = base.startsWith('http://api.rodnya-tree.ru') ||
        base.startsWith('http://rodnya-tree.ru') ||
        base.startsWith('http://api.fodder-development.ru');
    if (shouldForceHttps) {
      base = 'https://${base.replaceFirst(RegExp(r'^http://'), '')}';
    }
    return Uri.parse('$base$path').replace(queryParameters: queryParameters);
  }

  Map<String, String> _jsonHeaders({bool authenticated = false}) {
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'X-Client-Instance-Id': ClientInstanceId.current,
      if (authenticated && accessToken != null)
        'Authorization': 'Bearer ${accessToken!}',
    };
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    if (response.body.isEmpty) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return const <String, dynamic>{};
      }
      throw CustomApiException(
        'Пустой ответ от backend',
        statusCode: response.statusCode,
      );
    }

    final dynamic decodedBody = jsonDecode(response.body);
    final bodyMap = decodedBody is Map<String, dynamic>
        ? decodedBody
        : <String, dynamic>{'data': decodedBody};

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return bodyMap;
    }

    // Ship Bug B (2026-05-26): structured 409 EMAIL_PROVIDER_MISMATCH
    // → typed exception so UI catches specifically и shows disambig
    // modal. Pre-Bug-B: generic CustomApiException(message) was
    // surfaced как red snackbar; insufficient guidance для user.
    if (response.statusCode == 409) {
      final mismatch = EmailProviderMismatch.fromJson(bodyMap);
      if (mismatch != null) {
        throw EmailProviderMismatchException(mismatch);
      }
    }

    final message = bodyMap['message']?.toString() ??
        bodyMap['error']?.toString() ??
        'Ошибка backend (${response.statusCode})';
    throw CustomApiException(message, statusCode: response.statusCode);
  }

  CustomApiSession _sessionFromResponse(Map<String, dynamic> response) {
    final sessionJson = _extractSessionJson(response);
    final userJson = _extractUserJson(response);
    final profileStatus = _extractProfileStatus(response);
    final providerIds = (userJson['providerIds'] as List<dynamic>? ??
            sessionJson['providerIds'] as List<dynamic>? ??
            const [])
        .map((value) => value.toString())
        .toList();

    final session = CustomApiSession(
      accessToken: sessionJson['accessToken']?.toString() ??
          response['accessToken']?.toString() ??
          '',
      refreshToken: sessionJson['refreshToken']?.toString() ??
          response['refreshToken']?.toString(),
      userId: userJson['id']?.toString() ??
          sessionJson['userId']?.toString() ??
          response['userId']?.toString() ??
          '',
      email: userJson['email']?.toString() ?? response['email']?.toString(),
      displayName: userJson['displayName']?.toString() ??
          response['displayName']?.toString(),
      photoUrl: userJson['photoUrl']?.toString() ??
          userJson['photoURL']?.toString() ??
          response['photoUrl']?.toString() ??
          response['photoURL']?.toString(),
      providerIds: providerIds,
      isProfileComplete: profileStatus['isComplete'] == true,
      missingFields:
          (profileStatus['missingFields'] as List<dynamic>? ?? const [])
              .map((value) => value.toString())
              .toList(),
      // Phase 6 chunk 4a: backend signals post-signup redirect requirement.
      // Flag читается top-level либо вложен в session JSON. Если response
      // не carries the field at all (e.g. legacy endpoints, либо backend
      // doesn't include it on refresh path) — preserve **existing**
      // _session.requiresOnboarding значение. Без preservation, refresh
      // через `/v1/auth/session` overwrites flag к false и breaks
      // post-signup /setup redirect logic (bug discovered 2026-05-18).
      requiresOnboarding: response.containsKey('requiresOnboarding')
          ? response['requiresOnboarding'] == true
          : sessionJson.containsKey('requiresOnboarding')
              ? sessionJson['requiresOnboarding'] == true
              : (_session?.requiresOnboarding ?? false),
    );

    if (session.accessToken.isEmpty || session.userId.isEmpty) {
      throw const CustomApiException(
        'Backend не вернул session/access token для customApi auth',
      );
    }

    return session;
  }

  Map<String, dynamic> _extractSessionJson(Map<String, dynamic> response) {
    final sessionValue = response['session'];
    if (sessionValue is Map<String, dynamic>) {
      return sessionValue;
    }
    return response;
  }

  Map<String, dynamic> _extractUserJson(Map<String, dynamic> response) {
    final sessionJson = _extractSessionJson(response);
    final userValue = response['user'] ?? sessionJson['user'];
    if (userValue is Map<String, dynamic>) {
      return userValue;
    }
    return sessionJson;
  }

  Map<String, dynamic> _extractProfileStatus(Map<String, dynamic> response) {
    final sessionJson = _extractSessionJson(response);
    final statusValue =
        response['profileStatus'] ?? sessionJson['profileStatus'];
    if (statusValue is Map<String, dynamic>) {
      return statusValue;
    }
    return const <String, dynamic>{};
  }

  Map<String, dynamic> _profileStatusMap(CustomApiSession session) {
    return {
      'isComplete': session.isProfileComplete,
      'missingFields': session.missingFields,
    };
  }

  Map<String, dynamic> _signedOutProfileStatus() {
    return {
      'isComplete': false,
      'missingFields': ['auth'],
    };
  }

  @override
  String describeError(Object error) {
    if (error is CustomApiException) {
      final normalizedMessage = error.message.trim();
      final lowerMessage = normalizedMessage.toLowerCase();

      if (lowerMessage.contains('socketexception') ||
          lowerMessage.contains('failed host lookup') ||
          lowerMessage.contains('connection refused') ||
          lowerMessage.contains('connection reset') ||
          lowerMessage.contains('network is unreachable') ||
          lowerMessage.contains('timed out')) {
        return 'Не удалось подключиться к серверу. Проверьте интернет и попробуйте ещё раз.';
      }

      if (error.statusCode == 401 || error.statusCode == 403) {
        if (lowerMessage.contains('email') || lowerMessage.contains('парол')) {
          return 'Не удалось войти. Проверьте email и пароль.';
        }
        final sanitized = _sanitizeErrorMessage(normalizedMessage);
        return sanitized.isEmpty ? _loginFallback : sanitized;
      }
      // 152-ФЗ: /v1/auth/register отвечает 400 {requiresConsent: true},
      // когда consentDocVersion пуст (прямой вызов API мимо чекбокса —
      // экран его всегда шлёт, см. auth_screen._submit). Явная ветка нужна,
      // потому что общий catch-all ниже возвращает сообщение сервера
      // as-is, а describeUserFacingError считает «сообщение не изменилось
      // относительно raw» техническим и подменяет его на общий fallback
      // («Не удалось войти...») — пользователь не понял бы, что делать.
      if (error.statusCode == 400 && lowerMessage.contains('согласие')) {
        return 'Нужно подтвердить согласие на обработку персональных '
            'данных, чтобы создать аккаунт.';
      }
      if (error.statusCode == 409) {
        if (lowerMessage.contains('email') &&
            lowerMessage.contains('существ')) {
          return 'Аккаунт с таким email уже существует.';
        }
        final sanitized = _sanitizeErrorMessage(normalizedMessage);
        return sanitized.isEmpty ? _loginFallback : sanitized;
      }
      if (error.statusCode == 429) {
        return 'Слишком много попыток. Попробуйте чуть позже.';
      }
      if ((error.statusCode ?? 0) >= 500) {
        return 'Сервис временно недоступен. Попробуйте чуть позже.';
      }

      // For other status codes return the sanitized message or empty string
      // so the caller's context-specific fallback is used.
      final sanitized = _sanitizeErrorMessage(normalizedMessage);
      return sanitized.isEmpty ? _loginFallback : sanitized;
    }

    final rawMessage = error.toString();
    if (rawMessage.startsWith('Exception: ')) {
      return _sanitizeErrorMessage(rawMessage.substring('Exception: '.length));
    }
    return _sanitizeErrorMessage(rawMessage);
  }

  /// Returns `''` for empty or clearly-technical messages so the **caller** can
  /// substitute a context-appropriate fallback (e.g. photo, chat, etc.).
  /// Auth-specific callers that need the login string should handle the `''`
  /// case themselves — see [describeError].
  String _sanitizeErrorMessage(String message) {
    final trimmed = message.trim();
    final lowerMessage = trimmed.toLowerCase();

    if (trimmed.isEmpty) {
      return '';
    }
    if (lowerMessage.startsWith('error:') ||
        lowerMessage.contains('typeerror') ||
        lowerMessage.contains('stack trace') ||
        lowerMessage.contains('exception:') ||
        lowerMessage.contains('status code') ||
        lowerMessage.contains('backend (')) {
      return '';
    }

    return trimmed;
  }

  static const _loginFallback =
      'Не удалось выполнить вход. Попробуйте ещё раз.';
}
