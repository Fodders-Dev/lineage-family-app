// DeviceDescriptor.toJson() wire-contract: deviceName/platform/appVersion
// are always present, osVersion is present-if-known. This is the piece
// that flows verbatim into the /v1/auth/login|register|refresh body as
// `deviceInfo`, so a missing/empty osVersion must be OMITTED rather than
// sent as an empty string — the backend treats an omitted key differently
// from an explicit empty one (normalizeOptionalString would turn '' into
// null anyway, but omitting keeps the wire payload honest and small).
import 'package:flutter_test/flutter_test.dart';
import 'package:rodnya/utils/device_descriptor.dart';

void main() {
  group('DeviceDescriptor.toJson', () {
    test('includes osVersion when known', () {
      const descriptor = DeviceDescriptor(
        deviceName: 'Samsung Galaxy S20 FE',
        platform: 'android',
        osVersion: '14',
        appVersion: '1.0.35+42',
      );

      final json = descriptor.toJson();

      expect(json['deviceName'], 'Samsung Galaxy S20 FE');
      expect(json['platform'], 'android');
      expect(json['osVersion'], '14');
      expect(json['appVersion'], '1.0.35+42');
    });

    test('omits osVersion key when null (web, or platform lookup failed)',
        () {
      const descriptor = DeviceDescriptor(
        deviceName: 'Chrome • macOS',
        platform: 'web',
        appVersion: '1.0.35',
      );

      final json = descriptor.toJson();

      expect(json.containsKey('osVersion'), isFalse);
      expect(json['deviceName'], 'Chrome • macOS');
      expect(json['platform'], 'web');
    });

    test('omits osVersion key when resolved to an empty string', () {
      const descriptor = DeviceDescriptor(
        deviceName: 'Linux box',
        platform: 'linux',
        osVersion: '',
        appVersion: '1.0.35',
      );

      final json = descriptor.toJson();

      expect(json.containsKey('osVersion'), isFalse);
    });
  });
}
