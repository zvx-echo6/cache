// Map taps, round 2, for the owner to review at 390 wide, Light:
// - the marker of a notebook place with an icon (an antenna), at the size the map draws it (30 points, 3 pixels each): before, the
//   plain red dot with its halo that the chosen place got; after, its icon in the needle pin (what a notebook pin shows);
// - the elevation chart of a nearly flat route (3,753 to 3,778 ft): the preview box and the guidance panel.
// Only code that is on rel-1.1 is used, so the file compiles there for the "before" pictures of the chart.
// flutter test test_shots/taps_round2_renders_test.dart --update-goldens  (pictures in test_shots/taps_round2/)

import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/nav/elevation/elevation_profile.dart';
import 'package:cache/nav/elevation/route_elevation.dart';
import 'package:cache/nav/ui/elevation_panel.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/notebook/map_icons.dart';
import 'package:cache/notebook/pin_image.dart';
import 'package:cache/notebook/place_style.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/nav_fakes.dart';
import 'shot_kit.dart';

const _ft = 0.3048;
const _mi = 1609.344;

/// The marker as the map draws it: the image at [pinImageSize], the pin's point at [pinImageAt], or the dot of the chosen place.
class _Marker extends CustomPainter {
  _Marker({required this.dot, required this.palette});
  final bool dot;
  final MapPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    if (dot) {
      // The chosen place's circle layer: radius 11 with a 4 point edge in the casing colour, centred on the radius (style_generator.dart).
      final c = size.center(Offset.zero);
      canvas.drawCircle(c, 13, Paint()..color = palette['routeCasing']);
      canvas.drawCircle(c, 9, Paint()..color = palette['pin']);
    } else {
      final at = pinImageAt(PinStyle.teardrop, 30);
      paintMapPin(canvas, at, 30, mapIcon('antenna').icon, markerColor('red').color, PinStyle.teardrop);
    }
  }

  @override
  bool shouldRepaint(_Marker old) => false;
}

ElevationProfile _flat() {
  const miles = 0.3;
  final total = miles * _mi;
  final d = <double>[], e = <double>[];
  for (var x = 0.0; x <= total; x += kProfileStepM) {
    d.add(x);
    e.add((3753 + 25 * x / total) * _ft);
  }
  return ElevationProfile.fromSamples(d, e, totalM: total);
}

void main() {
  setUpAll(loadShotFonts);

  testWidgets('notebook place marker, before and after', (tester) async {
    phone(tester, size: const Size(390, 844), ratio: 3);
    final p = mapPaletteFor(CacheThemeId.light);
    final box = pinImageSize(PinStyle.teardrop, 30);
    Widget cell(String label, bool dot) => Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 150,
            height: 130,
            color: const Color(0xFFE6E2D3),
            alignment: Alignment.center,
            child: CustomPaint(size: dot ? const Size(45, 45) : box, painter: _Marker(dot: dot, palette: p)),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 14, color: Colors.black)),
        ]);
    await tester.pumpWidget(shotApp(Scaffold(
      backgroundColor: Colors.white,
      body: Center(child: Row(mainAxisSize: MainAxisSize.min, children: [cell('Before: a dot', true), const SizedBox(width: 20), cell('After: its icon', false)])),
    )));
    await tester.pump();
    await snap(tester, 'taps_round2', 'light-notebook-marker');
  });

  for (final panel in [false, true]) {
    testWidgets('flat route elevation, ${panel ? 'panel' : 'preview'}', (tester) async {
      phone(tester, size: const Size(390, 844), ratio: 3);
      final profile = _flat();
      final el = RouteElevation(loader: (r) async => profile)..request(MapRoute.fromJson(fakeRouteJson()));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      const fmt = Fmt(UnitSystem.imperial);
      final palette = mapPaletteFor(CacheThemeId.light);
      final Widget w = panel
          ? ElevationPanel(elevation: el, fmt: fmt, palette: palette, distanceAlongM: profile.totalM * 0.4, routeM: profile.totalM)
          : Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 0), child: RouteElevationSummary(elevation: el, fmt: fmt, palette: palette));
      await tester.pumpWidget(shotApp(Builder(builder: (c) => Scaffold(backgroundColor: c.t.background, body: Align(alignment: Alignment.topCenter, child: w)))));
      await tester.pump(const Duration(milliseconds: 50));
      await snap(tester, 'taps_round2', 'light-flat-${panel ? 'panel' : 'preview'}');
      await tester.pumpWidget(const SizedBox.shrink());
      el.dispose();
    });
  }
}
