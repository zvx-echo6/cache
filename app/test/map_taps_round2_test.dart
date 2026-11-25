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

    for (final (lo, hi) in [(3753.0, 3778.0), (3756.0, 3765.0)]) {
      for (final full in [true, false]) {
        test('a flat route ($lo to $hi ft), ${full ? 'full chart' : 'preview'}: the window is centred on it, even nice steps bracket it', () {
          final (yMin, yMax) = chartWindow(lo, hi, floor: floor);
          expect((yMin + yMax) / 2, closeTo((lo + hi) / 2, 0.01), reason: 'not anchored below the data');
          expect(yMax - yMin, closeTo(floor * 1.46, 0.01));
          final ph = full ? 98.0 : 64.0;
          final lines = chartGridLines(lo, hi, floor: floor, plotHeight: ph, full: full);
          expect(lines.length, greaterThanOrEqualTo(2), reason: '$lines');
          expect(lines.every((g) => g >= yMin && g <= yMax), isTrue, reason: '$lines in $yMin..$yMax');
          expect(lines.any((g) => g < lo), isTrue, reason: '$lines');
          expect(lines.any((g) => g > hi), isTrue, reason: '$lines');
          final step = lines[1] - lines[0];
          expect(lines.every((g) => g % 100 == 0), isTrue, reason: 'nice numbers: $lines');
          for (var i = 1; i < lines.length; i++) {
            expect(lines[i] - lines[i - 1], closeTo(step, 1e-6), reason: 'even steps: $lines');
            expect(step / (yMax - yMin) * ph, greaterThanOrEqualTo(kChartLabelGap - 1e-6));
          }
          if (full) expect(lines, containsAll([3700, 3800]));
        });
      }
    }

    test('a flat route in metres: nice steps of 10 or 20 m', () {
      final f = 100.0;
      final lines = chartGridLines(1144, 1148, floor: f, plotHeight: 98, full: true);
      expect(lines.any((g) => g >= 1140 && g <= 1150), isTrue, reason: '$lines');
      expect(lines.every((g) => g % 5 == 0), isTrue, reason: '$lines');
    });

    test('a hilly route keeps its lines: a nice step of its span, from one at or below the lowest to one at or above the highest; the preview keeps both ends and thins between', () {
      // 2,000 ft over the window: the step is niceStep(span / 2.2) as ever.
      final step = niceStep(2000 / 2.2);
      expect(step, 1000);
      // 4,900 to 6,900 ft: the lines run 4,000 to 7,000, so the lowest and the highest are inside the labelled range (the old lines
      // began at 5,000, above the 4,900 ft low point).
      expect(chartGridLines(4900, 6900, floor: floor, plotHeight: 98, full: true), [4000, 5000, 6000, 7000]);
      expect(chartGridLines(4900, 6900, floor: floor, plotHeight: 64, full: false), [4000, 7000]);
    });
  });
}
