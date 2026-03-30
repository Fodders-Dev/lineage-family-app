import 'backend_provider_config.dart';

class BackendRuntimeConfig {
  const BackendRuntimeConfig({
    this.publicAppUrl = 'https://rodnya-tree.ru',
    this.apiBaseUrl = 'https://api.rodnya-tree.ru',
    this.webSocketBaseUrl = 'wss://api.rodnya-tree.ru',
    this.supabaseUrl = _defaultSupabaseUrl,
    this.supabaseAnonKey = _defaultSupabaseAnonKey,
    this.enableLegacyDynamicLinks = true,
  });

  static const String _defaultSupabaseUrl =
      'https://aldugysbnodrfughcawu.supabase.co';
  static const String _defaultSupabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
      'eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFsZHVneXNibm9kcmZ1Z2hjYXd1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDM0MjM3OTQsImV4cCI6MjA1ODk5OTc5NH0.'
      'e_IyhyA5pv2tbi2wdCgdw5a2K0BaYxQsrxQdE459Prg';
  static const String _publicAppUrlEnv = String.fromEnvironment(
    'LINEAGE_PUBLIC_APP_URL',
    defaultValue: '',
  );
  static const String _apiBaseUrlEnv = String.fromEnvironment(
    'LINEAGE_API_BASE_URL',
    defaultValue: '',
  );
  static const String _webSocketBaseUrlEnv = String.fromEnvironment(
    'LINEAGE_WS_BASE_URL',
    defaultValue: '',
  );
  static const String _supabaseUrlEnv = String.fromEnvironment(
    'LINEAGE_SUPABASE_URL',
    defaultValue: '',
  );
  static const String _supabaseAnonKeyEnv = String.fromEnvironment(
    'LINEAGE_SUPABASE_ANON_KEY',
    defaultValue: '',
  );
  static const String _legacyDynamicLinksEnv = String.fromEnvironment(
    'LINEAGE_ENABLE_LEGACY_DYNAMIC_LINKS',
    defaultValue: '',
  );
  static const String _runtimePresetEnv = String.fromEnvironment(
    'LINEAGE_RUNTIME_PRESET',
    defaultValue: '',
  );

  final String publicAppUrl;
  final String apiBaseUrl;
  final String webSocketBaseUrl;
  final String supabaseUrl;
  final String supabaseAnonKey;
  final bool enableLegacyDynamicLinks;

  static BackendRuntimeConfig get current {
    return resolve(
      runtimePresetRaw: _runtimePresetEnv,
      publicAppUrlRaw: _publicAppUrlEnv,
      apiBaseUrlRaw: _apiBaseUrlEnv,
      webSocketBaseUrlRaw: _webSocketBaseUrlEnv,
      supabaseUrlRaw: _supabaseUrlEnv,
      supabaseAnonKeyRaw: _supabaseAnonKeyEnv,
      legacyDynamicLinksRaw: _legacyDynamicLinksEnv,
    );
  }

  static BackendRuntimeConfig resolve({
    String runtimePresetRaw = '',
    String publicAppUrlRaw = '',
    String apiBaseUrlRaw = '',
    String webSocketBaseUrlRaw = '',
    String supabaseUrlRaw = '',
    String supabaseAnonKeyRaw = '',
    String legacyDynamicLinksRaw = '',
    BackendProviderConfig? providerConfig,
  }) {
    final runtimePreset = runtimePresetRaw.trim();
    final resolvedProviderConfig =
        providerConfig ?? BackendProviderConfig.current;
    final isProdCustomApiPreset = runtimePreset == 'prod_custom_api';
    final fallbackApiBaseUrl = 'https://api.rodnya-tree.ru';
    final resolvedApiBaseUrl =
        _stringFromRaw(apiBaseUrlRaw, fallbackApiBaseUrl);
    final resolvedPublicAppUrl = _stringFromRaw(
      publicAppUrlRaw,
      'https://rodnya-tree.ru',
    );
    final resolvedWebSocketBaseUrl = _stringFromRaw(
      webSocketBaseUrlRaw,
      defaultWebSocketBaseUrl(resolvedApiBaseUrl),
    );
    final resolvedSupabaseUrl = _stringFromRaw(
      supabaseUrlRaw,
      _defaultSupabaseUrl,
    );
    final resolvedSupabaseAnonKey = _stringFromRaw(
      supabaseAnonKeyRaw,
      _defaultSupabaseAnonKey,
    );
    final resolvedLegacyDynamicLinks = _boolFromRaw(
      legacyDynamicLinksRaw,
      isProdCustomApiPreset
          ? false
          : defaultEnableLegacyDynamicLinks(
              providerConfig: resolvedProviderConfig),
    );

    return BackendRuntimeConfig(
      publicAppUrl: resolvedPublicAppUrl,
      apiBaseUrl: resolvedApiBaseUrl,
      webSocketBaseUrl: resolvedWebSocketBaseUrl,
      supabaseUrl: resolvedSupabaseUrl,
      supabaseAnonKey: resolvedSupabaseAnonKey,
      enableLegacyDynamicLinks: resolvedLegacyDynamicLinks,
    );
  }

  static bool defaultEnableLegacyDynamicLinks({
    required BackendProviderConfig providerConfig,
  }) {
    return !(providerConfig.authProvider == BackendProviderKind.customApi &&
        providerConfig.profileProvider == BackendProviderKind.customApi);
  }

  static String defaultWebSocketBaseUrl(String apiBaseUrl) {
    final trimmed = apiBaseUrl.trim();
    if (trimmed.startsWith('https://')) {
      return 'wss://${trimmed.substring('https://'.length)}';
    }
    if (trimmed.startsWith('http://')) {
      return 'ws://${trimmed.substring('http://'.length)}';
    }
    return trimmed;
  }

  static String _stringFromRaw(String rawValue, String fallback) {
    final resolved = rawValue.trim();
    return resolved.isEmpty ? fallback : resolved;
  }

  static bool _boolFromRaw(String rawValue, bool fallback) {
    final resolved = rawValue.trim();
    if (resolved.isEmpty) {
      return fallback;
    }

    switch (resolved.toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
      case 'on':
        return true;
      case 'false':
      case '0':
      case 'no':
      case 'off':
        return false;
      default:
        return fallback;
    }
  }
}
