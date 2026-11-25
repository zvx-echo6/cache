// The CPR metronome (First aid): the beat, the count to 30, the pause for two breaths and the running time. This file is the logic only:
// the sound, the vibration, the screen lock and the clock are handed in, so a test can run two minutes in a moment.

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Chest compressions a minute. Fixed: the metronome has no setting for it.
const int kCprPerMinute = 110;

/// Compressions before the pause for breaths (the "30" of 30:2).
const int kCprCompressions = 30;

/// How long the pause for two breaths lasts before the pushing starts again by itself, in seconds.
const int kCprBreathsSeconds = 5;

/// How the metronome works: 30 compressions then two breaths, or compressions only.
enum CprMode { withBreaths, handsOnly }

/// The mode the screen opens in (one line to change).
const CprMode kDefaultCprMode = CprMode.handsOnly;

/// Where the metronome is: ready to start, giving compressions, or in the pause for breaths.
enum CprPhase { ready, pushing, breaths }

/// What the metronome does to the person's senses. The real one (cpr_feedback.dart) plays a tick and vibrates; a test counts calls.
abstract class CprFeedback {
  /// A session starts: the sound is made ready (and, on a phone, its audio session and focus are taken).
  Future<void> begin();

  /// The session ended: whatever [begin] took is given back.
  Future<void> end();

  /// A short tick, on a compression.
  Future<void> tick();

  /// A short vibration, on a compression.
  Future<void> buzz();

  /// The cue at the start of the breaths pause: a gentle double tone and/or double vibration.
  Future<void> breathsCue({required bool sound, required bool vibration});
}

/// Makes a timer that calls [onFire] after [delay]; a test gives its own.
typedef CprTimerFactory = Timer Function(Duration delay, void Function() onFire);

/// The beat of the microseconds between two compressions at [kCprPerMinute].
const double kCprBeatMicros = 60 * 1000 * 1000 / kCprPerMinute;

class CprMetronome extends ChangeNotifier {
  CprMetronome({
    required this.feedback,
    this.mode = kDefaultCprMode,
    DateTime Function()? now,
    CprTimerFactory? timer,
    this.keepAwake,
    this.sound = true,
    this.vibration = true,
  })  : _now = now ?? DateTime.now,
        _timer = timer ?? Timer.new;

  final CprFeedback feedback;
  final DateTime Function() _now;
  final CprTimerFactory _timer;
  final Future<void> Function(bool on)? keepAwake;

  CprMode mode;
  bool sound;
  bool vibration;

  CprPhase _phase = CprPhase.ready;
  CprPhase get phase => _phase;
  bool get running => _phase != CprPhase.ready;

  /// The compression just given in this round of 30 (1 to 30); 0 before the first. Counts on in hands-only too, but is not shown there.
  int _count = 0;
  int get count => _count;

  /// Seconds left of the pause for breaths (5 down to 0).
  int _breathsLeft = 0;
  int get breathsLeft => _breathsLeft;

  /// Every compression given since Start (a test reads it).
  int totalBeats = 0;

  DateTime? _startedAt;

  /// The time since Start: compressions and pauses together.
  Duration get elapsed => _startedAt == null ? Duration.zero : _now().difference(_startedAt!);

  // Every beat is scheduled from the moment this round of pushing began, so the rhythm does not drift: a late timer is not added up.
  DateTime? _round;
  int _beat = 0;
  Timer? _beatTimer;
  Timer? _clockTimer;
  Timer? _breathsTimer;
  DateTime? _breathsAt;
  int _clockSecond = 0;
  bool _awake = false;
  bool _disposed = false;

  void setMode(CprMode m) {
    if (running || m == mode) return;
    mode = m;
    notifyListeners();
  }

  void setSound(bool on) {
    sound = on;
    notifyListeners();
  }

  void setVibration(bool on) {
    vibration = on;
    notifyListeners();
  }

