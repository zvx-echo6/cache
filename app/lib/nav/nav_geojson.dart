import 'package:cache_search/cache_search.dart';

/// The GeoJSON the map draws for navigation: the routes, and the pins.
Map<String, dynamic> _collection(List<Map<String, dynamic>> features) => {'type': 'FeatureCollection', 'features': features};

List<List<double>> _coords(List<GeoPoint> pts) => [for (final p in pts) [p.lon, p.lat]];

/// Every route as lines: the chosen one a line per stretch (road, off-road or trail, so each is drawn its own way), the
/// others whole and marked as alternatives.
Map<String, dynamic> routeGeoJson(List<MapRoute> routes, int selected) {
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
  return _collection(f);
}

/// The chosen place (large) and the search results (small).
Map<String, dynamic> pinGeoJson(MapPlace? selected, List<MapPlace> results) {
  final f = <Map<String, dynamic>>[];
  for (final p in results) {
    if (p.isCategory || p.id == selected?.id) continue;
    f.add({
      'type': 'Feature',
      'geometry': {'type': 'Point', 'coordinates': [p.lon, p.lat]},
      'properties': {'role': 'result', 'id': p.id},
    });
  }
  if (selected != null) {
    f.add({
      'type': 'Feature',
      'geometry': {'type': 'Point', 'coordinates': [selected.lon, selected.lat]},
      'properties': {'role': 'selected', 'id': selected.id},
    });
  }
  return _collection(f);
}
