import 'dart:math' as math;

/// The elevation along a route, made from the map's elevation layer (Terrarium tiles, the layer hillshade and contours are
/// drawn from). Plain data, so it is worked out in a background isolate and sent back to the screen.
///
/// How it is made (see also route_elevation.dart, which samples the tiles):
///
/// 1. **Sampling.** The route line is walked and a point is taken every [kProfileStepM] metres (40 m: between the 30 and 50 m
///    asked for, and about three pixels of the z12 elevation tiles). Each point's height is read bilinearly between the
///    centres of the four nearest elevation pixels. A point whose tile is not on the device has no height (NaN).
/// 2. **Smoothing.** The heights are smoothed with a Gaussian along the distance, sigma [kSmoothSigmaM] (60 m), over the
///    points within three sigma. Only points that have a height take part, and the weights are normalised over them, so a
///    stretch is never pulled towards a gap or the end of the route. Smoothing removes the stair steps and pixel noise of the
///    elevation data, which would otherwise add tens of metres of false climb over a few miles.
/// 3. **Climb and descent** are counted on the smoothed heights with a dead band of [kClimbThresholdM] (3 m): a rise counts,
///    from its low point to its high point, once the height has turned back from the high point by 3 m (and the same for a
///    fall), so wobbles smaller than that add nothing. They are counted separately on each stretch that has data, never across
///    a gap.
/// 4. **Climbs.** The smoothed profile is simplified into straight stretches (Douglas-Peucker, the line may stray
///    [kSimplifyM] (6 m) up or down), so a long climb that steepens is split where its grade changes. Each uphill stretch at
///    least [kMinClimbRiseM] (10 m) high and [kMinClimbLengthM] (200 m) long is a climb; its grade is its rise over its length.
///    The steepest climb ahead is the climb with the highest grade that ends ahead of the position (one the position is on
///    counts from the position).
class ElevationProfile {
  ElevationProfile({required this.distM, required this.rawM, required this.elevM, required this.totalM})
      : assert(distM.length == rawM.length && rawM.length == elevM.length) {
    _measure();
  }

  /// No elevation anywhere along a route of [totalM] metres.
  factory ElevationProfile.none(double totalM) => ElevationProfile(distM: const [], rawM: const [], elevM: const [], totalM: totalM);

  /// Builds the profile from the sampled heights (NaN = no data): smooths them and measures them.
  factory ElevationProfile.fromSamples(List<double> distM, List<double> rawM, {double? totalM}) => ElevationProfile(
        distM: List<double>.unmodifiable(distM),
        rawM: List<double>.unmodifiable(rawM),
        elevM: List<double>.unmodifiable(smoothProfile(distM, rawM)),
        totalM: totalM ?? (distM.isEmpty ? 0 : distM.last),
      );

  /// Metres from the start of each sample.
  final List<double> distM;

  /// The height read from the tiles at each sample, metres (NaN where there is no data).
  final List<double> rawM;

  /// The smoothed height, metres (NaN where there is no data): what is drawn and measured.
  final List<double> elevM;

  /// The route's length, metres.
  final double totalM;

  late final double climbM;
  late final double descentM;

  /// The highest and the lowest point: (metres along, height).
  late final ({double distM, double elevM})? highest;
  late final ({double distM, double elevM})? lowest;

  /// The stretches that have data, as (first sample, last sample) indexes.
  late final List<(int, int)> runs;

  /// The climbs along the whole route, in order.
  late final List<Climb> climbs;

  /// Metres of the route with elevation data (each sample stands for its share of the route).
  late final double coveredM;

  bool get hasData => runs.isNotEmpty;

  /// Part of the route has data and part has none.
  bool get partial => hasData && missingM > kProfileStepM * 1.5;

  /// Metres of the route with no elevation data.
  double get missingM => math.max(0, totalM - coveredM);

