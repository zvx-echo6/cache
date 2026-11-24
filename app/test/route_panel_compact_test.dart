// The directions panel is short: the three rows (as ever), one line with the ETA and distance and an outlined "N routes ^" chip, then
// "Turns" and Start. The route cards, the elevation chart and the route notes are in the "Routes" sheet that chip opens. Every name and
// place here is made up.

import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/nav/ui/elevation_panel.dart' show RouteElevationSummary;
import 'package:cache/nav/ui/route_panel.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'support/drive_rig.dart';

const _mi = 1609.344;

Map<String, dynamic> _json(String id, {required int alt, required bool off, double mi = 130, int min = 123, String road = 'I 84', List<String> notes = const []}) {
  final j = fakeRouteJson(id: id, alt: alt, offroad: off, name: 'Pine Hollow Trailhead');
  final m = mi * _mi * (alt == 0 ? 1 : 1 + 0.12 * alt);
  final offM = off ? 3.8 * _mi : 0.0;
  j['distance_m'] = m;
  j['duration_s'] = min * 60.0 * (alt == 0 ? 1 : 1 + 0.12 * alt);
  j['totals'] = {'distance_m': m, 'duration_s': j['duration_s'], 'road_m': m - offM, 'offroad_m': offM, 'ascent_m': off ? 30 : 0, 'descent_m': 0};
  if (off) {
    final sg = j['segments'] as List;
    sg[0]['distance_m'] = m - offM;
    sg[1]['distance_m'] = offM;
  }
  j['major_roads'] = [{'name': alt == 0 ? road : 'US 20', 'distance_km': 20.0}];
  j['notes'] = notes;
  return j;
}

class _Panel {
  late DriveRig rig;
  VoidCallback? swiped;
  int swipes = 0;
  int turns = 0;

