import 'package:cache_search/cache_search.dart' show GeoPoint, MapPlace, MapSearchResponse;

import '../nav/elevation/route_sampler.dart' show haversineM;

/// Whether the engine took the search for a KIND of place (gas station, hospital): it answered with a category row
/// (cache_places map.rs, `type: "category"`, put there when the query matched a category or a kind of place on the phone).
/// A name or an address gets no such row, so this is the engine's own call, never a guess at the words typed.
bool isCategorySearch(MapSearchResponse r) => r.categories.isNotEmpty || r.results.any((p) => p.isCategory);

/// The car's results for [r]: for a kind of place, the nearest first from [point] (the phone's position, else the map centre);
/// for a name, [MapSearchResponse.results] as the engine ordered them. Category rows are left out, as the car never lists them.
/// With no [point] the engine's own distances are used, and with neither the engine's order stays.
List<MapPlace> carResults(MapSearchResponse r, GeoPoint? point) {
  final places = [for (final p in r.results) if (!p.isCategory) p];
  if (!isCategorySearch(r)) return places;
  double? metres(MapPlace p) => point == null ? p.distanceM : haversineM(point.lat, point.lon, p.lat, p.lon);
  final keyed = [for (var i = 0; i < places.length; i++) (i, metres(places[i]), places[i])];
  keyed.sort((a, b) {
    final x = a.$2, y = b.$2;
    if (x == null || y == null) return x == null && y == null ? a.$1.compareTo(b.$1) : (x == null ? 1 : -1);
    final c = x.compareTo(y);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final k in keyed) k.$3];
}
