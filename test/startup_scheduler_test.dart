// S-fanout (05-06.09.2026): unit coverage for [StartupScheduler] itself,
// isolated from HomeScreen. home_screen_test.dart already exercises the
// scheduler end-to-end through a real screen (pumpPastStartupFanout), but
// that only proves "eventually everything loads" — it doesn't pin down
// the actual contract (nothing before the first frame, initialDelay
// before task #1, taskGap between every pair, one-at-a-time not
// Future.wait, cancel() stops it dead, a throwing task doesn't take the
// rest of the queue with it). These tests pin that contract directly.
//
// Two flutter_test gotchas drive the pump() choreography below:
//   - `addPostFrameCallback` only fires on a DRAWN frame, and
//     `WidgetTester.pump()` only draws one when `hasScheduledFrame` is
//     true — which only `pumpWidget` (or a widget's own setState)
//     guarantees. A scheduler with nothing built never gets a frame from
//     a bare `pump()`, so every test forces exactly one via
//     `pumpWidget(const SizedBox.shrink())` — the widget itself is
//     irrelevant, only the forced frame matters.
//   - `WidgetTester.pump()` with NO argument leaves `duration` `null`,
//     which skips `FakeAsync.elapse` entirely — even a zero-delay
//     `Timer` then never fires. `pump(Duration.zero)` (an explicit,
//     non-null zero) does elapse and drains it. So every wait below —
//     even a `Duration.zero` one — is pumped with an explicit duration,
//     never a bare `pump()`.
import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rodnya/startup/startup_scheduler.dart';

