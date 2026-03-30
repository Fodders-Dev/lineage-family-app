import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/notification_service_interface.dart';
import '../models/family_person.dart' as lineage_models;
import '../navigation/app_router.dart';
import '../providers/tree_provider.dart';
import 'custom_api_auth_service.dart';
import 'custom_api_realtime_service.dart';
import 'rustore_service.dart';

@pragma('vm:entry-point')
void onDidReceiveBackgroundCustomApiNotificationResponse(
  NotificationResponse response,
) {
  debugPrint(
    'Custom API notification tapped in background: ${response.payload}',
  );
}

typedef ChatNotificationCallback = Future<void> Function({
  required String chatId,
  required String senderId,
  required String senderName,
  required String messageText,
  required int notificationId,
});

typedef GenericNotificationCallback = Future<void> Function({
  required String title,
  required String body,
  required int notificationId,
  String? payload,
});

typedef RemotePushTokenProvider = Future<String?> Function();

class CustomApiNotificationService implements NotificationServiceInterface {
  CustomApiNotificationService._({
    required FlutterLocalNotificationsPlugin plugin,
    required SharedPreferences preferences,
    CustomApiAuthService? authService,
    BackendRuntimeConfig? runtimeConfig,
    CustomApiRealtimeService? realtimeService,
    RustoreService? rustoreService,
    http.Client? httpClient,
    Duration? pollInterval,
    RemotePushTokenProvider? remotePushTokenProvider,
    ChatNotificationCallback? onChatNotification,
    GenericNotificationCallback? onGenericNotification,
  })  : _plugin = plugin,
        _preferences = preferences,
        _authService = authService,
        _runtimeConfig = runtimeConfig,
        _realtimeService = realtimeService,
        _rustoreService = rustoreService,
        _httpClient = httpClient ?? http.Client(),
        _pollInterval = pollInterval ?? const Duration(seconds: 5),
        _remotePushTokenProvider = remotePushTokenProvider,
        _onChatNotification = onChatNotification,
        _onGenericNotification = onGenericNotification;

  static const String _deliveredIdsStorageKey =
      'custom_api_delivered_notification_ids_v1';
  static const String _registeredPushTokenStorageKey =
      'custom_api_registered_push_token_v1';

  static Future<CustomApiNotificationService> create({
    FlutterLocalNotificationsPlugin? plugin,
    SharedPreferences? preferences,
    CustomApiAuthService? authService,
    BackendRuntimeConfig? runtimeConfig,
    CustomApiRealtimeService? realtimeService,
    RustoreService? rustoreService,
    http.Client? httpClient,
    Duration? pollInterval,
    RemotePushTokenProvider? remotePushTokenProvider,
    ChatNotificationCallback? onChatNotification,
    GenericNotificationCallback? onGenericNotification,
  }) async {
    return CustomApiNotificationService._(
      plugin: plugin ?? FlutterLocalNotificationsPlugin(),
      preferences: preferences ?? await SharedPreferences.getInstance(),
      authService: authService,
      runtimeConfig: runtimeConfig,
      realtimeService: realtimeService,
      rustoreService: rustoreService,
      httpClient: httpClient,
      pollInterval: pollInterval,
      remotePushTokenProvider: remotePushTokenProvider,
      onChatNotification: onChatNotification,
      onGenericNotification: onGenericNotification,
    );
  }

  final FlutterLocalNotificationsPlugin _plugin;
  final SharedPreferences _preferences;
  final CustomApiAuthService? _authService;
  final BackendRuntimeConfig? _runtimeConfig;
  final CustomApiRealtimeService? _realtimeService;
  final RustoreService? _rustoreService;
  final http.Client _httpClient;
  final Duration _pollInterval;
  final RemotePushTokenProvider? _remotePushTokenProvider;
  final ChatNotificationCallback? _onChatNotification;
  final GenericNotificationCallback? _onGenericNotification;

  bool _isInitialized = false;
  String? _pendingNavigationPayload;
  Timer? _pollingTimer;
  StreamSubscription<CustomApiRealtimeEvent>? _realtimeSubscription;
  final Set<String> _deliveredNotificationIds = <String>{};

  static const String _channelIdGeneral = 'lineage_custom_general';
  static const String _channelNameGeneral = 'Родня уведомления';
  static const String _channelDescGeneral =
      'Локальные уведомления приложения Родня';

