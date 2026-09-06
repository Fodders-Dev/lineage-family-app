import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
        FontLoader,
        rootBundle,
        SystemChrome,
        SystemUiMode,
        SystemUiOverlayStyle;
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:country_picker/country_picker.dart';
import 'providers/theme_provider.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'navigation/app_router.dart';
import 'navigation/deep_link_handler.dart';
import 'services/local_storage_service.dart';
import 'utils/client_instance_id.dart';
import 'package:get_it/get_it.dart';
import 'providers/tree_provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/scheduler.dart'; // Для postFrameCallback
import 'package:shared_preferences/shared_preferences.dart';
import 'backend/interfaces/app_startup_service_interface.dart';
import 'backend/interfaces/auth_service_interface.dart';
import 'backend/interfaces/dynamic_link_service_interface.dart';
import 'backend/interfaces/story_service_interface.dart';
import 'backend/backend_runtime_config.dart';
import 'services/app_startup_service.dart';
import 'services/call_coordinator_service.dart';
import 'services/custom_api_diagnostics_service.dart';
import 'services/invitation_service.dart';
import 'startup/startup_failure_policy.dart';
import 'startup/app_warmup_coordinator.dart';
import 'widgets/app_update_ui.dart';
import 'widgets/call_runtime_host.dart';
import 'widgets/startup_failure_view.dart';
import 'utils/e2e_state_bridge.dart';
import 'utils/startup_trace.dart';

// --- Переменная для хранения SnackBarContext ---
// Используем GlobalKey, чтобы получить доступ к ScaffoldMessenger
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
Object? _e2eSemanticsHandle;
bool _clientDiagnosticsInstalled = false;

void main() async {
  // S-fanout (05.09.2026): t=0 для [StartupTrace] — максимально рано,
  // до любого сетевого вызова, чтобы debug-лог `[startup] +NNNms GET
  // ...` в adb logcat отражал реальную холодную загрузку, а не время
  // от первого запроса.
  StartupTrace.markAppStart();
  WidgetsFlutterBinding.ensureInitialized();

  // Cap the Flutter image cache. Default Flutter limits are 1000 images
  // / 100 MB, both of which are too generous for a chat-heavy app —
  // a single conversation with photo attachments easily fills the
  // bytes cap and OOM-kills mid-range Android devices. 200 images /
  // 64 MB is roomy enough for one screen of carousels but caps RAM
  // at a level Samsung Galaxy A-series and similar 3-4 GB devices
  // can tolerate without GC stalls.
  PaintingBinding.instance.imageCache
    ..maximumSize = 200
    ..maximumSizeBytes = 64 * 1024 * 1024;

  // Edge-to-edge on Android: transparent system bars overlap the
  // Flutter canvas, so backgrounds (warm cream / dark olive) reach
  // the screen edges. Status / nav bar icon brightness is then driven
  // per-frame via AnnotatedRegion in MaterialApp.builder so it tracks
  // theme changes without a frame of mismatched icons.
  if (!kIsWeb) {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
  }

  // Warm up the persistent device id before any auth call can fire so the
  // backend always sees the stable id rather than a transient uuid.
  await ClientInstanceId.ensureInitialized();

  // On web these fonts are network assets and blocking runApp on them extends
  // the blank startup window. Let the app paint with system fonts first; the
  // preloader swaps the brand fonts in as soon as they arrive. Native keeps the
  // old blocking preload because assets are local and first-frame stability is
  // more valuable there.
  if (kIsWeb) {
    unawaited(_preloadBrandFonts());
  } else {
    await _preloadBrandFonts();
  }

  await _bootstrapAndRunApp();
}