void main() {
  group('StartupScheduler', () {
    testWidgets('runs nothing until the first frame is drawn',
        (tester) async {
      final scheduler = StartupScheduler(
        initialDelay: Duration.zero,
        taskGap: Duration.zero,
      );
      final order = <int>[];
      scheduler.scheduleAfterFirstFrame(<DeferredStartupTask>[
        () async => order.add(0),
      ]);

      // Registered but no frame has been drawn yet — the queue must
      // not have started even though initialDelay is zero (zero delay
      // still waits for the *callback*, not the clock).
      expect(order, isEmpty);

      // Forces the one frame draw that fires the post-frame callback.
      await tester.pumpWidget(const SizedBox.shrink());
      // The callback ran synchronously inside the frame and kicked off
      // `_wait(Duration.zero)`, which parks a zero-delay Timer — still
      // pending until the clock actually elapses.
      expect(order, isEmpty);

      await tester.pump(Duration.zero);
      expect(order, [0]);
    });

    testWidgets(
        'waits initialDelay after the first frame before task #1, '
        'then taskGap between every subsequent task (sequential, not '
        'Future.wait)', (tester) async {
      final scheduler = StartupScheduler(
        initialDelay: const Duration(milliseconds: 700),
        taskGap: const Duration(milliseconds: 150),
      );
      final order = <int>[];
      // Each task itself awaits nothing — isolates the scheduler's own
      // pacing from any task-internal latency.
      scheduler.scheduleAfterFirstFrame(<DeferredStartupTask>[
        () async => order.add(0),
        () async => order.add(1),
        () async => order.add(2),
      ]);

      await tester.pumpWidget(const SizedBox.shrink()); // fires the queue
      expect(order, isEmpty, reason: 'still inside initialDelay');

      await tester.pump(const Duration(milliseconds: 699));
      expect(order, isEmpty, reason: '1ms short of initialDelay');

      await tester.pump(const Duration(milliseconds: 1));
      expect(order, [0], reason: 'initialDelay elapsed — task #1 fires');

      await tester.pump(const Duration(milliseconds: 149));
      expect(order, [0], reason: '1ms short of taskGap');

      await tester.pump(const Duration(milliseconds: 1));
      expect(order, [0, 1], reason: 'taskGap elapsed — task #2 fires');

      await tester.pump(const Duration(milliseconds: 150));
      expect(order, [0, 1, 2]);
    });

    testWidgets('scheduleAfterFirstFrame is idempotent — a second call '
        'on the same instance is a no-op', (tester) async {
      final scheduler = StartupScheduler(
        initialDelay: Duration.zero,
        taskGap: Duration.zero,
      );
      final order = <int>[];
      scheduler.scheduleAfterFirstFrame(<DeferredStartupTask>[
        () async => order.add(0),
      ]);
      scheduler.scheduleAfterFirstFrame(<DeferredStartupTask>[
        () async => order.add(99),
      ]);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);

      expect(order, [0], reason: 'the second schedule call never ran');
    });

    testWidgets('an empty task list is a no-op (isScheduled stays false)',
        (tester) async {
      final scheduler = StartupScheduler();
      scheduler.scheduleAfterFirstFrame(const <DeferredStartupTask>[]);
      expect(scheduler.isScheduled, isFalse);
    });

    testWidgets('cancel() before any frame draws stops the queue from '
        'ever starting', (tester) async {
      final scheduler = StartupScheduler(
        initialDelay: Duration.zero,
        taskGap: Duration.zero,
      );
      final order = <int>[];
      scheduler.scheduleAfterFirstFrame(<DeferredStartupTask>[
        () async => order.add(0),
      ]);
      scheduler.cancel();

      // The callback still fires here (it was already registered on
      // the real binding) — this proves it's a safe, immediate no-op
      // once cancelled, not that it never runs at all.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));

      expect(order, isEmpty);
    });

    testWidgets('cancel() mid-queue stops remaining tasks, keeps '
        'whatever already ran', (tester) async {
      final scheduler = StartupScheduler(
        initialDelay: Duration.zero,
        taskGap: const Duration(milliseconds: 150),
      );
      final order = <int>[];
      scheduler.scheduleAfterFirstFrame(<DeferredStartupTask>[
        () async => order.add(0),
        () async => order.add(1),
        () async => order.add(2),
      ]);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero); // initialDelay is zero -> task #0 fires
      expect(order, [0]);

      scheduler.cancel();
      // Advance well past every remaining gap — nothing more should
      // ever fire once cancelled, timers included.
      await tester.pump(const Duration(seconds: 2));

      expect(order, [0]);
    });

    testWidgets('a throwing task does not block the tasks queued behind '
        'it (M4 isolation)', (tester) async {
      final scheduler = StartupScheduler(
        initialDelay: Duration.zero,
        taskGap: Duration.zero,
      );
      final order = <int>[];
      scheduler.scheduleAfterFirstFrame(<DeferredStartupTask>[
        () async => order.add(0),
        () async => throw StateError('боевой отказ отложенной секции'),
        () async => order.add(2),
      ]);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);

      expect(order, [0, 2], reason: 'task #1 blew up but #0 and #2 ran');
    });

    testWidgets('a custom timerFactory is honoured (test seam)',
        (tester) async {
      var timerFactoryCalls = 0;
      final scheduler = StartupScheduler(
        initialDelay: const Duration(milliseconds: 10),
        taskGap: Duration.zero,
        timerFactory: (duration, callback) {
          timerFactoryCalls += 1;
          return Timer(duration, callback);
        },
      );
      scheduler.scheduleAfterFirstFrame(<DeferredStartupTask>[
        () async {},
      ]);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 10));

      expect(timerFactoryCalls, greaterThan(0));
    });

    testWidgets(
        'a custom schedulerBinding is honoured (test seam) — the queue '
        'starts only when THAT binding fires the post-frame callback',
        (tester) async {
      FrameCallback? capturedCallback;
      final fakeBinding = _RecordingSchedulerBinding(
        onAddPostFrameCallback: (cb) => capturedCallback = cb,
      );
      final scheduler = StartupScheduler(
        initialDelay: Duration.zero,
        taskGap: Duration.zero,
        schedulerBinding: fakeBinding,
      );
      final order = <int>[];
      scheduler.scheduleAfterFirstFrame(<DeferredStartupTask>[
        () async => order.add(0),
      ]);

      // A real drawn frame must NOT trigger the queue — it was
      // registered against the fake binding, not the app's real one.
      await tester.pumpWidget(const SizedBox.shrink());
      expect(order, isEmpty);

      expect(capturedCallback, isNotNull);
      capturedCallback!(Duration.zero);
      await tester.pump(Duration.zero);

      expect(order, [0]);
    });
  });
}

/// Minimal [SchedulerBinding] stand-in — only [addPostFrameCallback] is
/// exercised by [StartupScheduler], so that's the only member overridden.
/// Delegates everything else via [noSuchMethod] to keep this test file
/// from having to stub the entire (large) SchedulerBinding surface —
/// none of it is reachable from StartupScheduler's code path.
class _RecordingSchedulerBinding implements SchedulerBinding {
  _RecordingSchedulerBinding({required this.onAddPostFrameCallback});

  final void Function(FrameCallback callback) onAddPostFrameCallback;

  @override
  void addPostFrameCallback(
    FrameCallback callback, {
    String debugLabel = 'callback',
  }) {
    onAddPostFrameCallback(callback);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