  static const String _channelIdEvents = 'lineage_custom_events';
  static const String _channelNameEvents = 'Родня события';
  static const String _channelDescEvents =
      'Напоминания о событиях семьи и локальные уведомления чатов';

  @override
  Future<void> initialize() async {
    _deliveredNotificationIds
      ..clear()
      ..addAll(_preferences.getStringList(_deliveredIdsStorageKey) ?? const []);

    if (kIsWeb || _isInitialized) {
      _isInitialized = true;
      return;
    }

    const initializationSettingsAndroid = AndroidInitializationSettings(
      '@drawable/ic_stat_notification',
    );
    const initializationSettingsIOS = DarwinInitializationSettings();
    const initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await _plugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: _onDidReceiveNotificationResponse,
      onDidReceiveBackgroundNotificationResponse:
          onDidReceiveBackgroundCustomApiNotificationResponse,
    );

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelIdGeneral,
        _channelNameGeneral,
        description: _channelDescGeneral,
        importance: Importance.defaultImportance,
      ),
    );
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelIdEvents,
        _channelNameEvents,
        description: _channelDescEvents,
        importance: Importance.high,
      ),
    );

    await _restoreLaunchNotificationPayload();
    _isInitialized = true;
  }

  Future<void> startForegroundSync() async {
    await initialize();
    if (kIsWeb || _authService == null || _runtimeConfig == null) {
      return;
    }

    await _registerRemotePushDevice();

    if (_realtimeService != null) {
      await _realtimeService!.connect();
      await _realtimeSubscription?.cancel();
      _realtimeSubscription = _realtimeService!.events
          .where((event) => event.isNotificationEvent)
          .listen((event) {
        final notification = event.notification;
        if (notification == null) {
          return;
        }
        unawaited(_handleRealtimeNotification(notification));
      });
    }

    _pollingTimer?.cancel();
    await syncPendingNotifications();
    _pollingTimer = Timer.periodic(_pollInterval, (_) {
      unawaited(syncPendingNotifications());
    });

    final pendingPayload = _pendingNavigationPayload;
    if (pendingPayload != null && pendingPayload.isNotEmpty) {
      _schedulePayloadNavigation(pendingPayload);
    }
  }

  Future<void> syncPendingNotifications() async {
    final authService = _authService;
    final runtimeConfig = _runtimeConfig;
    if (authService == null || runtimeConfig == null) {
      return;
    }
    final accessToken = authService.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      return;
    }

    final token = authService.accessToken;
    if (token == null || token.isEmpty) {
      return;
    }

    final response = await _httpClient.get(
      _buildUri(runtimeConfig, '/v1/notifications?status=unread&limit=20'),
      headers: _headers(token),
    );

    final payload = _decodeResponse(response);
    final rawNotifications = payload['notifications'];
    if (rawNotifications is! List<dynamic>) {
      return;
    }

    final notifications = rawNotifications
        .whereType<Map<String, dynamic>>()
        .where((notification) {
      final id = notification['id']?.toString() ?? '';
      return id.isNotEmpty && !_deliveredNotificationIds.contains(id);
    }).toList()
      ..sort((left, right) {
        return (left['createdAt']?.toString() ?? '')
            .compareTo(right['createdAt']?.toString() ?? '');
      });

    for (final notification in notifications) {
      await _showBackendNotification(notification);
      final id = notification['id']!.toString();
      _deliveredNotificationIds.add(id);
      await _persistDeliveredNotificationIds();
    }
  }

  @override
  Future<void> showBirthdayNotification(
    lineage_models.FamilyPerson person,
  ) async {
    if (kIsWeb) {
      return;
    }
    await initialize();

    await _plugin.show(
      person.id.hashCode,
      'День рождения',
      'Сегодня день рождения у ${person.name}',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelIdEvents,
          _channelNameEvents,
          channelDescription: _channelDescEvents,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }

  @override
  Future<void> showChatMessageNotification({
    required String chatId,
    required String senderId,
    required String senderName,
    required String messageText,
    required int notificationId,
  }) async {
    if (kIsWeb) {
      return;
    }
    await initialize();

    if (_onChatNotification != null) {
      await _onChatNotification!(
        chatId: chatId,
        senderId: senderId,
        senderName: senderName,
        messageText: messageText,
        notificationId: notificationId,
      );
      return;
    }

    final shortText = messageText.length > 120
        ? '${messageText.substring(0, 117)}...'
        : messageText;

    await _plugin.show(
      notificationId,
      senderName,
      shortText,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelIdGeneral,
          _channelNameGeneral,
          channelDescription: _channelDescGeneral,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: jsonEncode({
        'type': 'chat',
        'chatId': chatId,
        'senderId': senderId,
        'senderName': senderName,
        'messageText': messageText,
      }),
    );
  }

  Future<void> _handleRealtimeNotification(
    Map<String, dynamic> notification,
  ) async {
    final id = notification['id']?.toString() ?? '';
    if (id.isEmpty || _deliveredNotificationIds.contains(id)) {
      return;
    }

    await _showBackendNotification(notification);
    _deliveredNotificationIds.add(id);
    await _persistDeliveredNotificationIds();
  }

  Future<void> _showBackendNotification(
      Map<String, dynamic> notification) async {
    final id = notification['id']?.toString() ?? '';
    final type = notification['type']?.toString() ?? 'generic';
    final title = notification['title']?.toString() ?? 'Родня';
    final body = notification['body']?.toString() ?? '';
    final data = notification['data'];
    final payload = jsonEncode({
      'id': id,
      'type': type,
      'data': data is Map<String, dynamic> ? data : const <String, dynamic>{},
    });

    if (type == 'chat_message') {
      final chatData =
          data is Map<String, dynamic> ? data : const <String, dynamic>{};
      await showChatMessageNotification(
        chatId: chatData['chatId']?.toString() ?? '',
        senderId: chatData['senderId']?.toString() ?? '',
        senderName: chatData['senderName']?.toString() ?? title,
        messageText: body,
        notificationId: id.hashCode,
      );
      return;
    }

    await _showGenericNotification(
      title: title,
      body: body,
      notificationId: id.hashCode,
      payload: payload,
    );
  }

  Future<void> _registerRemotePushDevice() async {
    if (kIsWeb) {
      return;
    }

    final authService = _authService;
    final runtimeConfig = _runtimeConfig;
    if (authService == null || runtimeConfig == null) {
      return;
    }
    final accessToken = authService.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      return;
    }

    final token = await _resolveRemotePushToken();
    if (token == null || token.isEmpty) {
      return;
    }

    final registeredFingerprint = _preferences.getString(
      _registeredPushTokenStorageKey,
    );
    final nextFingerprint =
        'rustore::$token::${authService.currentUserId ?? ''}';
    if (registeredFingerprint == nextFingerprint) {
      return;
    }

    final response = await _httpClient.post(
      _buildUri(runtimeConfig, '/v1/push/devices'),
      headers: _headers(accessToken),
      body: jsonEncode({
        'provider': 'rustore',
        'token': token,
        'platform': defaultTargetPlatform.name,
      }),
    );
    _decodeResponse(response);

    await _preferences.setString(
      _registeredPushTokenStorageKey,
      nextFingerprint,
    );
  }

  Future<String?> _resolveRemotePushToken() async {
    if (_remotePushTokenProvider != null) {
      return _remotePushTokenProvider!();
    }

    final rustoreService = _rustoreService;
    if (rustoreService == null) {
      return null;
    }

    return rustoreService.getRustorePushToken();
  }

  Future<void> _showGenericNotification({
    required String title,
    required String body,
    required int notificationId,
    String? payload,
  }) async {
    await initialize();

    if (_onGenericNotification != null) {
      await _onGenericNotification!(
        title: title,
        body: body,
        notificationId: notificationId,
        payload: payload,
      );
      return;
    }

    await _plugin.show(
      notificationId,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelIdGeneral,
          _channelNameGeneral,
          channelDescription: _channelDescGeneral,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: payload,
    );
  }

  Future<void> _restoreLaunchNotificationPayload() async {
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    final payload = launchDetails?.notificationResponse?.payload;
    if (launchDetails?.didNotificationLaunchApp == true &&
        payload != null &&
        payload.isNotEmpty) {
      _schedulePayloadNavigation(payload);
    }
  }

  void _onDidReceiveNotificationResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) {
      return;
    }
    _schedulePayloadNavigation(payload);
  }

  void _schedulePayloadNavigation(String payload, {int attempt = 0}) {
    final navigatorContext = rootNavigatorKey.currentContext;
    if (navigatorContext == null) {
      _pendingNavigationPayload = payload;
      if (attempt >= 12) {
        return;
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future<void>.delayed(const Duration(milliseconds: 250), () {
          _schedulePayloadNavigation(payload, attempt: attempt + 1);
        });
      });
      return;
    }

    _pendingNavigationPayload = null;
    unawaited(_handlePayloadNavigation(payload, navigatorContext));
  }

  Future<void> _handlePayloadNavigation(
    String payload,
    BuildContext navigatorContext,
  ) async {
    final rootPayload = _tryDecodePayload(payload);
    final type = rootPayload['type']?.toString() ?? '';
    final data = _asStringDynamicMap(rootPayload['data']);

    if (type == 'chat' || type == 'chat_message') {
      final router = GoRouter.of(navigatorContext);
      final senderId =
          rootPayload['senderId']?.toString() ?? data['senderId']?.toString();
      final senderName = rootPayload['senderName']?.toString() ??
          data['senderName']?.toString() ??
          'Пользователь';
      if (senderId == null || senderId.isEmpty) {
        return;
      }

      final relativeId = await _resolveRelativeIdForUser(senderId);
      if (relativeId == null || relativeId.isEmpty) {
        router.go('/user/$senderId');
        return;
      }

      final encodedName = Uri.encodeComponent(senderName);
      router.go('/chat/$senderId?relativeId=$relativeId&name=$encodedName');
      return;
    }

    if (type == 'birthday') {
      final personId =
          rootPayload['personId']?.toString() ?? data['personId']?.toString();
      if (personId != null && personId.isNotEmpty) {
        GoRouter.of(navigatorContext).go('/relative/details/$personId');
      }
      return;
    }

    if (type == 'relation_request') {
      final treeId =
          rootPayload['treeId']?.toString() ?? data['treeId']?.toString();
      if (treeId != null && treeId.isNotEmpty) {
        GoRouter.of(navigatorContext).go('/relatives/requests/$treeId');
      }
      return;
    }

    if (type == 'tree_invitation' || type == 'tree_update') {
      final treeId =
          rootPayload['treeId']?.toString() ?? data['treeId']?.toString();
      if (treeId != null && treeId.isNotEmpty) {
        GoRouter.of(navigatorContext).go('/tree/view/$treeId');
      }
      return;
    }

    final treeId =
        rootPayload['treeId']?.toString() ?? data['treeId']?.toString();
    if (treeId != null && treeId.isNotEmpty) {
      GoRouter.of(navigatorContext).go('/tree/view/$treeId');
    }
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

  Map<String, dynamic> _tryDecodePayload(String payload) {
    try {
      final decoded = jsonDecode(payload);
      return _asStringDynamicMap(decoded);
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  Map<String, dynamic> _asStringDynamicMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map(
        (key, mapValue) => MapEntry(key.toString(), mapValue),
      );
    }
    return const <String, dynamic>{};
  }

  Uri _buildUri(BackendRuntimeConfig runtimeConfig, String path) {
    final normalizedBase = runtimeConfig.apiBaseUrl.replaceAll(
      RegExp(r'/$'),
      '',
    );
    return Uri.parse('$normalizedBase$path');
  }

  Map<String, String> _headers(String token) {
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    if (response.body.isEmpty) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return const <String, dynamic>{};
      }
      throw const CustomApiException('Пустой ответ от backend');
    }

    final dynamic decoded = jsonDecode(response.body);
    final payload = decoded is Map<String, dynamic>
        ? decoded
        : <String, dynamic>{'data': decoded};

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return payload;
    }

    throw CustomApiException(
      payload['message']?.toString() ??
          'Ошибка backend (${response.statusCode})',
      statusCode: response.statusCode,
    );
  }

  Future<void> _persistDeliveredNotificationIds() async {
    final sortedIds = _deliveredNotificationIds.toList()
      ..sort((left, right) => left.compareTo(right));
    final trimmedIds = sortedIds.length > 200
        ? sortedIds.sublist(sortedIds.length - 200)
        : sortedIds;

    _deliveredNotificationIds
      ..clear()
      ..addAll(trimmedIds);
    await _preferences.setStringList(
      _deliveredIdsStorageKey,
      trimmedIds,
    );
  }

  Future<void> dispose() async {
    _pollingTimer?.cancel();
    await _realtimeSubscription?.cancel();
  }
}
