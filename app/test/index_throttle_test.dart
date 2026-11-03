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
      expect(heatOf(_r(thermal: Thermal.light)), 0, reason: "an iPhone's fair: where it sits under any steady work; runs as usual");
      expect(heatOf(_r(thermal: Thermal.moderate)), kHeatModerate, reason: "an iPhone's serious: slowed down");
      expect(heatFactor(kHeatModerate), lessThan(1));
      expect(kHeatModerate, lessThan(kHeatPause), reason: 'moderate never pauses');
      expect(heatOf(_r(thermal: Thermal.severe)), 1);
      expect(heatOf(_r(thermal: Thermal.critical)), 1);
      expect(heatOf(_r(thermal: Thermal.nominal, headroom: 0.5)), 0.5, reason: 'the headroom forecast is a hint to slow down');
      expect(heatOf(_r(headroom: 1.4)), kHeadroomMost, reason: 'never a pause from the forecast alone');
      expect(heatOf(_r(thermal: Thermal.severe, headroom: 0.2)), 1, reason: 'the status wins when it is hotter');
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
      expect((await at(_r(charging: true, thermal: Thermal.light))).idleMs, 0, reason: 'fair and charging: full speed');
      final warm = await at(_r(charging: true, thermal: Thermal.moderate));
      expect(warm.share, closeTo(kShareGentle * heatFactor(kHeatModerate), 0.01));
      expect(warm.hold, IndexHold.heat);
    });

    test('a high headroom forecast on a cool phone slows the work but is not called warm; the thermal status is', () async {
      final d = await at(_r(thermal: Thermal.nominal, headroom: 0.5));
      expect(d.hold, IndexHold.heat, reason: 'the forecast still eases the work off');
      expect(t.warm, isTrue);
      expect(t.thermalWarm, isFalse, reason: 'the system says nominal: the words must not say warm');
      await at(_r(thermal: Thermal.light, headroom: 0.5));
      expect(t.thermalWarm, isFalse, reason: "light (an iPhone's fair) is not called warm");
      await at(_r(thermal: Thermal.moderate));
      expect(t.thermalWarm, isTrue, reason: "moderate (an iPhone's serious) is");
    });

    test("the forecast alone never pauses, however high; an iPhone's fair runs as usual", () async {
      for (var i = 0; i < 4; i++) {
        expect((await at(_r(headroom: 0.99))).paused, isFalse);
      }
      expect(t.duty.hold, IndexHold.heat, reason: 'slowed');
      t.dispose();
      t = make();
      for (var i = 0; i < 4; i++) {
        final d = await at(_r(thermal: Thermal.light));
        expect((d.paused, d.hold), (false, IndexHold.none));
        expect(d.share, closeTo(kShareGentle, 0.01));
      }
    });

    test('heat rises: slowed when moderate, paused only when severe; it goes on again only well below that', () async {
      final light = await at(_r(thermal: Thermal.light));
      expect((light.paused, light.hold), (false, IndexHold.none));
      final moderate = await at(_r(thermal: Thermal.moderate));
      expect(moderate.paused, isFalse);
      expect(moderate.share, lessThan(light.share));
      expect(t.warm, isTrue, reason: 'slowed down for heat');
      final severe = await at(_r(thermal: Thermal.severe));
      expect(severe.paused, isTrue);
      expect(severe.hold, IndexHold.heat);
      // Cooling a little is not enough (hysteresis): 1.0 then moderate (0.55) smooths to 0.775, still paused.
      expect((await at(_r(thermal: Thermal.moderate))).paused, isTrue);
      // Then nominal: 0.3875, below 0.6, it goes on, slowed.
      final cooler = await at(_r(thermal: Thermal.nominal));
      expect(cooler.paused, isFalse);
      expect(cooler.hold, IndexHold.heat);
      // Cool again: as before.
      final cool = await at(_r(thermal: Thermal.nominal));
      expect(cool.hold, IndexHold.none);
      expect(cool.share, closeTo(kShareGentle, 0.01));
      expect(t.warm, isFalse);
    });

    test('a single hot reading takes effect at once; cooling down takes a few readings', () async {
      expect((await at(_r(thermal: Thermal.critical))).paused, isTrue);
      expect((await at(_r(thermal: Thermal.nominal))).paused, isFalse, reason: '(1 + 0) / 2 is below 0.6');
      expect((await at(_r(thermal: Thermal.critical))).paused, isTrue);
      expect((await at(_r(thermal: Thermal.moderate))).paused, isTrue, reason: '(1 + 0.55) / 2 is still above 0.6');
      expect((await at(_r(thermal: Thermal.moderate))).paused, isTrue, reason: '0.6625: still above 0.6');
      expect((await at(_r(thermal: Thermal.moderate))).paused, isTrue, reason: '0.606: still above 0.6');
      final on = await at(_r(thermal: Thermal.moderate));
      expect((on.paused, on.hold), (false, IndexHold.heat), reason: '0.578: it goes on, slowed');
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
      // The model loading or answering STOPS the running work (it keeps what it did), so its memory is back before the model
      // needs it; nothing starts meanwhile. After the answer it carries on.
      t.setGenerating(true);
      await Future<void>.delayed(Duration.zero);
      expect(s.running, isNull);
      expect(await runs.single.finished, isFalse);
      await s.kick();
      expect(runs, hasLength(1), reason: 'nothing starts while the model runs');
      expect(s.statusOf('zim/a')?.why ?? s.statusOf('zim/b')?.why, IndexWait.model);
      t.setGenerating(false);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(runs, hasLength(2), reason: 'it carries on once the answer is written');
      await at(_r(thermal: Thermal.moderate));
      expect(runs.last.duties.last.hold, IndexHold.heat);
      expect(s.line, 'Getting search ready · 0 of 2 done · Slowed down · device is warm');
      // Severe: the running work is held by its duty; nothing new would start.
      await at(_r(thermal: Thermal.severe));
      expect(runs.last.duties.last.paused, isTrue);
      runs.last.finish();
      await Future<void>.delayed(Duration.zero);
      await s.kick();
      expect(runs, hasLength(2), reason: 'too warm to start the next one');
      expect(s.wait, IndexWait.heat);
    });

    test('a slow but moving job at a low duty is never stuck; time held for heat is not counted; quiet long enough, it is', () async {
      var at0 = DateTime(2026, 11, 3);
      final runs = <_Run>[];
      final work = _Work(runs);
      var pulse = 0;
      final steady = _Pulsed(work, () => pulse);
      final s = IndexScheduler(
        sources: [steady],
        space: () => const Space(free: 100 << 30, reserve: 0),
        throttle: t,
        every: const Duration(hours: 1),
        stuckAfter: const Duration(minutes: 5),
        watchEvery: const Duration(milliseconds: 5),
        clock: () => at0,
      );
      addTearDown(s.dispose);
      now = _r(thermal: Thermal.moderate);
      await t.read(fresh: true);
      s.setOpen(true);
      await Future<void>.delayed(Duration.zero);
      await s.kick();
      final first = s.running!;
      final limit = s.stuckAfterNow;
      expect(limit, greaterThan(const Duration(minutes: 5)), reason: 'slowed: longer in proportion');
      Future<void> pass(Duration d) async {
        at0 = at0.add(d);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      // a step every 4 minutes for an hour: slow, but moving
      for (var i = 0; i < 15; i++) {
        await pass(const Duration(minutes: 4));
        pulse++;
      }
      expect(s.running, isNotNull);
      // held for heat (severe) for half an hour, nothing moving: not counted
      await at(_r(thermal: Thermal.severe));
      for (var i = 0; i < 6; i++) {
        await pass(const Duration(minutes: 5));
      }
      expect(s.running, isNotNull, reason: 'time held for heat is not working time');
      // cool again, and nothing moves for longer than the limit at this duty: stuck
      await at(_r(thermal: Thermal.nominal));
      await at(_r(thermal: Thermal.nominal));
      await pass(const Duration(seconds: 1));
      await pass(s.stuckAfterNow + const Duration(minutes: 1));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await runs.first.finished, isFalse, reason: 'stopped');
      expect(s.statusOf(first)?.why, IndexWait.stuck);
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

/// [_Work] whose tasks give a sign of life from [beat].
class _Pulsed implements IndexWorkSource {
  _Pulsed(this.inner, this.beat);
  final _Work inner;
  final int Function() beat;

  @override
  Future<List<IndexTask>> pending() async => [
        for (final t in await inner.pending())
          IndexTask(key: t.key, long: t.long, start: t.start, pulse: () => beat()),
      ];
}
