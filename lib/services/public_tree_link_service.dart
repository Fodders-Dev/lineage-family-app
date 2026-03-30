import '../backend/backend_runtime_config.dart';

class PublicTreeLinkService {
  static Uri buildPublicTreeUri(
    String publicTreeId, {
    String? publicAppUrl,
  }) {
    final baseUri = Uri.parse(
      publicAppUrl ?? BackendRuntimeConfig.current.publicAppUrl,
    );
    final normalizedBasePath =
        baseUri.path.isEmpty ? '/' : baseUri.path;
    final normalizedRoute = '/public/tree/${publicTreeId.trim()}';
    final existingFragment = baseUri.fragment.trim();

    if (existingFragment.isEmpty || existingFragment == '/') {
      return baseUri.replace(
        path: normalizedBasePath,
        fragment: normalizedRoute,
      );
    }

    final fragmentPath = existingFragment.startsWith('/')
        ? existingFragment
        : '/$existingFragment';
    final joinedFragment = [
      fragmentPath.replaceAll(RegExp(r'/$'), ''),
      normalizedRoute.replaceAll(RegExp(r'^/'), ''),
    ].join('/');

    return baseUri.replace(
      path: normalizedBasePath,
      fragment: joinedFragment,
    );
  }
}
