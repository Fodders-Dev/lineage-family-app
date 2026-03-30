enum BackendProviderKind { firebase, supabase, hybridLegacy, customApi }

class BackendProviderConfig {
  const BackendProviderConfig({
    this.authProvider = BackendProviderKind.firebase,
    this.profileProvider = BackendProviderKind.firebase,
    this.treeProvider = BackendProviderKind.firebase,
    this.chatProvider = BackendProviderKind.firebase,
    this.storageProvider = BackendProviderKind.hybridLegacy,
    this.notificationProvider = BackendProviderKind.firebase,
  });

  final BackendProviderKind authProvider;
  final BackendProviderKind profileProvider;
  final BackendProviderKind treeProvider;
  final BackendProviderKind chatProvider;
  final BackendProviderKind storageProvider;
  final BackendProviderKind notificationProvider;

  static const String _authProviderEnv = String.fromEnvironment(
    'LINEAGE_AUTH_PROVIDER',
    defaultValue: '',
  );
  static const String _profileProviderEnv = String.fromEnvironment(
    'LINEAGE_PROFILE_PROVIDER',
    defaultValue: '',
  );
  static const String _treeProviderEnv = String.fromEnvironment(
    'LINEAGE_TREE_PROVIDER',
    defaultValue: '',
  );
  static const String _chatProviderEnv = String.fromEnvironment(
    'LINEAGE_CHAT_PROVIDER',
    defaultValue: '',
  );
  static const String _storageProviderEnv = String.fromEnvironment(
    'LINEAGE_STORAGE_PROVIDER',
    defaultValue: '',
  );
  static const String _notificationProviderEnv = String.fromEnvironment(
    'LINEAGE_NOTIFICATION_PROVIDER',
    defaultValue: '',
  );
  static const String _runtimePresetEnv = String.fromEnvironment(
    'LINEAGE_RUNTIME_PRESET',
    defaultValue: '',
  );

  static BackendProviderConfig get current {
    final runtimePreset = _runtimePresetEnv.trim();
    if (_usesProdCustomApiPreset(runtimePreset, Uri.base.host)) {
      return const BackendProviderConfig(
        authProvider: BackendProviderKind.customApi,
        profileProvider: BackendProviderKind.customApi,
        treeProvider: BackendProviderKind.customApi,
        chatProvider: BackendProviderKind.customApi,
        storageProvider: BackendProviderKind.customApi,
        notificationProvider: BackendProviderKind.customApi,
      );
    }

    return resolve(
      authProviderRaw: _authProviderEnv,
      profileProviderRaw: _profileProviderEnv,
      treeProviderRaw: _treeProviderEnv,
      chatProviderRaw: _chatProviderEnv,
      storageProviderRaw: _storageProviderEnv,
      notificationProviderRaw: _notificationProviderEnv,
    );
  }

  static BackendProviderConfig resolve({
    String runtimePresetRaw = '',
    String hostRaw = '',
    String authProviderRaw = '',
    String profileProviderRaw = '',
    String treeProviderRaw = '',
    String chatProviderRaw = '',
    String storageProviderRaw = '',
    String notificationProviderRaw = '',
  }) {
    if (_usesProdCustomApiPreset(runtimePresetRaw, hostRaw)) {
      return const BackendProviderConfig(
        authProvider: BackendProviderKind.customApi,
        profileProvider: BackendProviderKind.customApi,
        treeProvider: BackendProviderKind.customApi,
        chatProvider: BackendProviderKind.customApi,
        storageProvider: BackendProviderKind.customApi,
        notificationProvider: BackendProviderKind.customApi,
      );
    }

    final authProvider = _providerFromRaw(
      authProviderRaw,
      BackendProviderKind.firebase,
    );
    final defaultDomainProvider = authProvider == BackendProviderKind.customApi
        ? BackendProviderKind.customApi
        : BackendProviderKind.firebase;

    return BackendProviderConfig(
      authProvider: authProvider,
      profileProvider: _providerFromRaw(
        profileProviderRaw,
        defaultDomainProvider,
      ),
      treeProvider: _providerFromRaw(treeProviderRaw, defaultDomainProvider),
      chatProvider: _providerFromRaw(chatProviderRaw, defaultDomainProvider),
      storageProvider: _providerFromRaw(
        storageProviderRaw,
        authProvider == BackendProviderKind.customApi
            ? BackendProviderKind.customApi
            : BackendProviderKind.hybridLegacy,
      ),
      notificationProvider: _providerFromRaw(
        notificationProviderRaw,
        defaultDomainProvider,
      ),
    );
  }

  static BackendProviderKind _providerFromRaw(
    String rawValue,
    BackendProviderKind fallback,
  ) {
    final resolved = rawValue.trim();
    if (resolved.isEmpty) {
      return fallback;
    }

    return BackendProviderKind.values.firstWhere(
      (value) => value.name == resolved,
      orElse: () => fallback,
    );
  }

  static bool _usesProdCustomApiPreset(
      String runtimePresetRaw, String hostRaw) {
    final runtimePreset = runtimePresetRaw.trim();
    if (runtimePreset == 'prod_custom_api') {
      return true;
    }

    final normalizedHost = hostRaw.trim().toLowerCase();
    return normalizedHost == 'rodnya-tree.ru' ||
        normalizedHost == 'www.rodnya-tree.ru';
  }
}
