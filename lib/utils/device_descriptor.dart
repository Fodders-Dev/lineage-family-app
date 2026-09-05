import 'dart:async';
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Plain-Dart payload that the auth API expects on every login/register/QR
/// approval — small enough to inline into a JSON body without ceremony.
class DeviceDescriptor {
  const DeviceDescriptor({
    required this.deviceName,
    required this.platform,
    this.osVersion,
    required this.appVersion,
  });

  final String deviceName;
  final String platform;
  // Null when the platform channel can't report it (web has no single OS
  // version concept; some plugin failures leave it unresolved) — honest
  // absence beats a fabricated value.
  final String? osVersion;
  final String appVersion;

  Map<String, dynamic> toJson() => {
        'deviceName': deviceName,
        'platform': platform,
        if (osVersion != null && osVersion!.isNotEmpty) 'osVersion': osVersion,
        'appVersion': appVersion,
      };
}

/// Resolves a one-line label for the device, suitable for display in the
/// "Active sessions" list ("Иван's iPhone 15 Pro", "Pixel 7", "Chrome on
/// macOS").  Cached after the first build so subsequent auth calls don't pay
/// the platform-channel hop again.
class DeviceDescriptorBuilder {
  DeviceDescriptorBuilder._();

  static DeviceDescriptor? _cached;
  static Future<DeviceDescriptor>? _inflight;

  static Future<DeviceDescriptor> resolve() {
    final cached = _cached;
    if (cached != null) {
      return Future.value(cached);
    }
    return _inflight ??= _build()
      ..whenComplete(() {
        _inflight = null;
      });
  }

  static Future<DeviceDescriptor> _build() async {
    final appVersion = await _resolveAppVersion();
    final platform = _resolvePlatform();
    final deviceName = await _resolveDeviceName();
    final osVersion = await _resolveOsVersion();
    final descriptor = DeviceDescriptor(
      deviceName: deviceName,
      platform: platform,
      osVersion: osVersion,
      appVersion: appVersion,
    );
    _cached = descriptor;
    return descriptor;
  }

  static Future<String> _resolveAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version = info.version.isNotEmpty ? info.version : '0.0.0';
      final build = info.buildNumber;
      return build.isNotEmpty ? '$version+$build' : version;
    } catch (error) {
      debugPrint('DeviceDescriptor: package info failed: $error');
      return 'unknown';
    }
  }

  static String _resolvePlatform() {
    if (kIsWeb) return 'web';
    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
      if (Platform.isMacOS) return 'macos';
      if (Platform.isWindows) return 'windows';
      if (Platform.isLinux) return 'linux';
      if (Platform.isFuchsia) return 'fuchsia';
    } catch (_) {
      // Some environments throw if Platform is queried — treat as unknown.
    }
    return 'unknown';
  }

  static Future<String> _resolveDeviceName() async {
    try {
      final plugin = DeviceInfoPlugin();
      if (kIsWeb) {
        final info = await plugin.webBrowserInfo;
        final browser = info.browserName.name;
        final ua = info.userAgent ?? '';
        if (browser.isNotEmpty) {
          // Try to surface OS/host from the user-agent so users can tell
          // "Chrome on Mac" from "Chrome on Windows" at a glance.
          final os = _osFromUserAgent(ua);
          return os.isNotEmpty ? '$browser • $os' : browser;
        }
        return ua.isNotEmpty ? ua : 'Web browser';
      }
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        final manufacturer = (info.manufacturer).trim();
        final model = (info.model).trim();
        final marketing = (info.brand).trim();
        if (model.isNotEmpty && manufacturer.isNotEmpty) {
          return '$manufacturer $model'.trim();
        }
        return model.isNotEmpty ? model : (marketing.isNotEmpty ? marketing : 'Android');
      }
      if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        final name = info.name.trim();
        final model = info.utsname.machine.trim();
        if (name.isNotEmpty) return name;
        return model.isNotEmpty ? model : 'iPhone';
      }
      if (Platform.isMacOS) {
        final info = await plugin.macOsInfo;
        final name = info.computerName.trim();
        return name.isNotEmpty ? name : 'Mac';
      }
      if (Platform.isWindows) {
        final info = await plugin.windowsInfo;
        final name = info.computerName.trim();
        return name.isNotEmpty ? name : 'Windows PC';
      }
      if (Platform.isLinux) {
        final info = await plugin.linuxInfo;
        final name = info.prettyName.trim();
        return name.isNotEmpty ? name : 'Linux';
      }
    } catch (error) {
      debugPrint('DeviceDescriptor: device name lookup failed: $error');
    }
    return 'Неизвестное устройство';
  }

  /// One-line OS version for the "Active sessions" subtitle ("Android 14",
  /// "17.5", "23H2"). Best-effort: any plugin failure falls back to null
  /// rather than a guessed value, and the caller/backend already tolerate
  /// missing osVersion (additive field, old sessions never had it).
  static Future<String?> _resolveOsVersion() async {
    if (kIsWeb) {
      // Browser UA doesn't cleanly map to one OS version string across
      // vendors; the device name already carries "Chrome • macOS" via
      // _osFromUserAgent, so skip rather than guess.
      return null;
    }
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        final release = info.version.release.trim();
        return release.isNotEmpty ? release : null;
      }
      if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        final version = info.systemVersion.trim();
        return version.isNotEmpty ? version : null;
      }
      if (Platform.isMacOS) {
        final info = await plugin.macOsInfo;
        return '${info.majorVersion}.${info.minorVersion}.${info.patchVersion}';
      }
      if (Platform.isWindows) {
        final info = await plugin.windowsInfo;
        final display = info.displayVersion.trim();
        if (display.isNotEmpty) return display;
        final releaseId = info.releaseId.trim();
        return releaseId.isNotEmpty ? releaseId : null;
      }
      if (Platform.isLinux) {
        final info = await plugin.linuxInfo;
        final versionId = info.versionId?.trim();
        if (versionId != null && versionId.isNotEmpty) return versionId;
        final version = info.version?.trim();
        return (version != null && version.isNotEmpty) ? version : null;
      }
    } catch (error) {
      debugPrint('DeviceDescriptor: OS version lookup failed: $error');
    }
    return null;
  }

  static String _osFromUserAgent(String ua) {
    if (ua.contains('Windows NT')) return 'Windows';
    if (ua.contains('Mac OS X')) return 'macOS';
    if (ua.contains('iPhone') || ua.contains('iPad')) return 'iOS';
    if (ua.contains('Android')) return 'Android';
    if (ua.contains('Linux')) return 'Linux';
    return '';
  }
}
