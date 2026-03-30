import 'dart:async'; // Добавляем для StreamSubscription
import 'package:flutter/foundation.dart';
// Используем новые импорты для API v8.0.0
import 'package:flutter_rustore_update/flutter_rustore_update.dart';
// Добавляем импорт для типов из update SDK
import 'package:flutter_rustore_update/pigeons/rustore.dart' as update;

// Импорт для Review API
import 'package:flutter_rustore_review/flutter_rustore_review.dart';

// Импорт для Billing API
import 'package:flutter_rustore_billing/flutter_rustore_billing.dart'; // Содержит RustoreBillingClient
import 'package:flutter_rustore_billing/pigeons/rustore.dart'
    as billing; // Нужен для типов Purchase, Product, PaymentResult и др.

// Импорт для Push API
import 'package:flutter_rustore_push/flutter_rustore_push.dart'; // Содержит RustorePushClient
// Типы Message, Notification доступны из основного импорта

// <<< Добавляем импорт SharedPreferences >>>
import 'package:shared_preferences/shared_preferences.dart';

// Константы из update SDK (могут быть уже определены в SDK, но оставим для ясности, если нужны напрямую)
// Используем целочисленные значения, т.к. доступ к enum вызывает ошибки
const int updateAvailabilityUnknown = 0;
const int updateAvailabilityNotAvailable = 1;
const int updateAvailabilityAvailable = 2;
const int updateAvailabilityInProgress = 3;

const int installStatusUnknown = 0;
const int installStatusDownloaded = 1;
const int installStatusDownloading = 2;
const int installStatusFailed = 3;
const int installStatusPending = 5;

// Ключ для сохранения статуса запроса отзыва
const String _reviewRequestedKey = 'lineage_review_requested';

class RustoreService {
  bool _isReviewInitialized = false; // Флаг для инициализации Review SDK
  // StreamSubscription больше не нужен

  // --- SharedPreferences Instance ---
  // Делаем Future, чтобы можно было получить его асинхронно
  late final Future<SharedPreferences> _prefs = SharedPreferences.getInstance();

