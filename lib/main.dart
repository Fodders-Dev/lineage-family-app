import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'providers/theme_provider.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'navigation/app_router.dart';
import 'services/local_storage_service.dart';
import 'services/sync_service.dart';
import 'package:get_it/get_it.dart';
import 'providers/tree_provider.dart';
import 'package:workmanager/workmanager.dart';
import 'services/rustore_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_rustore_update/pigeons/rustore.dart' as update;
import 'package:flutter/scheduler.dart'; // Для postFrameCallback
import 'backend/interfaces/app_startup_service_interface.dart';
import 'backend/interfaces/dynamic_link_service_interface.dart';
import 'services/app_startup_service.dart';
import 'services/background_task_runner.dart';

// Вспомогательная функция для расчета задержки до следующего запуска проверки дней рождения (9 утра)
Duration _calculateInitialDelayForBirthdayCheck() {
  final now = DateTime.now();
  // Устанавливаем время следующего запуска на 9 утра
  var nextRunTime = DateTime(now.year, now.month, now.day, 9, 0, 0);
  // Если 9 утра сегодня уже прошло, переносим на завтра
  if (now.isAfter(nextRunTime)) {
    nextRunTime = nextRunTime.add(const Duration(days: 1));
  }
  // Возвращаем разницу между следующим запуском и текущим временем
  return nextRunTime.difference(now);
}

// --- Переменная для хранения SnackBarContext ---
// Используем GlobalKey, чтобы получить доступ к ScaffoldMessenger
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // Инициализация Workmanager (только не для веба)
    if (!kIsWeb) {
      await Workmanager().initialize(
        callbackDispatcher, // Передаем созданную функцию
        isInDebugMode: kDebugMode, // Логи Workmanager только в debug-сборках
      );

      // Регистрация периодических задач (только не для веба)
      // Синхронизация каждые 6 часов при наличии сети
      Workmanager().registerPeriodicTask(
        "lineageSyncTask", // Уникальное имя
        "syncTask", // Имя задачи в callbackDispatcher
        frequency: const Duration(hours: 6),
        constraints: Constraints(networkType: NetworkType.connected),
        // existingWorkPolicy: ExistingWorkPolicy.replace, // Раскомментировать при необходимости
      );

      // Проверка дней рождения раз в день (запуск в 9 утра)
      Workmanager().registerPeriodicTask(
        "lineageBirthdayCheckTask", // Уникальное имя
        "birthdayCheckTask", // Имя задачи в callbackDispatcher
        frequency: const Duration(days: 1),
        initialDelay:
            _calculateInitialDelayForBirthdayCheck(), // Задержка до первого запуска
        constraints: Constraints(networkType: NetworkType.not_required),
        // existingWorkPolicy: ExistingWorkPolicy.replace, // Раскомментировать при необходимости
      );
    }

    if (!GetIt.I.isRegistered<AppStartupServiceInterface>()) {
      GetIt.I
          .registerSingleton<AppStartupServiceInterface>(AppStartupService());
    }
    await GetIt.I<AppStartupServiceInterface>().initializeForeground();

    final localStorageService = GetIt.I<LocalStorageService>();
    final syncService =
        GetIt.I.isRegistered<SyncService>() ? GetIt.I<SyncService>() : null;
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
        // Можно не прерывать выполнение, если переменные не критичны для старта
      }
    }

    // --- Проверка обновлений RuStore ---
    if (isRuStoreRuntime) {
      _checkRuStoreUpdate(rustoreService);

      rustoreService.initializePushListeners();

      rustoreService.getRustorePushToken().then((token) {
        if (token != null) {
          debugPrint('[RuStore Push] Token received for demonstration: $token');
          // TODO: Отправить токен на ваш бэкенд, если используете RuStore Push
        }
      });
    }

    // Отдельная инициализация Review Manager больше не нужна
    // await rustoreService.initializeReviewManager(); // Инициализация менеджера отзывов

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(
            create: (_) =>
                GetIt.I<TreeProvider>(), // Используем экземпляр из GetIt
          ),
          if (syncService != null)
            Provider<SyncService>.value(value: syncService),
          Provider<LocalStorageService>.value(value: localStorageService),
        ],
        // Возвращаем MyApp как корневой виджет
        child: const MyApp(),
        /* Старый вариант с оберткой MaterialApp:
        // Оборачиваем MyApp в ScaffoldMessenger
        child: MaterialApp(
          scaffoldMessengerKey: scaffoldMessengerKey, // Привязываем ключ
          home: const MyApp(),
        ),
        */
      ),
    );
  } catch (error, stackTrace) {
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
      ),
    );
  }
}

