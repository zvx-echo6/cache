// The car lists a search for a KIND of place nearest first, and keeps the engine's order for a name. The result shape is the
// engine's (cache_places map.rs): a category row, then places; every name here is made up.

import 'package:cache/car/car_nearest.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _place(String name, double lat, double lon, {double? m}) => {
      'id': 'place:$name',
      'type': 'place',
      'name': name,
      'kind': 'Shop',
      'lat': lat,
      'lon': lon,
      if (m != null) 'distance_m': m,
      'matched': 'name',
      'score': 0.5,
    };

Map<String, dynamic> _category() => {
      'id': 'category:fuel',
      'type': 'category',
      'name': 'Gas station',
      'kind': 'Category',
      'category': 'fuel',
      'lat': 0.0,
      'lon': 0.0,
      'matched': 'category',
      'score': 1.0,
    };

MapSearchResponse _response(List<Map<String, dynamic>> results, {List<String> categories = const []}) => MapSearchResponse.fromJson({
      'query': 'q',
      'interpreted': {'kind': 'text', 'categories': categories},
      'meaning': 'off',
      'results': results,
    });

// About 0.7 mi (0.0100 degrees of latitude is 1.1 km) and about 20 mi (0.29 degrees is 32 km) north of the point.
const _here = GeoPoint(43.0, -116.0);
List<String> _names(List<MapPlace> l) => [for (final p in l) p.name];

void main() {
  test('a category search lists the 0.7 mi place before the 20 mi place the engine ranked first', () {
    final r = _response([
      _category(),
      _place('Gas Station', 43.29, -116.0, m: 32000),
      _place('Roadside Fuel', 43.01, -116.0, m: 1100),
    ], categories: ['fuel']);
    expect(isCategorySearch(r), isTrue);
    expect(_names(carResults(r, _here)), ['Roadside Fuel', 'Gas Station']);
  });

  test('a category row alone (a kind of place found by meaning) is a category search', () {
    final r = _response([_category(), _place('Far Fuel', 43.29, -116.0), _place('Near Fuel', 43.01, -116.0)]);
    expect(_names(carResults(r, _here)), ['Near Fuel', 'Far Fuel']);
  });

  test('a name search keeps the engine order', () {
    final r = _response([_place('Roadside Fuel on Main', 43.29, -116.0, m: 32000), _place('Roadside Fuel', 43.01, -116.0, m: 1100)]);
    expect(isCategorySearch(r), isFalse);
    expect(_names(carResults(r, _here)), ['Roadside Fuel on Main', 'Roadside Fuel']);
  });

  test('the point is the map centre when there is no fix: the caller passes it, and the order follows it', () {
    final r = _response([_category(), _place('North Fuel', 43.29, -116.0), _place('South Fuel', 42.71, -116.0), _place('Centre Fuel', 43.0, -116.0)],
        categories: ['fuel']);
    expect(_names(carResults(r, const GeoPoint(42.7, -116.0))), ['South Fuel', 'Centre Fuel', 'North Fuel']);
  });

  test('with no point at all the engine distances are used, and with none the engine order stays', () {
    final withM = _response([_category(), _place('Far', 43.29, -116.0, m: 32000), _place('Near', 43.01, -116.0, m: 1100)], categories: ['fuel']);
    expect(_names(carResults(withM, null)), ['Near', 'Far']);
    final without = _response([_category(), _place('Far', 43.29, -116.0), _place('Near', 43.01, -116.0)], categories: ['fuel']);
    expect(_names(carResults(without, null)), ['Far', 'Near']);
  });

  test('category rows are never listed', () {
    final r = _response([_category(), _place('Only Fuel', 43.01, -116.0)], categories: ['fuel']);
    expect(_names(carResults(r, _here)), ['Only Fuel']);
  });
}
