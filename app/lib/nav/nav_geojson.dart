import 'dart:math' as math;

import 'package:cache_search/cache_search.dart';

import 'units.dart';

/// The GeoJSON the map draws for navigation: the routes, and the pins.
Map<String, dynamic> _collection(List<Map<String, dynamic>> features) => {'type': 'FeatureCollection', 'features': features};

List<List<double>> _coords(List<GeoPoint> pts) => [for (final p in pts) [p.lon, p.lat]];

/// The metres from ([lat], [lon]) to the nearest point of the line [pts] (flat-earth, which is close enough at a tap's reach).
double metresToLine(List<GeoPoint> pts, double lat, double lon) {
  if (pts.isEmpty) return double.infinity;
  final kx = 111320 * math.cos(lat * math.pi / 180), ky = 110574.0;
  (double, double) at(GeoPoint p) => ((p.lon - lon) * kx, (p.lat - lat) * ky);
  var best = double.infinity;
  var (ax, ay) = at(pts.first);
  if (pts.length == 1) return math.sqrt(ax * ax + ay * ay);
  for (final p in pts.skip(1)) {
    final (bx, by) = at(p);
    final dx = bx - ax, dy = by - ay;
    final len = dx * dx + dy * dy;
    final t = len <= 0 ? 0.0 : ((-ax * dx - ay * dy) / len).clamp(0.0, 1.0);
    final x = ax + t * dx, y = ay + t * dy;
    best = math.min(best, math.sqrt(x * x + y * y));
    (ax, ay) = (bx, by);
  }
  return best;
}

/// A route's time label on the map: where it sits, what it says (the panel's own duration words) and whether its route is the chosen one.
class RouteLabel {
  const RouteLabel({required this.route, required this.at, required this.text, required this.selected});

  final int route;
  final GeoPoint at;
  final String text;
  final bool selected;

  /// The name of the map image that draws it (one per text and state).
  String get image => 'route-time-${selected ? 'sel' : 'alt'}-$text';
}

/// One time label per route, each placed where its route is away from the others (so the labels do not stack where the routes run
/// together) and away from the labels already placed. A lone route's label is in the middle of its line. The chosen route is placed first.
List<RouteLabel> routeLabels(List<MapRoute> routes, int selected, Fmt fmt) {
  final order = [for (var i = 0; i < routes.length; i++) i]..sort((a, b) => a == selected ? -1 : (b == selected ? 1 : a.compareTo(b)));
  final placed = <GeoPoint>[];
  final out = <RouteLabel>[];
  for (final i in order) {
    final pts = routes[i].points;
    if (pts.length < 2) continue;
    // Candidates along the middle of the route, evenly by position in the line.
    final lo = (pts.length * 0.12).floor(), hi = math.max(lo + 1, (pts.length * 0.88).ceil() - 1);
    final steps = math.min(48, hi - lo);
    final cands = <GeoPoint>[for (var k = 0; k <= steps; k++) pts[lo + ((hi - lo) * k / math.max(1, steps)).round()]];
    GeoPoint best = pts[pts.length ~/ 2];
    var bestScore = -1.0;
    for (final c in cands) {
      var away = 5000.0;
      for (var j = 0; j < routes.length; j++) {
        if (j != i) away = math.min(away, metresToLine(routes[j].points, c.lat, c.lon));
      }
      var apart = 5000.0;
      for (final q in placed) {
        apart = math.min(apart, metresToLine([q], c.lat, c.lon));
      }
      // Away from the other routes counts most; with a lone route only the middle matters.
      final mid = 1 - ((cands.indexOf(c) / math.max(1, cands.length - 1)) - 0.5).abs();
      final score = routes.length == 1 ? mid : away * 2 + apart + mid * 10;
      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
    }
    placed.add(best);
    out.add(RouteLabel(route: i, at: best, text: fmt.duration(routes[i].durationS), selected: i == selected));
  }
  out.sort((a, b) => a.route.compareTo(b.route));
  return out;
}

/// Every route as lines: the chosen one a line per stretch (road, off-road or trail, so each is drawn its own way), the
/// others whole and marked as alternatives. With [fmt], each route also has a time label point (`img` names its map image, `sel` is
/// whether it is the chosen route's).
Map<String, dynamic> routeGeoJson(List<MapRoute> routes, int selected, {Fmt? fmt}) {
  final f = <Map<String, dynamic>>[];
  for (var i = 0; i < routes.length; i++) {
    final r = routes[i];
    if (i == selected) continue;
    f.add({
      'type': 'Feature',
      'geometry': {'type': 'LineString', 'coordinates': _coords(r.points)},
      'properties': {'alt': true, 'kind': 'road', 'route': i},
    });
  }
  if (selected >= 0 && selected < routes.length) {
    final r = routes[selected];
    for (final s in r.segments) {
      final pts = r.segmentPoints(s);
      if (pts.length < 2) continue;
      f.add({
        'type': 'Feature',
        'geometry': {'type': 'LineString', 'coordinates': _coords(pts)},
        'properties': {'alt': false, 'kind': s.kind, 'route': selected},
      });
    }
  }
  if (fmt != null) {
    for (final l in routeLabels(routes, selected, fmt)) {
      f.add({
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [l.at.lon, l.at.lat]},
        'properties': {'label': l.text, 'sel': l.selected, 'route': l.route, 'img': l.image},
      });
    }
  }
  return _collection(f);
}

/// The chosen place (large) and the search results (small). [mark]: the turn shown while stepping through a route before Start,
/// drawn as a small pin (a search result's).
///
/// [pinImages] names, by place id, the map image of a place that is a notebook entry (its icon in the pin style, see PinImages): its
/// feature carries it as `pin` and the map draws that in place of the plain dot.
Map<String, dynamic> pinGeoJson(MapPlace? selected, List<MapPlace> results, {GeoPoint? mark, Map<String, String> pinImages = const {}}) {
  final f = <Map<String, dynamic>>[];
  if (mark != null) {
    f.add({
      'type': 'Feature',
      'geometry': {'type': 'Point', 'coordinates': [mark.lon, mark.lat]},
      'properties': {'role': 'result', 'id': 'route-step'},
    });
  }
  for (final p in results) {
    if (p.isCategory || p.id == selected?.id) continue;
    f.add({
      'type': 'Feature',
      'geometry': {'type': 'Point', 'coordinates': [p.lon, p.lat]},
      'properties': {'role': 'result', 'id': p.id, if (pinImages[p.id] != null) 'pin': pinImages[p.id]},
    });
  }
  if (selected != null) {
    f.add({
      'type': 'Feature',
      'geometry': {'type': 'Point', 'coordinates': [selected.lon, selected.lat]},
      'properties': {'role': 'selected', 'id': selected.id, if (pinImages[selected.id] != null) 'pin': pinImages[selected.id]},
    });
  }
  return _collection(f);
}
