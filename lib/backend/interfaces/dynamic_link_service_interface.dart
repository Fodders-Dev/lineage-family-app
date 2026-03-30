import 'package:go_router/go_router.dart';

abstract class DynamicLinkServiceInterface {
  Future<void> startListening(GoRouter router);
  void dispose();
}
