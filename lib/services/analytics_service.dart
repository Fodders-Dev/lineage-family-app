import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

class AnalyticsService {
  final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  // Получить экземпляр для использования в navigatorObservers
  FirebaseAnalytics get analytics => _analytics;

  // Логирование входа пользователя
  Future<void> logLogin({required String loginMethod}) async {
    if (kIsWeb) return; // Пропускаем для веб-платформы, если нужно

    await _analytics.logLogin(loginMethod: loginMethod);
  }

  // Логирование регистрации пользователя
  Future<void> logSignUp({required String signUpMethod}) async {
    if (kIsWeb) return;

    await _analytics.logSignUp(signUpMethod: signUpMethod);
  }

  // Логирование создания дерева
  Future<void> logTreeCreated({
    required String treeId,
    required String treeName,
  }) async {
    if (kIsWeb) return;

    await _analytics.logEvent(
      name: 'tree_created',
      parameters: {'tree_id': treeId, 'tree_name': treeName},
    );
  }

  // Логирование добавления родственника
  Future<void> logRelativeAdded({
    required String treeId,
    required String relativeId,
  }) async {
    if (kIsWeb) return;

    await _analytics.logEvent(
      name: 'relative_added',
      parameters: {'tree_id': treeId, 'relative_id': relativeId},
    );
  }

  // Логирование создания публикации
  Future<void> logPostCreated({
    required String postId,
    bool hasImages = false,
  }) async {
    if (kIsWeb) return;

    await _analytics.logEvent(
      name: 'post_created',
      parameters: {'post_id': postId, 'has_images': hasImages},
    );
  }

  // Логирование просмотра дерева
  Future<void> logViewTree({
    required String treeId,
    required String treeName,
  }) async {
    if (kIsWeb) return;

    await _analytics.logEvent(
      name: 'view_tree',
      parameters: {'tree_id': treeId, 'tree_name': treeName},
    );
  }

  // Установка пользовательских свойств
  Future<void> setUserProperties({
    String? userId,
    String? userRole,
    int? treeCount,
  }) async {
    if (kIsWeb) return;

    if (userId != null) {
      await _analytics.setUserId(id: userId);
    }

    if (userRole != null) {
      await _analytics.setUserProperty(name: 'user_role', value: userRole);
    }

    if (treeCount != null) {
      await _analytics.setUserProperty(
        name: 'tree_count',
        value: treeCount.toString(),
      );
    }
  }

  // Тестовый метод для проверки событий
  Future<void> testEvent() async {
    if (kIsWeb) return;

    await _analytics.logEvent(
      name: 'test_event',
      parameters: {'string': 'string', 'int': 42, 'double': 3.14, 'bool': true},
    );

    print('Тестовое событие отправлено в Analytics');
  }
}
