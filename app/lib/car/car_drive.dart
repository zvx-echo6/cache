import 'dart:async';
import 'dart:math' as math;

import 'package:cache_search/cache_search.dart';

import '../location/position_source.dart';
import '../nav/nav_position.dart';

/// The position guidance runs on: the phone's GPS ([real]), or, while the car has asked for a test drive (Android Auto's
/// `onAutoDriveEnabled`, which Google Play's review uses), a drive along the chosen route. Guidance itself does not know the
/// difference: the same [NavState] turns the fixes into maneuvers, prompts and arrival either way.
class CarDriveSource implements NavPositionSource {
  CarDriveSource(this.real, {required this.route, this.tick = const Duration(seconds: 1), DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final NavPositionSource real;

  /// The route guidance is on when it starts.
  final MapRoute? Function() route;
  final Duration tick;
  final DateTime Function() _clock;

  /// Set by the car: the next guidance that starts is driven along its route instead of following the GPS.
  bool simulate = false;

  SimulatedDrive? _drive;

  /// True while the fixes are the simulated drive.
  bool get simulating => _drive != null;

  @override
  Stream<Fix> start({required String title, required String text}) {
    final r = route();
    _drive?.stop();
    _drive = null;
    if (!simulate || r == null || r.points.length < 2) return real.start(title: title, text: text);
    final d = SimulatedDrive(r.points, speedMps: simulatedSpeed(r), tick: tick, clock: _clock);
    _drive = d;
    return d.start();
  }

  @override
  Future<void> stop() async {
    final d = _drive;
    _drive = null;
    d?.stop();
    await real.stop();
  }
}

/// The speed a test drive goes at: the route's own average (its distance over its time), at least walking pace.
double simulatedSpeed(MapRoute r) {
  if (r.durationS <= 0) return 13.4;
  return math.max(1.4, r.distanceM / r.durationS);
}

/// Fixes along [points] at [speedMps], one every [tick], heading the way the line goes; at the end it keeps giving the last
/// point so guidance sees the arrival.
class SimulatedDrive {
  SimulatedDrive(this.points, {required this.speedMps, this.tick = const Duration(seconds: 1), DateTime Function()? clock})
      : _clock = clock ?? DateTime.now {
    _cum = [0];
    for (var i = 1; i < points.length; i++) {
      _cum.add(_cum.last + _metersBetween(points[i - 1], points[i]));
    }
  }

  final List<GeoPoint> points;
  final double speedMps;
  final Duration tick;
  final DateTime Function() _clock;
  late final List<double> _cum;
  StreamController<Fix>? _out;
  Timer? _timer;
  double _along = 0;

  double get totalM => _cum.last;

  Stream<Fix> start() {
    final out = StreamController<Fix>.broadcast();
    _out = out;
    _along = 0;
    // The first fix right away, so guidance starts without waiting a tick.
    scheduleMicrotask(() {
      if (!out.isClosed) out.add(fixAt(_along));
    });
    _timer = Timer.periodic(tick, (_) {
      _along = math.min(totalM, _along + speedMps * tick.inMilliseconds / 1000);
      if (!out.isClosed) out.add(fixAt(_along));
    });
    return out.stream;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _out?.close();
    _out = null;
  }

  /// The fix [along] meters from the start.
  Fix fixAt(double along) {
    var i = 1;
    while (i < _cum.length - 1 && _cum[i] < along) {
      i++;
    }
    final a = points[i - 1], b = points[i];
    final seg = _cum[i] - _cum[i - 1];
    final t = seg <= 0 ? 0.0 : ((along - _cum[i - 1]) / seg).clamp(0.0, 1.0);
    return Fix(
      lat: a.lat + (b.lat - a.lat) * t,
      lon: a.lon + (b.lon - a.lon) * t,
      accuracyM: 5,
      time: _clock(),
      heading: _bearingDeg(a, b),
    );
  }
}

double _metersBetween(GeoPoint a, GeoPoint b) {
  const r = 6371008.8;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(b.lat - a.lat), dLon = rad(b.lon - a.lon);
  final h = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(a.lat)) * math.cos(rad(b.lat)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(h));
}

double _bearingDeg(GeoPoint a, GeoPoint b) {
  double rad(double d) => d * math.pi / 180;
  final y = math.sin(rad(b.lon - a.lon)) * math.cos(rad(b.lat));
  final x = math.cos(rad(a.lat)) * math.sin(rad(b.lat)) - math.sin(rad(a.lat)) * math.cos(rad(b.lat)) * math.cos(rad(b.lon - a.lon));
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}
