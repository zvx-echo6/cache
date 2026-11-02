import 'package:cache/nav/nav_geojson.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';

void main() {
  test('the chosen route is a line per stretch, each its own kind; the others are whole and marked', () {
    final a = MapRoute.fromJson(fakeRouteJson(offroad: true));
    final b = MapRoute.fromJson(fakeRouteJson(id: 'r2', alt: 1));
    final g = routeGeoJson([a, b], 0);
    final f = (g['features'] as List).cast<Map<String, dynamic>>();
    expect(f.length, 3);
    final props = [for (final x in f) x['properties'] as Map];
    expect(props.where((p) => p['alt'] == true).length, 1);
    expect(props.where((p) => p['alt'] == false).map((p) => p['kind']), ['road', 'offroad']);
    // the stretches meet: the road ends where the open ground begins
    final road = (f.firstWhere((x) => (x['properties'] as Map)['kind'] == 'road' && (x['properties'] as Map)['alt'] == false)['geometry'] as Map)['coordinates'] as List;
    final open = (f.firstWhere((x) => (x['properties'] as Map)['kind'] == 'offroad')['geometry'] as Map)['coordinates'] as List;
    expect(road.last, open.first);
    // coordinates are [lon, lat]
    expect((road.first as List).first, closeTo(-113.8, 1e-6));
    expect((road.first as List).last, closeTo(42.5, 1e-6));
    // no route chosen: nothing is drawn
    expect((routeGeoJson(const [], 0)['features'] as List), isEmpty);
    // a choice that is not there draws every route as an alternative
    final none = (routeGeoJson([a], 5)['features'] as List).cast<Map>();
    expect([for (final x in none) (x['properties'] as Map)['alt']], [true]);
  });

  test('pins: the chosen place large, the results small, categories never', () {
    const sel = MapPlace(id: 'place:1', type: 'place', name: 'A', kind: 'Pharmacy', lat: 42.5, lon: -113.8);
    const other = MapPlace(id: 'place:2', type: 'place', name: 'B', kind: 'Pharmacy', lat: 42.6, lon: -113.7);
    const cat = MapPlace(id: 'category:pharmacy', type: 'category', name: 'Pharmacy', kind: 'Category', lat: 0, lon: 0);
    final g = pinGeoJson(sel, [cat, sel, other]);
    final roles = [for (final f in g['features'] as List) ((f as Map)['properties'] as Map)['role']];
    expect(roles, ['result', 'selected']);
    expect((pinGeoJson(null, const [])['features'] as List), isEmpty);
  });
}