// --- Функция для проверки обновлений и показа SnackBar ---
void _checkRuStoreUpdate(RustoreService rustoreService) {
  rustoreService.checkForUpdate().then((update.UpdateInfo? info) {
    if (info != null &&
        info.updateAvailability == updateAvailabilityAvailable) {
      debugPrint(
        "!!! Доступно обновление в RuStore (v8 API) !!! Info: ${info.toString()}",
      );

      // Используем SchedulerBinding, чтобы показать SnackBar после построения первого кадра
      SchedulerBinding.instance.addPostFrameCallback((_) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text('Доступно обновление приложения.'),
            duration: const Duration(days: 1), // Показываем долго
            action: SnackBarAction(
              label: 'ОБНОВИТЬ',
              onPressed: () {
                _startUpdateProcess(rustoreService);
              },
            ),
          ),
        );
      });
    } else if (info != null) {
      debugPrint("RuStore update status (v8 API): ${info.updateAvailability}");
    } else {
      debugPrint("RuStore update check returned null or failed.");
    }
  }).catchError((error) {
    debugPrint("Error during checkForUpdate: $error");
  });
}

// --- Функция для запуска процесса обновления ---
void _startUpdateProcess(RustoreService rustoreService) {
  // 1. Запускаем listener
  rustoreService.startUpdateListener((update.RequestResponse state) {
    if (state.installStatus == installStatusDownloaded) {
      debugPrint('Update downloaded! Showing confirmation SnackBar.');
      // Показываем SnackBar для подтверждения установки
      SchedulerBinding.instance.addPostFrameCallback((_) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text('Обновление скачано.'),
            duration: const Duration(days: 1), // Показываем долго
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
      debugPrint(
        'Update download failed! Error code: ${state.installErrorCode}',
      );
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
    // Можно добавить обработку других статусов (DOWNLOADING, PENDING и т.д.) для показа прогресса
  });

  // 2. Запускаем поток скачивания
  rustoreService.startUpdateFlow().then((update.DownloadResponse? response) {
    // response?.code может быть Activity.RESULT_OK или Activity.RESULT_CANCELED
    if (response != null) {
      debugPrint("Update flow (download) response code: ${response.code}");
    } else {
      debugPrint(
        "startUpdateFlow returned null (likely skipped or immediate error).",
      );
    }
  }).catchError((error) {
    debugPrint("Error during startUpdateFlow: $error");
  });
}

class MyApp extends StatefulWidget {
  final bool skipAuth;
  final bool skipProfileCheck;

  const MyApp({
    super.key,
    this.skipAuth = false,
    this.skipProfileCheck = false,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // Создаем экземпляр маршрутизатора ОДИН РАЗ
  late final AppRouter _appRouter;
  late final DynamicLinkServiceInterface _dynamicLinkService;

  @override
  void initState() {
    super.initState();
    _appRouter = AppRouter(); // Инициализируем здесь
    _dynamicLinkService = GetIt.I<DynamicLinkServiceInterface>();
    _dynamicLinkService.startListening(_appRouter.router);
  }

  @override
  void dispose() {
    _dynamicLinkService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Возвращаем MaterialApp.router и передаем scaffoldMessengerKey и routerConfig
    return MaterialApp.router(
      scaffoldMessengerKey: scaffoldMessengerKey, // Передаем ключ сюда
      routerConfig: _appRouter.router, // Используем routerConfig

      title: 'Lineage',
      debugShowCheckedModeBanner: false,
      theme: Provider.of<ThemeProvider>(context).themeMode == ThemeMode.dark
          ? AppTheme.darkTheme
          : AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: Provider.of<ThemeProvider>(context).themeMode,
      localizationsDelegates: [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: [const Locale('ru', 'RU'), const Locale('en', 'US')],
      locale: const Locale('ru', 'RU'),

      builder: (context, child) {
        // Builder можно оставить для других целей или убрать, если не нужен
        return child ?? const SizedBox.shrink();
      },
    );
    /* Старый неверный вариант:
    // Убираем MaterialApp отсюда, так как он теперь выше
    return Router.router(
      routerDelegate: _appRouter.router.routerDelegate,
      routeInformationParser: _appRouter.router.routeInformationParser,
      routeInformationProvider: _appRouter.router.routeInformationProvider,
    );
    */
  }
}

class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({
    required this.error,
    required this.stackTrace,
  });

  final Object error;
  final StackTrace stackTrace;

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
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Приложение не смогло запуститься',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(error.toString()),
                      const SizedBox(height: 16),
                      SelectableText(
                        stackTrace.toString(),
                        style: const TextStyle(fontSize: 12, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
