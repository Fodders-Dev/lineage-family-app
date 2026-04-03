import 'browser_notification_bridge.dart';

class _StubBrowserNotificationBridge implements BrowserNotificationBridge {
  @override
  bool get isSupported => false;

  @override
  bool get isPushSupported => false;

  @override
  BrowserNotificationPermissionStatus get permissionStatus =>
      BrowserNotificationPermissionStatus.unsupported;

  @override
  Future<BrowserNotificationPermissionStatus> requestPermission({
    bool prompt = true,
  }) async {
    return BrowserNotificationPermissionStatus.unsupported;
  }

  @override
  Future<void> showNotification({
    required String title,
    required String body,
    String? tag,
    void Function()? onClick,
  }) async {}

  @override
  Future<BrowserPushSubscription?> subscribeToPush({
    required String publicKey,
  }) async {
    return null;
  }

  @override
  Future<void> unsubscribeFromPush() async {}
}

BrowserNotificationBridge createBrowserNotificationBridgeImpl() =>
    _StubBrowserNotificationBridge();
