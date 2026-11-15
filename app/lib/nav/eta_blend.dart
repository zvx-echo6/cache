import 'dart:math' as math;

/// The time left of a drive, from the route's plan and the pace the drive has kept so far.
///
/// The core counts the plan down by the distance driven (MapProgress.remainingS): it never learns that the drive is slower
/// or faster than the router's speeds. This blends the measured pace into it, by these rules:
///
/// - Nothing changes until the drive has gone on for [startAfter] and [startAfterM] (the plan's time is shown as it is).
/// - The pace is the plan's time for the stretch driven in the last [window] against the time it took moving (stopped time is not
///   part of it) (a ratio, held between
///   [minRatio] and [maxRatio]), and it is blended in slowly ([settle]: an exponential blend at each fix), so the time left
///   follows a new pace over minutes, not at one fix.
/// - Stopped (under [movingMps] along the route since the last fix: a red light, a queue), the time left stays as it is; the
///   arrival clock, worked out from the fix's moment, moves later as the clock runs.
/// - Moving, the time left never falls faster than the clock, nor rises faster than it, so the minutes shown never jump.
/// - A new plan (a new route, a re-route, a fresh start) starts it again ([reset]); so does arrival.
///
/// The result is seconds; the phone and both cars show it through the one rounding rule (units.dart, shownMinutes).
class EtaBlend {
  EtaBlend({
    this.startAfter = const Duration(minutes: 3),
    this.startAfterM = 1000,
    this.window = const Duration(minutes: 5),
    this.settle = const Duration(seconds: 60),
    this.minRatio = 0.75,
    this.maxRatio = 2.0,
    this.movingMps = 1.0,
  });

  final Duration startAfter;
  final double startAfterM;
  final Duration window;
  final Duration settle;
  final double minRatio;
  final double maxRatio;
  final double movingMps;

  DateTime? _t0;
  double _along0 = 0;
  DateTime? _lastAt;
  double _lastAlong = 0;
  double _left = 0;
  double _ratio = 1;
  bool _active = false;
  double _lastPlan = 0;
  // Each fix that moved, in the last [window]: when, the seconds it took, the plan's time it covered. A stop adds nothing, so it is
  // never counted as a slow pace (it would otherwise carry its lost time into the time left for the whole window).
  final List<(DateTime, double, double)> _samples = [];

  /// The blended pace (1 is the plan's pace, 1.4 a drive at 70 % of it); 1 until the blend has started.
  double get ratio => _ratio;

  /// True once the drive has gone on long and far enough for the measured pace to count.
  bool get active => _active;

  /// Starts again: the next [update] is the first of a new plan.
  void reset() {
    _t0 = null;
    _lastAt = null;
    _samples.clear();
    _ratio = 1;
    _active = false;
  }

  /// The time left, in seconds, for a fix at [at] that the core has matched [distanceAlongM] along the route, with
  /// [planLeftS] of the plan's time left from there.
  int update({required DateTime at, required double distanceAlongM, required int planLeftS}) {
    final plan = planLeftS.toDouble();
    final last = _lastAt;
    if (_t0 == null || last == null) {
      _t0 = at;
      _along0 = distanceAlongM;
      _remember(at, distanceAlongM, plan);
      return planLeftS;
    }
    final dt = at.difference(last).inMilliseconds / 1000;
    if (dt <= 0) return _left.round();
    final moving = (distanceAlongM - _lastAlong) / dt >= movingMps;
    if (moving) _samples.add((at, dt, _lastPlan - plan));
    final from = at.subtract(window);
    while (_samples.isNotEmpty && !_samples.first.$1.isAfter(from)) {
      _samples.removeAt(0);
    }
    if (!_active) {
      if (at.difference(_t0!) >= startAfter && distanceAlongM - _along0 >= startAfterM) {
        _active = true;
      } else {
        _remember(at, distanceAlongM, plan);
        return planLeftS;
      }
    }
    if (moving) {
      var secs = 0.0, planDriven = 0.0;
      for (final (_, s, p) in _samples) {
        secs += s;
        planDriven += p;
      }
      if (planDriven > 0) {
        final measured = (secs / planDriven).clamp(minRatio, maxRatio).toDouble();
        _ratio += (measured - _ratio) * (1 - math.exp(-dt / (settle.inMilliseconds / 1000)));
      }
      _left = (plan * _ratio).clamp(_left - dt, _left + dt).toDouble();
    }
    if (_left < 0) _left = 0;
    _lastAt = at;
    _lastAlong = distanceAlongM;
    _lastPlan = plan;
    return _left.round();
  }

  void _remember(DateTime at, double along, double plan) {
    _lastAt = at;
    _lastAlong = along;
    _lastPlan = plan;
    _left = plan;
  }
}
