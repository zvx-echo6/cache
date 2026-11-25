import 'region_catalogue.dart';

/// Which town, county and state a point is in, from the region catalogue's polygons (the ones stored with a region's download,
/// see [RegionCatalogue.storeAreaPolygons]). The bounding boxes are the first cut, then an exact test of the polygon.

/// The kinds of the catalogue a point is placed in: a city or town, a county, a state.
const Set<String> kAreaKinds = {'locality', 'county', 'region'};

/// Where the Maps screen gets the town and county of a tapped point, their outlines and the county's towns: the region catalogue
/// ([RegionCatalogue]); tests give their own. Nothing here fetches: it is what is on the phone.
abstract class AreaSource {
  Future<AreaHit?> areaAtPoint(double lat, double lon);
  Future<Map<String, dynamic>?> storedGeometry(RegionRecord r);

  /// The most populous cities and towns inside [county] that the catalogue lists, largest first.
  List<RegionRecord> townsIn(RegionRecord county, {int limit = 3});
}

/// An [AreaSource] that can also fetch an outline that is not on the phone (and keeps it for next time). Asked only after a card is
/// open: a tap never waits for it.
abstract class AreaFetcher {
  /// The region's outline, fetched and kept; null when it cannot be had (no connection, not published).
  Future<Map<String, dynamic>?> fetchGeometry(RegionRecord r);
}

/// The result of [areaAt]: the smallest city or town holding the point, the county, the state. Any may be null.
class AreaHit {
  const AreaHit({this.town, this.county, this.state});

  final RegionRecord? town;
  final RegionRecord? county;
  final RegionRecord? state;

  bool get isEmpty => town == null && county == null && state == null;
}

/// Reads one region's outline (a GeoJSON Polygon or MultiPolygon) from where it is kept; null when it is not there.
typedef AreaGeometryLoader = Future<Map<String, dynamic>?> Function(RegionRecord r);

/// The town, county and state of [records] that hold the point, found from their outlines ([load]). A region with no outline on the
/// phone, or one that cannot be read, is skipped without a word. Null when the point is in none of them.
Future<AreaHit?> areaAt(double lat, double lon, Iterable<RegionRecord> records, AreaGeometryLoader load) async {
  final byKind = <String, List<RegionRecord>>{};
  for (final r in records) {
    if (!kAreaKinds.contains(r.kind)) continue;
    final b = r.bounds;
    if (b == null || !b.contains(lat, lon)) continue;
    (byKind[r.kind] ??= []).add(r);
  }
  Future<RegionRecord?> smallest(String kind) async {
    final list = byKind[kind];
    if (list == null) return null;
    // Smaller areas first: the first one that holds the point is the smallest. A region with no area figure goes last.
    list.sort((a, b) => (a.areaKm2 ?? double.infinity).compareTo(b.areaKm2 ?? double.infinity));
    for (final r in list) {
      Map<String, dynamic>? g;
      try {
        g = await load(r);
      } catch (_) {
        continue;
      }
      if (g != null && pointInGeometry(g, lat, lon)) return r;
    }
    return null;
  }

  final hit = AreaHit(town: await smallest('locality'), county: await smallest('county'), state: await smallest('region'));
  return hit.isEmpty ? null : hit;
}

/// Whether the point is inside a GeoJSON Polygon or MultiPolygon (coordinates are [lon, lat]): inside an outer ring and in none of
/// its holes. A geometry of another type, or with coordinates that are not numbers, holds nothing.
bool pointInGeometry(Map<String, dynamic> geometry, double lat, double lon) {
  try {
    final type = geometry['type'];
    final coords = geometry['coordinates'];
    if (coords is! List) return false;
    if (type == 'Polygon') return _inPolygon(coords, lat, lon);
    if (type == 'MultiPolygon') {
      for (final p in coords) {
        if (p is List && _inPolygon(p, lat, lon)) return true;
      }
    }
  } catch (_) {}
  return false;
}

bool _inPolygon(List rings, double lat, double lon) {
  if (rings.isEmpty || !_inRing(rings.first as List, lat, lon)) return false;
  for (var i = 1; i < rings.length; i++) {
    if (_inRing(rings[i] as List, lat, lon)) return false;
  }
  return true;
}

/// The ray-cast: a ray from the point towards the east crosses the ring's edges an odd number of times when the point is inside.
bool _inRing(List ring, double lat, double lon) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i] as List, b = ring[j] as List;
    final xi = (a[0] as num).toDouble(), yi = (a[1] as num).toDouble();
    final xj = (b[0] as num).toDouble(), yj = (b[1] as num).toDouble();
    if ((yi > lat) != (yj > lat) && lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

/// What the card of a tapped area shows, from the catalogue's record: the people living there, as the catalogue counts them. One
/// source for towns and counties alike (the places data has no population to read, and the Wikipedia text quotes a census year of
/// its own), so the numbers on the cards agree with each other.
String? areaPopulationLine(RegionRecord r) {
  final p = r.population;
  if (p == null || p <= 0) return null;
  return 'About ${_rounded(p)} people';
}

String _rounded(int n) {
  final step = n >= 100000 ? 1000 : n >= 10000 ? 100 : n >= 1000 ? 10 : 1;
  final v = (n / step).round() * step;
  final s = v.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}
