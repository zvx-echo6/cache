import 'dart:async';

import 'package:cache/platform/battery.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/search/index_throttle.dart';
import 'package:cache/settings/space.dart';
import 'package:flutter_test/flutter_test.dart';

BatteryReading _r({int percent = 80, bool charging = false, Thermal thermal = Thermal.nominal, double? headroom}) =>
    BatteryReading(percent: percent, charging: charging, thermal: thermal, headroom: headroom);

void main() {
  late BatteryReading? now;
  late DateTime clock;
  late List<Duration> slept;
  late IndexThrottle t;

  IndexThrottle make({bool mobile = true, IndexSpeed speed = IndexSpeed.gentle}) => IndexThrottle(
        read: () async => now,
        mobile: mobile,
        speed: speed,
        clock: () => clock,
        sleep: (d) async {
          slept.add(d);
          clock = clock.add(d);
        },
      );

  setUp(() {
    now = _r();
    clock = DateTime(2026, 11, 2, 12);
    slept = [];
    t = make();
  });
  tearDown(() => t.dispose());

  Future<IndexDuty> at(BatteryReading? r) async {
    now = r;
    await t.read(fresh: true);
    return t.duty;
  }

  group('the curve', () {
    test('heat from the thermal status, or from the headroom where the phone gives one', () {
      expect(heatOf(null), 0);
      expect(heatOf(_r(thermal: Thermal.unknown)), 0);
      expect(heatOf(_r(thermal: Thermal.nominal)), 0);
      expect(heatOf(_r(thermal: Thermal.light)), 0.4);
      expect(heatOf(_r(thermal: Thermal.moderate)), 0.7);
      expect(heatOf(_r(thermal: Thermal.severe)), 1);
      expect(heatOf(_r(thermal: Thermal.critical)), 1);
      expect(heatOf(_r(thermal: Thermal.nominal, headroom: 0.55)), 0.55, reason: 'the headroom is finer than the status');
      expect(heatOf(_r(headroom: 1.4)), 1);
    });

    test('the share eases off steadily from 0.3 to a sixth or so at 0.9', () {
      expect(heatFactor(0), 1);
      expect(heatFactor(0.3), 1);
      expect(heatFactor(0.6), closeTo(1 - 0.85 * 0.5, 1e-9));
      expect(heatFactor(0.9), kHeatFloor);
      var last = 1.0;
      for (var h = 0.3; h <= 0.9; h += 0.05) {
        expect(heatFactor(h), lessThanOrEqualTo(last));
        last = heatFactor(h);
      }
    });

    test("a duty is bursts of work and rests, and goes to a core job as cs_job_set's argument", () {
      final d = IndexDuty.share(2 / 3, threads: 1);
      expect(d.workMs, 2000);
      expect(d.idleMs, 1000);
      expect(d.toJson(), {'work_ms': 2000, 'idle_ms': 1000, 'paused': false, 'threads': 1});
      expect(IndexDuty.share(0.2, workMs: 1000).idleMs, 4000);
      expect(IndexDuty.share(1).idleMs, 0);
    });
  });

  group('each transition', () {
    test('on battery and cool: Gentle (2 s on, 1 s off) by default, Normal when chosen; one writer thread on a phone', () async {
      final d = await at(_r());
      expect(d.workMs, 2000);
      expect(d.idleMs, 1000);
      expect(d.threads, 1);
      t.setSpeed(IndexSpeed.normal);
      expect(t.duty.idleMs, 250);
    });

    test('charging and cool: the full duty cycle; charging but warm: eased like on battery', () async {
      expect((await at(_r(charging: true))).idleMs, 0);
      final warm = await at(_r(charging: true, thermal: Thermal.moderate));
      expect(warm.share, closeTo(kShareGentle * heatFactor(0.7), 0.01));
      expect(warm.hold, IndexHold.heat);
    });

    test('heat rises: eased off step by step, paused when severe; it goes on again only well below that', () async {
      final light = await at(_r(thermal: Thermal.light));
      expect(light.paused, isFalse);
      expect(light.share, closeTo(kShareGentle * heatFactor(0.4), 0.01));
      expect(t.warm, isTrue, reason: 'Settings says slowed down, phone is warm');
      final moderate = await at(_r(thermal: Thermal.moderate));
      expect(moderate.share, lessThan(light.share));
      final severe = await at(_r(thermal: Thermal.severe));
      expect(severe.paused, isTrue);
      expect(severe.hold, IndexHold.heat);
      // Cooling a little is not enough (hysteresis): 1.0 then moderate (0.7) smooths to 0.85, still paused.
      expect((await at(_r(thermal: Thermal.moderate))).paused, isTrue);
      // Then nominal: 0.425, below 0.6, it goes on, slowed.
      final cooler = await at(_r(thermal: Thermal.nominal));
      expect(cooler.paused, isFalse);
      expect(cooler.hold, IndexHold.heat);
      // Cool again: as before.
      final cool = await at(_r(thermal: Thermal.nominal));
      expect(cool.hold, IndexHold.none);
      expect(cool.share, closeTo(kShareGentle, 0.01));
      expect(t.warm, isFalse);
    });

    test('a single warm reading takes effect at once; cooling down takes a few readings', () async {
      expect((await at(_r(headroom: 0.95))).paused, isTrue);
      expect((await at(_r(headroom: 0.3))).paused, isTrue, reason: '(0.95 + 0.3) / 2 is still above 0.6');
      expect((await at(_r(headroom: 0.3))).paused, isFalse);
    });

    test('a low battery pauses until 25% or plugged in', () async {
      final low = await at(_r(percent: 15));
      expect(low.paused, isTrue);
      expect(low.hold, IndexHold.battery);
      expect((await at(_r(percent: 22))).paused, isTrue, reason: 'no flapping around 20%');
      expect((await at(_r(percent: 25))).paused, isFalse);
      expect((await at(_r(percent: 15))).paused, isTrue);
      expect((await at(_r(percent: 15, charging: true))).paused, isFalse);
    });

    test('paused while the model generates an answer', () async {
      await at(_r());
      t.setGenerating(true);
      expect(t.duty.paused, isTrue);
      expect(t.duty.hold, IndexHold.model);
      t.setGenerating(false);
      expect(t.duty.paused, isFalse);
    });

    test('while the person uses Cache: 1 s on, 4 s off, for 8 s after the last touch', () async {
      await at(_r(charging: true));
      t.noteActivity();
      expect(t.duty.workMs, 1000);
      expect(t.duty.idleMs, 4000);
      clock = clock.add(const Duration(seconds: 9));
      await t.read(fresh: true);
      expect(t.duty.idleMs, 0, reason: 'idle, cool and charging: full speed again');
    });

    test('a desktop (nothing to read) runs at Normal; a phone that cannot say runs at the speed chosen', () async {
      t.dispose();
      t = make(mobile: false);
      final d = await at(null);
      expect(d.share, closeTo(kShareNormal, 0.01));
      expect(d.threads, isNull);
      t.dispose();
      t = make();
      expect((await at(null)).share, closeTo(kShareGentle, 0.01));
    });

    test('no flapping: a small change of share is not applied', () async {
      await at(_r(headroom: 0.31));
      final before = t.duty;
      var told = 0;
      t.addListener(() => told++);
      await at(_r(headroom: 0.33));
      expect(t.duty, before);
      expect(told, 0);
      await at(_r(headroom: 0.6));
      expect(told, 1);
    });
  });

  group('permit, for the app loops', () {
    test('returns at once within a burst, rests at its end', () async {
      await at(_r());
      await t.permit();
      expect(slept, isEmpty);
      clock = clock.add(const Duration(milliseconds: 1500));
      await t.permit();
      expect(slept, isEmpty);
      clock = clock.add(const Duration(milliseconds: 600));
      await t.permit();
      expect(slept, [const Duration(milliseconds: 1000)]);
    });

    test('waits while paused and goes on when the pause ends', () async {
      t.dispose();
      // A real sleep here: the pause is waited out, not skipped.
      t = IndexThrottle(read: () async => now, mobile: true, clock: () => clock, every: const Duration(milliseconds: 20));
      await at(_r());
      t.setGenerating(true);
      var through = false;
      unawaited(t.permit().then((_) => through = true));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(through, isFalse);
      t.setGenerating(false);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(through, isTrue);
    });

    test('with no throttle set, the loops are not held', () async {
      indexThrottleShared = null;
      await indexPermit();
    });
  });

  group('the scheduler with the throttle', () {
    test('the running work gets the duty at start and every time it changes; heat holds new work back', () async {
      final runs = <_Run>[];
      final work = _Work(runs);
      final s = IndexScheduler(sources: [work], space: () => const Space(free: 100 << 30, reserve: 0), throttle: t, every: const Duration(hours: 1));
      addTearDown(s.dispose);
      now = _r();
      s.setOpen(true);
      await Future<void>.delayed(Duration.zero);
      await s.kick();
      expect(runs.single.duties.single.idleMs, 1000);
      t.setGenerating(true);
      expect(runs.single.duties.last.paused, isTrue, reason: 'a core job is paused through cs_job_set, not stopped');
      t.setGenerating(false);
      await at(_r(thermal: Thermal.light));
      expect(runs.single.duties.last.hold, IndexHold.heat);
      expect(s.line, 'Getting search ready · 0 of 2 done · Slowed down · device is warm');
      // Severe: the running work is held by its duty; nothing new would start.
      await at(_r(thermal: Thermal.severe));
      expect(runs.single.duties.last.paused, isTrue);
      runs.single.finish();
      await Future<void>.delayed(Duration.zero);
      await s.kick();
      expect(runs, hasLength(1), reason: 'too warm to start the next one');
      expect(s.wait, IndexWait.heat);
    });
  });
}

class _Run implements IndexRun {
  final Completer<bool> _done = Completer<bool>();
  final List<IndexDuty> duties = [];

  @override
  Future<bool> get finished => _done.future;

  @override
  Future<void> pause([IndexWait why = IndexWait.none]) async {
    if (!_done.isCompleted) _done.complete(false);
  }

  @override
  void setDuty(IndexDuty duty) => duties.add(duty);

  void finish() => _done.complete(true);
}

class _Work implements IndexWorkSource {
  _Work(this.runs);
  final List<_Run> runs;
  final Set<String> left = {'zim/a', 'zim/b'};

  @override
  Future<List<IndexTask>> pending() async => [
        for (final k in left)
          IndexTask(
            key: k,
            long: false,
            start: () async {
              final r = _Run();
              runs.add(r);
              r.finished.then((ok) {
                if (ok) left.remove(k);
              });
              return r;
            },
          ),
      ];
}
