import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/travel_prefs.dart';
import 'package:cache/nav/ui/atv_icon.dart';
import 'package:cache/nav/ui/route_panel.dart';
import 'package:cache/nav/ui/travel_rows.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';

class _NoSource implements PositionSource {
  @override
  Future<LocationPermissionState> permission() async => LocationPermissionState.granted;
  @override
  Future<LocationPermissionState> requestPermission() async => LocationPermissionState.granted;
  @override
  Future<bool> serviceEnabled() async => true;
  @override
  Future<Fix> current() async => fixAt(42.5, -113.8);
  @override
  Stream<Fix> stream() => const Stream.empty();
  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}

class _Nav extends NavState {
  _Nav(FakeBackend b, LocationService l, {super.prefs})
      : super(
          backend: b,
          location: l,
          speaker: FakeSpeaker(),
          positionSource: FakeNavPosition(),
          fmt: const Fmt(UnitSystem.imperial),
          searchDebounce: const Duration(milliseconds: 1),
          meaningDebounce: const Duration(milliseconds: 2),
        );
}

const hospital = MapPlace(
  id: 'place:osm:n4',
  type: 'place',
  name: 'Cassia Regional Hospital',
  kind: 'Hospital',
  category: 'hospital',
  address: '1501 Hiland Ave, Burley, ID',
  lat: 42.5,
  lon: -113.5,
  matched: 'name',
);

const clinic = MapPlace(
  id: 'place:osm:n5',
  type: 'place',
  name: 'Minidoka Clinic',
  kind: 'Clinic',
  category: 'clinic',
  address: '1 Main St, Rupert, ID',
  lat: 42.6,
  lon: -113.7,
  matched: 'name',
);

Widget _panel(NavState nav, {double scale = 1.0}) => MaterialApp(
      theme: buildTheme(CacheThemeId.light),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: ListenableBuilder(listenable: nav, builder: (_, _) => RoutePanel(nav: nav, fmt: const Fmt(UnitSystem.imperial))),
                ),
              ),
            ),
          ),
        ),
      ),
    );

