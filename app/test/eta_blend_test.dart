import 'package:cache/nav/eta_blend.dart';
import 'package:cache/nav/units.dart';
import 'package:flutter_test/flutter_test.dart';

// Simulated drives, one fix a second, on a road the plan drives at 20 m/s: the plan's time left is the distance left at that
// speed, as the core counts it down (MapProgress.remainingS).
const double planMps = 20;

class Fixed {
  Fixed(this.t, this.along, this.planS, this.leftS);
  final int t;
  final double along;
  final int planS;
  final int leftS;
}

/// Drives [legs] (seconds, and the pace as a share of the plan's speed; 0 is stopped) on a route [totalM] long.
List<Fixed> drive(List<(int, double)> legs, {double totalM = 24000, EtaBlend? blend}) {
  final b = blend ?? EtaBlend();
  final start = DateTime.utc(2026, 1, 1, 12);
  var t = 0;
  var along = 0.0;
  final out = <Fixed>[];
  void fix() {
    final plan = ((totalM - along) / planMps).round();
    out.add(Fixed(t, along, plan, b.update(at: start.add(Duration(seconds: t)), distanceAlongM: along, planLeftS: plan)));
  }

  fix();
  for (final (secs, pace) in legs) {
    for (var i = 0; i < secs; i++) {
      t++;
      along = (along + planMps * pace).clamp(0, totalM).toDouble();
      fix();
    }
  }
  return out;
}

/// The time left shown never moves by more than the clock between two fixes a second apart: no jumps, up or down. [from]: the
/// first fix to look at (before the blend starts, the plan's own time is shown, which a fast drive counts down faster).
void expectNoJumps(List<Fixed> d, {int from = 1}) {
  for (var i = from; i < d.length; i++) {
    final step = d[i].leftS - d[i - 1].leftS;
    expect(step, inInclusiveRange(-1, 1), reason: 'at ${d[i].t} s: ${d[i - 1].leftS} s then ${d[i].leftS} s');
    expect((shownMinutes(d[i].leftS) - shownMinutes(d[i - 1].leftS)).abs(), lessThanOrEqualTo(1), reason: 'at ${d[i].t} s');
  }
}

void main() {
  test('a drive at the plan\'s pace: the time left is the plan\'s, fix by fix', () {
    final d = drive([(1100, 1.0)]);
    for (final f in d) {
      expect(f.leftS, f.planS, reason: 'at ${f.t} s');
    }
  });

  test('before 3 minutes, or before 1 km, nothing changes', () {
    // Slow (30 % of the plan's pace) for 3 minutes: 1080 m, but under 3 minutes until the end.
    final slow = drive([(179, 0.3)]);
    for (final f in slow) {
      expect(f.leftS, f.planS, reason: 'at ${f.t} s');
    }
    // 5 minutes at 5 % of the plan's pace: 300 s but 300 m.
    final crawl = drive([(300, 0.05)]);
    for (final f in crawl) {
      expect(f.leftS, f.planS, reason: 'at ${f.t} s');
    }
  });

  test('a drive at 70 % of the plan\'s pace: the time left rises to the drive\'s, smoothly, within a few minutes', () {
    final d = drive([(1500, 0.7)]);
    expectNoJumps(d);
    double truth(Fixed f) => (24000 - f.along) / (planMps * 0.7);
    // Just before 3 minutes the plan's time alone, minutes short of the truth.
    expect(d[179].leftS, d[179].planS);
    expect(truth(d[179]) - d[179].leftS, greaterThan(400));
    // It rises.
    expect(d[400].leftS, greaterThan(d[179].leftS));
    // From 8 minutes on, the minutes shown are the drive's within one.
    for (final f in d.where((f) => f.t >= 480)) {
      expect((shownMinutes(f.leftS) - shownMinutes(truth(f).round())).abs(), lessThanOrEqualTo(1), reason: 'at ${f.t} s');
    }
  });

  test('a 60 s red light: the minutes do not fall, and the arrival clock moves later', () {
    final start = DateTime.utc(2026, 1, 1, 12);
    final d = drive([(300, 0.8), (60, 0.0), (300, 0.8)]);
    expectNoJumps(d);
    final atRed = d[300];
    for (final f in d.sublist(300, 361)) {
      expect(f.leftS, atRed.leftS, reason: 'stopped at ${f.t} s: the time left stays');
    }
    // The arrival clock is the fix's moment plus the minutes shown (shownArrival): a minute later after a minute stopped.
    DateTime arrival(Fixed f) => start.add(Duration(seconds: f.t + shownSeconds(f.leftS)));
    expect(arrival(d[360]).difference(arrival(d[300])), const Duration(seconds: 60));
  });

  test('stopped before the blend has started: the plan\'s time, which does not fall either', () {
    final d = drive([(60, 1.0), (60, 0.0)]);
    for (final f in d.sublist(60)) {
      expect(f.leftS, d[60].leftS);
    }
  });

  test('a fast highway stretch, then a slow town: no jump, and moving it never falls faster than the clock', () {
    final d = drive([(480, 1.3), (900, 0.6)], totalM: 36000);
    expectNoJumps(d, from: 180);
    // In town the time left comes up to the town's pace.
    double truth(Fixed f) => (36000 - f.along) / (planMps * 0.6);
    final late = d.last;
    expect((shownMinutes(late.leftS) - shownMinutes(truth(late).round())).abs(), lessThanOrEqualTo(1));
  });

  test('a new plan starts again: the plan\'s time until 3 minutes and 1 km of it', () {
    final b = EtaBlend();
    final first = drive([(600, 0.7)], blend: b);
    expect(first.last.leftS, greaterThan(first.last.planS + 60), reason: 'the slow pace is in it');
    expect(b.active, isTrue);
    b.reset();
    expect(b.active, isFalse);
    expect(b.ratio, 1);
    final again = drive([(179, 0.7)], blend: b);
    for (final f in again) {
      expect(f.leftS, f.planS, reason: 'the new plan at ${f.t} s');
    }
  });
}
