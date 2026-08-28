import 'package:flutter_test/flutter_test.dart';
import 'package:rodnya/services/posts_refresh_coordinator.dart';

void main() {
  // Coordinator is a singleton — every test cleans up its own callback
  // through `unregister` so the next test starts from a known empty
  // state. We never re-create the singleton because the production
  // call-sites (HomeScreen, notification service) reach for the
  // same instance — testing through it is the right surface.
  group('PostsRefreshCoordinator', () {
    test('hasSubscriber reflects register / unregister lifecycle',
        () async {
      final coordinator = PostsRefreshCoordinator.instance;
      Future<void> cb() async {}
      expect(coordinator.hasSubscriber, isFalse);
      coordinator.register(cb);
      expect(coordinator.hasSubscriber, isTrue);
      coordinator.unregister(cb);
      expect(coordinator.hasSubscriber, isFalse);
    });

    test(
        'requestRefresh fires callback once when called multiple times '
        'within debounce window', () async {
      final coordinator = PostsRefreshCoordinator.instance;
      var fireCount = 0;
      Future<void> cb() async {
        fireCount += 1;
      }

      coordinator.register(cb);
      addTearDown(() => coordinator.unregister(cb));

      coordinator.requestRefresh();
      coordinator.requestRefresh();
      coordinator.requestRefresh();

      // Within debounce window — no fire yet.
      expect(fireCount, 0);

      // 500ms debounce + a small buffer for async scheduling.
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(fireCount, 1);
    });

    test('requestRefresh is a no-op without subscriber', () async {
      final coordinator = PostsRefreshCoordinator.instance;
      expect(coordinator.hasSubscriber, isFalse);
      // Should silently ignore, not throw.
      coordinator.requestRefresh();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(coordinator.hasSubscriber, isFalse);
    });

    test(
        'unregister with foreign callback does not drop active subscription '
        '(identity check)', () async {
      final coordinator = PostsRefreshCoordinator.instance;
      Future<void> cb1() async {}
      Future<void> cb2() async {}

      coordinator.register(cb1);
      addTearDown(() => coordinator.unregister(cb1));

      // cb2 was never registered — unregister should be a no-op.
      coordinator.unregister(cb2);
      expect(coordinator.hasSubscriber, isTrue);
    });

    test(
        'несколько подписчиков (лента + профиль) получают один общий залп; '
        'повторная регистрация того же колбэка не задваивает', () async {
      // Шаг 5 bulk-upload: single-subscriber повышен до множества — после
      // фоновой публикации обновляться должны и home-лента, и профиль
      // «Мои записи». Прежний контракт «last writer wins» упразднён.
      final coordinator = PostsRefreshCoordinator.instance;
      var cb1Count = 0;
      var cb2Count = 0;
      Future<void> cb1() async {
        cb1Count += 1;
      }

      Future<void> cb2() async {
        cb2Count += 1;
      }

      coordinator.register(cb1);
      coordinator.register(cb2);
      // Rebuild экрана регистрирует тот же identity-stable колбэк ещё раз —
      // это no-op, а не второй вызов.
      coordinator.register(cb1);
      addTearDown(() => coordinator.unregister(cb1));
      addTearDown(() => coordinator.unregister(cb2));

      coordinator.requestRefresh();
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(cb1Count, 1);
      expect(cb2Count, 1);

      // Отписавшийся больше не получает залпов, оставшийся — получает.
      coordinator.unregister(cb1);
      coordinator.requestRefresh();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(cb1Count, 1);
      expect(cb2Count, 2);
    });

    test('callback exception is swallowed — coordinator survives',
        () async {
      final coordinator = PostsRefreshCoordinator.instance;
      Future<void> badCb() async {
        throw StateError('boom');
      }

      coordinator.register(badCb);
      addTearDown(() => coordinator.unregister(badCb));

      coordinator.requestRefresh();
      await Future<void>.delayed(const Duration(milliseconds: 700));

      // Second request should still arm a new timer — coordinator
      // must not be in a broken state after one exception.
      var secondCount = 0;
      Future<void> followupCb() async {
        secondCount += 1;
      }

      coordinator.register(followupCb);
      addTearDown(() => coordinator.unregister(followupCb));

      coordinator.requestRefresh();
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(secondCount, 1);
    });
  });
}
