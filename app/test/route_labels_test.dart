// Each route has a time label on the map, placed where the routes part so the labels do not stack; the chosen route's label is
// the filled one; the words are the panel's own duration words. Every name and place here is made up.

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:cache/maps/ui/route_time_image.dart';
import 'package:cache/nav/nav_geojson.dart';
import 'package:cache/nav/units.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';

const _fmt = Fmt(UnitSystem.imperial);

/// Three routes east along 42.5N that share a start and an end and part in the middle by [bulge] degrees of latitude each way.
List<MapRoute> _three() {
  MapRoute route(String id, double bulge, int minutes) {
    final j = fakeRouteJson(id: id);
    final pts = [for (var i = 0; i <= 40; i++) GeoPoint(42.5 + bulge * (i / 40 < 0.5 ? i / 20 : (40 - i) / 20) * (i == 0 || i == 40 ? 0 : 1), -113.8 + 0.3 * i / 40)];
    j['geometry'] = encodePolyline6(pts);
    j['point_count'] = pts.length;
    j['duration_s'] = minutes * 60.0;
    return MapRoute.fromJson(j);
  }

  return [route('a', 0.0, 14), route('b', 0.02, 15), route('c', -0.03, 17)];
}

void main() {
  test('one label per route, with the panel\'s duration words, and only the chosen one is selected', () {
    final routes = _three();
    final labels = routeLabels(routes, 0, _fmt);
    expect(labels.map((l) => l.route), [0, 1, 2]);
    expect(labels.map((l) => l.text), [for (final r in routes) _fmt.duration(r.durationS)]);
    expect(labels.map((l) => l.text), ['14 min', '15 min', '17 min']);
    expect(labels.map((l) => l.selected), [true, false, false]);
    final other = routeLabels(routes, 2, _fmt);
    expect(other.map((l) => l.selected), [false, false, true], reason: 'the styles follow the selection');
  });

  test('the labels do not stack: each is on a stretch its route has to itself, apart from the others', () {
    final routes = _three();
    final labels = routeLabels(routes, 0, _fmt);
    for (final l in labels) {
      for (final other in routes) {
        if (identical(other, routes[l.route])) continue;
        expect(metresToLine(other.points, l.at.lat, l.at.lon), greaterThan(300), reason: 'label ${l.text} sits on another route');
      }
    }
    for (var i = 0; i < labels.length; i++) {
      for (var j = i + 1; j < labels.length; j++) {
        expect(metresToLine([labels[i].at], labels[j].at.lat, labels[j].at.lon), greaterThan(500), reason: '${labels[i].text} and ${labels[j].text} are on top of each other');
      }
    }
  });

  test('a lone route has its label in the middle of its line', () {
    final r = _three().first;
    final l = routeLabels([r], 0, _fmt).single;
    expect((l.at.lon - r.points.first.lon).abs(), closeTo(0.15, 0.03));
  });

  test('the route source carries the labels: a point per route naming its image, the chosen one marked', () {
    final routes = _three();
    final g = routeGeoJson(routes, 1, fmt: _fmt);
    final points = [for (final f in g['features'] as List) if ((f as Map)['geometry']['type'] == 'Point') f['properties'] as Map];
    expect(points, hasLength(3));
    expect({for (final p in points) p['route']: p['sel']}, {0: false, 1: true, 2: false});
    expect(points.every((p) => (p['img'] as String).startsWith('route-time-')), isTrue);
    expect(points.firstWhere((p) => p['route'] == 1)['img'], 'route-time-sel-15 min');
    expect(points.firstWhere((p) => p['route'] == 0)['img'], 'route-time-alt-14 min');
    // Without the words (browsing) there are no labels.
    final none = routeGeoJson(routes, 1);
    expect([for (final f in none['features'] as List) if ((f as Map)['geometry']['type'] == 'Point') f], isEmpty);
    // The other routes are still lines marked as alternatives.
    expect([for (final f in g['features'] as List) if ((f as Map)['properties']['alt'] == true) f['properties']['route']], [0, 2]);
  });

  testWidgets('the selected label is filled in the route colour, the others are pale', (tester) async {
    const route = ui.Color(0xFF7A4E1D);
    Future<List<int>> px(bool selected) async {
      final png = await renderRouteTimePng('14 min', selected: selected, route: route, ratio: 3);
      final codec = await ui.instantiateImageCodec(png);
      final img = (await codec.getNextFrame()).image;
      final data = (await img.toByteData())!;
      // A pixel in the left padding, vertically in the middle: the label's fill.
      final x = (img.width * 0.07).round() + 3, y = img.height ~/ 2;
      final o = (y * img.width + x) * 4;
      return [data.getUint8(o), data.getUint8(o + 1), data.getUint8(o + 2), data.getUint8(o + 3)];
    }

    final sel = (await tester.runAsync(() => px(true)))!, alt = (await tester.runAsync(() => px(false)))!;
    expect(sel.take(3).toList(), [0x7A, 0x4E, 0x1D], reason: 'filled in the route colour');
    expect(alt.take(3).toList(), [0xFB, 0xF6, 0xE8], reason: 'pale');
    expect(jsonEncode(sel), isNot(jsonEncode(alt)));
  });
}
