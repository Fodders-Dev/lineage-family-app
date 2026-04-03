import 'package:flutter/foundation.dart';

import 'browser_notification_bridge_stub.dart'
    if (dart.library.html) 'browser_notification_bridge_web.dart';

enum BrowserNotificationPermissionStatus {
  granted,
  denied,
  defaultState,
  unsupported,
}

class BrowserPushSubscription {
  const BrowserPushSubscription({
    required this.token,
  });

  final String token;
}

abstract class BrowserNotificationBridge {
  bool get isSupported;
  bool get isPushSupported;
  BrowserNotificationPermissionStatus get permissionStatus;

  Future<BrowserNotificationPermissionStatus> requestPermission({
    bool prompt = true,
  });

  Future<void> showNotification({
    required String title,
    required String body,
    String? tag,
    VoidCallback? onClick,
  });

  Future<BrowserPushSubscription?> subscribeToPush({
    required String publicKey,
  });

  Future<void> unsubscribeFromPush();
}

BrowserNotificationBridge createBrowserNotificationBridge() =>
    createBrowserNotificationBridgeImpl();
