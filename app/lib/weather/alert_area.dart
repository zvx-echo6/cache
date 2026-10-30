/// Alert areas as the core gives them (GeoJSON: an alert's polygons and circles, a region's boxes), for telling whether two copies
/// of an alert cover the same ground. Coordinates are (lon, lat); areas are small enough to treat as flat.
library;

typedef Pt = (double, double);

/// Each polygon as its rings (the outer one first, then holes), and the loose points, of a GeoJSON value.
({List<List<List<Pt>>> polygons, List<Pt> points}) _parts(Object? g) {
  final polys = <List<List<Pt>>>[];
  final pts = <Pt>[];
  Pt? pt(Object? c) => c is List && c.length >= 2 && c[0] is num && c[1] is num ? ((c[0] as num).toDouble(), (c[1] as num).toDouble()) : null;
  List<Pt> ring(Object? r) => [if (r is List) for (final c in r) ?pt(c)];
  List<List<Pt>> poly(Object? p) => [if (p is List) for (final r in p) if (ring(r).length >= 3) ring(r)];
  void walk(Object? v) {
    if (v is! Map) return;
    final c = v['coordinates'];
    switch (v['type']) {
      case 'Polygon':
        final p = poly(c);
        if (p.isNotEmpty) polys.add(p);
      case 'MultiPolygon':
        if (c is List) {
          for (final x in c) {
            final p = poly(x);
            if (p.isNotEmpty) polys.add(p);
          }
        }
      case 'Point':
        final p = pt(c);
        if (p != null) pts.add(p);
      case 'MultiPoint' || 'LineString':
        pts.addAll(ring(c));
      case 'GeometryCollection':
        for (final x in (v['geometries'] as List? ?? const [])) {
          walk(x);
        }
      case 'Feature':
        walk(v['geometry']);
      case 'FeatureCollection':
        for (final f in (v['features'] as List? ?? const [])) {
          walk(f);
        }
    }
  }

  walk(g);
  return (polygons: polys, points: pts);
}

bool _inRing(List<Pt> r, Pt p) {
  var inside = false;
  for (var i = 0, j = r.length - 1; i < r.length; j = i++) {
    final (xi, yi) = r[i];
    final (xj, yj) = r[j];
    if ((yi > p.$2) != (yj > p.$2) && p.$1 < (xj - xi) * (p.$2 - yi) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

bool _inPolygon(List<List<Pt>> poly, Pt p) => _inRing(poly.first, p) && !poly.skip(1).any((h) => _inRing(h, p));

double _cross(Pt o, Pt a, Pt b) => (a.$1 - o.$1) * (b.$2 - o.$2) - (a.$2 - o.$2) * (b.$1 - o.$1);

bool _onSegment(Pt a, Pt b, Pt p) =>
    p.$1 >= (a.$1 < b.$1 ? a.$1 : b.$1) && p.$1 <= (a.$1 > b.$1 ? a.$1 : b.$1) && p.$2 >= (a.$2 < b.$2 ? a.$2 : b.$2) && p.$2 <= (a.$2 > b.$2 ? a.$2 : b.$2);

bool _segmentsMeet(Pt a, Pt b, Pt c, Pt d) {
  final d1 = _cross(c, d, a), d2 = _cross(c, d, b), d3 = _cross(a, b, c), d4 = _cross(a, b, d);
  if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) return true;
  return (d1 == 0 && _onSegment(c, d, a)) || (d2 == 0 && _onSegment(c, d, b)) || (d3 == 0 && _onSegment(a, b, c)) || (d4 == 0 && _onSegment(a, b, d));
}

bool _ringsMeet(List<Pt> r, List<Pt> s) {
  for (var i = 0; i < r.length; i++) {
    for (var j = 0; j < s.length; j++) {
      if (_segmentsMeet(r[i], r[(i + 1) % r.length], s[j], s[(j + 1) % s.length])) return true;
    }
  }
  return false;
}

bool _polygonsMeet(List<List<Pt>> p, List<List<Pt>> q) =>
    p.any((r) => q.any((s) => _ringsMeet(r, s))) || p.first.any((x) => _inPolygon(q, x)) || q.first.any((x) => _inPolygon(p, x));

/// Whether two GeoJSON areas share any ground: they overlap or touch, one holds a point of the other, or (two points) they are
/// the same point. False when either has nothing to compare.
bool areasMeet(Object? a, Object? b) {
  final pa = _parts(a), pb = _parts(b);
  return pa.polygons.any((p) => pb.polygons.any((q) => _polygonsMeet(p, q))) ||
      pa.points.any((x) => pb.polygons.any((q) => _inPolygon(q, x))) ||
      pb.points.any((x) => pa.polygons.any((p) => _inPolygon(p, x))) ||
      pa.points.any(pb.points.contains);
}

/// Whether a GeoJSON value holds anything [areasMeet] can compare.
bool hasArea(Object? g) {
  final p = _parts(g);
  return p.polygons.isNotEmpty || p.points.isNotEmpty;
}

/// The smallest box around a GeoJSON value, [west, south, east, north], or null when it holds no coordinates.
List<double>? boxOf(Object? g) {
  final p = _parts(g);
  final all = [for (final poly in p.polygons) ...poly.first, ...p.points];
  if (all.isEmpty) return null;
  var w = 180.0, s = 90.0, e = -180.0, n = -90.0;
  for (final (x, y) in all) {
    if (x < w) w = x;
    if (x > e) e = x;
    if (y < s) s = y;
    if (y > n) n = y;
  }
  return [w, s, e, n];
}

/// A box [west, south, east, north] as a GeoJSON Polygon.
Map<String, Object> boxPolygon(List<double> b) => {
  'type': 'Polygon',
  'coordinates': [
    [
      [b[0], b[1]],
      [b[2], b[1]],
      [b[2], b[3]],
      [b[0], b[3]],
      [b[0], b[1]],
    ],
  ],
};

/// Boxes as one GeoJSON MultiPolygon (a region's whole area: the boxes of its downloaded maps).
Map<String, Object>? boxesArea(List<List<double>> boxes) => boxes.isEmpty
    ? null
    : {
        'type': 'MultiPolygon',
        'coordinates': [for (final b in boxes) (boxPolygon(b)['coordinates'] as List)],
      };
