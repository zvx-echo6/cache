// The elevation chart with the 330 ft (100 m) floor, for the owner to review: the preview box (RouteElevationSummary) and the guidance
// panel (ElevationPanel), three routes (flat, rolling, mountain), four themes, phone width 390. With ELEV_OLD set (run against the
// code before the floor) only the flat route is drawn, for the comparison.
// flutter test test_shots/elevation_floor_renders_test.dart --update-goldens  (pictures in test_shots/elevation_floor/)

import 'dart:io';
import 'dart:math' as math;

import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/nav/elevation/elevation_profile.dart';
import 'package:cache/nav/elevation/route_elevation.dart';
import 'package:cache/nav/ui/elevation_panel.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/nav_fakes.dart';
import 'shot_kit.dart';

const _ft = 0.3048;
const _mi = 1609.344;

/// A realistic synthetic profile: [riseFt] of overall slope plus [wiggleFt] of rolling, over [miles].
ElevationProfile _route(double miles, double riseFt, double wiggleFt, double startFt) {
  final total = miles * _mi;
  final d = <double>[], e = <double>[];
  for (var x = 0.0; x <= total; x += kProfileStepM) {
    final t = x / total;
    d.add(x);
    e.add((startFt + riseFt * t + wiggleFt * math.sin(t * math.pi * 2 * (miles / 1.5).clamp(1, 6))) * _ft);
  }
  return ElevationProfile.fromSamples(d, e, totalM: total);
}

final _routes = <String, ElevationProfile Function()>{
  'flat': () => _route(0.3, -8, 1.5, 4310), // about 10 ft over 0.3 mi
  'flat-sealevel': () => _route(0.3, -8, 1.5, 20), // the same flat route at about 20 ft
  'rolling': () => _route(3, 60, 45, 4900), // about 150 ft over 3 mi
  'mountain': () => _route(12, -1500, 400, 6800), // about 2,000 ft over 12 mi
};

void main() {
  setUpAll(loadShotFonts);
  final old = Platform.environment.containsKey('ELEV_OLD');

  Future<void> render(WidgetTester tester, CacheThemeId theme, String route, bool panel, String name) async {
    phone(tester, size: const Size(390, 844), ratio: 3);
    final profile = _routes[route]!();
    final el = RouteElevation(loader: (r) async => profile)..request(MapRoute.fromJson(fakeRouteJson()));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    const fmt = Fmt(UnitSystem.imperial);
    final palette = mapPaletteFor(theme);
    final Widget w = panel
        ? ElevationPanel(elevation: el, fmt: fmt, palette: palette, distanceAlongM: profile.totalM * 0.4, routeM: profile.totalM)
        : Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 0), child: RouteElevationSummary(elevation: el, fmt: fmt, palette: palette));
    await tester.pumpWidget(shotApp(
      Builder(builder: (c) => Scaffold(backgroundColor: c.t.background, body: Align(alignment: Alignment.topCenter, child: w))),
      theme: theme,
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await snap(tester, 'elevation_floor', name);
    await tester.pumpWidget(const SizedBox.shrink());
    el.dispose();
  }

  if (old) {
    testWidgets('flat route with the old floor (light)', (t) => render(t, CacheThemeId.light, 'flat', false, 'light-flat-preview-OLD-floor'));
    testWidgets('flat route with the old floor, panel (light)', (t) => render(t, CacheThemeId.light, 'flat', true, 'light-flat-panel-OLD-floor'));
    return;
  }
  for (final theme in CacheThemeId.values) {
    for (final route in _routes.keys) {
      for (final panel in [false, true]) {
        final name = '${theme.name}-$route-${panel ? 'panel' : 'preview'}';
        testWidgets(name, (t) => render(t, theme, route, panel, name));
      }
    }
  }
}
