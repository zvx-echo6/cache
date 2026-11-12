// The phone's drive screen (what the Maps tab shows while a car screen is connected and guiding) for the owner to review, 390 points
// wide: the list of turns taking one half and two thirds of the room, the car carrying the extras (turns only), the Light theme, and
// a route with a stop and lane arrows. The route is made up (test/support/drive_rig.dart). The tab bar under the screen is a stand-in
// for the app's own (the same height and look); the bar above it is the phone's own guidance bar.
// flutter test test_shots/phone_drive_renders_test.dart --update-goldens  (pictures in test_shots/phone_drive/)

import 'package:cache/car/phone_drive.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/nav/ui/drive_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/drive_rig.dart';
import '../test/support/lane_rig.dart' show laneJson;
import 'shot_kit.dart';

const _out = 'phone_drive';
typedef D = LaneDirection;

void main() {
  setUpAll(loadShotFonts);

  late DriveRig rig;
  setUp(() async {
    rig = DriveRig();
    await rig.setUp();
  });
  tearDown(() => rig.tearDown());

  Future<void> draw(
    WidgetTester tester,
    String name, {
    required CacheThemeId theme,
    required double share,
    CarExtras extras = CarExtras.never,
    bool stop = false,
    bool lanes = false,
  }) async {
    phone(tester, size: const Size(390, 844), ratio: 3);
    await tester.runAsync(() async {
      await rig.guide(withStop: stop);
      rig.elevation.request(rig.nav.route);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    if (lanes) {
      rig.at(1, 640, lanes: [
        laneJson({D.left}, active: D.left),
        laneJson({D.left, D.through}, valid: D.left),
        laneJson({D.through}),
        laneJson({D.through}),
        laneJson({D.through, D.right}),
      ]);
    } else {
      rig.at(2, 640);
    }
    await tester.pumpWidget(shotApp(
      Scaffold(
        body: DriveScreen(nav: rig.nav, elevation: rig.elevation, palette: mapPaletteFor(theme), themeId: theme, extras: extras, turnsShare: share),
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
      theme: theme,
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    await snap(tester, _out, name);
  }

  testWidgets('a: Dark, turns one half, mini map and elevation in the rest', (tester) => draw(tester, 'a-dark-half', theme: CacheThemeId.dark, share: 1 / 2));
  testWidgets('b: Dark, turns two thirds, mini map and elevation in the rest', (tester) => draw(tester, 'b-dark-two-thirds', theme: CacheThemeId.dark, share: 2 / 3));
  testWidgets('c: Dark, the car carries the extras, turns only', (tester) => draw(tester, 'c-dark-car-carries', theme: CacheThemeId.dark, share: 1 / 2, extras: CarExtras.always));
  testWidgets('d: Light, turns one half', (tester) => draw(tester, 'd-light-half', theme: CacheThemeId.light, share: 1 / 2));
  testWidgets('e: Light, turns two thirds', (tester) => draw(tester, 'e-light-two-thirds', theme: CacheThemeId.light, share: 2 / 3));
  testWidgets('f: Dark, one half, a stop in the list and lane arrows on the next turn', (tester) => draw(tester, 'f-dark-half-stop-lanes', theme: CacheThemeId.dark, share: 1 / 2, stop: true, lanes: true));
}
