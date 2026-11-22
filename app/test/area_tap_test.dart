import 'package:cache/maps/area_tap.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/regions/area_lookup.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache_search/cache_search.dart' show MapPlace;
import 'package:flutter_test/flutter_test.dart';

RegionRecord _r(String id, String name, String kind, {String? cls, int? pop, double? area, List<double>? bbox}) => RegionRecord.fromJson({
      'id': id, 'name': name, 'kind': kind, 'class': cls, 'region_code': 'US-ID', 'population': pop, 'area_km2': area, 'bbox': bbox ?? [-114.5, 42.5, -114.4, 42.6],
    });

void main() {
  const imperial = Fmt(UnitSystem.imperial);
  final town = _r('us-id-twin-falls', 'Twin Falls', 'locality', cls: 'city', pop: 49764, area: 50.4);
  final county = _r('us-id-twin-falls-county', 'Twin Falls County', 'county', pop: 82375, area: 4988);
  final state = _r('us-id', 'Idaho', 'region');

  test('a town: its kind, county and state, people, Directions; the summary and Wikipedia title from the places data', () {
    const pack = MapPlaceFixture();
    final c = areaChoice(AreaHit(town: town, county: county, state: state), pack: pack.place, fmt: imperial);
    expect((c.place.id, c.place.name, c.place.kind, c.place.address), ('area:us-id-twin-falls', 'Twin Falls', 'City', 'Twin Falls County, ID'));
    expect(c.place.summary, 'Twin Falls is a city.');
    expect(c.place.wikipediaTitle, 'Twin Falls, Idaho');
    expect(c.info.people, 'About 49,800 people');
    expect(c.info.directions, isTrue);
    expect(c.info.squareArea, isNull);
    expect(c.isTown, isTrue);
  });

  test('a county: "County in Idaho", people, square miles (or kilometers), the largest towns, no Directions', () {
    final c = areaChoice(AreaHit(county: county, state: state), fmt: imperial, towns: [town, _r('a', 'Kimberly', 'locality'), _r('b', 'Buhl', 'locality')]);
    expect((c.place.name, c.place.kind), ('Twin Falls County', 'County in Idaho'));
    expect(c.info.people, 'About 82,400 people');
    expect(c.info.squareArea, 'About 1,930 square miles');
    expect(c.info.largestTowns, 'Largest towns: Twin Falls, Kimberly, Buhl');
    expect(c.info.directions, isFalse);
    expect(areaChoice(AreaHit(county: county, state: state), fmt: const Fmt(UnitSystem.metric)).info.squareArea, 'About 4,990 square kilometers');
  });

  test('the kind of a town is the catalogue\'s own word', () {
    expect(townKindLabel(_r('x', 'X', 'locality', cls: 'town')), 'Town');
    expect(townKindLabel(_r('x', 'X', 'locality', cls: 'village')), 'Village');
    expect(townKindLabel(_r('x', 'X', 'locality')), 'City or town');
  });

  test('the outline: one feature, or none; the box of a polygon', () {
    expect(areaOutlineGeoJson(null)['features'], isEmpty);
    final g = {
      'type': 'MultiPolygon',
      'coordinates': [
        [[[-114.5, 42.5], [-114.4, 42.5], [-114.4, 42.6], [-114.5, 42.5]]],
        [[[-114.2, 42.7], [-114.1, 42.7], [-114.1, 42.8], [-114.2, 42.7]]],
      ],
    };
    expect((areaOutlineGeoJson(g)['features'] as List).length, 1);
    expect(geometryBounds(g), [-114.5, 42.5, -114.1, 42.8]);
    expect(geometryBounds({'type': 'Polygon', 'coordinates': []}), isNull);
  });

  test('the fill fades after the zoom at which the whole area fits the screen', () {
    // A box a degree wide fits a 360-point wide room at about zoom 7.7; a bigger area fits sooner.
    final wide = fitZoomFor([-114.5, 42.0, -113.5, 43.0], 360, 400);
    final small = fitZoomFor([-114.5, 42.5, -114.45, 42.55], 360, 400);
    expect(wide, closeTo(7.7, 0.3));
    expect(small, greaterThan(wide + 3));
    final op = areaFillOpacity(wide);
    expect(op.first, 'interpolate');
    expect(op.sublist(3), [wide, 0.08, wide + 1.5, 0]);
  });
}

class MapPlaceFixture {
  const MapPlaceFixture();
  MapPlace get place => const MapPlace(id: 'town:x', type: 'place', name: 'Twin Falls', kind: 'City', lat: 42.56, lon: -114.46, summary: 'Twin Falls is a city.', wikipediaTitle: 'Twin Falls, Idaho');
}