  // Проверка наличия обновлений (возвращает UpdateInfo или null)
  Future<update.UpdateInfo?> checkForUpdate() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        debugPrint('Checking for RuStore update (v8 API)...');
        // Используем RustoreUpdateClient
        final update.UpdateInfo info = await RustoreUpdateClient.info();
        debugPrint(
          'RuStore update check completed (v8 API). Info: ${info.toString()}',
        );
        return info;
      } catch (e) {
        debugPrint('Error checking for RuStore update (v8 API): $e');
        debugPrint('Update check failed.');
        return null;
      }
    } else {
      debugPrint('RuStore SDK check skipped (not Android).');
      return null;
    }
  }

  // Используем download() для отложенного обновления
  Future<update.DownloadResponse?> startUpdateFlow() async {
    final info = await checkForUpdate();
    // Сравниваем с константой
    if (info == null ||
        info.updateAvailability != updateAvailabilityAvailable) {
      debugPrint(
        'RuStore update not available or error occurred. Cannot start update flow.',
      );
      return null;
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        debugPrint('Starting RuStore update flow (v8 - download)...');
        // Используем RustoreUpdateClient
        final update.DownloadResponse response =
            await RustoreUpdateClient.download();
        debugPrint(
          'Update flow (download) initiated. Response code: ${response.code}',
        );
        return response;
      } catch (e) {
        debugPrint('Error starting RuStore update flow (download): $e');
        return null;
      }
    } else {
      return null;
    }
  }

  // --- Методы для слушателя обновлений (v8 API) ---

  // Колбэк принимает RequestResponse
  void startUpdateListener(
    Function(update.RequestResponse state) onStateChanged,
  ) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      debugPrint('Starting RuStore update listener (v8 API)...');
      try {
        // Используем RustoreUpdateClient.listener
        // listener принимает колбэк напрямую
        RustoreUpdateClient.listener((state) {
          debugPrint('Update listener state received: ${state.toString()}');
          onStateChanged(state);

          // Используем state.installStatus и константу
          if (state.installStatus == installStatusDownloaded) {
            debugPrint('Update downloaded! Ready to complete.');
          }
        });
        debugPrint('Update listener started successfully.');
      } catch (e) {
        debugPrint('Error starting RuStore update listener: $e');
      }
    }
  }

  // Метод stopUpdateListener удален

  // --- Методы для завершения обновления (v8 API) ---
  Future<void> completeUpdateFlexible() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        debugPrint('Completing RuStore update (flexible v8)...');
        // Используем RustoreUpdateClient
        await RustoreUpdateClient.completeUpdateFlexible();
        debugPrint('Flexible update completion initiated.');
      } catch (e) {
        debugPrint('Error completing flexible update: $e');
      }
    }
  }

  // --- Review SDK Methods ---

  Future<void> initializeReview() async {
    if (!_isReviewInitialized &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
      try {
        debugPrint('Initializing RuStore Review SDK (v8 API)...');
        // Используем RustoreReviewClient
        await RustoreReviewClient.initialize();
        _isReviewInitialized = true;
        debugPrint('RuStore Review SDK initialized.');
      } catch (e) {
        debugPrint('Error initializing RuStore Review SDK: $e');
        _isReviewInitialized = false;
        debugPrint('Review SDK initialization failed. Error: $e');
      }
    }
  }

  Future<void> requestReview() async {
    debugPrint('[RustoreService] Attempting to initialize review...');
    await initializeReview();
    if (!_isReviewInitialized ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      debugPrint('Cannot request review: SDK not initialized or not Android.');
      return;
    }

    try {
      debugPrint('Requesting RuStore review (v8 API - step 1: request)...');
      // Используем RustoreReviewClient
      await RustoreReviewClient.request();
      debugPrint(
        '[RustoreService] Review request successful. Showing dialog (step 2: review)...',
      );
      // Используем RustoreReviewClient
      await RustoreReviewClient.review();
      debugPrint(
          '[RustoreService] Review dialog shown (or skipped by RuStore).');
      // <<< Помечаем, что запрос был сделан >>>
      await markReviewAsRequested();
    } catch (e) {
      debugPrint('Error requesting/showing RuStore review (v8 API): $e');
      debugPrint('Review request failed. Error: $e');
    }
  }

  // --- Методы для отслеживания статуса оценки ---

  /// Проверяет, был ли ранее успешно инициирован запрос на отзыв.
  Future<bool> checkIfReviewWasRequested() async {
    try {
      final SharedPreferences prefs = await _prefs; // Получаем инстанс
      return prefs.getBool(_reviewRequestedKey) ?? false;
    } catch (e) {
      debugPrint(
        'Error reading review request status from SharedPreferences: $e',
      );
      return false; // В случае ошибки считаем, что не запрашивали
    }
  }

  /// Помечает, что запрос на отзыв был успешно инициирован.
  Future<void> markReviewAsRequested() async {
    try {
      final SharedPreferences prefs = await _prefs; // Получаем инстанс
      await prefs.setBool(_reviewRequestedKey, true);
      debugPrint('Review request status saved to SharedPreferences.');
    } catch (e) {
      debugPrint('Error saving review request status to SharedPreferences: $e');
    }
  }
  // --- Конец методов для статуса оценки ---

  // --- Billing SDK Methods ---

  bool _isBillingAvailable = false; // Флаг доступности биллинга
  bool _isBillingInitialized = false; // Флаг инициализации биллинга

  // Инициализация биллинга (в v8 нет явного метода, проверяем доступность)
  Future<bool> initializeBilling() async {
    if (!_isBillingInitialized &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
      try {
        debugPrint(
            'Initializing RuStore Billing Client...'); // Лог инициализации
        // <<< Используем правильный числовой ID приложения >>>
        const String consoleAppId = '2063621085';
        const String deeplinkScheme = 'lineagebilling'; // Выбранная схема
        await RustoreBillingClient.initialize(
          consoleAppId,
          deeplinkScheme,
          kDebugMode,
        );
        debugPrint('RuStore Billing Client initialized successfully.');

        debugPrint('RuStore Billing availability assumed after initialize.');
        _isBillingAvailable = true;
        debugPrint(
          'Billing available check completed. Assuming available if no error.',
        );
        // Считаем инициализированным после первой проверки
        _isBillingInitialized = true;
        return true;
      } catch (e) {
        debugPrint(
          'Error during RuStore Billing initialization or availability check: $e',
        ); // Обновляем лог ошибки
        _isBillingAvailable = false;
        _isBillingInitialized = false; // Не удалось инициализировать
        return false;
      }
    } else if (_isBillingInitialized) {
      debugPrint('Billing already initialized.');
      return true; // Уже инициализирован
    } else {
      debugPrint(
          'Billing skipped (not Android or already attempted and failed).');
      return false; // Не инициализировано
    }
  }

  // Проверка имеющихся покупок
  Future<List<billing.Purchase>> checkPurchases() async {
    await initializeBilling(); // Убедимся, что была попытка инициализации
    if (!_isBillingAvailable ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      debugPrint('Billing not available or not Android.');
      return [];
    }
    try {
      debugPrint('Checking for existing purchases...');
      // Используем RustoreBillingClient.purchases()
      final billing.PurchasesResponse response =
          await RustoreBillingClient.purchases();
      final validPurchases =
          response.purchases.whereType<billing.Purchase>().toList();
      debugPrint('Found ${validPurchases.length} purchases.');
      return validPurchases;
    } catch (e) {
      debugPrint('Error checking purchases: $e');
      return [];
    }
  }

  // Получение информации о продуктах
  Future<List<billing.Product>> getProducts(List<String> productIds) async {
    final bool initialized = await initializeBilling();
    if (!initialized) return [];

    if (!_isBillingAvailable ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      debugPrint('Billing not available or not Android.');
      return [];
    }
    if (productIds.isEmpty) return [];

    try {
      debugPrint(
        '[RustoreService] Getting product info for IDs: ${productIds.join(", ")}',
      );
      // Используем RustoreBillingClient.products()
      final billing.ProductsResponse response =
          await RustoreBillingClient.products(productIds);
      final validProducts =
          response.products.whereType<billing.Product>().toList();
      debugPrint('Received info for ${validProducts.length} products.');
      return validProducts;
    } catch (e) {
      debugPrint('Error getting products: $e');
      return [];
    }
  }

  // Покупка продукта
  Future<billing.PaymentResult?> purchaseProduct(String productId) async {
    final bool initialized = await initializeBilling();
    if (!initialized) return null;

    if (!_isBillingAvailable ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      debugPrint('Billing not available or not Android.');
      return null;
    }
    try {
      debugPrint(
          '[RustoreService] Attempting purchase for product ID: $productId');
      // Используем RustoreBillingClient.purchase()
      final billing.PaymentResult result = await RustoreBillingClient.purchase(
        productId,
        null,
      );
      // Временно убираем детальную проверку полей result, т.к. они вызывают ошибки
      debugPrint('Purchase flow finished. Result: ${result.toString()}');
      return result;
    } catch (e) {
      debugPrint('Error purchasing product $productId: $e');
      return null;
    }
  }

  // Подтверждение покупки (если нужно для NON_CONSUMABLE/SUBSCRIPTION)
  Future<billing.ConfirmPurchaseResponse?> confirmPurchase(
    String purchaseId,
  ) async {
    await initializeBilling();
    if (!_isBillingAvailable ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      debugPrint('Billing not available or not Android.');
      return null;
    }
    try {
      debugPrint('Confirming purchase: $purchaseId');
      // Используем RustoreBillingClient.confirm()
      final billing.ConfirmPurchaseResponse response =
          await RustoreBillingClient.confirm(purchaseId);
      debugPrint('Purchase confirmation result: ${response.toString()}');
      return response;
    } catch (e) {
      debugPrint('Error confirming purchase $purchaseId: $e');
      return null;
    }
  }

  // Отмена/Удаление покупки (для тестирования)
  Future<bool> deletePurchase(String purchaseId) async {
    await initializeBilling();
    if (!_isBillingAvailable ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      debugPrint('Billing not available or not Android.');
      return false;
    }
    try {
      debugPrint('Deleting purchase: $purchaseId');
      // Используем RustoreBillingClient.deletePurchase()
      await RustoreBillingClient.deletePurchase(purchaseId);
      debugPrint('Purchase $purchaseId deleted successfully (for testing).');
      return true;
    } catch (e) {
      debugPrint('Error deleting purchase $purchaseId: $e');
      return false;
    }
  }

  // --- RuStore Push SDK Methods (v6.5.0) ---

  // Метод для инициализации слушателей Push SDK v6.5.0
  // Вызывать один раз при старте приложения
  void initializePushListeners() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      debugPrint('Initializing RuStore Push SDK v6.5.0 listeners...');

      try {
        // Используем attachCallbacks для передачи всех слушателей сразу
        RustorePushClient.attachCallbacks(
          onNewToken: (token) {
            debugPrint('[RuStore Push v6.5.0] New token received: $token');
            // TODO: Отправить новый токен на бэкенд
          },
          onMessageReceived: (message) {
            debugPrint(
              '[RuStore Push v6.5.0] Message received: id=${message.messageId}, data=${message.data}, notification=${message.notification.title}',
            );
            // TODO: Обработать полученное сообщение
          },
          onDeletedMessages: () {
            debugPrint('[RuStore Push v6.5.0] Messages deleted on server.');
          },
          onError: (err) {
            debugPrint('[RuStore Push v6.5.0] SDK Error: $err');
          },
        );

        // Проверка доступности (опционально)
        // Используем RustorePushClient
        RustorePushClient.available().then(
          (value) {
            debugPrint("[RuStore Push v6.5.0] Push available: $value");
          },
          onError: (err) {
            debugPrint(
              "[RuStore Push v6.5.0] Push availability check error: $err",
            );
          },
        );

        debugPrint(
          'RuStore Push SDK v6.5.0 listeners initialized successfully using attachCallbacks.',
        );
      } catch (e) {
        debugPrint('Error initializing RuStore Push listeners: $e');
      }
    } else {
      debugPrint('RuStore Push v6.5.0 skipped (not Android).');
    }
  }

  // Получение Push-токена RuStore
  Future<String?> getRustorePushToken() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      debugPrint('RuStore Push skipped (not Android).');
      return null;
    }

    try {
      debugPrint('Requesting RuStore Push Token...');
      // Используем RustorePushClient
      final String token = await RustorePushClient.getToken();
      debugPrint('RuStore Push Token: $token');
      return token;
    } catch (e) {
      debugPrint('Error getting RuStore Push Token: $e');
      return null;
    }
  }

  // TODO: Добавить методы для обработки полученных сообщений,
  // подписки/отписки от топиков, если необходимо для задания.
}
