// Link audit batch 2, before and after, for the owner: the two route errors that now have a button (outside the downloaded maps:
// Download this area; no off-road data: Add off-road data), and the phone's drive screen (a car connected) with the Map button.
// Phone 390 x 844, light. The same file runs on rel-1.1 (the buttons are passed by name at run time and left out where the screen
// has no such parameter, which draws the "before"). Made-up places only (test/support/drive_rig.dart).
// flutter test test_shots/links2_renders_test.dart --update-goldens  (pictures in test_shots/links2/)

import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/nav/ui/drive_screen.dart';
import 'package:cache/nav/ui/route_panel.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/drive_rig.dart';
import 'shot_kit.dart';

const _out = 'links2';
const _theme = CacheThemeId.light;

/// [make] called with [named] first; where the screen has no such parameter yet (rel-1.1), called without them.
Widget _maybe(Function make, Map<Symbol, dynamic> base, Map<Symbol, dynamic> named) {
  try {
    return Function.apply(make, const [], {...base, ...named}) as Widget;
  } on NoSuchMethodError {
    return Function.apply(make, const [], base) as Widget;
  }
}

void main() {
  setUpAll(loadShotFonts);

  late DriveRig rig;
  setUp(() async {
    rig = DriveRig();
    await rig.setUp();
  });
  tearDown(() => rig.tearDown());

  Future<void> routeError(WidgetTester tester, String name, {required String code, bool offroad = false}) async {
    phone(tester, size: const Size(390, 844), ratio: 3);
    rig.backend.onRoute = (to, mode, from) async => MapRoute.fromJson({
          'ok': false,
          'route_id': 'x',
          'mode': mode,
          'errors': [{'code': code, 'message': 'no route'}],
        });
    await tester.runAsync(() async {
      await rig.nav.openDirections(driveDestination);
      if (offroad) await rig.nav.setMode('offroad_foot');
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    final nav = rig.nav;
    await tester.pumpWidget(shotApp(
      Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 34),
            child: ListenableBuilder(
              listenable: nav,
              builder: (_, _) => _maybe(RoutePanel.new, {#nav: nav, #fmt: const Fmt(UnitSystem.imperial)}, {#onDownloadArea: () {}, #onAddOffroad: () {}}),
            ),
          ),
        ),
      ),
      theme: _theme,
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    await snap(tester, _out, name);
  }

  testWidgets('01 outside the downloaded maps', (t) => routeError(t, '01-outside-maps-error', code: 'out_of_coverage'));
  testWidgets('02 no off-road data', (t) => routeError(t, '02-offroad-error', code: 'not_set_up', offroad: true));

  testWidgets('03 the drive screen', (tester) async {
    phone(tester, size: const Size(390, 844), ratio: 3);
    await tester.runAsync(() async {
      await rig.guide();
      rig.elevation.request(rig.nav.route);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    rig.at(2, 640);
    await tester.pumpWidget(shotApp(
      Scaffold(
        body: _maybe(DriveScreen.new, {#nav: rig.nav, #elevation: rig.elevation, #palette: mapPaletteFor(_theme), #themeId: _theme}, {#onMap: () {}}),
        bottomNavigationBar: NavigationBar(
          selectedIndex: 2,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Ask'),
            NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Maps'),
            NavigationDestination(icon: Icon(Icons.local_library_outlined), label: 'Library'),
            NavigationDestination(icon: Icon(Icons.apps_outlined), label: 'Modules'),
          ],
        ),
      ),
      theme: _theme,
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    await snap(tester, _out, '03-drive-screen');
  });
}
