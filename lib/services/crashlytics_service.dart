import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

class CrashlyticsService {
  FirebaseCrashlytics? get _crashlytics {
    if (kIsWeb) {
      return null;
    }

    try {
      return FirebaseCrashlytics.instance;
    } catch (error) {
      debugPrint('Crashlytics недоступен: $error');
      return null;
    }
  }

  // Инициализация сервиса
  Future<void> initialize() async {
    final crashlytics = _crashlytics;
    if (crashlytics == null) return;

    // Включаем сбор данных для Crashlytics
    await crashlytics.setCrashlyticsCollectionEnabled(true);

    // Регистрируем обработчик ошибок Flutter
    FlutterError.onError = crashlytics.recordFlutterError;

    // Регистрируем обработчик асинхронных ошибок
    PlatformDispatcher.instance.onError = (error, stack) {
      crashlytics.recordError(error, stack, fatal: true);
      return true;
    };
  }

  // Установка идентификаторов пользователя
  Future<void> setUserIdentifier(String userId) async {
    final crashlytics = _crashlytics;
    if (crashlytics == null) return;
    await crashlytics.setUserIdentifier(userId);
  }

  // Добавление пользовательских ключей
  Future<void> setCustomKey(String key, dynamic value) async {
    final crashlytics = _crashlytics;
    if (crashlytics == null) return;
    await crashlytics.setCustomKey(key, value);
  }

  // Логирование не фатальной ошибки
  Future<void> logError(
    dynamic exception,
    StackTrace? stack, {
    String? reason,
  }) async {
    final crashlytics = _crashlytics;
    if (crashlytics == null) return;
    await crashlytics.recordError(
      exception,
      stack,
      reason: reason,
      fatal: false,
    );
  }

  // Отправка логов для последующего отчета о сбое
  Future<void> log(String message) async {
    final crashlytics = _crashlytics;
    if (crashlytics == null) return;
    await crashlytics.log(message);
  }

  // Тестовый метод для проверки Crashlytics
  Future<void> testCrash() async {
    final crashlytics = _crashlytics;
    if (crashlytics == null) {
      debugPrint('Тестовое падение недоступно без Crashlytics');
      return;
    }

    // Добавляем лог перед сбоем
    await crashlytics.log('Тестовое падение приложения начинается');

    // Это вызовет сбой приложения
    crashlytics.crash();
  }
}
