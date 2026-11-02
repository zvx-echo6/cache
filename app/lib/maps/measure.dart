import 'dart:math' as math;

/// A distance measured on the map (the ring's Measure): points the person taps, joined in order. Each tap adds a point; Undo
/// takes the last one off (the first point stays); the total is the sum of the straight lines between them.
class MeasureLine {
  MeasureLine(double lat, double lon) : _points = [(lat: lat, lon: lon)];

  final List<({double lat, double lon})> _points;

  List<({double lat, double lon})> get points => List.unmodifiable(_points);

  void add(double lat, double lon) => _points.add((lat: lat, lon: lon));

  /// Takes the last point off; false when only the first is left.
  bool undo() {
    if (_points.length <= 1) return false;
    _points.removeLast();
    return true;
  }

  bool get canUndo => _points.length > 1;

  /// Metres along the line (great-circle between points).
  double get totalM {
    var t = 0.0;
    for (var i = 1; i < _points.length; i++) {
      t += metresBetween(_points[i - 1].lat, _points[i - 1].lon, _points[i].lat, _points[i].lon);
    }
    return t;
  }

  /// The map's measure source: each point, and the line once there are two.
  Map<String, dynamic> geoJson() => {
        'type': 'FeatureCollection',
        'features': [
          for (final p in _points)
            {
              'type': 'Feature',
              'geometry': {'type': 'Point', 'coordinates': [p.lon, p.lat]},
              'properties': <String, dynamic>{},
            },
          if (_points.length > 1)
            {
              'type': 'Feature',
              'geometry': {'type': 'LineString', 'coordinates': [for (final p in _points) [p.lon, p.lat]]},
              'properties': <String, dynamic>{},
            },
        ],
      };
}

/// Metres between two points (haversine).
double metresBetween(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371008.8;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(a.toDouble()));
}
