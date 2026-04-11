enum BackendProviderKind { customApi }

class BackendProviderConfig {
  const BackendProviderConfig({
    this.authProvider = BackendProviderKind.customApi,
    this.profileProvider = BackendProviderKind.customApi,
    this.treeProvider = BackendProviderKind.customApi,
    this.chatProvider = BackendProviderKind.customApi,
    this.storageProvider = BackendProviderKind.customApi,
    this.notificationProvider = BackendProviderKind.customApi,
  });

  final BackendProviderKind authProvider;
  final BackendProviderKind profileProvider;
  final BackendProviderKind treeProvider;
  final BackendProviderKind chatProvider;
  final BackendProviderKind storageProvider;
  final BackendProviderKind notificationProvider;

  static BackendProviderConfig get current {
    return const BackendProviderConfig();
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
    bool isWebRuntime = false,
    bool hasWebFirebaseOptions = false,
  }) {
    return const BackendProviderConfig();
  }
}
