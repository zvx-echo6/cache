// The phone's drive screen (what the Maps tab shows while a car screen is connected and guiding), the layout the owner chose: the list
// of turns two thirds, the mini map and the elevation side by side under it. Four themes, the stop and lane arrows case, the car
// carrying the extras (turns only), rerouting, arrival, a route with no elevation data, and the stress cases (a 320 point wide phone
// and a large text size). The route is made up (test/support/drive_rig.dart). The tab bar under the screen is a stand-in for the app's
// own; the bar above it is the phone's own guidance bar.
// flutter test test_shots/phone_drive_renders_test.dart --update-goldens  (pictures in test_shots/phone_drive/)

import 'package:cache/car/phone_drive.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/nav/elevation/elevation_profile.dart';
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
    CacheThemeId theme = CacheThemeId.dark,
    CarExtras extras = CarExtras.never,
    bool stop = false,
    bool lanes = false,
    bool rerouting = false,
    bool arrived = false,
    bool noElevation = false,
    Size size = const Size(390, 844),
    EdgeInsets? insets,
    double textScale = 1,
  }) async {
    phone(tester, size: size, ratio: 3);
    if (noElevation) rig.profile = () => ElevationProfile.none(24600);
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
    } else if (arrived) {
      rig.at(8, 20);
      rig.nav.arrived = true;
      rig.nav.poke();
    } else {
      rig.at(2, 640);
    }
    if (rerouting) {
      rig.nav.rerouting = true;
      rig.nav.poke();
    }
    await tester.pumpWidget(shotApp(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: DriveScreen(nav: rig.nav, elevation: rig.elevation, palette: mapPaletteFor(theme), themeId: theme, extras: extras),
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
        ),
      ),
      theme: theme,
      insets: insets,
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    await snap(tester, _out, name);
  }

  testWidgets('1 Dark', (t) => draw(t, '1-dark', theme: CacheThemeId.dark));
  testWidgets('2 Light', (t) => draw(t, '2-light', theme: CacheThemeId.light));
  testWidgets('3 Tactical', (t) => draw(t, '3-tactical', theme: CacheThemeId.tactical));
  testWidgets('4 Parchment', (t) => draw(t, '4-parchment', theme: CacheThemeId.parchment));
  testWidgets('5 a stop in the list and lane arrows on the next turn', (t) => draw(t, '5-stop-and-lanes', stop: true, lanes: true));
  testWidgets('6 the car carries the extras: turns only', (t) => draw(t, '6-car-carries', extras: CarExtras.always));
  testWidgets('7 rerouting', (t) => draw(t, '7-rerouting', rerouting: true));
  testWidgets('8 arrival', (t) => draw(t, '8-arrival', arrived: true));
  testWidgets('9 no elevation data for the route', (t) => draw(t, '9-no-elevation', noElevation: true));
  testWidgets('10 a 320 point wide phone', (t) => draw(t, '10-small-phone-320', stop: true, lanes: true, size: const Size(320, 640), insets: const EdgeInsets.only(top: 24, bottom: 16)));
  testWidgets('11 large text (2x)', (t) => draw(t, '11-large-text', stop: true, lanes: true, textScale: 2));
}