  /// Start: the screen is kept awake, the first compression is given at once and the beat goes on from it.
  Future<void> start() async {
    if (running || _disposed) return;
    _phase = CprPhase.pushing;
    _startedAt = _now();
    _count = 0;
    totalBeats = 0;
    _clockSecond = 0;
    if (!_awake) {
      _awake = true;
      unawaited(keepAwake?.call(true));
    }
    unawaited(_safe(feedback.begin()));
    notifyListeners();
    _begin(_now());
    _tickClock();
  }

  /// Stop: back to ready, the screen is let go, nothing is kept.
  Future<void> stop() async {
    if (!running) return;
    _cancelTimers();
    _phase = CprPhase.ready;
    _count = 0;
    _breathsLeft = 0;
    _startedAt = null;
    await _release();
    notifyListeners();
  }

  /// "Continue" on the breaths prompt: the pushing starts again at once.
  void continueNow() {
    if (_phase != CprPhase.breaths) return;
    _resume();
  }

  Future<void> _release() async {
    if (_awake) {
      _awake = false;
      unawaited(keepAwake?.call(false));
    }
    unawaited(_safe(feedback.end()));
  }

  Future<void> _safe(Future<void> f) async {
    try {
      await f;
    } catch (_) {
      // A sound or a buzz that fails must never stop the beat.
    }
  }

  void _cancelTimers() {
    _beatTimer?.cancel();
    _clockTimer?.cancel();
    _breathsTimer?.cancel();
    _beatTimer = _clockTimer = _breathsTimer = null;
  }

  /// A round of pushing begins at [at]: its first compression is then, the next ones every [kCprBeatMicros] from it.
  void _begin(DateTime at) {
    _round = at;
    _beat = 0;
    _count = 0;
    _onBeat(); // the first compression is given at once, not a beat later
  }

  void _scheduleBeat() {
    final due = _round!.add(Duration(microseconds: (_beat * kCprBeatMicros).round()));
    var wait = due.difference(_now());
    if (wait < Duration.zero) wait = Duration.zero;
    _beatTimer = _timer(wait, _onBeat);
  }

  void _onBeat() {
    if (_phase != CprPhase.pushing || _disposed) return;
    _count++;
    totalBeats++;
    if (sound) unawaited(_safe(feedback.tick()));
    if (vibration) unawaited(_safe(feedback.buzz()));
    notifyListeners();
    if (mode == CprMode.withBreaths && _count >= kCprCompressions) {
      _startBreaths();
      return;
    }
    _beat++;
    _scheduleBeat();
  }

  void _startBreaths() {
    _phase = CprPhase.breaths;
    _breathsLeft = kCprBreathsSeconds;
    _breathsAt = _now();
    if (sound || vibration) unawaited(_safe(feedback.breathsCue(sound: sound, vibration: vibration)));
    notifyListeners();
    _scheduleBreaths(1);
  }

  void _scheduleBreaths(int second) {
    final due = _breathsAt!.add(Duration(seconds: second));
    var wait = due.difference(_now());
    if (wait < Duration.zero) wait = Duration.zero;
    _breathsTimer = _timer(wait, () {
      if (_phase != CprPhase.breaths || _disposed) return;
      _breathsLeft = kCprBreathsSeconds - second;
      notifyListeners();
      if (_breathsLeft <= 0) {
        _resume();
      } else {
        _scheduleBreaths(second + 1);
      }
    });
  }

  void _resume() {
    _breathsTimer?.cancel();
    _breathsTimer = null;
    _breathsLeft = 0;
    _phase = CprPhase.pushing;
    notifyListeners();
    _begin(_now());
  }

  /// The running time is redrawn each second, scheduled from Start like the beats.
  void _tickClock() {
    _clockSecond++;
    final due = _startedAt!.add(Duration(seconds: _clockSecond));
    var wait = due.difference(_now());
    if (wait < Duration.zero) wait = Duration.zero;
    _clockTimer = _timer(wait, () {
      if (!running || _disposed) return;
      notifyListeners();
      _tickClock();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimers();
    if (_awake) {
      _awake = false;
      unawaited(keepAwake?.call(false));
    }
    if (_phase != CprPhase.ready) unawaited(_safe(feedback.end()));
    super.dispose();
  }
}

/// The running time as mm:ss.
String cprClock(Duration d) {
  final s = d.inSeconds;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}