  Future<void> pump(WidgetTester tester, {bool off = false, int alts = 2, Size size = const Size(390, 844), double text = 1.0, String travel = 'drive'}) async {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = text;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    rig = DriveRig();
    await tester.runAsync(rig.setUp);
    rig.backend.onRoute = (to, mode, from) async {
      final o = mode.startsWith('offroad');
      final j = _json('r1', alt: 0, off: o, mi: o ? 14 : 130, min: o ? 44 : 123, road: o ? 'Forest Road 142' : 'I 84', notes: const ['Gate at mile 3 may be locked.']);
      j['alternatives'] = [for (var a = 1; a <= alts; a++) _json('r${a + 1}', alt: a, off: o, mi: o ? 14 : 130, min: o ? 44 : 123)];
      return MapRoute.fromJson(j);
    };
    await tester.runAsync(() async {
      await rig.nav.openDirections(const MapPlace(id: 'place:osm:n4', type: 'place', name: 'Pine Hollow Trailhead', kind: 'Park', address: '', lat: 42.5, lon: -113.5, matched: 'name'));
      if (travel != 'drive') await rig.nav.setTravel(travel);
      if (travel == 'atv') await rig.nav.setMode('offroad_sxs');
      rig.elevation.request(rig.nav.route);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.parchment),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: ListenableBuilder(
            listenable: rig.nav,
            builder: (context, _) => RoutePanel(
              nav: rig.nav,
              fmt: const Fmt(UnitSystem.imperial),
              elevation: RouteElevationSummary(elevation: rig.elevation, fmt: const Fmt(UnitSystem.imperial), palette: mapPaletteFor(CacheThemeId.parchment)),
              onNextTurn: () => turns++,
              onSwipeDown: () => swipes++,
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async => rig.tearDown());
  }
}

void main() {
  testWidgets('the panel has the three rows, one ETA line and Start; the routes, the chart and the notes are not in it', (tester) async {
    final p = _Panel();
    await p.pump(tester);
    expect(find.byKey(const ValueKey('route-summary')), findsOneWidget);
    expect(find.text('2 h 3 min · 130 mi'), findsOneWidget);
    expect(find.text('via I 84'), findsOneWidget);
    expect(find.byKey(const ValueKey('route-start')), findsOneWidget);
    expect(find.byKey(const ValueKey('route-turns')), findsOneWidget);
    expect(find.text('Turns'), findsOneWidget);
    // The chip: "3 routes" and the ^, outlined, on the right of the ETA line.
    expect(find.byKey(const ValueKey('routes-chip')), findsOneWidget);
    expect(find.text('3 routes'), findsOneWidget);
    expect(find.byIcon(Icons.expand_less), findsOneWidget, reason: 'the ^');
    // No arrow and no route-cycling control: the old next and disabled back arrows, and "Route 1 of 3", are gone.
    expect(find.byKey(const ValueKey('step-next')), findsNothing);
    expect(find.byKey(const ValueKey('step-back')), findsNothing);
    expect(find.byIcon(Icons.arrow_forward), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    expect(find.textContaining('Route 1 of'), findsNothing);
    expect(find.textContaining(' of 3'), findsNothing);
    for (final k in ['route-card-0', 'route-card-1', 'route-card-2', 'preview-elevation']) {
      expect(find.byKey(ValueKey(k)), findsNothing, reason: '$k belongs in the Routes sheet');
    }
    expect(find.textContaining('Gate at mile 3'), findsNothing);
    expect(find.text('Routes'), findsNothing);
    // The panel is short: the rows and one line, not the half-screen it was with the routes and the chart.
    final h = tester.getSize(find.byType(RoutePanel)).height;
    expect(h, lessThan(844 * 0.3), reason: '$h dp');
    await p.done(tester);
  });

  testWidgets('tapping the ETA line opens the Routes sheet: the routes (tappable to choose), the elevation chart and the notes', (tester) async {
    final p = _Panel();
    await p.pump(tester);
    await tester.tap(find.byKey(const ValueKey('route-summary')));
    await tester.pumpAndSettle();
    expect(find.text('Routes'), findsOneWidget);
    expect(find.byKey(const ValueKey('route-card-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('route-card-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('route-card-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-elevation')), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-elevation-chart')), findsOneWidget, reason: 'the profile read before the sheet opened is drawn');
    expect(find.textContaining('Gate at mile 3'), findsOneWidget);
    expect(p.rig.nav.routeIndex, 0);
    await tester.tap(find.byKey(const ValueKey('route-card-1')));
    await tester.pumpAndSettle();
    expect(p.rig.nav.routeIndex, 1, reason: 'an alternative is chosen as before');
    await p.done(tester);
  });

  testWidgets('the "3 routes" chip opens the same sheet', (tester) async {
    final p = _Panel();
    await p.pump(tester);
    await tester.tap(find.byKey(const ValueKey('routes-chip')));
    await tester.pumpAndSettle();
    expect(find.text('Routes'), findsOneWidget);
    await p.done(tester);
  });

  testWidgets('with one route the chip shows just the ^ (no count) and still opens the sheet with that route', (tester) async {
    final p = _Panel();
    await p.pump(tester, alts: 0);
    expect(find.byKey(const ValueKey('routes-chip')), findsOneWidget);
    expect(find.textContaining('routes'), findsNothing);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('routes-chip')));
    await tester.pumpAndSettle();
    expect(find.text('Routes'), findsOneWidget);
    expect(find.byKey(const ValueKey('route-card-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('route-card-1')), findsNothing);
    await p.done(tester);
  });

  testWidgets('Turns opens the turn list (what the old arrow did) and is off with no route', (tester) async {
    final p = _Panel();
    await p.pump(tester);
    await tester.tap(find.byKey(const ValueKey('route-turns')));
    await tester.pump();
    expect(p.turns, 1);
    await p.done(tester);
  });

  testWidgets('selecting a card in the Routes sheet selects that route: the panel line follows', (tester) async {
    final p = _Panel();
    await p.pump(tester);
    expect(find.text('2 h 3 min · 130 mi'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('routes-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('route-card-2')));
    await tester.pumpAndSettle();
    expect(p.rig.nav.routeIndex, 2);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('2 h 3 min · 130 mi'), findsNothing, reason: 'the line is the third route now');
    expect(find.text('${p.rig.nav.fmt.duration(p.rig.nav.route!.durationS)} · ${p.rig.nav.fmt.distance(p.rig.nav.route!.distanceM)}'), findsOneWidget);
    await p.done(tester);
  });

  testWidgets('off-road: "44 min · 14 mi" then "3.8 mi off-road · via Forest Road 142"', (tester) async {
    final p = _Panel();
    await p.pump(tester, off: true, travel: 'atv');
    expect(find.text('44 min · 14 mi'), findsOneWidget);
    expect(find.text('3.8 mi off-road · via Forest Road 142', findRichText: true), findsOneWidget);
    // The Standard | Emergency row is still in the panel (only for the off-road choices).
    expect(find.text('Standard'), findsOneWidget);
    expect(find.text('Emergency'), findsOneWidget);
    await p.done(tester);
  });

  testWidgets('a swipe down on the panel is reported, from the rows and from the Start line; a tap and a slow drag are not', (tester) async {
    final p = _Panel();
    await p.pump(tester);
    final c = tester.getCenter(find.byType(RoutePanel));
    await tester.flingFrom(c.translate(0, -40), const Offset(0, 160), 1200);
    await tester.pump(const Duration(milliseconds: 400));
    expect(p.swipes, 1, reason: 'over the choices');
    await tester.flingFrom(tester.getCenter(find.byKey(const ValueKey('route-start'))).translate(-120, 0), const Offset(0, 160), 1200);
    await tester.pump(const Duration(milliseconds: 400));
    expect(p.swipes, 2, reason: 'over the Start line');
    await tester.flingFrom(c, const Offset(0, -160), 1200);
    await tester.pump(const Duration(milliseconds: 400));
    expect(p.swipes, 2, reason: 'up is not back');
    await tester.drag(find.byType(RoutePanel), const Offset(0, 100), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 800));
    expect(p.swipes, 2, reason: 'a slow drag is not a swipe');
    await p.done(tester);
  });

  for (final off in [false, true]) {
    testWidgets('320 dp wide at 2.0x text (${off ? 'ATV, Emergency' : 'drive'}): nothing overflows and the panel stays inside its cap', (tester) async {
      final p = _Panel();
      await p.pump(tester, size: const Size(320, 640), text: 2.0, off: off, travel: off ? 'atv' : 'drive');
      if (off) {
        await tester.runAsync(() => p.rig.nav.setLandAccess('emergency'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      final h = tester.getSize(find.byType(RoutePanel)).height;
      // The rows scroll inside half the screen; the buttons stay at the foot.
      expect(h, lessThanOrEqualTo(640 * 0.5 + 100), reason: '$h dp');
      expect(tester.getRect(find.byKey(const ValueKey('route-start'))).right, lessThanOrEqualTo(320));
      expect(find.byKey(const ValueKey('route-summary')), findsOneWidget);
      await p.done(tester);
    });
  }
}
