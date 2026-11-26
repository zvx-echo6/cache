// A clock and timers a test moves by hand, and a feedback that counts what it was asked: two minutes of metronome in a moment.

import 'dart:async';

import 'package:cache/firstaid/cpr_metronome.dart';

class FakeClock {
  DateTime now = DateTime(2026, 11, 25, 12);
  final List<_FakeTimer> _timers = [];

  Timer timer(Duration d, void Function() f) {
    final t = _FakeTimer(now.add(d), f);
    _timers.add(t);
    return t;
  }

  /// Moves time on by [d], firing every timer that falls due on the way at its own moment.
  void advance(Duration d) {
    final end = now.add(d);
    while (true) {
      _timers.removeWhere((t) => t.cancelled || t.done);
      _timers.sort((a, b) => a.at.compareTo(b.at));
      if (_timers.isEmpty || _timers.first.at.isAfter(end)) break;
      final t = _timers.first;
      if (t.at.isAfter(now)) now = t.at;
      t.done = true;
      t.callback();
    }
    now = end;
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.at, this.callback);
  final DateTime at;
  final void Function() callback;
  bool cancelled = false;
  bool done = false;

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled && !done;

  @override
  int get tick => 0;
}

/// Counts the calls and remembers when each beat was given.
class FakeFeedback implements CprFeedback {
  FakeFeedback(this.clock);
  final FakeClock clock;
  int begins = 0, ends = 0, ticks = 0, buzzes = 0;
  final List<DateTime> tickTimes = [];
  final List<({bool sound, bool vibration})> cues = [];

  @override
  Future<void> begin() async => begins++;
  @override
  Future<void> end() async => ends++;
  @override
  Future<void> tick() async {
    ticks++;
    tickTimes.add(clock.now);
  }

  @override
  Future<void> buzz() async => buzzes++;
  @override
  Future<void> breathsCue({required bool sound, required bool vibration}) async => cues.add((sound: sound, vibration: vibration));
}

/// What the screen-awake calls were, in order.
class AwakeLog {
  final List<bool> calls = [];
  bool get on => calls.isNotEmpty && calls.last;
  Future<void> call(bool on) async => calls.add(on);
}
