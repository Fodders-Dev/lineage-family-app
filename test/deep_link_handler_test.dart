import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:lineage/backend/interfaces/dynamic_link_service_interface.dart';
import 'package:lineage/navigation/deep_link_handler.dart';

class _FakeDynamicLinkService implements DynamicLinkServiceInterface {
  GoRouter? receivedRouter;
  var started = false;
  var disposed = false;

  @override
  Future<void> startListening(GoRouter router) async {
    started = true;
    receivedRouter = router;
  }

  @override
  void dispose() {
    disposed = true;
  }
}

void main() {
  final getIt = GetIt.I;

  setUp(() async {
    await getIt.reset();
  });

  tearDown(() async {
    await getIt.reset();
  });

  test(
    'DeepLinkHandler delegates to registered dynamic link service',
    () async {
      final fakeService = _FakeDynamicLinkService();
      getIt.registerSingleton<DynamicLinkServiceInterface>(fakeService);

      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const SizedBox.shrink(),
          ),
        ],
      );

      final handler = DeepLinkHandler(router: router);
      await handler.initDynamicLinks();

      expect(fakeService.started, isTrue);
      expect(fakeService.receivedRouter, same(router));

      handler.dispose();
      expect(fakeService.disposed, isTrue);
    },
  );
}
