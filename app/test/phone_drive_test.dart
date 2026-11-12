// The phone's drive screen: what the Maps tab shows while a car screen is connected and guiding (nav/ui/drive_screen.dart), and the
// signal "the phone's drive screen is showing" the car is told (car/phone_drive.dart).

import 'dart:io';

import 'package:cache/car/phone_drive.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/nav/elevation/elevation_profile.dart';
import 'package:cache/nav/ui/drive_screen.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'location_service_test.dart' show FakeSource;
import 'navigation_camera_test.dart' show CameraController, NoSurface;
import 'support/drive_rig.dart';
import 'support/lane_rig.dart' show laneJson;
import 'support/test_layer_engine.dart';

typedef D = LaneDirection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the Maps tab and the signal', () {
    late Directory dir;
    late LocationService location;
    late MapsState maps;
    late DriveNav nav;
    late PhoneDrive drive;
    late CameraController camera;
    late ValueNotifier<bool> active;
    late DriveRig rig;
    final changes = <bool>[];
    late MapLibrePlatform Function() originalPlatform;

    Future<void> pumpMaps(WidgetTester tester, {PhoneDrive? give, bool withDrive = true}) async {
      tester.view.physicalSize = const Size(390, 844) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      rootBundle.clear();
      dir = Directory.systemTemp.createTempSync('phone-drive-');
      originalPlatform = MapLibrePlatform.createInstance;
      MapLibrePlatform.createInstance = () => NoSurface();
      location = LocationService(source: FakeSource(), settingsDirOverride: dir);
      final engine = TestLayerEngine();
      maps = MapsState(engine: engine, settingsDirOverride: dir);
      rig = DriveRig();
      await tester.runAsync(() async {
        await rig.setUp();
        await location.init();
        await engine.start();
      });
      nav = rig.nav;
      drive = give ?? PhoneDrive();
      changes.clear();
      drive.signal.addListener(() => changes.add(drive.signal.value));
      camera = CameraController();
      active = ValueNotifier(true);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.dark),
        home: ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (context, on, _) => MapsScreen(
            location: location,
            maps: maps,
            nav: nav,
            themeId: CacheThemeId.dark,
            glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf',
            elevation: rig.elevation,
            drive: withDrive ? drive : null,
            active: on,
          ),
        ),
      ));
      for (var i = 0; i < 100 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      map.onMapCreated!(camera);
      map.onStyleLoadedCallback!();
      await tester.pump();
      await tester.runAsync(() => rig.guide());
      rig.at(1, 400, lanes: [laneJson({D.left}, active: D.left), laneJson({D.through})]);
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      MapLibrePlatform.createInstance = originalPlatform;
      camera.dispose();
      maps.dispose();
      drive.dispose();
      active.dispose();
      await tester.runAsync(() async {
        rig.tearDown();
        location.dispose();
        await dir.delete(recursive: true);
      });
    }

    Finder driveScreen() => find.byKey(const ValueKey('drive-screen'));

    testWidgets('with no car connected the Maps tab is exactly today\'s screen, and the signal stays false', (tester) async {
      await pumpMaps(tester);
      expect(driveScreen(), findsNothing);
      expect(find.byKey(const ValueKey('guidance-banner')), findsOneWidget);
      expect(find.byKey(const ValueKey('banner-then')), findsOneWidget, reason: 'the banner keeps its "Then" line');
      expect(find.byKey(const ValueKey('guidance-dock')), findsOneWidget);
      expect(find.byKey(const ValueKey('elevation-handle')), findsOneWidget);
      expect(find.byType(MapLibreMap), findsOneWidget);
      expect(tester.getSize(find.byType(MapLibreMap)), const Size(390, 844));
      expect(drive.signal.value, isFalse);
      expect(changes, isEmpty);
      await finish(tester);
    });

    testWidgets('with no car link at all (a platform without a car screen) it is the same screen', (tester) async {
      await pumpMaps(tester, withDrive: false);
      expect(driveScreen(), findsNothing);
      expect(find.byKey(const ValueKey('guidance-dock')), findsOneWidget);
      expect(find.byType(MapLibreMap), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a car connecting while guiding shows the drive screen; the signal is true once it is built, and false when the car leaves', (tester) async {
      await pumpMaps(tester);
      drive.carConnected.value = true;
      await tester.pump(); // builds the drive screen
      expect(driveScreen(), findsOneWidget);
      expect(find.byKey(const ValueKey('guidance-dock')), findsNothing);
      expect(find.byType(MapLibreMap), findsNothing, reason: 'the map is not drawn');
      expect(find.byType(MapLibreMap, skipOffstage: false), findsOneWidget, reason: 'but it is kept, so it is there at once when the car goes');
      expect(drive.signal.value, isTrue);
      expect(changes, [true]);

      drive.carConnected.value = false;
      // False at once, before any frame is drawn.
      expect(drive.signal.value, isFalse);
      await tester.pump();
      expect(driveScreen(), findsNothing);
      expect(find.byKey(const ValueKey('guidance-dock')), findsOneWidget);
      expect(find.byType(MapLibreMap), findsOneWidget);
      expect(changes, [true, false]);

      // The car comes back mid-drive: the drive screen returns.
      drive.carConnected.value = true;
      await tester.pump();
      expect(driveScreen(), findsOneWidget);
      expect(drive.signal.value, isTrue);
      await finish(tester);
    });

    testWidgets('the signal follows the Maps tab: false on another tab at once, true again on coming back', (tester) async {
      await pumpMaps(tester);
      drive.carConnected.value = true;
      await tester.pump();
      expect(drive.signal.value, isTrue);
      active.value = false; // another tab
      await tester.pump();
      expect(drive.signal.value, isFalse);
      expect(driveScreen(), findsOneWidget, reason: 'the tab is kept; coming back to Maps shows the drive screen again');
      active.value = true;
      await tester.pump();
      expect(drive.signal.value, isTrue);
      expect(changes, [true, false, true]);
      await finish(tester);
    });

    testWidgets('the signal follows the app: false while the phone is locked or Cache is not in front, true when it is back', (tester) async {
      await pumpMaps(tester);
      drive.carConnected.value = true;
      await tester.pump();
      expect(drive.signal.value, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(drive.signal.value, isFalse, reason: 'at once, with no frame');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(drive.signal.value, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(drive.signal.value, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(drive.signal.value, isTrue);
      expect(changes, [true, false, true, false, true]);
      await finish(tester);
    });

    testWidgets('guidance ending (End on the phone or the car) puts today\'s map back and the signal false', (tester) async {
      await pumpMaps(tester);
      drive.carConnected.value = true;
      await tester.pump();
      expect(drive.signal.value, isTrue);
      await tester.runAsync(() => nav.end());
      expect(drive.signal.value, isFalse);
      await tester.pump();
      expect(driveScreen(), findsNothing);
      expect(find.byType(MapLibreMap), findsOneWidget);
      expect(find.byKey(const ValueKey('guidance-dock')), findsNothing, reason: 'no guidance, no dock: the plain map');
      expect(changes, [true, false]);
      await finish(tester);
    });

    testWidgets('whatever the car carries (each word, or none), the screen shows the list, the mini map and the elevation', (tester) async {
      await pumpMaps(tester);
      drive.carConnected.value = true;
      await tester.pump();
      for (final word in [null, CarExtras.never, CarExtras.unlessPhoneShows, CarExtras.always]) {
        if (word != null) drive.extras.value = word;
        await tester.pump();
        expect(driveScreen(), findsOneWidget, reason: '$word');
        expect(find.byType(DriveTurns), findsOneWidget, reason: '$word');
        expect(find.byKey(const ValueKey('drive-mini-map')), findsOneWidget, reason: '$word');
        expect(find.byKey(const ValueKey('drive-elevation')), findsOneWidget, reason: '$word');
        expect(drive.signal.value, isTrue, reason: 'phoneDrive keeps its meaning');
      }
      await finish(tester);
    });

    testWidgets('a car connected while nothing is guided changes nothing', (tester) async {
      await pumpMaps(tester);
      await tester.runAsync(() => nav.end());
      await tester.pump();
      drive.carConnected.value = true;
      await tester.pump();
      expect(driveScreen(), findsNothing);
      expect(drive.signal.value, isFalse);
      expect(changes, isEmpty);
      await finish(tester);
    });
  });

  group('the drive screen', () {
    late DriveRig rig;
    setUp(() async {
      rig = DriveRig();
      await rig.setUp();
    });
    tearDown(() => rig.tearDown());

    Future<void> show(WidgetTester tester, {CacheThemeId theme = CacheThemeId.dark, double? aspect}) async {
      tester.view.physicalSize = const Size(390, 844) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await rig.guide(aspect: aspect);
        rig.elevation.request(rig.nav.route);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      rig.at(1, 400, lanes: [laneJson({D.left}, active: D.left), laneJson({D.through}), laneJson({D.through})]);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(theme),
        home: Scaffold(
          body: DriveScreen(nav: rig.nav, elevation: rig.elevation, palette: mapPaletteFor(theme), themeId: theme),
        ),
      ));
      await tester.pump();
    }

    // The rows of the list as the screen builds them (the list draws only the rows near its window).
    List<int> rowIndexes(WidgetTester tester) => [for (final r in DriveTurns.rowsAfterNext(rig.nav)) r.maneuver.index];

    testWidgets('the next turn is first, with its lane arrows, then the turns after it with the stop in its place', (tester) async {
      await show(tester);
      expect(find.byKey(const ValueKey('guidance-banner')), findsOneWidget);
      expect(find.byKey(const ValueKey('banner-then')), findsNothing, reason: 'the turn after is the first row of the list');
      expect(find.byKey(const ValueKey('lane-strip')), findsOneWidget);
      expect(find.textContaining('Alder Street'), findsOneWidget, reason: 'the next turn, in the banner');
      expect(rowIndexes(tester), [2, 3, 4, 5, 6, 7, 8, 9]);
      expect(find.byKey(const ValueKey('drive-turns-fade')), findsOneWidget, reason: 'the list is longer than its room: it fades at its lower edge');
      expect(find.text('Turn right onto Birch Hollow Road'), findsOneWidget);
      expect(find.text('Stop 1: Corner Market'), findsOneWidget);
      expect(find.text('Merge onto Route 9'), findsOneWidget);
      // The stop sits between the turn before it and the turn after it.
      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(y('Turn right onto Birch Hollow Road') < y('Stop 1: Corner Market'), isTrue);
      expect(y('Stop 1: Corner Market') < y('Merge onto Route 9'), isTrue);
      // The bottom bar is the phone's own.
      expect(find.byKey(const ValueKey('guidance-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('guidance-voice')), findsOneWidget);
      expect(find.byKey(const ValueKey('guidance-end')), findsOneWidget);
      expect(find.byKey(const ValueKey('elevation-handle')), findsNothing, reason: 'no new control; the elevation is on the screen');
    });

    testWidgets('no lane strip when the next turn has no lanes', (tester) async {
      await show(tester);
      rig.at(1, 400);
      await tester.pump();
      expect(find.byKey(const ValueKey('lane-strip')), findsNothing);
    });

    testWidgets('a turn passed: the list moves on, the passed turn is gone', (tester) async {
      await show(tester);
      expect(rowIndexes(tester), [2, 3, 4, 5, 6, 7, 8, 9]);
      rig.at(2, 900);
      await tester.pump();
      expect(find.textContaining('Birch Hollow Road'), findsOneWidget, reason: 'now the banner\'s turn');
      expect(find.text('Turn right onto Birch Hollow Road'), findsNothing, reason: 'not repeated as a row');
      expect(rowIndexes(tester), [3, 4, 5, 6, 7, 8, 9]);
      expect(find.text('Turn left onto Alder Street'), findsNothing);
    });

    testWidgets('a stop reached: it leaves the list, the next turn after it is first', (tester) async {
      await show(tester);
      rig.at(3, 150);
      await tester.pump();
      expect(rowIndexes(tester), [4, 5, 6, 7, 8, 9]);
      rig.at(4, 1200, stopsReached: 1);
      await tester.pump();
      expect(find.text('Stop 1: Corner Market'), findsNothing);
      expect(rowIndexes(tester), [5, 6, 7, 8, 9]);
      expect(find.textContaining('Route 9'), findsOneWidget);
    });

    testWidgets('rerouting: the banner says so and the old list stays, dimmed', (tester) async {
      await show(tester);
      rig.nav.rerouting = true;
      rig.nav.poke();
      await tester.pump();
      expect(find.textContaining('Rerouting'), findsOneWidget);
      expect(rowIndexes(tester), [2, 3, 4, 5, 6, 7, 8, 9]);
      expect(tester.widget<Opacity>(find.ancestor(of: find.byKey(const ValueKey('drive-turns')), matching: find.byType(Opacity)).first).opacity, lessThan(1));
      // The new route lands: the list is the new route's.
      rig.nav.rerouting = false;
      rig.route = driveRouteJson(withStop: false, id: 'drive2');
      rig.nav.routes = [MapRoute.fromJson(rig.route)];
      rig.at(1, 300);
      await tester.pump();
      expect(rowIndexes(tester), [2, 3, 4, 5, 6, 7, 8]);
      expect(find.textContaining('Stop 1'), findsNothing);
    });

    testWidgets('arrival: "You have arrived", no rows, the bar says so with Done', (tester) async {
      await show(tester);
      rig.nav.arrived = true;
      rig.nav.poke();
      await tester.pump();
      expect(find.text('You have arrived'), findsWidgets);
      expect(rowIndexes(tester), isEmpty);
      expect(find.byKey(const ValueKey('guidance-done')), findsOneWidget);
    });

    test('the mini map\'s grade pill follows the car\'s rule: left out where it would lie under the destination dot', () {
      const end = Offset(300, 40);
      expect(RouteMiniMapPainter.pillFits(const Offset(150, 100), end, 1), isTrue);
      expect(RouteMiniMapPainter.pillFits(end, end, 1), isFalse, reason: 'a climb at the destination end');
      expect(RouteMiniMapPainter.pillFits(const Offset(310, 45), end, 1), isFalse);
      expect(RouteMiniMapPainter.pillFits(const Offset(300 - 22, 40), end, 1), isTrue, reason: 'the edge: 14 + 6 + 2 apart');
      expect(RouteMiniMapPainter.pillFits(const Offset(300 - 21, 40), end, 1), isFalse);
      expect(RouteMiniMapPainter.pillFits(const Offset(300, 40 + 18), end, 1), isTrue);
    });

    test('a route too short to chart is not charted', () {
      expect(driveTinyProfile().chartable, isFalse);
      expect(driveProfile().chartable, isTrue);
      expect(ElevationProfile.none(24600).chartable, isFalse);
      expect(ElevationProfile.fromSamples([for (var x = 0.0; x <= 160; x += 40) x], [for (var x = 0.0; x <= 160; x += 40) 1000 + x], totalM: 160).chartable, isFalse);
    });

    testWidgets('on a route a few feet long the elevation box shows the panel\'s own no-data line, never a length or an axis', (tester) async {
      await tester.runAsync(() async {
        rig.profile = driveTinyProfile;
        await rig.guide();
        rig.elevation.request(rig.nav.route);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      rig.at(1, 400);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.dark),
        home: Scaffold(body: SizedBox(width: 300, height: 220, child: DriveElevation(nav: rig.nav, elevation: rig.elevation, palette: mapPaletteFor(CacheThemeId.dark)))),
      ));
      await tester.pump();
      expect(find.text('No elevation data for this route.'), findsOneWidget);
      expect(find.textContaining('Whole route'), findsNothing);
      expect(find.byKey(const ValueKey('elevation-chart')), findsNothing);
    });

    group('the two boxes follow the route\'s shape', () {
      Rect box(WidgetTester t, String key) => t.getRect(find.byKey(ValueKey(key)));
      bool stackedNow(WidgetTester t) {
        final m = box(t, 'drive-mini-map'), e = box(t, 'drive-elevation');
        return m.bottom <= e.top && (m.left - e.left).abs() < 1 && (m.width - e.width).abs() < 1;
      }

      bool sideBySideNow(WidgetTester t) {
        final m = box(t, 'drive-mini-map'), e = box(t, 'drive-elevation');
        return m.right < e.left && (m.top - e.top).abs() < 1;
      }

      test('the shape of a route is its width over its height as the mini map draws it', () {
        GeoPoint g(double lat, double lon) => GeoPoint(lat, lon);
        expect(routeAspect([g(42.5, -113.8), g(42.5, -113.5)]), greaterThan(100), reason: 'flat east-west');
        expect(routeAspect([g(42.5, -113.8), g(42.8, -113.8)]), 0, reason: 'straight north-south');
        final square = routeAspect([g(42.5, -113.8), g(42.6, -113.8 + 0.1 / 0.7373)]);
        expect(square, closeTo(1, 0.02), reason: 'the longitude is scaled by the cosine of the latitude, so a degree east is shorter');
        expect(routeAspect([g(42.5, -113.8)]), 1);
      });

      test('the line, its margin and the name of each', () {
        expect(kDriveStackAspect, 1.5);
        expect(kDriveStackMargin, 1.25);
        // The first route is decided by the line alone: wide stacks, tall and neither do not.
        expect(driveStacked(3.0), isTrue, reason: 'wide');
        expect(driveStacked(0.4), isFalse, reason: 'tall');
        expect(driveStacked(1.0), isFalse, reason: 'neither');
        expect(driveStacked(1.49), isFalse);
        expect(driveStacked(1.5), isTrue);
        // After that the margin: stacked goes back only below 1.2, side by side stacks only from 1.875.
        expect(driveStacked(1.3, previous: true), isTrue);
        expect(driveStacked(1.21, previous: true), isTrue);
        expect(driveStacked(1.19, previous: true), isFalse);
        expect(driveStacked(1.7, previous: false), isFalse);
        expect(driveStacked(1.87, previous: false), isFalse);
        expect(driveStacked(1.88, previous: false), isTrue);
        // A route that wanders around the line never flips back and forth.
        var state = driveStacked(1.55);
        for (final a in [1.45, 1.55, 1.4, 1.6, 1.3, 1.7]) {
          expect(driveStacked(a, previous: state), state, reason: 'aspect $a');
          state = driveStacked(a, previous: state);
        }
      });

      testWidgets('a wide route: the mini map across the full width, the elevation under it, both full width, at the planned heights', (tester) async {
        await show(tester, aspect: 3.0);
        expect(stackedNow(tester), isTrue);
        expect(box(tester, 'drive-mini-map').width, closeTo(366, 1));
        expect(box(tester, 'drive-elevation').width, closeTo(366, 1));
        expect(find.byKey(const ValueKey('elevation-chart')), findsOneWidget);
        expect(find.byKey(const ValueKey('elevation-steep')), findsOneWidget);
        final turns = tester.getSize(find.byType(DriveTurns)).height, extras = tester.getSize(find.byType(DriveExtras)).height;
        final plan = driveStackedPlan(room: turns + extras, width: 366, aspect: routeAspect(rig.nav.route!.points))!;
        expect(turns, closeTo(plan.turnsH, 0.5));
        expect(box(tester, 'drive-mini-map').height, closeTo(plan.miniH, 0.5));
        expect(box(tester, 'drive-elevation').height, closeTo(plan.elevH, 0.5));
        expect(box(tester, 'drive-elevation').height, greaterThanOrEqualTo(kDriveElevationMinHeight));
        expect(box(tester, 'drive-mini-map').height, greaterThanOrEqualTo(kDriveMiniMinHeight));
      });

      test('the stacked plan: the mini map follows the route\'s shape between its least and most, the elevation gets the rest of the half up to its most, then the list', () {
        const room = 770.0, width = 366.0;
        StackedPlan plan(double aspect, {double w = width, double r = room, double f = 1}) => driveStackedPlan(room: r, width: w, aspect: aspect, textScale: f)!;
        final p3 = plan(3), p2 = plan(2), p16 = plan(1.6), p8 = plan(8), p15 = plan(1.5);
        // The box height follows the shape: a very wide route a shorter box, a moderately wide one a taller box.
        expect(p3.miniH, closeTo(miniFitHeight(width, 3), 0.01));
        expect(p2.miniH, closeTo(miniFitHeight(width, 2), 0.01));
        expect(p3.miniH, lessThan(p2.miniH));
        expect(p2.miniH, lessThan(p16.miniH));
        // The route fills the box with only the mini map's own padding (the route's height is the box's less twice the padding).
        for (final (a, p) in [(3.0, p3), (2.0, p2)]) {
          final sc = (p.miniH / RouteMiniMapPainter.fullHeight).clamp(0.5, 1.4);
          final pad = 24 * sc;
          expect((width - 2 * pad) / a + 2 * pad, closeTo(p.miniH, 1), reason: 'aspect $a');
        }
        // The least and the most.
        expect(p8.miniH, kDriveMiniMinHeight);
        expect(p15.miniH, kDriveMiniMaxHeight);
        expect(plan(1.6).miniH, kDriveMiniMaxHeight);
        // What the mini map does not use goes to the elevation first, up to its most, then to the list.
        expect(p3.elevH, kDriveElevationMaxHeight);
        expect(p3.turnsH, greaterThan(room / 2));
        expect(p2.elevH, inInclusiveRange(kDriveElevationMinHeight, kDriveElevationMaxHeight));
        expect(p2.turnsH, closeTo(room / 2, 0.5));
        expect(p16.elevH, greaterThanOrEqualTo(kDriveElevationMinHeight));
        expect(p16.turnsH, closeTo(room / 2, 0.5));
        for (final p in [p3, p2, p16, p8, p15]) {
          expect(p.turnsH + p.miniH + p.elevH + 16, closeTo(room, 0.01));
        }
        // 320 wide (a 296 wide box, its climb line wraps): the elevation needs 18 more, the mini map gives way to it.
        final n = plan(3, w: 296, r: 520);
        expect(n.elevH, kDriveElevationMinHeight + 18);
        expect(n.miniH, greaterThanOrEqualTo(kDriveMiniMinHeight));
        expect(n.turnsH + n.miniH + n.elevH + 16, closeTo(520, 0.01));
        // No room for both: side by side.
        expect(driveStackedPlan(room: 400, width: 296, aspect: 3), isNull, reason: 'a short 320 wide phone');
        expect(driveStackedPlan(room: 500, width: 366, aspect: 3, textScale: 2), isNull, reason: 'large text');
        expect(driveStackedPlan(room: 770, width: 366, aspect: 3, textScale: 2), isNotNull, reason: 'large text on a tall phone still stacks');
      });

      for (final width in [390.0, 320.0]) {
        testWidgets('the half form scrolls by finger through every turn to the destination and back, at $width wide', (tester) async {
          await show(tester, aspect: 3.0);
          tester.view.physicalSize = Size(width, 844) * 3;
          await tester.pumpWidget(MaterialApp(
            theme: buildTheme(CacheThemeId.dark),
            home: MediaQuery(
              data: MediaQueryData(size: Size(width, 844)),
              child: Scaffold(body: DriveScreen(nav: rig.nav, elevation: rig.elevation, palette: mapPaletteFor(CacheThemeId.dark), themeId: CacheThemeId.dark)),
            ),
          ));
          await tester.pump();
          expect(stackedNow(tester), isTrue);
          final list = find.byKey(const ValueKey('drive-turns'));
          final fade = find.byKey(const ValueKey('drive-turns-fade'));
          expect(find.byKey(const ValueKey('drive-row-9')), findsNothing, reason: 'the destination is below the window');
          expect(fade, findsOneWidget, reason: 'more rows lie below');
          // To the end.
          for (var i = 0; i < 6; i++) {
            await tester.drag(list, const Offset(0, -400));
            await tester.pumpAndSettle();
          }
          expect(find.byKey(const ValueKey('drive-row-9')), findsOneWidget, reason: 'the destination row');
          expect(find.text('You have arrived at your destination'), findsOneWidget);
          expect(fade, findsNothing, reason: 'nothing below: no fade');
          // It stays where it was left (no return by itself).
          await tester.pump(const Duration(seconds: 30));
          expect(find.byKey(const ValueKey('drive-row-9')), findsOneWidget);
          // And back to the first row after the next turn.
          for (var i = 0; i < 6; i++) {
            await tester.drag(list, const Offset(0, 400));
            await tester.pumpAndSettle();
          }
          expect(find.byKey(const ValueKey('drive-row-2')), findsOneWidget);
          expect(fade, findsOneWidget, reason: 'more rows lie below again');
        });
      }

      testWidgets('a tall route: side by side', (tester) async {
        await show(tester, aspect: 0.4);
        expect(sideBySideNow(tester), isTrue);
      });

      testWidgets('a route that is neither: side by side', (tester) async {
        await show(tester, aspect: 1.0);
        expect(sideBySideNow(tester), isTrue);
      });

      testWidgets('the arrangement does not change during a drive (progress updates, turns)', (tester) async {
        await show(tester, aspect: 3.0);
        for (final (next, m) in [(1, 300.0), (2, 900.0), (3, 150.0), (5, 700.0)]) {
          rig.at(next, m);
          await tester.pump();
          expect(stackedNow(tester), isTrue, reason: 'next $next');
        }
      });

      Future<void> reroute(WidgetTester tester, double aspect) async {
        rig.route = driveRouteJson(withStop: false, id: 'r${aspect.toString()}', aspect: aspect);
        rig.nav.routes = [MapRoute.fromJson(rig.route)];
        rig.at(1, 300);
        await tester.pump();
      }

      testWidgets('a re-route to a clearly different shape changes it; one near the line does not', (tester) async {
        await show(tester, aspect: 3.0);
        expect(stackedNow(tester), isTrue);
        await reroute(tester, 1.5); // about 1.4 as drawn: inside the margin
        expect(stackedNow(tester), isTrue, reason: 'near the line: kept');
        await reroute(tester, 1.0); // clearly neither
        expect(sideBySideNow(tester), isTrue, reason: 'clearly the other kind: changed');
        await reroute(tester, 1.9); // about 1.8: inside the margin on the other side
        expect(sideBySideNow(tester), isTrue, reason: 'near the line: kept');
        await reroute(tester, 3.5);
        expect(stackedNow(tester), isTrue, reason: 'clearly wide: changed');
      });

      for (final (w, scale) in [(390.0, 1.0), (320.0, 1.0), (390.0, 2.0), (320.0, 2.0)]) {
        testWidgets('at $w wide, text x$scale: lays out without overflow and keeps the chart and the climb line', (tester) async {
          await show(tester, aspect: 3.0);
          tester.view.physicalSize = Size(w, 844) * 3;
          await tester.pumpWidget(MaterialApp(
            theme: buildTheme(CacheThemeId.dark),
            home: MediaQuery(
              data: MediaQueryData(size: Size(w, 844), textScaler: TextScaler.linear(scale)),
              child: Scaffold(body: DriveScreen(nav: rig.nav, elevation: rig.elevation, palette: mapPaletteFor(CacheThemeId.dark), themeId: CacheThemeId.dark)),
            ),
          ));
          await tester.pump();
          expect(tester.takeException(), isNull);
          // Stacked where there is room for both boxes at their least heights, else side by side.
          expect(stackedNow(tester) || sideBySideNow(tester), isTrue);
          expect(find.byKey(const ValueKey('elevation-chart')), findsOneWidget);
          expect(find.byKey(const ValueKey('elevation-steep')), findsOneWidget);
          expect(find.byKey(const ValueKey('guidance-end')), findsOneWidget);
        });
      }
    });

    testWidgets('the mini map and the elevation are on the screen with the list of turns', (tester) async {
      await show(tester);
      expect(find.byType(DriveTurns), findsOneWidget);
      expect(find.byKey(const ValueKey('drive-mini-map')), findsOneWidget);
      expect(find.byKey(const ValueKey('drive-elevation')), findsOneWidget);
      expect(find.text('Elevation'), findsOneWidget);
      expect(find.text('Steepest climb ahead'), findsOneWidget);
    });

    testWidgets('the split is one constant: the list takes two thirds of the room, the extras the rest, side by side', (tester) async {
      await show(tester, aspect: 1.0);
      final turns = tester.getSize(find.byType(DriveTurns)).height;
      final extras = tester.getSize(find.byType(DriveExtras)).height;
      expect(turns / (turns + extras), closeTo(kDriveTurnsShare, 0.005));
      expect(find.byKey(const ValueKey('guidance-bar')), findsOneWidget);
      final mini = tester.getRect(find.byKey(const ValueKey('drive-mini-map')));
      final elev = tester.getRect(find.byKey(const ValueKey('drive-elevation')));
      expect(mini.right, lessThan(elev.left));
      expect(mini.top, closeTo(elev.top, 0.5));
    });

    testWidgets('a 320 point wide phone and the largest text size lay out without overflow', (tester) async {
      await show(tester);
      for (final (w, scale) in [(320.0, 1.0), (390.0, 2.0), (320.0, 2.0)]) {
        tester.view.physicalSize = Size(w, 700) * 3;
        await tester.pumpWidget(MaterialApp(
          theme: buildTheme(CacheThemeId.dark),
          home: MediaQuery(
            data: MediaQueryData(size: Size(w, 700), textScaler: TextScaler.linear(scale)),
            child: Scaffold(body: DriveScreen(nav: rig.nav, elevation: rig.elevation, palette: mapPaletteFor(CacheThemeId.dark), themeId: CacheThemeId.dark)),
          ),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'width $w, text x$scale');
        expect(find.byKey(const ValueKey('guidance-end')), findsOneWidget);
      }
    });

    test('the split is two thirds', () => expect(kDriveTurnsShare, 2 / 3));
  });
}
