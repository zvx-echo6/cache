import 'dart:async';
import 'dart:io';

/// What the host lets background index work do right now: bursts of [workMs] with [idleMs] rests, or nothing ([paused]).
/// [hold] says why it is slower or stopped ("heat", "memory"), null at the full pace.
class HostDuty {
  const HostDuty({required this.workMs, required this.idleMs, this.paused = false, this.hold});

  final int workMs;
  final int idleMs;
  final bool paused;
  final String? hold;

  /// cs_job_start's "duty" (without a pause) and cs_job_set's argument.
  Map<String, Object?> pace() => {'work_ms': workMs, 'idle_ms': idleMs, 'paused': paused};

  @override
  bool operator ==(Object other) => other is HostDuty && other.workMs == workMs && other.idleMs == idleMs && other.paused == paused && other.hold == hold;

  @override
  int get hashCode => Object.hash(workMs, idleMs, paused, hold);

  @override
  String toString() => paused ? 'HostDuty(paused: $hold)' : 'HostDuty($workMs ms on, $idleMs ms off, $hold)';
}

/// The yield the phone's IndexThrottle (app/lib/search/index_throttle.dart) does for heat, for the server: the hottest thermal
/// zone sets a heat from 0 to 1 (70 C is 0, 95 C is 1), smoothed (it counts at once when it rises and eases off by halves when it
/// falls); from 0.3 the share of one core falls steadily to 0.15 of itself at 0.9, where work pauses, and goes on again below 0.6.
/// The server has no battery and no screen, so the base is the phone's desktop share (2 s on, a quarter second off). Memory has
/// no rule on the phone; on the server work also pauses while the memory the host can still give (MemAvailable) is under the
/// larger of 256 MB and 5% of the whole, and goes on again at twice that, so indexing never pushes the host (or the model
/// beside it) into swap. Nothing to read (no sensors, no /proc) means no yield.
///
/// The model generating an answer pauses work on the phone; the helper cannot see that (the model runs in the server), so
/// there is no such yield here.
class HostLoad {
  HostLoad({this.readTempC = readThermalC, this.readMemory = readMemInfo, this.every = const Duration(seconds: 5), DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// The hottest zone in degrees C, or null when none can be read.
  final double? Function() readTempC;

  /// MemAvailable and MemTotal in bytes, or null when they cannot be read.
  final ({int available, int total})? Function() readMemory;
  final Duration every;
  final DateTime Function() _clock;

  static const double heatEase = 0.3;
  static const double heatPause = 0.9;
  static const double heatResume = 0.6;
  static const double heatFloor = 0.15;
  static const double shareNormal = 8 / 9;

  double _heat = 0;
  bool _hot = false;
  bool _lowMem = false;
  DateTime? _readAt;
  HostDuty _duty = HostLoad._full;

  static const HostDuty _full = HostDuty(workMs: 2000, idleMs: 250);

  /// The smoothed heat, 0 to 1.
  double get heat => _heat;

  /// How work may run now (the host is read again at most every [every]).
  HostDuty duty() {
    final now = _clock();
    if (_readAt == null || now.difference(_readAt!) >= every) {
      _readAt = now;
      _read();
    }
    return _duty;
  }

  void _read() {
    double? c;
    try {
      c = readTempC();
    } catch (_) {}
    final h = c == null ? 0.0 : ((c - 70) / 25).clamp(0.0, 1.0).toDouble();
    _heat = h >= _heat ? h : (_heat + h) / 2;
    if (_heat >= heatPause) _hot = true;
    if (_heat < heatResume) _hot = false;
    ({int available, int total})? m;
    try {
      m = readMemory();
    } catch (_) {}
    if (m != null && m.total > 0) {
      final floor = m.total * 0.05 > (256 << 20) ? (m.total * 0.05).round() : (256 << 20);
      if (m.available < floor) _lowMem = true;
      if (m.available >= floor * 2) _lowMem = false;
    } else {
      _lowMem = false;
    }
    if (_lowMem) {
      _duty = const HostDuty(workMs: 0, idleMs: 0, paused: true, hold: 'memory');
    } else if (_hot) {
      _duty = const HostDuty(workMs: 0, idleMs: 0, paused: true, hold: 'heat');
    } else {
      final f = _heat <= heatEase ? 1.0 : (_heat >= heatPause ? heatFloor : 1 - (1 - heatFloor) * (_heat - heatEase) / (heatPause - heatEase));
      final s = (shareNormal * f).clamp(0.05, 1.0).toDouble();
      _duty = HostDuty(workMs: 2000, idleMs: (2000 * (1 - s) / s).round(), hold: f < 1 ? 'heat' : null);
    }
  }
}

/// The hottest thermal zone of the host (`/sys/class/thermal/thermal_zone*/temp`, thousandths of a degree C), or null.
double? readThermalC() {
  try {
    var best = 0.0;
    for (final e in Directory('/sys/class/thermal').listSync()) {
      final name = e.path.split('/').last;
      if (!name.startsWith('thermal_zone')) continue;
      try {
        final v = int.tryParse(File('${e.path}/temp').readAsStringSync().trim());
        if (v != null && v / 1000 > best && v / 1000 < 150) best = v / 1000;
      } catch (_) {}
    }
    return best > 0 ? best : null;
  } catch (_) {
    return null;
  }
}

/// MemAvailable and MemTotal from `/proc/meminfo`, in bytes, or null.
({int available, int total})? readMemInfo() {
  try {
    return parseMemInfo(File('/proc/meminfo').readAsStringSync());
  } catch (_) {
    return null;
  }
}

({int available, int total})? parseMemInfo(String text) {
  int? kb(String key) {
    final m = RegExp('^$key:\\s+(\\d+)\\s*kB', multiLine: true).firstMatch(text);
    return m == null ? null : int.parse(m.group(1)!) * 1024;
  }

  final a = kb('MemAvailable'), t = kb('MemTotal');
  return a == null || t == null ? null : (available: a, total: t);
}

/// The app's loops' wait (the phone's IndexThrottle.permit): returns at once while a burst lasts, rests when it is over, and
/// waits while the host holds work. Looks again now and then; [cancelled] ends the wait.
class IndexPacer {
  IndexPacer(this.load, {Future<void> Function(Duration d)? sleep, DateTime Function()? clock, this.recheck = const Duration(seconds: 2)})
      : _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
        _clock = clock ?? DateTime.now;

  final HostLoad? load;
  final Future<void> Function(Duration d) _sleep;
  final DateTime Function() _clock;
  final Duration recheck;
  bool Function() cancelled = () => false;
  DateTime? _burst;

  Future<void> permit() async {
    final l = load;
    if (l == null) return;
    while (l.duty().paused && !cancelled()) {
      await _sleep(recheck);
    }
    final d = l.duty();
    final now = _clock();
    final start = _burst ??= now;
    if (now.difference(start).inMilliseconds < d.workMs) return;
    if (d.idleMs > 0 && !d.paused) await _sleep(Duration(milliseconds: d.idleMs));
    _burst = _clock();
  }
}
