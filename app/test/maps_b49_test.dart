import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/overview/overview_camera.dart';
import 'package:cache/nav/overview/route_overview.dart';
import 'package:cache/nav/ui/place_card.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/screens/maps_screen.dart' show NotebookPinSheet;
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

const _entry = NbEntry(id: 'e1', notebookId: 'nb1', occurredAt: '2026-11-01T10:00:00-07:00', title: 'Hot spring', place: NbPlace(lat: 42.6, lon: -113.4, label: 'Off Hwy 30'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late LocationService location;
  late FakeBackend backend;
  late NavState nav;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('maps-b49');
    location = LocationService(source: _NoSource(), settingsDirOverride: dir);
    await location.init();
    location.publish(fixAt(42.5, -113.8));
    backend = FakeBackend()..onRoute = ((to, mode, from) async => MapRoute.fromJson(fakeRouteJson()));
    nav = NavState(backend: backend, location: location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
  });
  tearDown(() {
    nav.dispose();
    location.dispose();
    dir.deleteSync(recursive: true);
  });

  Widget app(Widget home) => MaterialApp(theme: buildTheme(CacheThemeId.light), home: home);

  group('a notebook pin\'s sheet', () {
    testWidgets('Directions opens the route preview in one tap', (tester) async {
      await tester.pumpWidget(app(Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const ValueKey('open-sheet'),
            onPressed: () => showModalBottomSheet<void>(context: context, builder: (_) => NotebookPinSheet(entry: _entry, book: null, nav: nav)),
            child: const Text('sheet'),
          ),
        ),
      )));
      await tester.tap(find.byKey(const ValueKey('open-sheet')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pin-directions')));
      await tester.pumpAndSettle();
      expect(nav.phase, NavPhase.previewing, reason: 'one tap: not the place card first');
      expect(nav.selected?.id, 'notebook:e1');
      expect(nav.selected?.name, 'Hot spring');
      expect(nav.selected?.lat, 42.6);
    });
  });

  group('the place card', () {
    const notebookPlace = MapPlace(id: 'notebook:e1', type: 'place', name: 'Hot spring', kind: 'Places', address: 'Off Hwy 30', lat: 42.6, lon: -113.4, matched: '');
    const found = MapPlace(id: 'place:osm:n4', type: 'place', name: 'Cassia Regional Hospital', kind: 'Hospital', address: 'Burley', lat: 42.5, lon: -113.5, matched: 'name');

    testWidgets('a place from a notebook is not offered for saving', (tester) async {
      await tester.pumpWidget(app(Scaffold(body: PlaceCard(nav: nav, place: notebookPlace, fmt: const Fmt(UnitSystem.imperial), onClose: () {}))));
      expect(find.byKey(const ValueKey('place-save')), findsNothing);
      expect(find.text('Save place'), findsNothing);
      expect(find.byKey(const ValueKey('place-directions')), findsOneWidget);
    });

    testWidgets('a long summary is cut to three lines with an ellipsis, and every button still fits on a phone', (tester) async {
      tester.view.physicalSize = const Size(412, 915) * 2.625;
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final long = MapPlace(
        id: 'place:osm:w1', type: 'place', name: 'Shoshone Falls', kind: 'Waterfall', address: 'Twin Falls, ID', lat: 42.6, lon: -114.4, matched: 'name',
        phone: '+1 208 555 0142', hours: 'Open daily, 6 AM to 10 PM', website: 'https://www.example.org/shoshone-falls', wikipediaTitle: 'Shoshone Falls',
        summary: List.filled(40, 'Shoshone Falls is a waterfall in the western United States, on the Snake River.').join(' ').substring(0, 367),
      );
      await tester.pumpWidget(app(Scaffold(body: Align(alignment: Alignment.bottomCenter, child: PlaceCard(nav: nav, place: long, fmt: const Fmt(UnitSystem.imperial), onClose: () {})))));
      final t = tester.widget<Text>(find.byKey(const ValueKey('place-card-summary')));
      expect((t.maxLines, t.overflow), (3, TextOverflow.ellipsis));
      final lines = tester.getSize(find.byKey(const ValueKey('place-card-summary'))).height / (14 * 1.35);
      expect(lines, lessThanOrEqualTo(3.05), reason: 'three lines of the summary at most');
      for (final k in ['place-directions', 'place-save', 'place-add-home']) {
        final r = tester.getRect(find.byKey(ValueKey(k)));
        expect(r.bottom, lessThanOrEqualTo(915), reason: '$k is on the screen');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('a short summary and a card without one are as they were; the no-details line is only for a chip with nothing', (tester) async {
      const short = MapPlace(id: 'place:osm:w2', type: 'place', name: 'Sorrel Bakery', kind: 'Bakery', lat: 42.6, lon: -114.4, matched: 'name', summary: 'A bakery.');
      await tester.pumpWidget(app(Scaffold(body: PlaceCard(nav: nav, place: short, fmt: const Fmt(UnitSystem.imperial), onClose: () {}))));
      expect(find.text('A bakery.'), findsOneWidget);
      expect(find.byKey(const ValueKey('place-card-no-details')), findsNothing);
      await tester.pumpWidget(app(Scaffold(body: PlaceCard(nav: nav, place: found, fmt: const Fmt(UnitSystem.imperial), onClose: () {}))));
      expect(find.byKey(const ValueKey('place-card-no-details')), findsNothing);
      const chip = MapPlace(id: 'loc:42.5,-113.5', type: 'place', name: 'Cascade Park', kind: 'Park', lat: 42.5, lon: -113.5, matched: 'poi');
      await tester.pumpWidget(app(Scaffold(body: PlaceCard(nav: nav, place: chip, fmt: const Fmt(UnitSystem.imperial), onClose: () {}))));
      expect(find.text('No other details for this place.'), findsOneWidget);
    });

    for (final id in CacheThemeId.values) {
      testWidgets('the card is fully solid in the ${id.name} theme: nothing of the map shows through it', (tester) async {
        await tester.pumpWidget(MaterialApp(
          theme: buildTheme(id),
          home: Scaffold(body: Stack(children: [
            Container(color: const Color(0xFFFF00FF)),
            Align(alignment: Alignment.bottomCenter, child: PlaceCard(nav: nav, place: found, fmt: const Fmt(UnitSystem.imperial), onClose: () {})),
          ])),
        ));
        final box = tester.widgetList<DecoratedBox>(find.descendant(of: find.byType(PlaceCard), matching: find.byType(DecoratedBox))).map((d) => d.decoration).whereType<BoxDecoration>().firstWhere((d) => d.boxShadow != null);
        expect(box.color!.a, 1.0, reason: 'an alpha under 1 lets the map\'s labels show faintly behind the title');
      });
    }

    testWidgets('a found place still is', (tester) async {
      await tester.pumpWidget(app(Scaffold(body: PlaceCard(nav: nav, place: found, fmt: const Fmt(UnitSystem.imperial), onClose: () {}))));
      expect(find.byKey(const ValueKey('place-save')), findsOneWidget);
    });
  });

  group('the corner picture\'s credit strip', () {
    test('the corner picture is rendered taller than the corner by the strip, and the route is kept clear of it', () {
      expect(insetPictureSize(108), Size(108, 108 + kSnapshotCreditStripPt));
      expect(insetPicturePadding.bottom, 16 + kSnapshotCreditStripPt);
    });

    testWidgets('the crop shows the corner\'s square and cuts the strip below it', (tester) async {
      final key = GlobalKey();
      final inner = GlobalKey();
      await tester.pumpWidget(app(Scaffold(
        body: Center(
          child: SizedBox(
            width: 108,
            height: 108,
            child: CreditStripCrop(key: key, child: SizedBox.expand(key: inner)),
          ),
        ),
      )));
      expect(tester.getSize(find.byKey(key)), const Size(108, 108));
      expect(tester.getSize(find.byKey(inner)), Size(108, 108 + kSnapshotCreditStripPt), reason: 'the picture is the taller one');
      expect(tester.getTopLeft(find.byKey(inner)), tester.getTopLeft(find.byKey(key)), reason: 'its top is shown, its foot is cut');
    });
  });

  test('the dot still lands on the route on the taller picture', () {
    final cam = OverviewCamera.fit(south: 42.0, west: -114.0, north: 42.1, east: -113.9, size: insetPictureSize(108), padding: insetPicturePadding);
    final p = cam.project(42.05, -113.95);
    expect(p.dy, inInclusiveRange(0, 108), reason: 'inside the visible square, above the strip');
    expect(cam.project(42.0, -113.95).dy, lessThanOrEqualTo(108 - 16), reason: 'the foot of the route is above the strip');
  });
}
