// The phone's drive screen (what the Maps tab shows while a car screen is connected and guiding), the layout the owner chose: the list
// of turns two thirds, the mini map and the elevation side by side under it. Four themes, the stop and lane arrows case, the car
// rerouting, arrival, a route with no elevation data, and the stress cases (a 320 point wide phone
// and a large text size). The route is made up (test/support/drive_rig.dart). The tab bar under the screen is a stand-in for the app's
// own; the bar above it is the phone's own guidance bar.
// flutter test test_shots/phone_drive_renders_test.dart --update-goldens  (pictures in test_shots/phone_drive/)

import 'package:cache/maps/palette/map_palette.dart';
import 'dart:async';

import 'package:cache/nav/elevation/elevation_profile.dart';
import 'package:cache/nav/elevation/route_elevation.dart';
import 'package:cache/nav/elevation/route_sampler.dart';
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
    bool stop = false,
    bool lanes = false,
    bool rerouting = false,
    bool arrived = false,
    bool shortClimbEnd = false,
    double? partial,
    double? aspect,
    bool wideHalf = false,
    bool sideBySideOnly = false,
    bool noElevation = false,
    ElevationProfile Function()? profile,
    Size size = const Size(390, 844),
    EdgeInsets? insets,
    double textScale = 1,
  }) async {
    phone(tester, size: size, ratio: 3);
    if (noElevation) rig.profile = () => ElevationProfile.none(24600);
    if (profile != null) rig.profile = profile;
    await tester.runAsync(() async {
      await rig.guide(withStop: stop, aspect: aspect);
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
    } else if (shortClimbEnd) {
      rig.at(5, 500);
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
    // A read still going: the chunks so far cover [partial] of the route, from the start (where the driver is).
    var elevation = rig.elevation;
    if (partial != null) {
      final chunks = StreamController<ElevationChunk>();
      addTearDown(chunks.close);
      elevation = RouteElevation(start: (r) => ElevationJob(Completer<ElevationProfile>().future, chunks: chunks.stream));
      addTearDown(elevation.dispose);
      elevation.request(rig.nav.route, following: true);
      final samples = resampleRoute([for (final p in rig.nav.route!.points) (p.lat, p.lon)]);
      final shape = driveProfile();
      final upTo = (samples.length * partial).floor();
      for (var a = 0; a < upTo; a += kElevationChunkSamples) {
        final b = a + kElevationChunkSamples < upTo ? a + kElevationChunkSamples : upTo;
        chunks.add((first: a, heights: [for (var i = a; i < b; i++) shape.elevationAt(samples[i].distM) ?? double.nan]));
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
    await tester.pumpWidget(shotApp(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: DriveScreen(nav: rig.nav, elevation: elevation, palette: mapPaletteFor(theme), themeId: theme, wideHalf: wideHalf, sideBySideOnly: sideBySideOnly),
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
  testWidgets('7 rerouting', (t) => draw(t, '7-rerouting', rerouting: true));
  testWidgets('8 arrival', (t) => draw(t, '8-arrival', arrived: true));
  testWidgets('9 no elevation data for the route', (t) => draw(t, '9-no-elevation', noElevation: true));
  testWidgets('12 a short steep climb at the destination end: no grade badge on the mini map, as on the car', (t) => draw(t, '12-short-climb-at-destination', shortClimbEnd: true, profile: driveEndClimbProfile));
  testWidgets('13 a route a few feet long: the elevation box says there is nothing to chart', (t) => draw(t, '13-tiny-route', profile: driveTinyProfile));
  testWidgets('14 the read has got a quarter of the way along', (t) => draw(t, '14-chunks-quarter', partial: 0.25));
  testWidgets('15 the read has got two thirds of the way along', (t) => draw(t, '15-chunks-two-thirds', partial: 0.66));
  testWidgets('16 a wide route: stacked', (t) => draw(t, '16-wide-stacked'));
  testWidgets('17 a tall route: side by side', (t) => draw(t, '17-tall-side-by-side', aspect: 0.5));
  testWidgets('18 a near-square route', (t) => draw(t, '18-near-square', aspect: 1.1));
  testWidgets('19 a wide route, stacked, 320 wide', (t) => draw(t, '19-stacked-320', stop: true, lanes: true, size: const Size(320, 640), insets: const EdgeInsets.only(top: 24, bottom: 16)));
  testWidgets('20 a wide route, stacked, large text', (t) => draw(t, '20-stacked-large-text', stop: true, lanes: true, textScale: 2));
  testWidgets('21 a wide route (3.5:1), the list half, the boxes stacked in the other half', (t) => draw(t, '21-a-wide-half', aspect: 3.5, wideHalf: true));
  testWidgets('22 the same route, the list two thirds, the boxes stacked', (t) => draw(t, '22-b-wide-two-thirds-stacked', aspect: 3.5));
  testWidgets('23 the same route, the list two thirds, side by side', (t) => draw(t, '23-c-wide-two-thirds-side-by-side', aspect: 3.5, sideBySideOnly: true));
  testWidgets('24 the half form at 320 wide', (t) => draw(t, '24-d-wide-half-320', aspect: 3.5, wideHalf: true, stop: true, lanes: true, size: const Size(320, 640), insets: const EdgeInsets.only(top: 24, bottom: 16)));
  testWidgets('25 the half form at large text', (t) => draw(t, '25-e-wide-half-large-text', aspect: 3.5, wideHalf: true, stop: true, lanes: true, textScale: 2));
  testWidgets('10 a 320 point wide phone', (t) => draw(t, '10-small-phone-320', stop: true, lanes: true, size: const Size(320, 640), insets: const EdgeInsets.only(top: 24, bottom: 16)));
  testWidgets('11 large text (2x)', (t) => draw(t, '11-large-text', stop: true, lanes: true, textScale: 2));
}
