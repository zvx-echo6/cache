import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/battery.dart';

/// The person's choice for background index work (Settings > Storage > Advanced): Gentle, the default, or Normal.
enum IndexSpeed { gentle, normal }

/// Why background index work is held or slowed right now.
enum IndexHold { none, heat, battery, model }

/// How index work may run right now: in bursts of [workMs] with [idleMs] rests, or not at all ([paused]); [threads] caps a
/// core job's writer threads (1 on a phone). The same duty drives the core's jobs (cs_job_set) and the app's own loops
/// ([IndexThrottle.permit]); it is worked out again every few seconds.
@immutable
class IndexDuty {
  const IndexDuty({required this.workMs, required this.idleMs, this.paused = false, this.hold = IndexHold.none, this.threads});

  /// A burst of [workMs] using [share] of one core.
  factory IndexDuty.share(double share, {int workMs = 2000, IndexHold hold = IndexHold.none, int? threads}) {
    final s = share.clamp(0.05, 1.0);
    return IndexDuty(workMs: workMs, idleMs: (workMs * (1 - s) / s).round(), hold: hold, threads: threads);
  }

  static const IndexDuty pausedFor = IndexDuty(workMs: 0, idleMs: 0, paused: true);

  final int workMs;
  final int idleMs;
  final bool paused;

  /// Why it is paused or slowed below the person's speed ([IndexHold.none]: neither).
  final IndexHold hold;
  final int? threads;

  /// The share of one core the work may use.
  double get share => paused || workMs == 0 ? 0 : workMs / (workMs + idleMs);

  /// For a core job: cs_job_start's "duty" and cs_job_set's argument.
  Map<String, Object?> toJson() => {'work_ms': workMs, 'idle_ms': idleMs, 'paused': paused, 'threads': ?threads};

  @override
  bool operator ==(Object other) =>
      other is IndexDuty && other.workMs == workMs && other.idleMs == idleMs && other.paused == paused && other.hold == hold && other.threads == threads;

  @override
  int get hashCode => Object.hash(workMs, idleMs, paused, hold, threads);

  @override
  String toString() => paused ? 'IndexDuty(paused: ${hold.name})' : 'IndexDuty($workMs ms on, $idleMs ms off, ${hold.name}, threads $threads)';
}

/// The shares of one core (owner decision, 2026-11-02: throttle indexing dynamically, so it is never hot, laggy or a battery hog).
const double kShareGentle = 2 / 3; // 2 s on, 1 s off
const double kShareNormal = 8 / 9; // 2 s on, a quarter second off
const double kShareFull = 1; // charging and cool
const double kShareForeground = 0.2; // 1 s on, 4 s off, while the person is using Cache

/// How long after the last touch the person counts as using Cache.
const Duration kActiveFor = Duration(seconds: 8);

/// Heat on a 0 (cool) to 1 (severe) scale, smoothed (see [IndexThrottle.read]): below [kHeatEase] nothing changes; from there the share falls steadily to
/// [kHeatFloor] of itself at [kHeatPause], where work pauses; once paused it goes on again only below [kHeatResume].
const double kHeatEase = 0.3;
const double kHeatPause = 0.9;
const double kHeatResume = 0.6;
const double kHeatFloor = 0.15;

/// The battery is low under 20% unplugged (work pauses); it goes on again from [kBatteryResume]% or plugged in.
const int kBatteryResume = 25;

/// A new share smaller than this change from the current one is not applied (no flapping).
const double kShareStep = 0.05;

/// The heat a reading says, 0 to 1: Android's thermal headroom where the phone gives one (1.0 is where it throttles hard),
/// else the thermal status (nominal 0, light 0.4, moderate 0.7, severe and above 1); unknown is cool.
double heatOf(BatteryReading? r) {
  if (r == null) return 0;
  final h = r.headroom;
  if (h != null && h >= 0) return h.clamp(0.0, 1.0);
  return switch (r.thermal) {
    Thermal.unknown || Thermal.nominal => 0,
    Thermal.light => 0.4,
    Thermal.moderate => 0.7,
    Thermal.severe || Thermal.critical => 1,
  };
}

/// What heat leaves of a share: all of it up to [kHeatEase], then less and less, to [kHeatFloor] at [kHeatPause].
double heatFactor(double heat) {
  if (heat <= kHeatEase) return 1;
  if (heat >= kHeatPause) return kHeatFloor;
  return 1 - (1 - kHeatFloor) * (heat - kHeatEase) / (kHeatPause - kHeatEase);
}

/// The one throttle for all background index work: a control loop that reads the device every [every] while work runs (and
/// at once when iOS says the warmth changed), and works out the duty again:
/// - while the model is generating an answer: paused;
/// - a low battery (under 20%, unplugged): paused, until [kBatteryResume]% or plugged in;
/// - heat (smoothed): the share eases off from [kHeatEase], pauses at [kHeatPause], goes on below [kHeatResume];
/// - the person is using Cache (a touch in the last [kActiveFor]): 1 s on, 4 s off;
/// - charging and cool: the full duty cycle;
/// - otherwise the person's speed: Gentle (2 s on, 1 s off: at most about two thirds of one core; the default) or Normal
///   (2 s on, a quarter second off). A desktop (no battery or warmth to read) is Normal.
/// A change smaller than [kShareStep] is not applied. On a phone a core job uses one writer thread.
class IndexThrottle extends ChangeNotifier {
  IndexThrottle({
    BatteryReader? read,
    this.speed = IndexSpeed.gentle,
    this.mobile = false,
    this.every = const Duration(seconds: 5),
    DateTime Function()? clock,
    Future<void> Function(Duration d)? sleep,
  }) : _read = read ?? readBattery,
       _clock = clock ?? DateTime.now,
       _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  final BatteryReader _read;
  final DateTime Function() _clock;
  final Future<void> Function(Duration d) _sleep;
  final Duration every;

