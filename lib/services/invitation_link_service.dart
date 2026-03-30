import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/invitation_link_service_interface.dart';

class HttpInvitationLinkService implements InvitationLinkServiceInterface {
  HttpInvitationLinkService({
    String? publicAppUrl,
    BackendRuntimeConfig? runtimeConfig,
  }) : _publicAppUrl = publicAppUrl ??
            runtimeConfig?.publicAppUrl ??
            BackendRuntimeConfig.current.publicAppUrl;

  final String _publicAppUrl;

  @override
  Uri buildInvitationLink({required String treeId, required String personId}) {
    final baseUri = Uri.parse(_publicAppUrl);
    final normalizedPath = _appendInvitePath(baseUri.path);
    return baseUri.replace(
      path: normalizedPath,
      queryParameters: {'treeId': treeId, 'personId': personId},
    );
  }

  String _appendInvitePath(String existingPath) {
    final normalized = existingPath.endsWith('/')
        ? existingPath.substring(0, existingPath.length - 1)
        : existingPath;
    if (normalized.isEmpty) {
      return '/invite';
    }
    return '$normalized/invite';
  }
}
