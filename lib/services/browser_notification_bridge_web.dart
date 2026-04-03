import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:typed_data';

import 'browser_notification_bridge.dart';

class _HtmlBrowserNotificationBridge implements BrowserNotificationBridge {
  @override
  bool get isSupported => html.Notification.supported;

  @override
  bool get isPushSupported =>
      isSupported &&
      (html.window.isSecureContext ?? false) &&
      js_util.hasProperty(html.window.navigator, 'serviceWorker');

  @override
  BrowserNotificationPermissionStatus get permissionStatus =>
      _permissionFromRaw(html.Notification.permission ?? 'default');

  @override
  Future<BrowserNotificationPermissionStatus> requestPermission({
    bool prompt = true,
  }) async {
    if (!isSupported) {
      return BrowserNotificationPermissionStatus.unsupported;
    }
    if (!prompt) {
      return permissionStatus;
    }

    final rawPermission = await html.Notification.requestPermission();
    return _permissionFromRaw(rawPermission);
  }

  @override
  Future<void> showNotification({
    required String title,
    required String body,
    String? tag,
    void Function()? onClick,
  }) async {
    if (!isSupported ||
        permissionStatus != BrowserNotificationPermissionStatus.granted) {
      return;
    }

    final notification = html.Notification(
      title,
      body: body,
      tag: tag,
    );

    StreamSubscription<html.Event>? clickSubscription;
    clickSubscription = notification.onClick.listen((_) {
      onClick?.call();
      notification.close();
      unawaited(clickSubscription?.cancel());
    });

    unawaited(
      Future<void>.delayed(const Duration(seconds: 8), () {
        notification.close();
        unawaited(clickSubscription?.cancel());
      }),
    );
  }

  @override
  Future<BrowserPushSubscription?> subscribeToPush({
    required String publicKey,
  }) async {
    if (!isPushSupported ||
        permissionStatus != BrowserNotificationPermissionStatus.granted) {
      return null;
    }

    final serviceWorkerContainer =
        js_util.getProperty(html.window.navigator, 'serviceWorker');
    final registration = await js_util.promiseToFuture<dynamic>(
      js_util.callMethod(
        serviceWorkerContainer,
        'register',
        [
          '/push/push-sw.js',
          js_util.jsify(<String, dynamic>{'scope': '/push/'}),
        ],
      ),
    );

    final pushManager = js_util.getProperty(registration, 'pushManager');
    var subscription = await js_util.promiseToFuture<dynamic>(
      js_util.callMethod(pushManager, 'getSubscription', const []),
    );

    if (subscription == null) {
      final subscriptionOptions = js_util.newObject();
      js_util.setProperty(subscriptionOptions, 'userVisibleOnly', true);
      js_util.setProperty(
        subscriptionOptions,
        'applicationServerKey',
        _decodeBase64Url(publicKey),
      );
      subscription = await js_util.promiseToFuture<dynamic>(
        js_util.callMethod(
          pushManager,
          'subscribe',
          [subscriptionOptions],
        ),
      );
    }

    if (subscription == null) {
      return null;
    }

    final serialized = js_util.callMethod<dynamic>(
      subscription,
      'toJSON',
      const [],
    );
    final token = jsonEncode(js_util.dartify(serialized));
    return BrowserPushSubscription(token: token);
  }

  @override
  Future<void> unsubscribeFromPush() async {
    if (!isPushSupported) {
      return;
    }

    final serviceWorkerContainer =
        js_util.getProperty(html.window.navigator, 'serviceWorker');
    final registration = await js_util.promiseToFuture<dynamic>(
      js_util.callMethod(
        serviceWorkerContainer,
        'getRegistration',
        ['/push/'],
      ),
    );
    if (registration == null) {
      return;
    }

    final pushManager = js_util.getProperty(registration, 'pushManager');
    final subscription = await js_util.promiseToFuture<dynamic>(
      js_util.callMethod(pushManager, 'getSubscription', const []),
    );
    if (subscription == null) {
      return;
    }

    await js_util.promiseToFuture<dynamic>(
      js_util.callMethod(subscription, 'unsubscribe', const []),
    );
  }

  BrowserNotificationPermissionStatus _permissionFromRaw(String rawValue) {
    switch (rawValue) {
      case 'granted':
        return BrowserNotificationPermissionStatus.granted;
      case 'denied':
        return BrowserNotificationPermissionStatus.denied;
      case 'default':
        return BrowserNotificationPermissionStatus.defaultState;
      default:
        return BrowserNotificationPermissionStatus.unsupported;
    }
  }

  Uint8List _decodeBase64Url(String value) {
    final normalized = value
        .replaceAll('-', '+')
        .replaceAll('_', '/')
        .padRight((value.length + 3) & ~3, '=');
    return Uint8List.fromList(base64Decode(normalized));
  }
}

BrowserNotificationBridge createBrowserNotificationBridgeImpl() =>
    _HtmlBrowserNotificationBridge();