  /// A phone or tablet: one writer thread for core jobs.
  final bool mobile;

  IndexSpeed speed;
  BatteryReading? _reading;
  double _heat = 0;
  bool _hot = false;
  bool _low = false;
  DateTime? _readAt;
  DateTime? _lastTouch;
  bool _generating = false;
  IndexDuty _duty = IndexDuty.share(kShareGentle);
  Completer<void>? _resume;
  Timer? _loop;
  bool _disposed = false;

  /// The start of the burst the app's loops are in (see [permit]).
  DateTime? _burst;

  /// The device as last read (null: not read, or nothing to read).
  BatteryReading? get reading => _reading;

  /// The smoothed heat, 0 to 1.
  double get heat => _heat;

  /// How work may run now.
  IndexDuty get duty => _duty;

  /// Heat is slowing the work down or holding it.
  bool get warm => _duty.hold == IndexHold.heat;

  /// Runs the control loop (reads every [every]) while there is work; the scheduler turns it on and off.
  void watch(bool on) {
    if (_disposed) return;
    if (!on) {
      _loop?.cancel();
      _loop = null;
      return;
    }
    _loop ??= Timer.periodic(every, (_) => unawaited(read(fresh: true)));
  }

  /// Reads the device (at most every [every], unless [fresh]) and works the duty out again; also the scheduler's battery reader.
  Future<BatteryReading?> read({bool fresh = false}) async {
    final now = _clock();
    if (fresh || _readAt == null || now.difference(_readAt!) >= every) {
      _readAt = now;
      BatteryReading? r;
      try {
        r = await _read();
      } catch (_) {
        r = null;
      }
      _reading = r;
      // Smoothed: heat counts at once when it rises and eases off by halves when it falls, so the work backs off quickly and
      // speeds up again only when the device has stayed cooler.
      final h = heatOf(r);
      _heat = h >= _heat ? h : (_heat + h) / 2;
      if (r == null || r.charging || r.percent >= kBatteryResume) _low = false;
      if (r != null && r.low) _low = true;
      if (_heat >= kHeatPause) _hot = true;
      if (_heat < kHeatResume) _hot = false;
    }
    _update();
    return _reading;
  }

  /// The person touched the screen (scrolled, tapped, typed): work slows for [kActiveFor].
  void noteActivity() {
    final was = _active;
    _lastTouch = _clock();
    if (!was) _update();
  }

  /// The model is generating an answer (true) or done (false): work pauses meanwhile.
  void setGenerating(bool on) {
    if (_generating == on) return;
    _generating = on;
    _update();
  }

  void setSpeed(IndexSpeed s) {
    if (speed == s) return;
    speed = s;
    _update();
  }

  bool get _active => _lastTouch != null && _clock().difference(_lastTouch!) < kActiveFor;

  void _update() {
    final next = _work();
    final cur = _duty;
    // No flapping: a small change of share (same pause and reason, same burst length) is not applied.
    if (next.paused == cur.paused && next.hold == cur.hold && next.workMs == cur.workMs && next.threads == cur.threads && (next.share - cur.share).abs() < kShareStep) {
      return;
    }
    _duty = next;
    if (!next.paused) {
      _resume?.complete();
      _resume = null;
    }
    notifyListeners();
  }

  IndexDuty _work() {
    final r = _reading;
    final threads = mobile ? 1 : null;
    IndexDuty held(IndexHold why) => IndexDuty(workMs: 0, idleMs: 0, paused: true, hold: why, threads: threads);
    if (_generating) return held(IndexHold.model);
    if (_low) return held(IndexHold.battery);
    if (_hot) return held(IndexHold.heat);
    final active = _active;
    final double base;
    if (active) {
      base = kShareForeground;
    } else if (r == null && !mobile) {
      base = kShareNormal; // a desktop: nothing to read
    } else if (r != null && r.charging && _heat <= kHeatEase) {
      base = kShareFull;
    } else {
      base = speed == IndexSpeed.normal ? kShareNormal : kShareGentle;
    }
    final f = heatFactor(_heat);
    return IndexDuty.share(base * f, workMs: active ? 1000 : 2000, hold: f < 1 ? IndexHold.heat : IndexHold.none, threads: threads);
  }

  /// For the app's own loops (the PDF loop between PDFs and between pages): returns at once while the burst lasts, rests when it
  /// is over, and waits while work is paused (heat, low battery, the model generating).
  Future<void> permit() async {
    await read();
    while (_duty.paused && !_disposed) {
      final c = _resume ??= Completer<void>();
      // Looks again now and then: the warmth goes down without anyone saying so.
      await Future.any([c.future, _sleep(every)]);
      await read(fresh: true);
    }
    final now = _clock();
    final start = _burst ??= now;
    if (now.difference(start).inMilliseconds < _duty.workMs) return;
    if (_duty.idleMs > 0) await _sleep(Duration(milliseconds: _duty.idleMs));
    _burst = _clock();
  }

  @override
  void dispose() {
    _disposed = true;
    _loop?.cancel();
    _resume?.complete();
    super.dispose();
  }
}

/// The app's throttle, set at start; null in tests that do not need one ([indexPermit] then returns at once).
IndexThrottle? indexThrottleShared;

/// The call a background index loop awaits between its steps (between PDFs, between pages).
Future<void> indexPermit() => indexThrottleShared?.permit() ?? Future<void>.value();
