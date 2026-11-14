// Directions from a place always takes the phone to the Maps tab with the route preview for that place (with Start), whether
// or not a car is connected; the car's trip shows the same preview, and guidance starts only with Start. Before the fix a
// notebook place's Directions opened the preview behind the place screen: the phone stayed on the place (it looked like
// nothing happened) while a connected car showed the preview.

import 'dart:io';

import 'package:cache/car/car_trip.dart';
import 'package:cache/car/phone_drive.dart';
import 'package:cache/layout/adaptive.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/screens/notebooks/places_screen.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/place_alerts.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'support/drive_rig.dart';
import 'support/notebook_fake.dart';
import 'support/settings_rig.dart';

const PlaceChoices _places = PlaceChoices(here: _here, saved: _saved);
Future<({double lat, double lon})?> _here() async => (lat: 42.5, lon: -113.8);
Future<List<NbPlace>> _saved() async => const [];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  String selectedTab(WidgetTester tester) {
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    return (bar.destinations[bar.selectedIndex] as NavigationDestination).label;
  }

  Future<void> directionsFromNotebookPlace(WidgetTester tester, {required bool car}) async {
    final r = await SettingsRig.create(tester);
    final dir = Directory('${r.dir.path}/layout')..createSync();
    PanePrefs.testDir = dir;
    addTearDown(() => PanePrefs.testDir = null);
    final layout = LayoutState(settingsDirOverride: dir);
    await tester.runAsync(layout.init);
    final backend = FakeBackend();
    final nav = DriveNav(backend, r.location);
    final drive = PhoneDrive();
    final route = driveRouteJson();
    var routeAsks = 0;
    backend.onRoute = (to, m, from) async {
      routeAsks++;
      return MapRoute.fromJson(route);
    };
    final nb = fakeNotebook(FakeNotebookBackend());
    late final Notebook book;
    late final NbEntry entry;
    await tester.runAsync(() async {
      await nb.start();
      book = await nb.ensureSavedPlaces();
      entry = await nb.saveEntry(notebookId: book.id, occurredAt: '2026-11-01T10:00:00-06:00', title: 'Fernwood Trailhead', place: const NbPlace(lat: 42.5, lon: -113.5), props: {'on_map': true});
    });
    final deps = NotebookDeps(
      notebook: nb,
      places: _places,
      placesDeps: PlaceNotebookDeps(
        watched: (_) => false,
        setWatched: (_, _) {},
        alerts: PlaceAlerts.memory(),
        // The app's own Directions of a notebook place (main.dart).
        directions: (p, name) => placeDirections(nav, p, name),
      ),
      now: () => DateTime(2026, 11, 1, 10),
    );
    tester.view.physicalSize = const Size(390, 844) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.light),
      home: Shell(app: r.app, chat: r.chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: r.browse, nav: nav, layout: layout, hub: r.hub, phoneDrive: drive, notebooks: deps, railPrefs: RailPrefs(dirOverride: dir)),
    ));
    await settle(tester);
    drive.carConnected.value = car;

    // The place, opened over the tabs (a notebook's row or a Home search hit: openNotebookEntry).
    openNotebookEntry(tester.element(find.byType(NavigationBar)), deps, book, entry);
    await settle(tester);
    expect(find.byType(PlaceView), findsOneWidget);
    final button = find.byKey(const ValueKey('place-directions'));
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.tap(button);
    await settle(tester);

    // The phone: Maps, the route preview for the place, with Start; the place screen is closed.
    expect(find.byType(PlaceView), findsNothing, reason: 'the place screen does not stay over the preview');
    expect(selectedTab(tester), 'Maps');
    expect(nav.phase, NavPhase.previewing);
    expect(nav.selected?.name, 'Fernwood Trailhead');
    expect(nav.guiding, isFalse, reason: 'guidance starts only with Start');
    expect(routeAsks, 1, reason: 'the route is asked for once');
    expect(find.byKey(const ValueKey('route-start')).hitTestable(), findsOneWidget);
    // The car's trip (what the car bridge sends): the same preview, not guidance.
    final trip = carTrip(nav);
    expect(trip['phase'], 'previewing');
    expect((trip['destination'] as Map)['name'], isNotEmpty);
    expect(trip.containsKey('step'), isFalse);

    // Start on the phone begins guidance.
    await tester.tap(find.byKey(const ValueKey('route-start')));
    await settle(tester);
    expect(nav.guiding, isTrue);
    await tester.runAsync(nav.end);

    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    layout.dispose();
    drive.dispose();
    await r.dispose(tester);
  }

  testWidgets('Directions from a notebook place with no car connected: Maps, the preview with Start', (tester) async {
    await directionsFromNotebookPlace(tester, car: false);
  });

  testWidgets('Directions from a notebook place with a car connected: Maps on the phone too, the car shows the same preview', (tester) async {
    await directionsFromNotebookPlace(tester, car: true);
  });

  testWidgets('Directions again to the place whose preview is shown asks for the route once', (tester) async {
    final r = await SettingsRig.create(tester);
    final backend = FakeBackend();
    var routeAsks = 0;
    backend.onRoute = (to, m, from) async {
      routeAsks++;
      return MapRoute.fromJson(driveRouteJson());
    };
    final nav = DriveNav(backend, r.location);
    final maps = <Object>[];
    final sub = nav.events.listen((e) {
      if (e is MapRequested) maps.add(e);
    });
    const place = NbPlace(lat: 42.5, lon: -113.5);
    await tester.runAsync(() async {
      // Taps in a row on a place's Directions (the place screen seemed to do nothing).
      for (var i = 0; i < 5; i++) {
        expect(placeDirections(nav, place, 'Fernwood Trailhead'), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });
    expect(routeAsks, 1);
    expect(nav.phase, NavPhase.previewing);
    expect(nav.guiding, isFalse);
    expect(maps, hasLength(5), reason: 'each still brings the Maps tab');
    // Another place: its own route.
    await tester.runAsync(() async {
      placeDirections(nav, const NbPlace(lat: 42.6, lon: -113.4), 'Corner Market');
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    expect(routeAsks, 2);
    expect(nav.selected?.name, 'Corner Market');
    await sub.cancel();
    nav.dispose();
    await r.dispose(tester);
  });

  testWidgets('Maps asked for over another screen (the assistant\'s route preview): the screen closes, Maps shows', (tester) async {
    final r = await SettingsRig.create(tester);
    final dir = Directory('${r.dir.path}/layout')..createSync();
    PanePrefs.testDir = dir;
    addTearDown(() => PanePrefs.testDir = null);
    final layout = LayoutState(settingsDirOverride: dir);
    await tester.runAsync(layout.init);
    final nav = DriveNav(FakeBackend(), r.location);
    tester.view.physicalSize = const Size(390, 844) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.light),
      home: Shell(app: r.app, chat: r.chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: r.browse, nav: nav, layout: layout, hub: r.hub, railPrefs: RailPrefs(dirOverride: dir)),
    ));
    await settle(tester);
    Navigator.of(tester.element(find.byType(NavigationBar))).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(key: ValueKey('over-tabs'), body: SizedBox.expand())));
    await settle(tester);
    expect(find.byKey(const ValueKey('over-tabs')), findsOneWidget);
    nav.requestMap();
    await settle(tester);
    expect(find.byKey(const ValueKey('over-tabs')), findsNothing);
    expect(selectedTab(tester), 'Maps');

    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    layout.dispose();
    await r.dispose(tester);
  });
}
