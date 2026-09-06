// perf(client): стартовый fan-out — живая трассировка исходящих API-
// запросов относительно момента старта приложения. Только kDebugMode:
// `adb logcat` показывает реальную последовательность/интервалы GET на
// холодном старте («[startup] +NNNms GET /v1/...»), без единого байта
// накладных расходов в релизе (проверка kDebugMode — константа времени
// компиляции, debugPrint внутри неё даже не вызывается).
//
// Единой точки входа у HTTP-слоя нет — каждый custom_api_*_service.dart
// держит свой приватный _requestJson/_sendRequest поверх собственного
// http.Client (см. CLAUDE.md: аддитивные capability-адаптеры, не общий
// базовый класс). [StartupTrace.logRequest] поэтому вызывается точечно
// из choke-point каждого сервиса — один вызов на файл, там где реально
// уходит запрос.

import 'package:flutter/foundation.dart';

class StartupTrace {
  StartupTrace._();

  static final Stopwatch _stopwatch = Stopwatch();

  /// Фиксирует t=0. Вызывать один раз, максимально рано в `main()` —
  /// до `runApp`, чтобы отметки времени отражали реальный холодный
  /// старт, а не время до первого сетевого вызова. Повторный вызов —
  /// no-op (первый старт побеждает).
  static void markAppStart() {
    if (_stopwatch.isRunning) return;
    _stopwatch.start();
  }

  /// Логирует один исходящий запрос. No-op вне [kDebugMode]. Если
  /// [markAppStart] не вызывался (например, в юнит-тестах сервисов в
  /// отрыве от `main()`), секундомер стартует лениво при первом
  /// обращении — отметки остаются внутренне согласованными.
  static void logRequest(String method, String path) {
    if (!kDebugMode) return;
    if (!_stopwatch.isRunning) {
      _stopwatch.start();
    }
    debugPrint(
      '[startup] +${_stopwatch.elapsedMilliseconds}ms $method $path',
    );
  }
}
