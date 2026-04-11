import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'providers/theme_provider.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'navigation/app_router.dart';
import 'services/local_storage_service.dart';
import 'package:get_it/get_it.dart';
import 'providers/tree_provider.dart';
import 'services/rustore_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_rustore_update/pigeons/rustore.dart' as update;
import 'package:flutter/scheduler.dart'; // Для postFrameCallback
import 'package:shared_preferences/shared_preferences.dart';
import 'backend/interfaces/app_startup_service_interface.dart';
import 'services/app_startup_service.dart';
import 'startup/startup_failure_policy.dart';
import 'widgets/startup_failure_view.dart';

// --- Переменная для хранения SnackBarContext ---
// Используем GlobalKey, чтобы получить доступ к ScaffoldMessenger
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await _bootstrapAndRunApp();
}

Future<void> _bootstrapAndRunApp() async {
  try {
    if (!GetIt.I.isRegistered<AppStartupServiceInterface>()) {
      GetIt.I
          .registerSingleton<AppStartupServiceInterface>(AppStartupService());
    }
    await GetIt.I<AppStartupServiceInterface>().initializeForeground();

    final localStorageService = GetIt.I<LocalStorageService>();
    final rustoreService = GetIt.I<RustoreService>();
    final isRuStoreRuntime =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

    // На web не тянем .env как asset, чтобы не получать лишний 404 в консоли.
    if (!kIsWeb) {
      try {
        await dotenv.load(fileName: ".env");
        debugPrint('.env file loaded successfully.');
      } catch (e) {
        debugPrint(
          'Error loading .env file: $e. Ensure the file exists at the project root and is listed in pubspec.yaml assets.',
        );
      }
    }

    // --- Проверка обновлений RuStore ---
    if (isRuStoreRuntime) {
      _checkRuStoreUpdate(rustoreService);
      rustoreService.initializePushListeners();
      rustoreService.getRustorePushToken().then((token) {
        if (token != null) {
          debugPrint('[RuStore Push] Token received for demonstration: $token');
        }
      });
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
        library: 'lineage_bootstrap',
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

void _checkRuStoreUpdate(RustoreService rustoreService) {
  rustoreService.checkForUpdate().then((update.UpdateInfo? info) {
    if (info != null &&
        info.updateAvailability == updateAvailabilityAvailable) {
      debugPrint(
        "!!! Доступно обновление в RuStore (v8 API) !!! Info: ${info.toString()}",
      );

      SchedulerBinding.instance.addPostFrameCallback((_) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text('Доступно обновление приложения.'),
            duration: const Duration(days: 1),
            action: SnackBarAction(
              label: 'ОБНОВИТЬ',
              onPressed: () {
                _startUpdateProcess(rustoreService);
              },
            ),
          ),
        );
      });
    }
  }).catchError((error) {
    debugPrint("Error during checkForUpdate: $error");
  });
}

void _startUpdateProcess(RustoreService rustoreService) {
  rustoreService.startUpdateListener((update.RequestResponse state) {
    if (state.installStatus == installStatusDownloaded) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text('Обновление скачано.'),
            duration: const Duration(days: 1),
            action: SnackBarAction(
              label: 'УСТАНОВИТЬ',
              onPressed: () {
                rustoreService.completeUpdateFlexible();
              },
            ),
          ),
        );
      });
    } else if (state.installStatus == installStatusFailed) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text(
              'Ошибка загрузки обновления: ${state.installErrorCode}',
            ),
            duration: const Duration(seconds: 10),
          ),
        );
      });
    }
  });

  rustoreService.startUpdateFlow().then((update.DownloadResponse? response) {
    if (response != null) {
      debugPrint("Update flow (download) response code: ${response.code}");
    }
  }).catchError((error) {
    debugPrint("Error during startUpdateFlow: $error");
  });
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final AppRouter _appRouter;

  @override
  void initState() {
    super.initState();
    _appRouter = AppRouter();
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
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: [const Locale('ru', 'RU'), const Locale('en', 'US')],
      locale: const Locale('ru', 'RU'),
      builder: (context, child) {
        return child ?? const SizedBox.shrink();
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
