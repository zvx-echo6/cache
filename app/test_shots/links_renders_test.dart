// The link audit's changes, drawn for the owner to review (phone 390 x 844, light; made-up places). This file compiles and runs
// unchanged on rel-1.1 (before) and on the link branches (after): the new parameters are passed by name at run time, and left out
// when the screen does not have them. Some changes are a tap target with no visible change; those scenes look the same.
// flutter test test_shots/links_renders_test.dart --update-goldens  (pictures in test_shots/links/)
//   01 place card of a Places notebook place (after: "Open")   02 the route panel's header   03 the elevation panel

import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/nav/elevation/route_elevation.dart';
import 'package:cache/nav/ui/elevation_panel.dart';
import 'package:cache/nav/ui/place_card.dart';
import 'package:cache/nav/ui/route_panel.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/drive_rig.dart';
import 'shot_kit.dart';

const _out = 'links';

/// [ctor] with [base] named arguments, and [extra] too when the widget has them (a widget without them is drawn as it was).
Widget _either(Function ctor, Map<Symbol, Object?> base, Map<Symbol, Object?> extra) {
  try {
    return Function.apply(ctor, null, {...base, ...extra}) as Widget;
  } on NoSuchMethodError {
    return Function.apply(ctor, null, base) as Widget;
  }
}

void main() {
  setUpAll(() async {
    await loadShotFonts();
  });

  testWidgets('01 place card of a Places notebook place', (tester) async {
    phone(tester, size: const Size(390, 844));
    final r = DriveRig();
    await tester.runAsync(r.setUp);
    addTearDown(r.tearDown);
    const place = MapPlace(id: 'notebook:e1', type: 'place', name: 'Spring box', kind: 'Places', address: '', lat: 42.54, lon: -113.62, matched: '');
    await tester.pumpWidget(shotApp(Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        child: _either(PlaceCard.new, {#nav: r.nav, #place: place, #fmt: r.nav.fmt, #onClose: () {}}, {#onOpenEntry: () {}}),
      ),
    )));
    await tester.pump();
    await snap(tester, _out, '01-place-card-places');
  });

  testWidgets('02 the route panel header', (tester) async {
    phone(tester, size: const Size(390, 844));
    final r = DriveRig();
    await tester.runAsync(r.setUp);
    addTearDown(r.tearDown);
    final nav = r.nav
      ..selected = driveDestination
      ..fromPlace = MapPlace.pin(42.49, -113.81, name: 'Gravel lot')
      ..stops = [driveStop, MapPlace.pin(42.47, -113.7, name: 'Fuel stop')];
    await tester.pumpWidget(shotApp(Align(
      alignment: Alignment.topCenter,
      child: Padding(padding: const EdgeInsets.all(12), child: Material(type: MaterialType.transparency, child: DirectionsHeader(nav: nav))),
    )));
    await tester.pump();
    await snap(tester, _out, '02-route-header');
  });

  testWidgets('03 the elevation panel during guidance', (tester) async {
    phone(tester, size: const Size(390, 844));
    final el = RouteElevation(loader: (route) async => driveProfile());
    addTearDown(el.dispose);
    await tester.runAsync(() async {
      el.request(MapRoute.fromJson(driveRouteJson()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpWidget(shotApp(Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        child: SizedBox(
          width: 390,
          child: _either(ElevationPanel.new, {#elevation: el, #fmt: const Fmt(UnitSystem.imperial), #palette: mapPaletteFor(CacheThemeId.light), #distanceAlongM: 0.0, #routeM: 24600.0}, {#onSpot: (double _) {}}),
        ),
      ),
    )));
    await tester.pump();
    await snap(tester, _out, '03-elevation-panel');
  });
}