  void _measure() {
    final r = <(int, int)>[];
    var start = -1;
    for (var i = 0; i < elevM.length; i++) {
      final ok = !elevM[i].isNaN;
      if (ok && start < 0) start = i;
      if (!ok && start >= 0) {
        r.add((start, i - 1));
        start = -1;
      }
    }
    if (start >= 0) r.add((start, elevM.length - 1));
    runs = List.unmodifiable(r);

    var up = 0.0, down = 0.0;
    ({double distM, double elevM})? hi, lo;
    final found = <Climb>[];
    for (final (a, b) in runs) {
      final t = climbAndDescent(elevM.sublist(a, b + 1));
      up += t.climb;
      down += t.descent;
      for (var i = a; i <= b; i++) {
        final e = elevM[i];
        if (hi == null || e > hi.elevM) hi = (distM: distM[i], elevM: e);
        if (lo == null || e < lo.elevM) lo = (distM: distM[i], elevM: e);
      }
      found.addAll(findClimbs(distM.sublist(a, b + 1), elevM.sublist(a, b + 1)));
    }
    climbM = up;
    descentM = down;
    highest = hi;
    lowest = lo;
    climbs = List.unmodifiable(found);

    // Each sample stands for the route halfway to its neighbours.
    var covered = 0.0;
    for (var i = 0; i < distM.length; i++) {
      if (elevM[i].isNaN) continue;
      final from = i == 0 ? 0.0 : (distM[i - 1] + distM[i]) / 2;
      final to = i == distM.length - 1 ? totalM : (distM[i] + distM[i + 1]) / 2;
      covered += math.max(0, to - from);
    }
    coveredM = math.min(covered, totalM);
  }

  /// The smoothed height at [atM] metres along (linear between samples), or null where there is no data.
  double? elevationAt(double atM) {
    if (distM.isEmpty) return null;
    if (atM <= distM.first) return elevM.first.isNaN ? null : elevM.first;
    if (atM >= distM.last) return elevM.last.isNaN ? null : elevM.last;
    var lo = 0, hi = distM.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (distM[mid] <= atM) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = elevM[lo], b = elevM[hi];
    if (a.isNaN || b.isNaN) return a.isNaN ? (b.isNaN ? null : b) : a;
    final t = (atM - distM[lo]) / (distM[hi] - distM[lo]);
    return a + (b - a) * t;
  }

  /// The steepest climb that is still ahead of [fromM] metres along; a climb the position is on counts from the position.
  Climb? steepestClimbAhead(double fromM) {
    Climb? best;
    for (final c in climbs) {
      if (c.endM <= fromM) continue;
      var ahead = c;
      if (c.startM < fromM) {
        final e = elevationAt(fromM);
        if (e == null) continue;
        ahead = Climb(startM: fromM, endM: c.endM, startElevM: e, endElevM: c.endElevM);
        if (ahead.riseM < kMinClimbRiseM || ahead.lengthM < kMinClimbLengthM) continue;
      }
      if (best == null || ahead.grade > best.grade) best = ahead;
    }
    return best;
  }
}

/// A rise from a low point to the next high point.
class Climb {
  const Climb({required this.startM, required this.endM, required this.startElevM, required this.endElevM});

  final double startM;
  final double endM;
  final double startElevM;
  final double endElevM;

  double get lengthM => endM - startM;
  double get riseM => endElevM - startElevM;

  /// Rise over run (0.08 is 8%).
  double get grade => lengthM <= 0 ? 0 : riseM / lengthM;

  @override
  String toString() => 'Climb(${startM.round()}..${endM.round()} m, +${riseM.round()} m, ${(grade * 100).toStringAsFixed(1)}%)';
}

/// Metres between samples along the route.
const double kProfileStepM = 40;

/// The Gaussian's sigma for smoothing, metres along the route.
const double kSmoothSigmaM = 60;

/// The dead band for counting climb and descent, metres.
const double kClimbThresholdM = 3;

/// How far (metres up or down) the profile may stray from a straight stretch when it is simplified into stretches for finding climbs.
const double kSimplifyM = 6;

/// The smallest rise and length that count as a climb.
const double kMinClimbRiseM = 10;
const double kMinClimbLengthM = 200;

