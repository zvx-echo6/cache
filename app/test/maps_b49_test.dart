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