Future<void> _preloadBrandFonts() async {
  Future<void> loadOne(String family, List<String> assetPaths) async {
    final loader = FontLoader(family);
    for (final path in assetPaths) {
      loader.addFont(rootBundle.load(path));
    }
    try {
      await loader.load();
    } catch (error) {
      debugPrint('Font preload failed for $family: $error');
    }
  }

  await Future.wait([
    loadOne('Manrope', const ['assets/fonts/Manrope-VariableFont_wght.ttf']),
    loadOne('Lora', const [
      'assets/fonts/Lora-VariableFont_wght.ttf',
      'assets/fonts/Lora-Italic-VariableFont_wght.ttf',
    ]),
    loadOne('NotoSans', const ['assets/fonts/NotoSans-VariableFont.ttf']),
  ]);
}

Future<void> _bootstrapAndRunApp() async {
  try {
    if (!GetIt.I.isRegistered<AppStartupServiceInterface>()) {
      GetIt.I
          .registerSingleton<AppStartupServiceInterface>(AppStartupService());
    }
    await GetIt.I<AppStartupServiceInterface>().initializeForeground();
    _installClientDiagnostics();

    final localStorageService = GetIt.I<LocalStorageService>();
    final runtimeConfig = BackendRuntimeConfig.current;

    if (kIsWeb && runtimeConfig.enableE2e) {
      _e2eSemanticsHandle ??= WidgetsBinding.instance.ensureSemantics();
    }

    // На web не тянем .env как asset, чтобы не получать лишний 404 в консоли.
    if (!kIsWeb && kDebugMode) {
      try {
        await dotenv.load(fileName: ".env");
        debugPrint('.env file loaded successfully.');
      } catch (e) {
        debugPrint(
          'Error loading .env file: $e. Ensure the file exists at the project root and is listed in pubspec.yaml assets.',
        );
      }
    }

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(
            create: (_) => GetIt.I<TreeProvider>(),
          ),
          Provider<LocalStorageService>.value(value: localStorageService),
        ],
        child: const MyApp(),
      ),
    );
  } catch (error, stackTrace) {
    final canResetSession = await _shouldOfferSessionReset(error);
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'rodnya_bootstrap',
        context: ErrorDescription('while starting the application'),
      ),
    );
    runApp(
      _StartupFailureApp(
        error: error,
        stackTrace: stackTrace,
        onRetry: _bootstrapAndRunApp,
        onResetSessionAndRetry:
            canResetSession ? _resetRecoverableSessionAndRetry : null,
        canResetSession: canResetSession,
      ),
    );
  }
}

void _installClientDiagnostics() {
  if (_clientDiagnosticsInstalled ||
      !GetIt.I.isRegistered<CustomApiDiagnosticsService>()) {
    return;
  }
  _clientDiagnosticsInstalled = true;
  final diagnostics = GetIt.I<CustomApiDiagnosticsService>();
  final previousFlutterOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (previousFlutterOnError != null) {
      previousFlutterOnError(details);
    } else {
      FlutterError.presentError(details);
    }
    unawaited(
      diagnostics.capture(
        type: 'flutter_error',
        message: details.exceptionAsString(),
        error: details.exception,
        stackTrace: details.stack,
        context: <String, dynamic>{
          'library': details.library,
          'context': details.context?.toString(),
        },
      ),
    );
  };

  final previousPlatformOnError = ui.PlatformDispatcher.instance.onError;
  ui.PlatformDispatcher.instance.onError = (error, stackTrace) {
    unawaited(
      diagnostics.capture(
        type: 'platform_error',
        message: error.toString(),
        error: error,
        stackTrace: stackTrace,
      ),
    );
    return previousPlatformOnError?.call(error, stackTrace) ?? false;
  };
}

Future<void> _resetRecoverableSessionAndRetry() async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.remove('custom_api_session_v1');
  await _bootstrapAndRunApp();
}

