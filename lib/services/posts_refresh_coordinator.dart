import 'dart:async';

/// Coordinates auto-refresh of the home feed when new posts arrive
/// via realtime либо push.
///
/// Flow:
/// 1. Backend `post_created` notification published via
///    `createAndDispatchNotification`. Two channels carry it:
///    - WebSocket `notification.created` event (foreground users)
///    - Push gateway FCM/RuStore/web-push (background users)
/// 2. Client `_handleRealtimeNotification` (and equivalent push tap
///    handler) calls `PostsRefreshCoordinator.instance.requestRefresh()`.
/// 3. Home feed registers callback via [register] when widget mounts.
/// 4. Coordinator debounces requests (500ms) — burst of N pushes
///    coalesces в один refresh call.
///
/// Singleton. Изначально был single-subscriber (одна лента); с шага 5
/// bulk-upload подписчиков двое — home-лента и профиль «Мои записи»
/// (фоновая публикация закрывает composer до ACK, и pop(true) больше
/// не сигналит экранам об успехе).
class PostsRefreshCoordinator {
  PostsRefreshCoordinator._();

  static final PostsRefreshCoordinator instance = PostsRefreshCoordinator._();

  static const Duration _debounceWindow = Duration(milliseconds: 500);

  // Вторая feed-поверхность появилась (профиль «Мои записи» после фоновой
  // публикации шага 5) — single-subscriber повышен до множества, как и
  // предвещал комментарий выше. LinkedHashSet держит порядок регистрации;
  // сравнение — по identity колбэка, как раньше.
  final Set<Future<void> Function()> _callbacks = <Future<void> Function()>{};
  Timer? _debounceTimer;

  /// `true` если у coordinator есть хотя бы один subscriber, который
  /// примет refresh request. False — pending requests дропаются (no-op),
  /// потому что нет UI surface чтобы refetch'ить.
  bool get hasSubscriber => _callbacks.isNotEmpty;

  /// Register a refresh callback. Каждая поверхность регистрирует свой
  /// identity-stable колбэк; повторная регистрация того же — no-op.
  void register(Future<void> Function() callback) {
    _callbacks.add(callback);
  }

  /// Unregister callback (на dispose of subscriber). Последний ушедший
  /// гасит pending debounce timer, чтобы dangling callback не вызвался.
  void unregister(Future<void> Function() callback) {
    _callbacks.remove(callback);
    if (_callbacks.isEmpty) {
      _debounceTimer?.cancel();
      _debounceTimer = null;
    }
  }

  /// Request a refresh. Debounced — multiple requests within
  /// [_debounceWindow] collapse в один общий залп по всем subscribers.
  /// No-op если нет ни одного — refresh would have nothing to do.
  void requestRefresh() {
    if (_callbacks.isEmpty) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceWindow, _fire);
  }

  Future<void> _fire() async {
    _debounceTimer = null;
    // Копия: колбэк может отписаться прямо из своего же вызова.
    for (final callback in List<Future<void> Function()>.of(_callbacks)) {
      try {
        await callback();
      } catch (_) {
        // Refresh callbacks should swallow their own errors; coordinator
        // не должен крашить от UI-level failures. Silent — каждый
        // refresh is best-effort, next push triggers retry.
      }
    }
  }
}
