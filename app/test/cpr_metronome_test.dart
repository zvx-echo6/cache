// The CPR metronome's logic: the beat is 110 a minute with no drift, 30 compressions then the pause for two breaths that ends by
// itself after 5 seconds, hands-only has no pause, the screen is kept awake while it runs, and the sound and the buzz follow the toggles.

import 'dart:async';

import 'package:cache/firstaid/cpr_metronome.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/cpr_fakes.dart';

CprMetronome make(FakeClock c, FakeFeedback f, AwakeLog a, {CprMode mode = CprMode.handsOnly, bool sound = true, bool vibration = true}) =>
    CprMetronome(feedback: f, mode: mode, now: () => c.now, timer: c.timer, keepAwake: a.call, sound: sound, vibration: vibration);

void main() {
  group('the beat', () {
    test('110 a minute over two minutes of time, each beat on its own moment (no drift)', () async {
      final c = FakeClock(), f = FakeFeedback(c), a = AwakeLog();
      final m = make(c, f, a);
      final start = c.now;
      await m.start();
      c.advance(const Duration(minutes: 2));
      // Beats at 0, 545.45 ms, 1090.9 ms ...: 221 of them in 120 s (a beat at the very end falls inside).
      final inTwoMinutes = f.tickTimes.where((t) => t.difference(start) <= const Duration(minutes: 2)).length;
      expect(inTwoMinutes, inInclusiveRange(220, 222), reason: '110 per minute for 2 minutes is 220 beats, give or take the one at each end');
      expect((inTwoMinutes - 1) / 2, closeTo(110, 1.0), reason: 'the rate');
      for (var k = 0; k < f.tickTimes.length; k++) {
        final ideal = Duration(microseconds: (k * kCprBeatMicros).round());
        expect((f.tickTimes[k].difference(start) - ideal).inMicroseconds.abs(), lessThanOrEqualTo(1000), reason: 'beat $k is on its moment, not later than the one before it plus a beat');
      }
      m.dispose();
    });

    test('a timer that fires late does not push the later beats back', () async {
      final c = FakeClock(), f = FakeFeedback(c), a = AwakeLog();
      // Every timer is 30 ms late: the beats must still follow the 545 ms grid from Start.
      Timer late(Duration d, void Function() cb) => c.timer(d + const Duration(milliseconds: 30), cb);
      final m = CprMetronome(feedback: f, mode: CprMode.handsOnly, now: () => c.now, timer: late, keepAwake: a.call);
      final start = c.now;
      await m.start();
      c.advance(const Duration(seconds: 60));
      final last = f.tickTimes.last.difference(start);
      final ideal = Duration(microseconds: ((f.tickTimes.length - 1) * kCprBeatMicros).round());
      expect((last - ideal).inMilliseconds.abs(), lessThanOrEqualTo(40), reason: 'late by 30 ms at most, never by the sum of the lateness');
      expect(f.tickTimes.length, inInclusiveRange(108, 111));
      m.dispose();
    });
  });

  group('with breaths (30:2)', () {
    test('counts 1 to 30, then the breaths pause with a 5 second countdown that resumes by itself at 1', () async {
      final c = FakeClock(), f = FakeFeedback(c), a = AwakeLog();
      final m = make(c, f, a, mode: CprMode.withBreaths);
      await m.start();
      expect(m.count, 1);
      c.advance(Duration(microseconds: (28 * kCprBeatMicros).round() + 1000));
      expect(m.count, 29);
      expect(m.phase, CprPhase.pushing);
      c.advance(Duration(microseconds: kCprBeatMicros.round()));
      expect(m.count, 30);
      expect(m.phase, CprPhase.breaths, reason: 'on the 30th the beat stops and the breaths prompt shows');
      expect(m.breathsLeft, 5);
      final beatsAt30 = f.ticks;
      expect(beatsAt30, 30);
      for (final left in [4, 3, 2, 1]) {
        c.advance(const Duration(seconds: 1));
        expect(m.breathsLeft, left);
        expect(m.phase, CprPhase.breaths);
        expect(f.ticks, beatsAt30, reason: 'no beat in the pause');
      }
      c.advance(const Duration(seconds: 1));
      expect(m.phase, CprPhase.pushing, reason: 'it resumes by itself at 0');
      expect(m.count, 1, reason: 'counting from 1 again, the first compression at once');
      expect(f.ticks, beatsAt30 + 1);
      m.dispose();
    });

    test('Continue resumes at once', () async {
      final c = FakeClock(), f = FakeFeedback(c), a = AwakeLog();
      final m = make(c, f, a, mode: CprMode.withBreaths);
      await m.start();
      c.advance(Duration(microseconds: (29 * kCprBeatMicros).round() + 1000));
      expect(m.phase, CprPhase.breaths);
      c.advance(const Duration(seconds: 2));
      m.continueNow();
      expect(m.phase, CprPhase.pushing);
      expect(m.count, 1);
      c.advance(const Duration(seconds: 17));
      expect(m.phase, CprPhase.breaths, reason: 'the next 30 are counted (16 seconds) and the next pause comes');
      m.dispose();
    });

    test('the pause gives one cue (a double tone and buzz) when it starts, with the toggles as set', () async {
      final c = FakeClock(), f = FakeFeedback(c), a = AwakeLog();
      final m = make(c, f, a, mode: CprMode.withBreaths, vibration: false);
      await m.start();
      c.advance(Duration(microseconds: (29 * kCprBeatMicros).round() + 1000));
      expect(f.cues, [(sound: true, vibration: false)]);
      m.dispose();
    });

    test('the running time counts the pauses too', () async {
      final c = FakeClock(), f = FakeFeedback(c), a = AwakeLog();
      final m = make(c, f, a, mode: CprMode.withBreaths);
      await m.start();
      c.advance(const Duration(seconds: 25));
      expect(cprClock(m.elapsed), '00:25');
      c.advance(const Duration(seconds: 95));
      expect(cprClock(m.elapsed), '02:00');
      m.dispose();
    });
  });

  group('hands-only', () {
    test('no count to 30 and no pause: it beats on until Stop', () async {
      final c = FakeClock(), f = FakeFeedback(c), a = AwakeLog();
      final m = make(c, f, a);
      await m.start();
      c.advance(const Duration(minutes: 1));
      expect(m.phase, CprPhase.pushing, reason: 'still pushing after more than 30 beats');
      expect(f.ticks, greaterThan(100));
      expect(f.cues, isEmpty);
      await m.stop();
      expect(m.phase, CprPhase.ready);
      final n = f.ticks;
      c.advance(const Duration(seconds: 5));
      expect(f.ticks, n, reason: 'nothing after Stop');
      m.dispose();
    });
  });

  group('the screen and the senses', () {
    test('the screen is kept awake from Start to Stop, and let go on leaving', () async {
      final c = FakeClock(), f = FakeFeedback(c), a = AwakeLog();
      final m = make(c, f, a);
      expect(a.calls, isEmpty);
      await m.start();
      expect(a.calls, [true]);
      await m.stop();
      expect(a.calls, [true, false]);
      expect(f.begins, 1);
      expect(f.ends, 1);
      await m.start();
      m.dispose();
      expect(a.calls, [true, false, true, false], reason: 'leaving the screen while it runs lets the screen go too');
    });

    test('a sound and a buzz on each beat, as the toggles say', () async {
      for (final (sound, vibration) in [(true, true), (true, false), (false, true), (false, false)]) {
        final c = FakeClock(), f = FakeFeedback(c), a = AwakeLog();
        final m = make(c, f, a, sound: sound, vibration: vibration);
        await m.start();
        c.advance(const Duration(seconds: 10));
        expect(f.ticks, sound ? greaterThan(15) : 0, reason: 'sound=$sound');
        expect(f.buzzes, vibration ? greaterThan(15) : 0, reason: 'vibration=$vibration');
        if (sound && vibration) expect(f.ticks, f.buzzes);
        m.dispose();
      }
    });

    test('the toggles can be changed while it runs', () async {
      final c = FakeClock(), f = FakeFeedback(c), a = AwakeLog();
      final m = make(c, f, a);
      await m.start();
      c.advance(const Duration(seconds: 5));
      m.setSound(false);
      final n = f.ticks;
      c.advance(const Duration(seconds: 5));
      expect(f.ticks, n);
      expect(f.buzzes, greaterThan(n));
      m.dispose();
    });

    test('a feedback that throws does not stop the beat', () async {
      final c = FakeClock(), a = AwakeLog();
      final f = _Throwing(c);
      final m = CprMetronome(feedback: f, mode: CprMode.handsOnly, now: () => c.now, timer: c.timer, keepAwake: a.call);
      await m.start();
      c.advance(const Duration(seconds: 5));
      expect(f.ticks, greaterThan(8));
      m.dispose();
    });
  });

  test('the rate is 110 and the beat 545 ms', () {
    expect(kCprPerMinute, 110);
    expect(kCprBeatMicros / 1000, closeTo(545.45, 0.01));
  });

  test('the mode switch changes only when not running', () async {
    final c = FakeClock(), f = FakeFeedback(c), a = AwakeLog();
    final m = make(c, f, a);
    m.setMode(CprMode.withBreaths);
    expect(m.mode, CprMode.withBreaths);
    await m.start();
    m.setMode(CprMode.handsOnly);
    expect(m.mode, CprMode.withBreaths);
    m.dispose();
  });
}

class _Throwing extends FakeFeedback {
  _Throwing(super.clock);
  @override
  Future<void> tick() async {
    ticks++;
    throw StateError('no audio');
  }
}
