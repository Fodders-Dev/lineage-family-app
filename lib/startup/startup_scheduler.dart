// perf(client): стартовый fan-out (05-06.09.2026) — на медленном прод-vCPU
// ~10 параллельных GET на холодном старте (posts/graph-adjacent persons/
// stories/gatherings/polls/merge-proposals/onboarding-state/…) складывают
// CPU на одном event-loop бэкенда: wall ~450мс, и даже лёгкие calls/active
// и unread-count ждут своей очереди. Пользователь при этом видит только
// ленту — всё остальное не нужно первому кадру.
//
// [StartupScheduler] — «вторая волна»: всё, что не рисуется в первом
// кадре, но должно подгрузиться проактивно вскоре после него, без
// конкуренции с холодной лентой за event-loop. Экран (обычно HomeScreen)
// сам решает, какие свои загрузки immediate, а какие — сюда; сам
// scheduler не знает про конкретные эндпоинты.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Один отложенный таск: просто асинхронная работа. Логирование/подписи
/// — на совести вызывающего кода (см. debugPrint внутри конкретных
/// _load*-методов экрана).
typedef DeferredStartupTask = Future<void> Function();

/// Планирует «вторую волну» стартового fan-out.
///
/// Контракт:
///   - стартует через `addPostFrameCallback` — то есть не раньше первого
///     отрисованного кадра;
///   - затем выжидает [initialDelay] сверху;
///   - затем прогоняет [DeferredStartupTask] ОДИН ЗА ДРУГИМ (await), с
///     паузой [taskGap] между ними — никогда не пачкой (`Future.wait`),
///     иначе на месте одного fan-out'а на старте получим точно такой же
///     fan-out на 700мс позже;
///   - падение одного таска не блокирует следующие в очереди (M4-паттерн,
///     как в [AppStartupPipeline]) — надломленная секция (истории/хабы/
///     identity-плашка) не должна гасить остальные.
///
/// Владелец (обычно `State.dispose()`) обязан вызвать [cancel] при
/// разрушении экрана — иначе таймер очереди переживёт виджет: в проде
/// это просто бесполезная работа для экрана, которого больше нет
/// (`_load*`-методы всё равно гасятся своим `mounted`-гардом), а в
/// виджет-тестах Flutter's `!timersPending`-инвариант превращает это в
/// падение теста при teardown.
///
/// Тестовый шов: [schedulerBinding] и [timerFactory] инжектируемы для
/// юнит-тестов самого класса; виджет-тесты экранов используют
/// `tester.pump(duration)` — Flutter TEST binding сам фейкует `Timer`,
/// отдельный мок не нужен.
class StartupScheduler {
  StartupScheduler({
    this.initialDelay = const Duration(milliseconds: 700),
    this.taskGap = const Duration(milliseconds: 150),
    SchedulerBinding? schedulerBinding,
    Timer Function(Duration duration, void Function() callback)?
        timerFactory,
  })  : _schedulerBinding = schedulerBinding ?? SchedulerBinding.instance,
        _timerFactory = timerFactory ?? Timer.new;

  /// Пауза после первого кадра перед первым отложенным таском.
  final Duration initialDelay;

  /// Пауза МЕЖДУ отложенными тасками (сверх времени, которое сам таск
  /// уже потратил на await своего запроса).
  final Duration taskGap;

  final SchedulerBinding _schedulerBinding;
  final Timer Function(Duration duration, void Function() callback)
      _timerFactory;

  bool _fired = false;
  bool _cancelled = false;
  Timer? _pendingTimer;

  /// True как только очередь была поставлена в план (не то же самое,
  /// что «выполнена» — экран не ждёт завершения второй волны).
  bool get isScheduled => _fired;

  /// Регистрирует [tasks] на выполнение — по одному, по порядку,
  /// начиная с первого post-frame callback + [initialDelay]. Идемпотентно:
  /// повторный вызов на том же инстансе — no-op (защита от повторного
  /// срабатывания initState/rebuild). Пустой список — no-op.
  void scheduleAfterFirstFrame(List<DeferredStartupTask> tasks) {
    if (_fired || tasks.isEmpty) return;
    _fired = true;
    _schedulerBinding.addPostFrameCallback((_) {
      // `addPostFrameCallback` живёт на биндинге, а не на виджете — если
      // экран успел disposeнуться (или [cancel] позвали) ДО этого кадра,
      // очередь не стартует вовсе.
      if (_cancelled) return;
      unawaited(_runSequentially(tasks));
    });
  }

  /// Останавливает очередь немедленно — вызывать из `dispose()`
  /// владельца. Отменяет текущее ожидание, если оно есть, так что ни
  /// один Timer не переживает teardown.
  void cancel() {
    _cancelled = true;
    _pendingTimer?.cancel();
    _pendingTimer = null;
  }

  Future<void> _runSequentially(List<DeferredStartupTask> tasks) async {
    if (!await _wait(initialDelay)) return;
    for (var i = 0; i < tasks.length; i++) {
      if (_cancelled) return;
      if (i > 0 && !await _wait(taskGap)) return;
      try {
        await tasks[i]();
      } catch (error, stackTrace) {
        // Best-effort — сломанная отложенная секция не должна гасить
        // очередь позади себя.
        debugPrint('[startup] отложенный таск #$i упал: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  /// Ждёт [duration], уважая [cancel]. Возвращает false, если отменили
  /// прямо во время ожидания — вызывающий код должен немедленно
  /// остановиться, ничего больше не запуская.
  Future<bool> _wait(Duration duration) {
    if (_cancelled) return Future.value(false);
    final completer = Completer<bool>();
    _pendingTimer = _timerFactory(duration, () {
      _pendingTimer = null;
      if (!completer.isCompleted) {
        completer.complete(!_cancelled);
      }
    });
    return completer.future;
  }
}
