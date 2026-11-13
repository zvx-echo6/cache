// The other tabs of Cache work as normal while a car is guiding: the selected tab stays where the person put it through progress
// updates, maneuvers and a car reconnect; the drive screen shows again only when the person comes back to Maps. And the route
// preview's elevation box says there is nothing to chart for a route a few feet long (the drive screen's rule).

import 'dart:io';

import 'package:cache/car/phone_drive.dart';
import 'package:cache/layout/adaptive.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/nav/elevation/route_elevation.dart';
import 'package:cache/nav/ui/elevation_panel.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'support/drive_rig.dart';
import 'support/settings_rig.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the selected tab stays through progress updates, maneuvers and a car reconnect', (tester) async {
    final r = await SettingsRig.create(tester);
    final dir = Directory.systemTemp.createTempSync('tabstay');
    PanePrefs.testDir = dir;
    addTearDown(() => PanePrefs.testDir = null);
    final layout = LayoutState(settingsDirOverride: dir);
    await tester.runAsync(layout.init);
    final backend = FakeBackend();
    final nav = DriveNav(backend, r.location);
    final drive = PhoneDrive();
    final route = driveRouteJson();
    backend.onRoute = (to, m, from) async => MapRoute.fromJson(route);
    backend.onProgress = (rt, lat, lon) async => MapProgress.fromJson(driveProgressJson(route, 1, 400));
    tester.view.physicalSize = const Size(390, 844) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.light),
      home: Shell(app: r.app, chat: r.chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: r.browse, nav: nav, layout: layout, hub: r.hub, phoneDrive: drive, railPrefs: RailPrefs(dirOverride: dir)),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    // A car is connected and a route is being guided, then the person goes to the Library.
    drive.carConnected.value = true;
    await tester.runAsync(() async {
      await nav.openDirections(driveDestination);
      await nav.start();
    });
    await tester.pump();
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Library')));
    await tester.pump(const Duration(milliseconds: 200));
    int selected() => tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;
    final library = selected();
    expect(find.byKey(const ValueKey('drive-screen')), findsNothing);

    // Progress updates and maneuvers.
    for (final (next, m) in [(1, 400.0), (1, 250.0), (2, 900.0), (3, 150.0), (4, 1200.0), (5, 500.0)]) {
      nav.progress = MapProgress.fromJson(driveProgressJson(route, next, m));
      nav.poke();
      await tester.pump(const Duration(milliseconds: 100));
      expect(selected(), library, reason: 'next $next, $m m');
    }
    // A stop passed.
    nav.progress = MapProgress.fromJson(driveProgressJson(route, 5, 300, stopsReached: 1));
    nav.poke();
    await tester.pump(const Duration(seconds: 1));
    expect(selected(), library);
    // The car leaves and comes back.
    drive.carConnected.value = false;
    await tester.pump(const Duration(seconds: 1));
    expect(selected(), library);
    drive.carConnected.value = true;
    await tester.pump(const Duration(seconds: 61));
    expect(selected(), library, reason: 'a minute on, still the Library');
    expect(find.byKey(const ValueKey('drive-screen')), findsNothing);
    expect(drive.signal.value, isFalse, reason: 'the drive screen is not showing');

    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    layout.dispose();
    await r.dispose(tester);
  });

  testWidgets('the route preview\'s elevation box has no chart, length or axis for a route a few feet long', (tester) async {
    final el = RouteElevation(loader: (route) async => driveTinyProfile());
    addTearDown(el.dispose);
    await tester.runAsync(() async {
      el.request(MapRoute.fromJson(fakeRouteJson()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.light),
      home: Scaffold(body: RouteElevationSummary(elevation: el, fmt: const Fmt(UnitSystem.imperial), palette: mapPaletteFor(CacheThemeId.light))),
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey('preview-elevation-none')), findsOneWidget);
    expect(find.text('No elevation data for this route.'), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-elevation-chart')), findsNothing);
  });
}
