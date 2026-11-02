import 'dart:math' as math;

/// A rectangle on the map, in degrees. Never crosses the antimeridian (the app's map does not wrap).
class GeoBounds {
  const GeoBounds({required this.south, required this.west, required this.north, required this.east});

  final double south;
  final double west;
  final double north;
  final double east;

  double get centerLat => (south + north) / 2;
  double get centerLon => (west + east) / 2;

  bool contains(double lat, double lon) => lat >= south && lat <= north && lon >= west && lon <= east;

  Map<String, double> toJson() => {'south': south, 'west': west, 'north': north, 'east': east};

  factory GeoBounds.fromJson(Map<String, dynamic> j) => GeoBounds(
        south: (j['south'] as num).toDouble(),
        west: (j['west'] as num).toDouble(),
        north: (j['north'] as num).toDouble(),
        east: (j['east'] as num).toDouble(),
      );

  @override
  bool operator ==(Object other) =>
      other is GeoBounds && other.south == south && other.west == west && other.north == north && other.east == east;

  @override
  int get hashCode => Object.hash(south, west, north, east);

  @override
  String toString() => 'GeoBounds($south, $west, $north, $east)';
}

const double _earthRadiusM = 6371008.8;

/// A circle of [radiusM] metres around a point as a closed GeoJSON ring, for the accuracy circle.
List<List<double>> circleRing(double lat, double lon, double radiusM, {int steps = 64}) {
  final latR = lat * math.pi / 180;
  final d = radiusM / _earthRadiusM;
  final ring = <List<double>>[];
  for (var i = 0; i <= steps; i++) {
    final bearing = 2 * math.pi * (i % steps) / steps;
    final lat2 = math.asin(math.sin(latR) * math.cos(d) + math.cos(latR) * math.sin(d) * math.cos(bearing));
    final lon2 = lon * math.pi / 180 +
        math.atan2(math.sin(bearing) * math.sin(d) * math.cos(latR), math.cos(d) - math.sin(latR) * math.sin(lat2));
    ring.add([_wrapLon(lon2 * 180 / math.pi), lat2 * 180 / math.pi]);
  }
  return ring;
}

double _wrapLon(double lon) {
  var l = lon;
  while (l > 180) {
    l -= 360;
  }
  while (l < -180) {
    l += 360;
  }
  return l;
}

/// Metres one screen point covers at a latitude and zoom (MapLibre zoom, 512-point tiles).
double metersPerPoint(double lat, double zoom) =>
    78271.51696402048 * math.cos(lat * math.pi / 180) / math.pow(2, zoom);

/// One scale bar: its length in points and the labels for it.
class ScaleBar {
  const ScaleBar({required this.widthPoints, required this.label});
  final double widthPoints;
  final String label;
}

String _num(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

/// The "nice" length (1, 2, 5 times a power of ten) that is not longer than [maxMeters].
double niceLength(double maxMeters) {
  if (maxMeters <= 0) return 0;
  final p = math.pow(10, (math.log(maxMeters) / math.ln10).floor()).toDouble();
  for (final m in const [5.0, 2.0, 1.0]) {
    if (m * p <= maxMeters) return m * p;
  }
  return p;
}

/// Metric scale bar no wider than [maxPoints].
ScaleBar metricScale(double metersPerPt, double maxPoints) {
  final len = niceLength(metersPerPt * maxPoints);
  final label = len >= 1000 ? '${_num(len / 1000)} km' : '${_num(len)} m';
  return ScaleBar(widthPoints: len / metersPerPt, label: label);
}

/// US scale bar (feet below a mile's worth, else miles) no wider than [maxPoints].
ScaleBar imperialScale(double metersPerPt, double maxPoints) {
  const ftPerM = 3.280839895;
  final maxFeet = metersPerPt * maxPoints * ftPerM;
  if (maxFeet >= 5280) {
    final miles = niceLength(maxFeet / 5280);
    return ScaleBar(widthPoints: miles * 5280 / ftPerM / metersPerPt, label: '${_num(miles)} mi');
  }
  final feet = niceLength(maxFeet);
  return ScaleBar(widthPoints: feet / ftPerM / metersPerPt, label: '${_num(feet)} ft');
}
