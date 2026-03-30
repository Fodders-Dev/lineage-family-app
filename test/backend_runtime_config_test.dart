import 'package:flutter_test/flutter_test.dart';
import 'package:lineage/backend/backend_provider_config.dart';
import 'package:lineage/backend/backend_runtime_config.dart';

void main() {
  test('BackendRuntimeConfig uses legacy-compatible defaults', () {
    const config = BackendRuntimeConfig();

    expect(config.publicAppUrl, 'https://lineage.app');
    expect(config.apiBaseUrl, 'https://api.lineage.app');
    expect(config.webSocketBaseUrl, 'wss://api.lineage.app');
    expect(config.supabaseUrl, 'https://aldugysbnodrfughcawu.supabase.co');
    expect(config.supabaseAnonKey, isNotEmpty);
    expect(config.enableLegacyDynamicLinks, isTrue);
  });

  test('BackendRuntimeConfig allows explicit runtime overrides', () {
    const config = BackendRuntimeConfig(
      publicAppUrl: 'https://family.example.ru',
      apiBaseUrl: 'https://api.family.example.ru',
      webSocketBaseUrl: 'wss://ws.family.example.ru',
      supabaseUrl: 'https://supabase.internal',
      supabaseAnonKey: 'test-key',
      enableLegacyDynamicLinks: false,
    );

    expect(config.publicAppUrl, 'https://family.example.ru');
    expect(config.apiBaseUrl, 'https://api.family.example.ru');
    expect(config.webSocketBaseUrl, 'wss://ws.family.example.ru');
    expect(config.supabaseUrl, 'https://supabase.internal');
    expect(config.supabaseAnonKey, 'test-key');
    expect(config.enableLegacyDynamicLinks, isFalse);
  });

  test(
    'BackendRuntimeConfig disables legacy dynamic links by default for custom auth/profile phase',
    () {
      const providerConfig = BackendProviderConfig(
        authProvider: BackendProviderKind.customApi,
        profileProvider: BackendProviderKind.customApi,
      );

      expect(
        BackendRuntimeConfig.defaultEnableLegacyDynamicLinks(
          providerConfig: providerConfig,
        ),
        isFalse,
      );
    },
  );

  test('BackendRuntimeConfig derives websocket url from api url', () {
    expect(
      BackendRuntimeConfig.defaultWebSocketBaseUrl(
        'https://api.family.example.ru',
      ),
      'wss://api.family.example.ru',
    );
    expect(
      BackendRuntimeConfig.defaultWebSocketBaseUrl(
        'http://127.0.0.1:8080',
      ),
      'ws://127.0.0.1:8080',
    );
  });

  test(
    'BackendRuntimeConfig prod_custom_api preset disables legacy dynamic links',
    () {
      final config = BackendRuntimeConfig.resolve(
        runtimePresetRaw: 'prod_custom_api',
        providerConfig: const BackendProviderConfig(),
      );

      expect(config.publicAppUrl, 'https://lineage.app');
      expect(config.apiBaseUrl, 'https://api.lineage.app');
      expect(config.webSocketBaseUrl, 'wss://api.lineage.app');
      expect(config.enableLegacyDynamicLinks, isFalse);
    },
  );

  test(
    'BackendRuntimeConfig resolve honors explicit overrides on top of preset',
    () {
      final config = BackendRuntimeConfig.resolve(
        runtimePresetRaw: 'prod_custom_api',
        publicAppUrlRaw: 'https://family.example.ru',
        apiBaseUrlRaw: 'https://api.family.example.ru',
        webSocketBaseUrlRaw: 'wss://socket.family.example.ru',
        legacyDynamicLinksRaw: 'true',
      );

      expect(config.publicAppUrl, 'https://family.example.ru');
      expect(config.apiBaseUrl, 'https://api.family.example.ru');
      expect(config.webSocketBaseUrl, 'wss://socket.family.example.ru');
      expect(config.enableLegacyDynamicLinks, isTrue);
    },
  );
}