Future<bool> _shouldOfferSessionReset(Object error) async {
  if (looksLikeRecoverableSessionIssue(error)) {
    return true;
  }

  final preferences = await SharedPreferences.getInstance();
  return preferences.containsKey('custom_api_session_v1');
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final AppRouter _appRouter;
  DeepLinkHandler? _deepLinkHandler;
  VoidCallback? _routerE2EListener;
  StreamSubscription<InvitationProcessOutcome>? _invitationOutcomesSub;

  @override
  void initState() {
    super.initState();
    _appRouter = AppRouter();
    _configureE2EBridge();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !GetIt.I.isRegistered<AppWarmupCoordinator>()) {
        return;
      }
      unawaited(
        GetIt.I<AppWarmupCoordinator>().start(scaffoldMessengerKey),
      );
    });
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !GetIt.I.isRegistered<DynamicLinkServiceInterface>()) {
        return;
      }
      _deepLinkHandler = DeepLinkHandler(router: _appRouter.router);
      unawaited(_deepLinkHandler!.initDynamicLinks());
    });

    // Subscribe to invitation outcomes ASAP so we don't miss the
    // event that fires right after OAuth-callback resumes the app.
    _subscribeToInvitationOutcomes();
  }

  @override
  void dispose() {
    final routerE2EListener = _routerE2EListener;
    if (routerE2EListener != null) {
      _appRouter.router.routerDelegate.removeListener(routerE2EListener);
    }
    if (GetIt.I.isRegistered<AppWarmupCoordinator>()) {
      unawaited(GetIt.I<AppWarmupCoordinator>().dispose());
    }
    unawaited(_invitationOutcomesSub?.cancel());
    _invitationOutcomesSub = null;
    _deepLinkHandler?.dispose();
    _deepLinkHandler = null;
    super.dispose();
  }

  /// Listen to invitation-link processing results so the user gets
  /// visible feedback when they tap an invite URL. Without this the
  /// brother (Степа in the bug report) saw nothing happen — the API
  /// call was either silently swallowed or successfully ran but the
  /// branch picker never refreshed to show the newly-joined tree.
  void _subscribeToInvitationOutcomes() {
    if (!GetIt.I.isRegistered<InvitationService>()) {
      return;
    }
    final service = GetIt.I<InvitationService>();
    _invitationOutcomesSub = service.outcomes.listen(_handleInvitationOutcome);
  }

  Future<void> _handleInvitationOutcome(
    InvitationProcessOutcome outcome,
  ) async {
    final messengerState = scaffoldMessengerKey.currentState;

    if (outcome.isSuccess) {
      // Refresh the tree list so the branch switcher chip shows the
      // newly-joined tree, then auto-select it — the user clicked a
      // link to JOIN this specific family, so dropping them on it
      // is the obviously-right behavior.
      if (GetIt.I.isRegistered<TreeProvider>()) {
        final treeProvider = GetIt.I<TreeProvider>();
        try {
          await treeProvider.refreshAvailableTrees();
          if (outcome.treeId != null && outcome.treeId!.isNotEmpty) {
            await treeProvider.selectTree(
              outcome.treeId,
              outcome.treeName,
            );
          }
        } catch (error, stackTrace) {
          debugPrint(
            'Failed to refresh trees after invitation: $error',
          );
          debugPrintStack(stackTrace: stackTrace);
        }
      }
      messengerState?.showSnackBar(
        SnackBar(
          // Имя ветки в именительном после двоеточия — «к Близкие друзья»
          // склонять произвольные названия нельзя (смоук 2026-07-04).
          content: Text(
            outcome.treeName == null
                ? 'Вы присоединились'
                : 'Вы присоединились: «${outcome.treeName}»',
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    } else {
      // Map common backend errors to user-friendly text. Always
      // surface SOMETHING — never the silent failure that left
      // Степа staring at his old tree wondering what happened.
      final code = outcome.errorCode ?? 'unknown';
      String message;
      if (code == 'http_409') {
        message = 'Этот профиль в дереве уже привязан к другому пользователю.';
      } else if (code == 'http_404') {
        message = 'Приглашение устарело. Попросите отправить новую ссылку.';
      } else if (code == 'http_400') {
        message = 'Ссылка-приглашение повреждена.';
      } else {
        message = outcome.errorMessage ??
            'Не удалось обработать приглашение. Попробуйте ещё раз.';
      }
      messengerState?.showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  void _configureE2EBridge() {
    if (!kIsWeb || !BackendRuntimeConfig.current.enableE2e) {
      return;
    }

    E2EStateBridge.initialize(
      onLogin: _handleE2ELogin,
      onLogout: _handleE2ELogout,
      onStatus: _collectE2EStatus,
      onNavigate: _handleE2ENavigate,
      onOpenTree: _handleE2EOpenTree,
      onOpenAddRelative: _handleE2EOpenAddRelative,
      onOpenStoryViewer: _handleE2EOpenStoryViewer,
    );

    _routerE2EListener ??= _publishAppE2EState;
    _appRouter.router.routerDelegate.addListener(_routerE2EListener!);
    _publishAppE2EState();
  }

  Future<Map<String, dynamic>> _handleE2ELogin(
    String email,
    String password,
    String? targetPath,
  ) async {
    await GetIt.I<AuthServiceInterface>().loginWithEmail(email, password);
    final targetTreeId = _extractTreeIdFromPath(targetPath);
    final targetTreeName = _extractTreeNameFromPath(targetPath);
    await _syncTreeProviderAfterLogin(
      preferredTreeId: targetTreeId,
      preferredTreeName: targetTreeName,
    );
    await _navigateE2E(
      targetPath != null && targetPath.isNotEmpty ? targetPath : '/',
    );
    return _collectE2EStatus();
  }

  Future<Map<String, dynamic>> _handleE2ELogout(String? targetPath) async {
    await _navigateE2E('/__e2e__/idle');
    await Future<void>.delayed(const Duration(milliseconds: 220));
    await GetIt.I<AuthServiceInterface>().signOut();
    await _clearTreeProviderSelection();
    await _navigateE2E(
      targetPath != null && targetPath.isNotEmpty ? targetPath : '/login',
    );
    return _collectE2EStatus();
  }

  Future<Map<String, dynamic>> _collectE2EStatus() async {
    final authService = GetIt.I<AuthServiceInterface>();
    final treeProvider =
        GetIt.I.isRegistered<TreeProvider>() ? GetIt.I<TreeProvider>() : null;
    final isLoggedIn = authService.currentUserId != null;
    final profileStatus = isLoggedIn
        ? await authService.checkProfileCompleteness()
        : <String, dynamic>{
            'isComplete': false,
            'missingFields': const <String>['auth'],
          };

    return <String, dynamic>{
      'isLoggedIn': authService.currentUserId != null,
      'currentUserId': authService.currentUserId,
      'currentUserEmail': authService.currentUserEmail,
      'currentUserDisplayName': authService.currentUserDisplayName,
      'selectedTreeId': treeProvider?.selectedTreeId,
      'selectedTreeName': treeProvider?.selectedTreeName,
      'selectedTreeKind': treeProvider?.selectedTreeKind?.name,
      'profileStatus': profileStatus,
      'currentUrl': Uri.base.toString(),
      'currentPath': Uri.base.path,
      'currentHash': Uri.base.fragment,
    };
  }

  Future<Map<String, dynamic>> _handleE2ENavigate(String path) async {
    if (path.isEmpty) {
      return _collectE2EStatus();
    }
    return _navigateE2E(path);
  }

  Future<Map<String, dynamic>> _handleE2EOpenTree(
    String treeId,
    String? treeName,
    String? targetPath,
  ) async {
    await _selectTreeForE2E(treeId, treeName);
    final resolvedTarget = targetPath?.isNotEmpty == true
        ? targetPath!
        : _buildTreeRoute(treeId, treeName);
    return _navigateE2E(resolvedTarget);
  }

  Future<Map<String, dynamic>> _handleE2EOpenAddRelative({
    required String treeId,
    String? contextPersonId,
    String? relationType,
    bool quickAddMode = false,
  }) async {
    await _selectTreeForE2E(treeId, null);
    final uri = Uri(
      path: '/relatives/add/$treeId',
      queryParameters: <String, String>{
        if (contextPersonId != null && contextPersonId.isNotEmpty)
          'contextPersonId': contextPersonId,
        if (relationType != null && relationType.isNotEmpty)
          'relationType': relationType,
        if (quickAddMode) 'quickAddMode': '1',
      },
    );
    return _navigateE2E(uri.toString());
  }

  Future<Map<String, dynamic>> _handleE2EOpenStoryViewer({
    String? treeId,
    String? authorId,
  }) async {
    final authService = GetIt.I<AuthServiceInterface>();
    final resolvedAuthorId = authorId?.trim().isNotEmpty == true
        ? authorId!.trim()
        : authService.currentUserId;
    final selectedTreeId = GetIt.I.isRegistered<TreeProvider>()
        ? GetIt.I<TreeProvider>().selectedTreeId
        : null;
    final resolvedTreeId =
        treeId?.trim().isNotEmpty == true ? treeId!.trim() : selectedTreeId;

    if (resolvedTreeId == null || resolvedTreeId.isEmpty) {
      throw StateError('No tree selected for story viewer');
    }
    if (resolvedAuthorId == null || resolvedAuthorId.isEmpty) {
      throw StateError('No author resolved for story viewer');
    }

    await _selectTreeForE2E(resolvedTreeId, null);
    final stories = await GetIt.I<StoryServiceInterface>().getStories(
      treeId: resolvedTreeId,
      authorId: resolvedAuthorId,
    );
    if (stories.isEmpty) {
      throw StateError('No stories available for author $resolvedAuthorId');
    }

    final route = '/stories/view/$resolvedTreeId/$resolvedAuthorId';
    final status = await _collectE2EStatus();
    return <String, dynamic>{
      ...status,
      'storyViewerRequested': true,
      'storyViewerRoute': route,
      'storyCount': stories.length,
      'currentStoryId': stories.first.id,
    };
  }

  void _publishAppE2EState() {
    if (!mounted || !kIsWeb || !BackendRuntimeConfig.current.enableE2e) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      final status = await _collectE2EStatus();
      if (!mounted) {
        return;
      }
      E2EStateBridge.publish(
        screen: 'app',
        state: status,
      );
    });
  }

  Future<Map<String, dynamic>> _navigateE2E(String path) async {
    _appRouter.router.go(path);
    await Future<void>.delayed(const Duration(milliseconds: 180));
    _publishAppE2EState();
    return _collectE2EStatus();
  }

  Future<void> _syncTreeProviderAfterLogin({
    String? preferredTreeId,
    String? preferredTreeName,
  }) async {
    if (!GetIt.I.isRegistered<TreeProvider>()) {
      return;
    }

    final treeProvider = GetIt.I<TreeProvider>();
    if (preferredTreeId != null && preferredTreeId.isNotEmpty) {
      await treeProvider.selectTree(preferredTreeId, preferredTreeName);
      return;
    }

    await treeProvider.clearSelection();
    await treeProvider.selectDefaultTreeIfNeeded();
  }

  Future<void> _clearTreeProviderSelection() async {
    if (!GetIt.I.isRegistered<TreeProvider>()) {
      return;
    }
    await GetIt.I<TreeProvider>().clearSelection();
  }

  Future<void> _selectTreeForE2E(
    String treeId,
    String? treeName,
  ) async {
    if (!GetIt.I.isRegistered<TreeProvider>()) {
      return;
    }
    final treeProvider = GetIt.I<TreeProvider>();
    final resolvedTreeName = (treeName != null && treeName.isNotEmpty)
        ? treeName
        : (treeProvider.selectedTreeId == treeId
            ? treeProvider.selectedTreeName
            : null);
    await treeProvider.selectTree(treeId, resolvedTreeName);
  }

  String _buildTreeRoute(String treeId, String? treeName) {
    final uri = Uri(
      path: '/tree/view/$treeId',
      queryParameters: <String, String>{
        if (treeName != null && treeName.isNotEmpty) 'name': treeName,
      },
    );
    return uri.toString();
  }

  String? _extractTreeIdFromPath(String? targetPath) {
    if (targetPath == null || targetPath.trim().isEmpty) {
      return null;
    }
    final normalizedPath =
        targetPath.startsWith('#') ? targetPath.substring(1) : targetPath;
    final uri = Uri.tryParse(normalizedPath);
    final segments = uri?.pathSegments ?? const <String>[];
    if (segments.length >= 3 &&
        segments[0] == 'tree' &&
        segments[1] == 'view') {
      final treeId = segments[2].trim();
      return treeId.isEmpty ? null : treeId;
    }
    return null;
  }

  String? _extractTreeNameFromPath(String? targetPath) {
    if (targetPath == null || targetPath.trim().isEmpty) {
      return null;
    }
    final normalizedPath =
        targetPath.startsWith('#') ? targetPath.substring(1) : targetPath;
    final uri = Uri.tryParse(normalizedPath);
    final treeName = uri?.queryParameters['name']?.trim();
    if (treeName == null || treeName.isEmpty) {
      return null;
    }
    return treeName;
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return MaterialApp.router(
      scaffoldMessengerKey: scaffoldMessengerKey,
      routerConfig: _appRouter.router,
      title: 'Родня',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeProvider.themeMode,
      localizationsDelegates: [
        CountryLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: [const Locale('ru', 'RU'), const Locale('en', 'US')],
      locale: const Locale('ru', 'RU'),
      builder: (context, child) {
        final content = child ?? const SizedBox.shrink();
        // Theme-aligned system bars: transparent status / nav bar so
        // Flutter's warm cream backdrop reaches the system edges, with
        // icon brightness flipped against the active Brightness so the
        // clock + battery stay readable in both light and dark mode.
        // Same setup TG / iOS-style apps use for edge-to-edge.
        final brightness = Theme.of(context).brightness;
        final iconBrightness =
            brightness == Brightness.light ? Brightness.dark : Brightness.light;
        final systemBars = SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: iconBrightness,
          statusBarBrightness: brightness,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: iconBrightness,
          systemNavigationBarDividerColor: Colors.transparent,
        );
        Widget wrapped = AnnotatedRegion<SystemUiOverlayStyle>(
          value: systemBars,
          child: content,
        );
        if (GetIt.I.isRegistered<CallCoordinatorService>()) {
          wrapped = CallRuntimeHost(child: wrapped);
        }
        // U2: foreground-монитор sideload OTA + блокирующий экран
        // «Нужно обновить» при несовместимой старой версии. Монитор живёт
        // у корня, поэтому открытое приложение замечает новый APK без
        // перезапуска.
        wrapped = AppUpdateMonitor(
          child: AppUpdateGate(child: wrapped),
        );
        // Cap runaway OS font scaling — the dominant cause of an oversized,
        // cramped UI (esp. chat) on phones with an enlarged system font —
        // while still allowing mild accessibility scaling. Never below 1.0.
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: MediaQuery.textScalerOf(context).clamp(
              minScaleFactor: 1.0,
              maxScaleFactor: 1.15,
            ),
          ),
          child: wrapped,
        );
      },
    );
  }
}

class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({
    required this.error,
    required this.stackTrace,
    required this.onRetry,
    required this.canResetSession,
    this.onResetSessionAndRetry,
  });

  final Object error;
  final StackTrace stackTrace;
  final Future<void> Function() onRetry;
  final bool canResetSession;
  final Future<void> Function()? onResetSessionAndRetry;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: StartupFailureView(
                  title: 'Не удалось открыть Родню',
                  message: startupFailureMessageFor(
                    error,
                    canResetSession: canResetSession,
                  ),
                  onRetry: onRetry,
                  onResetSessionAndRetry: onResetSessionAndRetry,
                  showTechnicalDetails: kDebugMode,
                  technicalDetails: [
                    error.toString(),
                    '',
                    stackTrace.toString(),
                  ].join('\n'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
