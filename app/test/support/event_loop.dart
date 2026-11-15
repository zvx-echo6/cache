import 'package:flutter_test/flutter_test.dart';

/// Event-loop turns, never time: waits for [ok] by giving the loop turns (each a real turn: timers and I/O get theirs), so a slow
/// or loaded machine only takes more turns, never a different order. Fails after [turns] turns.
/// [step] is the real pause per turn: zero for pure-Dart work; a millisecond for real file I/O (done on other threads), so the
/// turn count is not spent before the disk answers. The limit is only a guard against a hang, never what a test waits for.
Future<void> pumpUntil(bool Function() ok, {int turns = 20000, String what = 'the condition', Duration step = Duration.zero}) async {
  for (var i = 0; i < turns; i++) {
    if (ok()) return;
    await Future<void>.delayed(step);
  }
  throw StateError('gave up waiting for $what after $turns event-loop turns');
}

/// [n] event-loop turns, for "nothing more happens".
Future<void> turns(int n) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// For a widget test: waits for [ok] while giving both clocks their turns, a real event-loop turn (file I/O, futures) and a short
/// fake-clock frame (routes, animations, snack bars), so it waits on the condition and never on a stretch of time.
Future<void> pumpWidgetsUntil(WidgetTester tester, bool Function() ok, {int turns = 20000, String what = 'the condition'}) async {
  for (var i = 0; i < turns; i++) {
    if (ok()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  throw StateError('gave up waiting for $what after $turns event-loop turns');
}