Future<void> settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late LocationService location;
  late FakeBackend backend;
  late _Nav nav;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('travel');
    location = LocationService(source: _NoSource(), settingsDirOverride: dir);
    await location.init();
    location.publish(fixAt(42.5, -113.8));
    backend = FakeBackend()..onRoute = (to, mode, from) async => MapRoute.fromJson(fakeRouteJson(mode: mode, offroad: mode.startsWith('offroad')));
    nav = _Nav(backend, location);
    await nav.openDirections(hospital);
  });

  tearDown(() {
    nav.dispose();
    location.dispose();
    dir.deleteSync(recursive: true);
  });

  bool has(String key) => find.byKey(ValueKey(key)).evaluate().isNotEmpty;

  testWidgets('Drive: Avoid highways and Avoid tolls are toggles, and no land row', (tester) async {
    await tester.pumpWidget(_panel(nav));
    for (final t in ['Drive', 'Walk', 'Bike', 'ATV', 'Avoid highways', 'Avoid tolls']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(has('travel-row-3'), isFalse);
    // both boxes empty
    expect(find.byIcon(Icons.check_box_outline_blank), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('opt-avoid-highways')));
    await settle(tester);
    expect(nav.avoidHighways, isTrue);
    expect(nav.avoidTolls, isFalse);
    expect(find.byIcon(Icons.check_box), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('opt-avoid-tolls')));
    await settle(tester);
    expect((nav.avoidHighways, nav.avoidTolls), (true, true));
    expect(find.byIcon(Icons.check_box), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('opt-avoid-highways')));
    await settle(tester);
    expect((nav.avoidHighways, nav.avoidTolls), (false, true));
    // every change routes again, with what is avoided
    expect(backend.avoids, [(false, false), (true, false), (true, true), (false, true)]);
    expect(backend.calls.every((c) => c.startsWith('route:drive:')), isTrue);
  });

  testWidgets('Walk: Pedestrian | Off-road, and the land row only for Off-road', (tester) async {
    await tester.pumpWidget(_panel(nav));
    await tester.tap(find.byKey(const ValueKey('mode-walk')));
    await settle(tester);
    expect(nav.mode, 'walk');
    expect(find.text('Pedestrian'), findsOneWidget);
    expect(find.text('Off-road'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget, reason: 'the chosen one carries a check mark');
    expect(has('travel-row-3'), isFalse);
    expect(find.text('Avoid highways'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('opt-offroad_foot')));
    await settle(tester);
    expect(nav.mode, 'offroad_foot');
    expect(find.text('Standard'), findsOneWidget);
    expect(find.text('Emergency'), findsOneWidget);
    expect(backend.calls.last, 'route:offroad_foot:Cassia Regional Hospital:from');
    expect(backend.landAccesses.last, 'pragmatic');
    // Standard is chosen, with its check mark
    expect(find.byIcon(Icons.check), findsNWidgets(2));
    // leaving the road for the road again takes the land row away
    await tester.tap(find.byKey(const ValueKey('opt-walk')));
    await settle(tester);
    expect(has('travel-row-3'), isFalse);
    expect(backend.landAccesses.last, isNull);
  });

  testWidgets('Bike: Bicycle | Dirt bike, the land row only for Dirt bike', (tester) async {
    await tester.pumpWidget(_panel(nav));
    await tester.tap(find.byKey(const ValueKey('mode-bike')));
    await settle(tester);
    expect(nav.mode, 'bike');
    expect(find.text('Bicycle'), findsOneWidget);
    expect(find.text('Dirt bike'), findsOneWidget);
    expect(has('travel-row-3'), isFalse);
    await tester.tap(find.byKey(const ValueKey('opt-offroad_moto')));
    await settle(tester);
    expect(nav.mode, 'offroad_moto');
    expect(has('travel-row-3'), isTrue);
    expect(backend.calls.last, 'route:offroad_moto:Cassia Regional Hospital:from');
  });

  testWidgets('ATV: Quad | Side-by-side, always with the land row', (tester) async {
    await tester.pumpWidget(_panel(nav));
    await tester.tap(find.byKey(const ValueKey('mode-atv')));
    await settle(tester);
    expect(nav.mode, 'offroad_4w');
    expect(find.text('Quad'), findsOneWidget);
    expect(find.text('Side-by-side'), findsOneWidget);
    expect(has('travel-row-3'), isTrue);
    expect(backend.calls.last, 'route:offroad_4w:Cassia Regional Hospital:from');
    await tester.tap(find.byKey(const ValueKey('opt-offroad_sxs')));
    await settle(tester);
    expect(backend.calls.last, 'route:offroad_sxs:Cassia Regional Hospital:from');
    expect(find.byType(AtvIcon), findsOneWidget);
  });

  testWidgets('Emergency shows its one-line explanation and sends emergency; Standard sends pragmatic', (tester) async {
    await nav.setMode('offroad_4w');
    await tester.pumpWidget(_panel(nav));
    expect(find.text(TravelChoicesView.emergencyWarning), findsNothing);
    await tester.tap(find.byKey(const ValueKey('land-emergency')));
    await settle(tester);
    expect(nav.landAccess, 'emergency');
    expect(backend.landAccesses.last, 'emergency');
    expect(find.text('Emergency routing ignores land-access rules. The route may cross private or closed land.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('land-pragmatic')));
    await settle(tester);
    expect(backend.landAccesses.last, 'pragmatic');
    expect(find.text(TravelChoicesView.emergencyWarning), findsNothing);
  });

  testWidgets('each way of travel comes back to the option it was last set to', (tester) async {
    await tester.pumpWidget(_panel(nav));
    await tester.tap(find.byKey(const ValueKey('mode-bike')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('opt-offroad_moto')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('mode-drive')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('mode-bike')));
    await settle(tester);
    expect(nav.mode, 'offroad_moto');
  });

  group('the assistant\'s routes', () {
    MapRoute asked(String mode, {String land = 'pragmatic'}) => MapRoute.fromJson({...fakeRouteJson(id: 'ask-$mode-$land', mode: mode, offroad: mode.startsWith('offroad')), 'land_access': land});

    testWidgets('each of the five modes shows as the design says', (tester) async {
      Future<void> shows(String mode, String? travel, String option) async {
        expect(nav.previewSnapshot(asked(mode)), isTrue, reason: mode);
        await tester.pumpWidget(_panel(nav));
        await tester.pump();
        expect(nav.travel, travel, reason: mode);
        expect(nav.mode, mode);
        expect(find.text(option), option.isEmpty ? findsNothing : findsOneWidget, reason: mode);
      }

      await shows('drive', 'drive', 'Avoid highways');
      expect(nav.avoidHighways || nav.avoidTolls, isFalse, reason: 'Drive, no toggles');
      await shows('walk', 'walk', 'Pedestrian');
      await shows('bike', 'bike', 'Bicycle');
      await shows('offroad_foot', 'walk', 'Off-road');
      expect(find.byKey(const ValueKey('land-pragmatic')), findsOneWidget);
    });

    testWidgets('offroad_vehicle: nothing highlighted and one line; any tap routes with that choice', (tester) async {
      expect(nav.previewSnapshot(asked('offroad_vehicle')), isTrue);
      await tester.pumpWidget(_panel(nav));
      await tester.pump();
      expect(find.text("Ask's route: by any vehicle, on foot where none can go."), findsOneWidget);
      expect(nav.travel, isNull);
      // none of the four is highlighted
      for (final id in ['drive', 'walk', 'bike', 'atv']) {
        final seg = tester.widget<InkWell>(find.byKey(ValueKey('mode-$id')));
        expect(seg.onTap, isNotNull);
      }
      expect(find.byIcon(Icons.check_box), findsNothing);
      expect(find.byIcon(Icons.check_box_outline_blank), findsNothing);
      expect(find.text('Pedestrian'), findsNothing);
      expect(find.text('Quad'), findsNothing);
      // the land the assistant chose is Standard, so it is highlighted as Standard
      expect(find.byKey(const ValueKey('land-pragmatic')), findsOneWidget);
      final before = backend.calls.length;
      await tester.tap(find.byKey(const ValueKey('mode-atv')));
      await settle(tester);
      expect(backend.calls.length, before + 1);
      expect(backend.calls.last, startsWith('route:offroad_4w:'));
      expect(find.text("Ask's route: by any vehicle, on foot where none can go."), findsNothing);
    });

    testWidgets('strict: neither Standard nor Emergency highlighted, one line; a tap routes with that choice', (tester) async {
      expect(nav.previewSnapshot(asked('offroad_foot', land: 'strict')), isTrue);
      await tester.pumpWidget(_panel(nav));
      await tester.pump();
      expect(find.text("Ask's route stays on open land."), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget, reason: 'only the Off-road option of Walk is checked, neither Standard nor Emergency');
      final before = backend.calls.length;
      await tester.tap(find.byKey(const ValueKey('land-pragmatic')));
      await settle(tester);
      expect(backend.calls.length, before + 1);
      expect(backend.landAccesses.last, 'pragmatic');
      expect(find.text("Ask's route stays on open land."), findsNothing);
    });
  });

  testWidgets('a note on the route (the data it lacks) shows in the Route details sheet, not in the short panel', (tester) async {
    backend.onRoute = (to, mode, from) async => MapRoute.fromJson({
          ...fakeRouteJson(mode: mode, offroad: true),
          'notes': ['This off-road data has no dirt bike trail rules yet, so ATV trail rules were used.'],
        });
    await nav.setMode('offroad_moto');
    await tester.pumpWidget(_panel(nav));
    await tester.pump();
    const note = 'This off-road data has no dirt bike trail rules yet, so ATV trail rules were used.';
    expect(find.text(note), findsNothing, reason: 'the panel is short: notes are in the sheet');
    await tester.tap(find.byKey(const ValueKey('route-summary')));
    await tester.pumpAndSettle();
    expect(find.text(note), findsOneWidget);
  });

  group('one line, equal segments, one text size per row', () {
    // Every state of the screen: way of travel, option, land, and what is chosen in each.
    final states = <(String, String, bool)>[
      ('drive', 'drive', false),
      ('drive', 'drive', true),
      ('walk', 'walk', false),
      ('walk', 'offroad_foot', false),
      ('bike', 'bike', false),
      ('bike', 'offroad_moto', false),
      ('atv', 'offroad_4w', false),
      ('atv', 'offroad_sxs', true),
    ];
    for (final (w, scale) in [(360.0, 1.0), (360.0, 1.3), (320.0, 1.0), (320.0, 2.0), (360.0, 2.0)]) {
      testWidgets('${w.toInt()} dp wide, text ${scale}x', (tester) async {
        tester.view.physicalSize = Size(w, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        // A plain road route under the choices: this checks the choices, and the route card has its own limits at these sizes.
        backend.onRoute = (to, mode, from) async => MapRoute.fromJson(fakeRouteJson(mode: mode));
        await tester.pumpWidget(_panel(nav, scale: scale));
        for (final (_, mode, emergency) in states) {
          await nav.setMode(mode);
          await nav.setLandAccess(emergency ? 'emergency' : 'pragmatic');
          if (mode == 'drive') await nav.setAvoid(highways: emergency, tolls: emergency);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull, reason: '$mode at $w dp, ${scale}x');
          for (final row in ['travel-row-1', 'travel-row-2', 'travel-row-3']) {
            final rowFinder = find.byKey(ValueKey(row));
            if (rowFinder.evaluate().isEmpty) continue;
            expect(tester.getSize(rowFinder).height, 48, reason: '$row is 48 dp ($mode, $w dp, ${scale}x)');
            final rowRect = tester.getRect(rowFinder);
            final texts = find.descendant(of: rowFinder, matching: find.byType(Text));
            final sizes = <double>{};
            final tops = <double>{};
            for (final e in texts.evaluate()) {
              final t = e.widget as Text;
              sizes.add(t.style!.fontSize!);
              final r = tester.getRect(find.byWidget(t));
              tops.add((r.center.dy * 10).roundToDouble());
              expect(rowRect.contains(r.topLeft) && rowRect.contains(r.bottomRight), isTrue, reason: '${t.data} inside $row ($mode, $w dp, ${scale}x): $r in $rowRect');
              expect(t.maxLines, 1);
              expect(r.height, lessThan(48), reason: '${t.data} is one line');
            }
            expect(sizes.length, 1, reason: '$row shows one text size ($mode, $w dp, ${scale}x): $sizes');
            expect(tops.length, 1, reason: '$row labels are on one line ($mode, $w dp, ${scale}x)');
          }
        }
      });
    }

    testWidgets('segments of a row are the same width', (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      backend.onRoute = (to, mode, from) async => MapRoute.fromJson(fakeRouteJson(mode: mode));
      await nav.setMode('offroad_sxs');
      await tester.pumpWidget(_panel(nav, scale: 2.0));
      await tester.pump();
      final w1 = {for (final id in ['drive', 'walk', 'bike', 'atv']) tester.getSize(find.byKey(ValueKey('mode-$id'))).width};
      expect(w1.length, 1);
      final w2 = {for (final id in ['offroad_4w', 'offroad_sxs']) tester.getSize(find.byKey(ValueKey('opt-$id'))).width};
      expect(w2.length, 1);
      // at this size the text does shrink, down to about half for the widest label
      final fs = tester.widget<Text>(find.text('Side-by-side')).style!.fontSize!;
      expect(fs, lessThan(16));
      expect(fs, greaterThan(4));
    });
  });

  group('remembered across restarts', () {
    late Directory prefsDir;
    setUp(() => prefsDir = Directory.systemTemp.createTempSync('travelprefs'));
    tearDown(() => prefsDir.deleteSync(recursive: true));

    _Nav fresh() => _Nav(backend, location, prefs: TravelPrefs(dirOverride: prefsDir));

    test('the mode and its options come back', () async {
      final a = fresh();
      await a.restored;
      expect(a.mode, 'drive');
      await a.setMode('offroad_sxs');
      await a.setLandAccess('emergency');
      await a.setMode('offroad_moto');
      await a.setAvoid(highways: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      a.dispose();
      final b = fresh();
      await b.restored;
      expect(b.mode, 'offroad_moto');
      expect(b.landAccess, 'pragmatic', reason: 'Emergency is for one trip: a restart is Standard');
      expect(b.avoidHighways, isTrue);
      expect(b.avoidTolls, isFalse);
      // ATV comes back to the side-by-side, Walk to Pedestrian
      expect(b.modeFor('atv'), 'offroad_sxs');
      expect(b.modeFor('walk'), 'walk');
      expect(b.modeFor('bike'), 'offroad_moto');
      b.dispose();
    });

    test('Emergency does not survive a restart, even from a file that says it does', () async {
      final a = fresh();
      await a.restored;
      await a.setMode('offroad_4w');
      await a.setLandAccess('emergency');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(File('${prefsDir.path}/${TravelPrefs.fileName}').readAsStringSync(), contains('"land_access":"pragmatic"'));
      a.dispose();
      File('${prefsDir.path}/${TravelPrefs.fileName}').writeAsStringSync('{"mode": "offroad_4w", "land_access": "emergency"}');
      final b = fresh();
      await b.restored;
      expect((b.mode, b.landAccess), ('offroad_4w', 'pragmatic'));
      b.dispose();
    });

    test('a route the assistant planned is shown but never remembered', () async {
      final a = fresh();
      await a.restored;
      await a.setMode('bike');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(a.previewSnapshot(MapRoute.fromJson({...fakeRouteJson(id: 'x', mode: 'offroad_vehicle', offroad: true), 'land_access': 'strict'})), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      a.dispose();
      final b = fresh();
      await b.restored;
      expect(b.mode, 'bike');
      expect(b.landAccess, 'pragmatic');
      b.dispose();
    });

    test('what the person chooses before the file is read wins over it', () async {
      final a = fresh();
      await a.restored;
      await a.setMode('offroad_4w');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      a.dispose();
      final b = fresh();
      await b.setMode('walk');
      await b.restored;
      expect(b.mode, 'walk');
      b.dispose();
    });

    test('a damaged file leaves Drive', () async {
      File('${prefsDir.path}/${TravelPrefs.fileName}').writeAsStringSync('{"mode": 7,');
      final a = fresh();
      await a.restored;
      expect(a.mode, 'drive');
      File('${prefsDir.path}/${TravelPrefs.fileName}').writeAsStringSync('{"mode": "teleport", "land_access": "strict", "avoid_tolls": true}');
      final b = fresh();
      await b.restored;
      expect((b.mode, b.landAccess, b.avoidTolls), ('drive', 'pragmatic', true));
      a.dispose();
      b.dispose();
    });
  });

  group('Emergency lasts for one trip', () {
    test('a new destination goes back to Standard; the same trip and a change of mode keep Emergency', () async {
      final nav = _Nav(backend, location);
      await nav.openDirections(hospital);
      await nav.setMode('offroad_4w');
      await nav.setLandAccess('emergency');
      expect(nav.landAccess, 'emergency');
      // another way of travel in the same trip keeps it
      await nav.setMode('offroad_moto');
      expect(nav.landAccess, 'emergency');
      // the same destination opened again, while still previewing it: the same trip
      await nav.openDirections(hospital);
      expect(nav.landAccess, 'emergency');
      // a different destination is a new trip
      await nav.openDirections(clinic);
      expect(nav.landAccess, 'pragmatic');
      expect(nav.mode, 'offroad_moto', reason: 'the way of travel is still remembered');
      expect(backend.landAccesses.last, 'pragmatic');
      nav.dispose();
    });

    test('after the trip is closed, asking for directions again starts on Standard', () async {
      final nav = _Nav(backend, location);
      await nav.openDirections(hospital);
      await nav.setMode('offroad_4w');
      await nav.setLandAccess('emergency');
      nav.cancelDirections();
      await nav.openDirections(hospital);
      expect(nav.landAccess, 'pragmatic');
      nav.dispose();
    });
  });
}
