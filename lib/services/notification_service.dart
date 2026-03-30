import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart'; // Для kIsWeb
import 'package:permission_handler/permission_handler.dart'; // Добавляем импорт
// Используем alias для нашей модели, чтобы избежать конфликта имен
import '../models/family_person.dart' as lineage_models;
// <<< Добавляем импорты >>>
import 'package:get_it/get_it.dart';
import 'auth_service.dart';
import 'package:firebase_auth/firebase_auth.dart'; // Нужен для FirebaseAuth.instance
import 'dart:convert'; // Для jsonEncode/Decode
import 'package:go_router/go_router.dart'; // Для навигации
import '../navigation/app_router.dart'; // Для доступа к _rootNavigatorKey
import 'package:flutter/material.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/notification_service_interface.dart';
import '../providers/tree_provider.dart';

class NoopNotificationService implements NotificationServiceInterface {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> showBirthdayNotification(
    lineage_models.FamilyPerson person,
  ) async {}

  @override
  Future<void> showChatMessageNotification({
    required String chatId,
    required String senderId,
    required String senderName,
    required String messageText,
    required int notificationId,
  }) async {}
}

// Обработчик фоновых сообщений (должен быть top-level функцией)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Если нужно выполнить какую-то логику при получении сообщения в фоне
  // (когда приложение не запущено или свернуто)
  // Например, инициализировать Firebase, если еще не сделано
  // await Firebase.initializeApp(); // Обычно уже инициализировано
  debugPrint('Handling a background message: ${message.messageId}');
  // ВАЖНО: Не вызывайте здесь setState или другие UI-операции
  // Можно сохранить данные уведомления, чтобы показать их при открытии приложения
}

// НОВЫЙ Обработчик нажатия на уведомление Local Notifications (когда приложение было закрыто)
@pragma('vm:entry-point')
void onDidReceiveBackgroundNotificationResponseHandler(
  NotificationResponse response,
) {
  final String? payload = response.payload;
  debugPrint(
    'Notification clicked (terminated - top-level): id=${response.id}, payload=$payload',
  );
  // Здесь нельзя использовать context или плагины, требующие UI
  // Можно сохранить payload в SharedPreferences и обработать при запуске
}

class NotificationService implements NotificationServiceInterface {
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  // <<< Получаем Navigator Key для навигации >>>
  // Мы не можем получить GoRouter напрямую, но можем использовать ключ навигатора
  // Важно: Используем публичный ключ rootNavigatorKey из app_router.dart
  final GlobalKey<NavigatorState> _navigatorKey = rootNavigatorKey;

  // --- Каналы уведомлений (Android) ---
  // ID и Названия каналов
  static const String channelIdGeneral = 'general_notifications';
  static const String channelNameGeneral = 'Общие уведомления';
  static const String channelDescGeneral =
      'Уведомления о новостях, акциях и прочая информация';

  static const String channelIdEvents = 'family_events';
  static const String channelNameEvents = 'Семейные события';
  static const String channelDescEvents =
      'Напоминания о днях рождения, годовщинах и других событиях';

  // Метод для создания каналов
  Future<void> _createNotificationChannels() async {
    const AndroidNotificationChannel generalChannel =
        AndroidNotificationChannel(
      channelIdGeneral,
      channelNameGeneral,
      description: channelDescGeneral,
      importance: Importance.defaultImportance, // Обычная важность
    );

    const AndroidNotificationChannel eventsChannel = AndroidNotificationChannel(
      channelIdEvents,
      channelNameEvents,
      description: channelDescEvents,
      importance: Importance.high, // Высокая важность для событий
    );

    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(generalChannel);

    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(eventsChannel);

    debugPrint('Notification channels created.');
  }

  @override
  Future<void> initialize() async {
    if (kIsWeb) return; // Уведомления не работают так же в Web

    // 1. Запрос разрешений (iOS и Android 13+)
    await _requestPermissions();

    // 2. Инициализация Local Notifications
    await _initializeLocalNotifications();

    // 3. Создание каналов (Android)
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _createNotificationChannels();
    }

    // 4. Получение FCM токена
    await _getFcmToken();

    // 5. Настройка обработчиков сообщений
    _setupMessageHandlers();

