// The phone's drive screen: what the Maps tab shows while a car screen is connected and guiding (nav/ui/drive_screen.dart), and the
// signal "the phone's drive screen is showing" the car is told (car/phone_drive.dart).

import 'dart:io';

import 'package:cache/car/phone_drive.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/palette/map_palette.dart';
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

    Future<void> show(WidgetTester tester, {CarExtras extras = CarExtras.never, CacheThemeId theme = CacheThemeId.dark}) async {
      tester.view.physicalSize = const Size(390, 844) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await rig.guide();
        rig.elevation.request(rig.nav.route);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      rig.at(1, 400, lanes: [laneJson({D.left}, active: D.left), laneJson({D.through}), laneJson({D.through})]);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(theme),
        home: Scaffold(
          body: DriveScreen(nav: rig.nav, elevation: rig.elevation, palette: mapPaletteFor(theme), themeId: theme, extras: extras),
        ),
      ));
      await tester.pump();
    }

    List<int> rowIndexes(WidgetTester tester) => [
          for (final e in find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('drive-row-')).evaluate()) int.parse(((e.widget.key as ValueKey<String>).value).substring('drive-row-'.length)),
        ];

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
      expect(find.text('You have arrived at your destination'), findsOneWidget);
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

    testWidgets('where the extras are, case 1: a small car screen never carries them, so the phone draws the mini map and the elevation', (tester) async {
      await show(tester, extras: CarExtras.never);
      expect(find.byKey(const ValueKey('drive-mini-map')), findsOneWidget);
      expect(find.byKey(const ValueKey('drive-elevation')), findsOneWidget);
      expect(find.text('Elevation'), findsOneWidget);
      expect(find.text('Steepest climb ahead'), findsOneWidget);
    });

    testWidgets('where the extras are, case 2: an in-between car screen carries them unless this screen shows; it shows, so the phone draws them', (tester) async {
      await show(tester, extras: CarExtras.unlessPhoneShows);
      expect(find.byKey(const ValueKey('drive-mini-map')), findsOneWidget);
      expect(find.byKey(const ValueKey('drive-elevation')), findsOneWidget);
    });

    testWidgets('where the extras are, case 3: a big car screen always carries them; the list has the whole room', (tester) async {
      await show(tester, extras: CarExtras.always);
      expect(find.byKey(const ValueKey('drive-mini-map')), findsNothing);
      expect(find.byKey(const ValueKey('drive-elevation')), findsNothing);
      expect(find.byType(DriveExtras), findsNothing);
      final turns = tester.getSize(find.byType(DriveTurns)).height;
      expect(turns, greaterThan(500), reason: 'the whole room between the top and the bar');
      expect(find.byKey(const ValueKey('drive-turns-fade')), findsNothing, reason: 'the whole list fits: no fade');
      expect(find.byKey(const ValueKey('guidance-bar')), findsOneWidget);
    });

    testWidgets('the split is one constant: the list takes two thirds of the room, the extras the rest, side by side', (tester) async {
      await show(tester);
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
