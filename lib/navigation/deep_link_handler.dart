import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../backend/interfaces/dynamic_link_service_interface.dart';

class DeepLinkHandler {
  DeepLinkHandler({required this.router})
      : _dynamicLinkService = GetIt.I<DynamicLinkServiceInterface>();

  final GoRouter router;
  final DynamicLinkServiceInterface _dynamicLinkService;

  Future<void> initDynamicLinks() {
    return _dynamicLinkService.startListening(router);
  }

  void dispose() {
    _dynamicLinkService.dispose();
  }
}