    debugPrint('NotificationService initialized.');
  }

  Future<void> _requestPermissions() async {
    // --- Запрос разрешений через Firebase Messaging (основное для iOS) ---
    NotificationSettings settings = await _firebaseMessaging.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false, // true - для временных разрешений на iOS без запроса
      sound: true,
    );
    debugPrint('FCM User granted permission: ${settings.authorizationStatus}');

    // --- Дополнительные запросы разрешений через permission_handler (особенно для Android) ---
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      // Запрос разрешения на показ уведомлений (Android 13+)
      PermissionStatus notificationStatus =
          await Permission.notification.request();
      debugPrint('Notification permission status: $notificationStatus');
      if (notificationStatus.isDenied ||
          notificationStatus.isPermanentlyDenied) {
        // Пользователь отказал. Можно показать объяснение и кнопку для открытия настроек.
        // openAppSettings();
        debugPrint('Notification permission denied by user.');
      }

      // Запрос разрешения на точное планирование (если необходимо)
      // Это специальное разрешение, которое может требовать навигации в настройки
      // PermissionStatus exactAlarmStatus = await Permission.scheduleExactAlarm.request();
      // print('Schedule exact alarm permission status: $exactAlarmStatus');
      // if (!exactAlarmStatus.isGranted) {
      //   print('Exact alarm permission not granted. Notifications might be delayed.');
      // }
      // Пока закомментируем запрос scheduleExactAlarm, т.к. он часто требует доп. действий
      // и не всегда критичен для базовых уведомлений о ДР.
    }
  }

  Future<void> _initializeLocalNotifications() async {
    // Настройки для Android (используем иконку по умолчанию)
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings(
      '@drawable/ic_stat_notification',
    ); // Иконка из AndroidManifest

    // Настройки для iOS (запрос разрешений делается через FCM)
    final DarwinInitializationSettings initializationSettingsIOS =
        DarwinInitializationSettings();

    final InitializationSettings initializationSettings =
        InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await _localNotifications.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: _onDidReceiveNotificationResponse,
      onDidReceiveBackgroundNotificationResponse:
          onDidReceiveBackgroundNotificationResponseHandler,
    );
  }

  Future<void> _getFcmToken() async {
    String? token = await _firebaseMessaging.getToken();
    debugPrint('Firebase Messaging Token: $token');
    // <<< Вызываем обновление токена в Firestore >>>
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId != null && token != null) {
      try {
        // Пытаемся получить AuthService через GetIt
        final authService = GetIt.I<AuthService>();
        await authService.updateUserFcmToken(userId, token);
      } catch (e) {
        debugPrint(
          'Error getting AuthService or updating token in _getFcmToken: $e',
        );
      }
    }
    // <<< Конец вызова обновления >>>

    _firebaseMessaging.onTokenRefresh.listen((newToken) {
      debugPrint('Firebase Messaging Token Refreshed: $newToken');
      // <<< Вызываем обновление токена при обновлении >>>
      final refreshedUserId = FirebaseAuth.instance.currentUser?.uid;
      if (refreshedUserId != null) {
        try {
          final authService = GetIt.I<AuthService>();
          authService.updateUserFcmToken(refreshedUserId, newToken);
        } catch (e) {
          debugPrint(
            'Error getting AuthService or updating token in onTokenRefresh: $e',
          );
        }
      }
      // <<< Конец вызова обновления >>>
    });
  }

  void _setupMessageHandlers() {
    // Обработка сообщений, когда приложение находится на переднем плане (foreground)
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('Got a message whilst in the foreground!');
      debugPrint('Message data: ${message.data}');

      if (message.notification != null) {
        debugPrint(
          'Message also contained a notification: ${message.notification}',
        );
        _showLocalNotification(message);
      }
    });

    // Обработка сообщений, когда приложение открыто из фона (terminated -> background/foreground)
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('Message clicked!');
      debugPrint('Message data: ${message.data}');
      // Здесь можно навигировать пользователя на определенный экран
      // Например, если в data есть 'screen': GoRouter.of(context).go(message.data['screen']);
    });

    // Обработчик для фоновых сообщений (когда приложение закрыто или в фоне)
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // Проверка, было ли приложение запущено нажатием на уведомление (когда было закрыто)
    _checkForInitialMessage();
  }

  Future<void> _checkForInitialMessage() async {
    RemoteMessage? initialMessage =
        await _firebaseMessaging.getInitialMessage();
    if (initialMessage != null) {
      debugPrint('App opened by initial message: ${initialMessage.data}');
      // Навигация на основе initialMessage.data
    }
  }

  // Показ уведомления с помощью flutter_local_notifications
  Future<void> _showLocalNotification(RemoteMessage message) async {
    RemoteNotification? notification = message.notification;
    AndroidNotification? android = message.notification?.android;
    AppleNotification? apple = message.notification?.apple;

    // Если это Android и есть данные о канале, используем его
    // Иначе используем канал по умолчанию или наш 'general_notifications'
    String channelId = android?.channelId ?? channelIdGeneral;

    if (notification != null &&
        (android != null ||
            apple != null ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      // Adjusted condition for iOS
      await _localNotifications.show(
        notification.hashCode, // Уникальный ID уведомления
        notification.title,
        notification.body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            channelId, // Используем ID канала из уведомления или наш по умолчанию
            _getChannelNameById(channelId), // Получаем имя канала по ID
            channelDescription: _getChannelDescriptionById(channelId),
            icon: '@drawable/ic_stat_notification', // Та же иконка
            importance: _getImportanceByChannelId(channelId), // Важность канала
            priority: _getPriorityByChannelId(channelId), // Приоритет канала
            // color: Colors.blue, // Можно задать цвет здесь, если не из манифеста
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        payload: message.data.toString(), // Передаем данные в payload
      );
    }
  }

  // Вспомогательные методы для получения данных канала по ID (упрощенно)
  String _getChannelNameById(String id) {
    if (id == channelIdEvents) return channelNameEvents;
    return channelNameGeneral;
  }

  String _getChannelDescriptionById(String id) {
    if (id == channelIdEvents) return channelDescEvents;
    return channelDescGeneral;
  }

  Importance _getImportanceByChannelId(String id) {
    if (id == channelIdEvents) return Importance.high;
    return Importance.defaultImportance;
  }

  Priority _getPriorityByChannelId(String id) {
    if (id == channelIdEvents) return Priority.high;
    return Priority.defaultPriority;
  }

  // --- Обработчики нажатий на уведомления (Local Notifications) ---

  // Когда пользователь нажимает на уведомление (приложение активно или в фоне)
  void _onDidReceiveNotificationResponse(NotificationResponse response) async {
    final String? payload = response.payload;
    debugPrint(
      'Notification clicked (foreground/background): id=${response.id}, payload=$payload',
    );
    if (payload != null) {
      _handlePayloadNavigation(payload);
    }
  }

  // Старый обработчик удален, т.к. вынесен на верхний уровень
  // @pragma('vm:entry-point')
  // void _onDidReceiveBackgroundNotificationResponse(NotificationResponse response) {
  //    ...
  // }

  // --- Метод для показа УВЕДОМЛЕНИЯ О ДНЕ РОЖДЕНИЯ ---
  @override
  Future<void> showBirthdayNotification(
    lineage_models.FamilyPerson person,
  ) async {
    if (kIsWeb) return;

    final String title = 'День рождения!';
    // Используем person.name вместо firstName/lastName
    final String body = 'Сегодня день рождения у ${person.name}!';
    final int notificationId = person.id.hashCode;

    await _localNotifications.show(
      notificationId,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelIdEvents,
          channelNameEvents,
          channelDescription: channelDescEvents,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          subtitle: body,
        ),
      ),
      payload: 'birthday_${person.id}',
    );
    // Используем person.name
    debugPrint('Showing birthday notification for ${person.name}');
  }

  // <<< НОВЫЙ МЕТОД: Показ уведомления о новом сообщении >>>
  @override
  Future<void> showChatMessageNotification({
    required String chatId, // ID чата, для группировки или навигации
    required String senderId, // <<< Добавляем ID отправителя
    required String senderName,
    required String messageText,
    required int
        notificationId, // Уникальный ID для уведомления (можно использовать хэш сообщения)
  }) async {
    if (kIsWeb) return;

    final String shortMessage = messageText.length > 100
        ? '${messageText.substring(0, 97)}...'
        : messageText;

    // <<< Формируем JSON payload >>>
    final payloadData = {
      'type': 'chat',
      'chatId': chatId, // Оставляем chatId, если понадобится
      'senderId': senderId, // Передаем ID отправителя для навигации
    };
    final String payloadJson = jsonEncode(payloadData);

    await _localNotifications.show(
      notificationId,
      senderName, // Имя отправителя в заголовке
      shortMessage, // Текст сообщения в теле
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelIdGeneral,
          channelNameGeneral,
          channelDescription: channelDescGeneral,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          subtitle: shortMessage,
        ),
      ),
      payload: payloadJson,
    );
    debugPrint(
      'Showing chat notification from $senderName with payload: $payloadJson',
    );
  }
  // <<< КОНЕЦ НОВОГО МЕТОДА >>>

  // <<< НОВЫЙ МЕТОД: Обработка навигации по payload >>>
  Future<void> _handlePayloadNavigation(String payload) async {
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final type = data['type'] as String?;

      if (type == 'chat') {
        final senderId = data['senderId'] as String?;
        final chatId = data['chatId']
            as String?; // chatId пока не используем для навигации
        debugPrint(
          'Handling chat notification click: senderId=$senderId, chatId=$chatId',
        );

        if (senderId != null && _navigatorKey.currentState != null) {
          // Используем GoRouter через контекст навигатора или напрямую
          // Важно: Нужен именно otherUserId (т.е. senderId)
          // Предполагаем, что путь к чату /relatives/chat/:userId
          // или /chat/:userId
          // Если GoRouter доступен глобально (например, через GetIt), можно использовать его.
          // Иначе, используем ключ навигатора. GoRouter интегрируется с Navigator 2.0
          // context.push() не сработает здесь напрямую.
          // Используем go() для перехода к абсолютному пути.

          // Получаем GoRouter через контекст ключа
          final relativeId = await _resolveRelativeIdForUser(senderId);
          if (relativeId == null || relativeId.isEmpty) {
            debugPrint(
              'Error: relativeId is missing for sender $senderId. Opening fallback profile route.',
            );
            _goToRoute('/user/$senderId');
            return;
          }

          final route = '/chat/$senderId?relativeId=$relativeId';
          debugPrint('Navigating to: $route');
          _goToRoute(route);
        } else {
          debugPrint('Error: senderId is null or navigator state is null.');
        }
      } else if (type == 'birthday') {
        final personId = data['personId'] as String?;
        debugPrint('Handling birthday notification click: personId=$personId');
        if (personId != null) {
          final route = '/relative/details/$personId';
          debugPrint('Navigating to: $route');
          _goToRoute(route);
        }
      } else {
        debugPrint('Unknown notification payload type: $type');
      }
    } catch (e) {
      debugPrint('Error handling notification payload: $e');
    }
  }

  void _goToRoute(String route) {
    final context = _navigatorKey.currentContext;
    if (context == null) {
      debugPrint(
        'Error: Cannot get context from navigator key for navigation.',
      );
      return;
    }
    GoRouter.of(context).go(route);
  }

  Future<String?> _resolveRelativeIdForUser(String userId) async {
    if (!GetIt.I.isRegistered<FamilyTreeServiceInterface>()) {
      return null;
    }

    final familyTreeService = GetIt.I<FamilyTreeServiceInterface>();
    final treeProvider =
        GetIt.I.isRegistered<TreeProvider>() ? GetIt.I<TreeProvider>() : null;

    final candidateTreeIds = <String>[];
    final selectedTreeId = treeProvider?.selectedTreeId;
    if (selectedTreeId != null && selectedTreeId.isNotEmpty) {
      candidateTreeIds.add(selectedTreeId);
    }

    try {
      final userTrees = await familyTreeService.getUserTrees();
      for (final tree in userTrees) {
        if (!candidateTreeIds.contains(tree.id)) {
          candidateTreeIds.add(tree.id);
        }
      }
    } catch (_) {
      // Если список деревьев не загрузился, пробуем хотя бы выбранное.
    }

    for (final treeId in candidateTreeIds) {
      try {
        final relatives = await familyTreeService.getRelatives(treeId);
        for (final person in relatives) {
          if (person.userId == userId) {
            return person.id;
          }
        }
      } catch (_) {
        // Переходим к следующему дереву.
      }
    }

    return null;
  }
  // <<< КОНЕЦ МЕТОДА ОБРАБОТКИ НАВИГАЦИИ >>>
}