/// Gaussian smoothing along the distance, within the stretches that have data (see [ElevationProfile]).
List<double> smoothProfile(List<double> distM, List<double> elevM, {double sigmaM = kSmoothSigmaM}) {
  final n = elevM.length;
  final out = List<double>.filled(n, double.nan);
  final reach = 3 * sigmaM;
  final twoSigma2 = 2 * sigmaM * sigmaM;
  var lo = 0;
  for (var i = 0; i < n; i++) {
    if (elevM[i].isNaN) continue;
    while (distM[i] - distM[lo] > reach) {
      lo++;
    }
    var sum = 0.0, weight = 0.0;
    // Only the stretch the point is on: stop at the first gap either side.
    for (var j = i; j >= lo && !elevM[j].isNaN; j--) {
      final d = distM[i] - distM[j];
      final w = math.exp(-d * d / twoSigma2);
      sum += w * elevM[j];
      weight += w;
    }
    for (var j = i + 1; j < n && !elevM[j].isNaN && distM[j] - distM[i] <= reach; j++) {
      final d = distM[j] - distM[i];
      final w = math.exp(-d * d / twoSigma2);
      sum += w * elevM[j];
      weight += w;
    }
    out[i] = sum / weight;
  }
  return out;
}

/// Climb and descent of one stretch of heights with a dead band of [threshold] metres: a rise or fall counts once the height has
/// turned back from its high or low point by [threshold], and then in full, from the last low to the high point (or the other
/// way); the last leg counts to its high or low point. Wobbles smaller than [threshold] add nothing.
({double climb, double descent}) climbAndDescent(List<double> elevM, {double threshold = kClimbThresholdM}) {
  if (elevM.isEmpty) return (climb: 0, descent: 0);
  var anchor = elevM.first, ext = elevM.first;
  var dir = 0;
  var up = 0.0, down = 0.0;
  for (final e in elevM.skip(1)) {
    if (dir == 0) {
      if (e - anchor >= threshold) {
        dir = 1;
        ext = e;
      } else if (anchor - e >= threshold) {
        dir = -1;
        ext = e;
      }
    } else if (dir == 1) {
      if (e > ext) {
        ext = e;
      } else if (ext - e >= threshold) {
        up += ext - anchor;
        anchor = ext;
        dir = -1;
        ext = e;
      }
    } else {
      if (e < ext) {
        ext = e;
      } else if (e - ext >= threshold) {
        down += anchor - ext;
        anchor = ext;
        dir = 1;
        ext = e;
      }
    }
  }
  if (dir == 1) up += ext - anchor;
  if (dir == -1) down += anchor - ext;
  return (climb: up, descent: down);
}

/// The climbs of one stretch: the profile is simplified to straight stretches (Douglas-Peucker on the heights, [tolerance] metres
/// up or down from the straight line), and each uphill stretch at least [kMinClimbRiseM] high and [kMinClimbLengthM] long is a
/// climb, with the grade of its straight line.
List<Climb> findClimbs(List<double> distM, List<double> elevM, {double tolerance = kSimplifyM}) {
  final n = elevM.length;
  if (n < 2) return const [];
  final keep = List<bool>.filled(n, false)
    ..[0] = true
    ..[n - 1] = true;
  final stack = <(int, int)>[(0, n - 1)];
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    if (b - a < 2) continue;
    final slope = (elevM[b] - elevM[a]) / (distM[b] - distM[a]);
    var worst = -1.0, at = -1;
    for (var i = a + 1; i < b; i++) {
      final off = (elevM[i] - (elevM[a] + slope * (distM[i] - distM[a]))).abs();
      if (off > worst) {
        worst = off;
        at = i;
      }
    }
    if (worst > tolerance) {
      keep[at] = true;
      stack
        ..add((a, at))
        ..add((at, b));
    }
  }
  final out = <Climb>[];
  var prev = 0;
  for (var i = 1; i < n; i++) {
    if (!keep[i]) continue;
    final c = Climb(startM: distM[prev], endM: distM[i], startElevM: elevM[prev], endElevM: elevM[i]);
    if (c.riseM >= kMinClimbRiseM && c.lengthM >= kMinClimbLengthM) out.add(c);
    prev = i;
  }
  return out;
}
