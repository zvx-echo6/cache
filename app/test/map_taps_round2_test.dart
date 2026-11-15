// Map taps, round 2: the notebook place's marker carries its icon, the route header's destination is brought clear of the panel, and
// the elevation chart's height labels sit around the real heights of a flat route. Every name and place is made up.

import 'dart:math' as math;

import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/maps/style/style_generator.dart';
import 'package:cache/nav/guidance_camera.dart';
import 'package:cache/nav/nav_geojson.dart';
import 'package:cache/nav/ui/elevation_panel.dart';
import 'package:cache/notebook/map_icons.dart';
import 'package:cache/notebook/pin_image.dart';
import 'package:cache/notebook/place_style.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('a notebook place\'s marker is its icon', () {
    const sel = MapPlace(id: 'notebook:e1', type: 'place', name: 'Quillmoor relay', kind: '', lat: 42.5, lon: -113.8);
    const other = MapPlace(id: 'place:2', type: 'place', name: 'B', kind: 'Pharmacy', lat: 42.6, lon: -113.7);
    final image = pinImageId(PinStyle.teardrop, 'antenna', markerColor('red').color);

    test('the chosen place\'s feature names the image of its icon; one that is not an entry has none (the dot)', () {
      final g = pinGeoJson(sel, [other], pinImages: {sel.id: image});
      final props = {for (final f in g['features'] as List) ((f as Map)['properties'] as Map)['id']: f['properties'] as Map};
      expect(props['notebook:e1']!['pin'], image);
      expect(image, contains('antenna'));
      expect(props['place:2']!.containsKey('pin'), isFalse);
      expect((pinGeoJson(sel, const [])['features'] as List).single['properties'], isNot(contains('pin')));
    });

    test('the style draws the dot only for a feature with no image, and the image of the others in the pin style', () {
      final style = buildMapStyle(
        palette: mapPaletteFor(CacheThemeId.light),
        omtTemplate: const {'layers': []},
        layers: const [],
        tilesUrl: (d) => '',
        glyphsUrl: 'file:///f/{fontstack}/{range}.pbf',
        pinStyle: PinStyle.teardrop,
      );
      final layers = {for (final l in style['layers'] as List) (l as Map)['id'] as String: l};
      expect(layers[kPinSelected]!['filter'].toString(), contains('!'));
      final icon = layers[kPinSelectedIcon]!;
      expect(icon['type'], 'symbol');
      expect(icon['layout']['icon-image'], ['get', 'pin']);
      expect(icon['layout']['icon-anchor'], 'bottom');
      expect(layers.keys.toList().indexOf(kPinSelectedIcon), greaterThan(layers.keys.toList().indexOf(kPinSelected)));
    });

    test('the image is the one a notebook pin of that icon and colour has', () {
      expect(mapIcon('antenna').id, 'antenna');
      expect(image, pinImageId(PinStyle.teardrop, mapIcon('antenna').id, markerColor('red').color));
    });
  });

  group('the route header\'s destination is brought above the panel', () {
    const map = Size(390, 780);
    // A phone with the directions header over the top and the route panel over the foot.
    final covers = MapCovers(header: Rect.fromLTWH(8, 50, 374, 64), panel: Rect.fromLTWH(0, 470, 390, 310));

    test('the anchor is in the free room: below the header, above the panel', () {
      final a = spotAnchor(map, covers);
      expect(a.dy, greaterThan(covers.header!.bottom));
      expect(a.dy, lessThan(covers.panel!.top));
      expect(a.dy, lessThan(map.height / 2), reason: 'the map\'s middle (390) is not under the panel here, but the anchor is clear of it by its own room');
    });

    test('the camera target puts the pin at the anchor, so it is above the panel (it was at the map\'s middle)', () {
      const lat = 42.5, lon = -113.5;
      const zoom = 14.0;
      final a = spotAnchor(map, covers);
      final (clat, clon) = cameraCentreFor(lat, lon, bearing: 0, zoom: zoom, map: map, anchor: a);
      // Where the pin lands on the screen with the camera there (north up): from the centre by its metres per pixel.
      final mpp = metresPerPixel(clat, zoom);
      final dy = (clat - lat) * 111320 / mpp;
      final dx = (lon - clon) * 111320 * math.cos(lat * math.pi / 180) / mpp;
      final pin = Offset(map.width / 2 + dx, map.height / 2 + dy);
      expect(pin.dy, closeTo(a.dy, 1.0));
      expect(pin.dy, lessThan(covers.panel!.top - kPinSelectedReach));
      expect(pin.dy, greaterThan(covers.header!.bottom + kPinSelectedReach));
    });

    test('a tall panel: the pin is still above it; nothing over the map: the map\'s middle', () {
      final tall = MapCovers(header: Rect.fromLTWH(8, 50, 374, 64), panel: Rect.fromLTWH(0, 300, 390, 480));
      expect(spotAnchor(map, tall).dy, lessThan(300));
      expect(spotAnchor(map, null), map.center(Offset.zero));
      expect(spotAnchor(map, const MapCovers()), map.center(Offset.zero));
    });
  });

  group('the elevation chart\'s height labels', () {
    const floor = kChartMinSpanM * 3.28084;

    test('a flat route (3,755 to 3,766 ft): the full chart keeps even nice steps that bracket the route', () {
      final (yMin, yMax) = chartWindow(3755, 3766, floor: floor);
      final lines = chartGridLines(3755, 3766, floor: floor, plotHeight: 98, full: true);
      expect(lines, [3600, 3800]);
      expect(lines.every((g) => g >= yMin && g <= yMax), isTrue);
      expect(lines.first, lessThan(3755));
      expect(lines.last, greaterThan(3766));
    });

    test('a flat route: the preview, which would show one label, adds one at the route\'s height, apart from the others', () {
      final (yMin, yMax) = chartWindow(3755, 3766, floor: floor);
      final lines = chartGridLines(3755, 3766, floor: floor, plotHeight: 64, full: false);
      expect(lines.length, greaterThanOrEqualTo(2), reason: '$lines');
      expect(lines.any((g) => g >= 3750 && g <= 3770), isTrue, reason: '$lines');
      expect(lines.every((g) => g >= yMin && g <= yMax && g % 10 == 0), isTrue, reason: '$lines');
      for (var i = 1; i < lines.length; i++) {
        expect((lines[i] - lines[i - 1]) / (yMax - yMin) * 64, greaterThanOrEqualTo(kChartLabelGap - 1e-6), reason: '$lines');
      }
    });

    test('a flat route in metres: nice steps of 10 or 20 m', () {
      final f = 100.0;
      final lines = chartGridLines(1144, 1148, floor: f, plotHeight: 98, full: true);
      expect(lines.any((g) => g >= 1140 && g <= 1150), isTrue, reason: '$lines');
      expect(lines.every((g) => g % 5 == 0), isTrue, reason: '$lines');
    });

    test('a hilly route keeps its lines: a nice step of its span, every other one in the preview', () {
      // 2,000 ft over the window: the step is niceStep(span / 2.2) as ever.
      final step = niceStep(2000 / 2.2);
      final (yMin, yMax) = chartWindow(4900, 6900, floor: floor);
      final all = <double>[for (var g = (yMin / step).ceil() * step; g <= yMax; g += step) g];
      expect(chartGridLines(4900, 6900, floor: floor, plotHeight: 98, full: true), all);
      expect(chartGridLines(4900, 6900, floor: floor, plotHeight: 64, full: false), [for (var i = 0; i < all.length; i += 2) all[i]]);
    });
  });
}
