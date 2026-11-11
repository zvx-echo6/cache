import 'dart:io';

import 'package:cache/maps/geo.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/ui/place_map.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/pin_image.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/screens/notebooks/map_spot_picker.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/screens/notebooks/places_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/place_alerts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'support/notebook_fake.dart';
import 'support/test_layer_engine.dart';

const _fix = (lat: 43.47, lon: -112.01);

/// Records what a place map was told: the camera it opened on and every move after.
class _Cam {
  CameraPosition? initial;
  final moves = <(LatLng, double?)>[];
  VoidCallback? styleLoaded;
  ValueChanged<LatLng>? tapped;
  int builds = 0;

  /// Where the camera ends: the last move (a null zoom keeps the one before).
  ({double lat, double lon, double zoom}) get end {
    var t = initial!.target;
    var z = initial!.zoom;
    for (final (to, zoom) in moves) {
      t = to;
      z = zoom ?? z;
    }
    return (lat: t.latitude, lon: t.longitude, zoom: z);
  }

  PlaceMapHooks hooks({Duration style = Duration.zero}) => PlaceMapHooks(
        loadStyle: () => Future.delayed(style, () => '{}'),
        camera: (t, z) => moves.add((t, z)),
        surface: (context, init, loaded, tapped) => _Probe(onMount: () {
          // A map opened afresh (a new mount) starts the record again.
          builds++;
          initial = init;
          moves.clear();
          this.tapped = tapped;
          styleLoaded = loaded;
          WidgetsBinding.instance.addPostFrameCallback((_) => loaded());
        }),
      );
}

class _Probe extends StatefulWidget {
  const _Probe({required this.onMount});
  final VoidCallback onMount;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

late MapsState _maps;

void _expectClose(_Cam cam, {double? lat, double? lon}) {
  lat ??= _fix.lat;
  lon ??= _fix.lon;
  final e = cam.end;
  expect(e.zoom, kPlaceZoom);
  expect(e.lat, closeTo(lat, 1e-9));
  expect(e.lon, closeTo(lon, 1e-9));
}

Widget _host(Widget child) => MaterialApp(theme: buildTheme(CacheThemeId.light), home: Scaffold(body: SizedBox(width: 300, height: 300, child: child)));

class _Pin extends StatefulWidget {
  const _Pin(this.cam, this.notifier, {this.style = Duration.zero, this.fallback});
  final _Cam cam;
  final ValueNotifier<NbPlace?> notifier;
  final Duration style;
  final Future<({double lat, double lon, double zoom})?> Function()? fallback;
  @override
  State<_Pin> createState() => _PinState();
}

class _PinState extends State<_Pin> {
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<NbPlace?>(
        valueListenable: widget.notifier,
        builder: (context, p, _) => PlaceMap(
          maps: _maps,
          themeId: CacheThemeId.light,
          pin: p,
          onPick: (q) => widget.notifier.value = q,
          fallback: widget.fallback,
          hooks: widget.cam.hooks(style: widget.style),
        ),
      );
}

void main() {
  setUp(() {
    final dir = Directory.systemTemp.createTempSync('place-zoom');
    addTearDown(() => dir.deleteSync(recursive: true));
    _maps = MapsState(engine: TestLayerEngine(), settingsDirOverride: dir);
  });

  group('PlaceMap camera', () {
    testWidgets('the fix is there before the style: opens on it at the place zoom', (tester) async {
      final cam = _Cam();
      await tester.pumpWidget(_host(_Pin(cam, ValueNotifier(const NbPlace(lat: 43.47, lon: -112.01)), style: const Duration(milliseconds: 400))));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(cam.initial!.zoom, kPlaceZoom);
      _expectClose(cam);
    });

    testWidgets('the style is there before the fix (the bug): ends at the place zoom on the pin', (tester) async {
      final cam = _Cam();
      final pin = ValueNotifier<NbPlace?>(null);
      await tester.pumpWidget(_host(_Pin(cam, pin)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(cam.initial, isNull, reason: 'waits for the fix, a bounded time');
      pin.value = const NbPlace(lat: 43.47, lon: -112.01);
      await tester.pump();
      await tester.pump();
      expect(cam.initial!.zoom, kPlaceZoom);
      _expectClose(cam);
    });

    testWidgets('no permission: opens after 3 s on the last Maps camera, never zoom 3', (tester) async {
      final cam = _Cam();
      await tester.pumpWidget(_host(_Pin(cam, ValueNotifier(null), fallback: () async => placeFallbackCamera(last: const SavedCamera(44.5, -116.1, 11)))));
      await tester.pump(const Duration(milliseconds: 2900));
      expect(cam.initial, isNull);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(cam.initial!.zoom, 11);
      expect(cam.initial!.target.latitude, 44.5);
      expect(cam.moves, isEmpty);
    });

    testWidgets('nothing at all: the wide view, the first tap only zooms in (pin unchanged), a later tap places the pin', (tester) async {
      final cam = _Cam();
      final pin = ValueNotifier<NbPlace?>(null);
      await tester.pumpWidget(_host(_Pin(cam, pin)));
      await tester.pump(kPlaceFixWait + const Duration(milliseconds: 100));
      await tester.pump();
      expect(cam.initial!.zoom, kPlaceWideView.zoom);
      cam.tapped!(LatLng(43.5, -112.0));
      await tester.pump();
      expect(pin.value, isNull);
      expect(cam.moves.single.$2, kPrecisePlaceZoom);
      expect(cam.moves.single.$1.latitude, 43.5);
      cam.tapped!(LatLng(43.51, -112.01));
      await tester.pump();
      expect(pin.value!.lat, 43.51);
      expect(cam.moves.last.$2, isNull);
    });

    testWidgets('a downloaded region: opens on its centre', (tester) async {
      final cam = _Cam();
      const region = GeoBounds(south: 42.5, west: -113.8, north: 42.6, east: -113.66);
      await tester.pumpWidget(_host(_Pin(cam, ValueNotifier(null), fallback: () async => placeFallbackCamera(regions: const [region]))));
      await tester.pump(kPlaceFixWait + const Duration(milliseconds: 100));
      await tester.pump();
      expect(cam.initial!.target.latitude, closeTo(42.55, 1e-9));
      expect(cam.initial!.target.longitude, closeTo(-113.73, 1e-9));
      // A region of about 15 km fits at about zoom 11; a tiny one would open at the place zoom.
      expect(cam.initial!.zoom, closeTo(11.3, 0.1));
      expect(cam.initial!.zoom, greaterThanOrEqualTo(kPrecisePlaceZoom));
    });

    test('a big region fits at a lower zoom, the largest one is used', () {
      final c = placeFallbackCamera(regions: const [GeoBounds(south: 42.5, west: -113.8, north: 42.6, east: -113.66), GeoBounds(south: 40, west: -120, north: 48, east: -110)])!;
      expect(c.lat, 44.0);
      expect(c.zoom, lessThan(kPlaceZoom));
      expect(c.zoom, greaterThanOrEqualTo(3));
    });

    test('the fallback: the last camera, else the places\' middle at the place zoom, else nothing', () {
      expect(placeFallbackCamera(last: const SavedCamera(1, 2, 9))!.zoom, 9);
      // A continent-wide last camera is not used.
      final c = placeFallbackCamera(last: const SavedCamera(39.8, -98.6, 3), places: const [NbPlace(lat: 40, lon: -110), NbPlace(lat: 42, lon: -112)])!;
      expect((c.lat, c.lon, c.zoom), (41.0, -111.0, kPlaceZoom));
      expect(placeFallbackCamera(), isNull);
    });

    testWidgets('the fix arrives after 3 s with the map untouched: recentres on it at the place zoom', (tester) async {
      final cam = _Cam();
      final pin = ValueNotifier<NbPlace?>(null);
      await tester.pumpWidget(_host(_Pin(cam, pin, fallback: () async => placeFallbackCamera(last: const SavedCamera(44.5, -116.1, 11)))));
      await tester.pump(const Duration(seconds: 4));
      expect(cam.initial!.zoom, 11);
      pin.value = const NbPlace(lat: 43.47, lon: -112.01);
      await tester.pump();
      _expectClose(cam);
      expect(cam.moves, hasLength(1));
    });

    testWidgets('a tap moves the pin and keeps the zoom; a position that is not a tap goes to the place zoom', (tester) async {
      final cam = _Cam();
      final pin = ValueNotifier<NbPlace?>(const NbPlace(lat: 43.47, lon: -112.01));
      await tester.pumpWidget(_host(_Pin(cam, pin)));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      cam.tapped!(LatLng(43.5, -112.0));
      await tester.pump();
      expect(cam.moves.single.$2, isNull);
      // Any other position (the phone's fix, a search result, Where I am) goes to the place zoom.
      pin.value = const NbPlace(lat: 43.6, lon: -112.1);
      await tester.pump();
      expect(cam.moves, hasLength(2));
      expect(cam.moves.last.$2, kPlaceZoom);
    });
  });

  group('PlaceForm', () {
    late Notebook book;

    Future<NotebookDeps> deps(WidgetTester tester, _Cam cam, {required Duration fixAfter, bool fix = true, Duration style = Duration.zero}) async {
      final nb = fakeNotebook(FakeNotebookBackend());
      await tester.runAsync(() async {
        await nb.start();
        book = await nb.ensureSavedPlaces();
      });
      return NotebookDeps(
        notebook: nb,
        places: PlaceChoices(here: () => Future.delayed(fixAfter, () => fix ? _fix : null), saved: () async => const []),
        placesDeps: PlaceNotebookDeps(
          watched: (_) => false,
          setWatched: (_, _) {},
          alerts: PlaceAlerts.memory(),
          map: (context, pin, onPick, look) => PlaceMap(maps: _maps, themeId: CacheThemeId.light, pin: pin, onPick: onPick, hooks: cam.hooks(style: style)),
          pickerMap: (context, target, onMoving, onCentre, onTap) => PlaceMap(maps: _maps, themeId: CacheThemeId.light, pin: target, onPick: onTap, showPin: false, hooks: cam.hooks(style: style)),
        ),
      );
    }

    void bigView(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
    }

    Future<void> open(WidgetTester tester, NotebookDeps d, [Key? key]) async {
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: PlaceForm(key: key, deps: d, book: book)));
    }

    testWidgets('Add place five times in a row with varied timings: the pin is close every time', (tester) async {
      bigView(tester);
      // (style load ms, fix ms): the fix before the style, after it, near 3 s and well after it.
      for (final (style, fixMs) in [(0, 0), (800, 100), (100, 1500), (200, 2900), (100, 3500), (2000, 6000)]) {
        final cam = _Cam();
        final d = await deps(tester, cam, fixAfter: Duration(milliseconds: fixMs), style: Duration(milliseconds: style));
        await open(tester, d, UniqueKey());
        await tester.pump(const Duration(seconds: 8));
        await tester.pump();
        expect(cam.initial, isNotNull, reason: 'style $style fix $fixMs');
        _expectClose(cam);
      }
    });

    testWidgets('no permission: the map opens on the fallback inside 3 s plus the style, never zoom 3, and nothing moves', (tester) async {
      bigView(tester);
      final cam = _Cam();
      final d = await deps(tester, cam, fixAfter: Duration.zero, fix: false);
      await open(tester, d);
      await tester.pump(kPlaceFixWait + const Duration(milliseconds: 100));
      await tester.pump();
      expect(cam.initial!.zoom, kPlaceWideView.zoom);
      expect(cam.moves, isEmpty);
    });

    testWidgets('the fix arrives after 3 s: untouched map recentres, a touched one stays', (tester) async {
      bigView(tester);
      final untouched = _Cam();
      await open(tester, await deps(tester, untouched, fixAfter: const Duration(seconds: 5)));
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(untouched.initial!.zoom, kPlaceWideView.zoom);
      _expectClose(untouched);

      final touched = _Cam();
      await open(tester, await deps(tester, touched, fixAfter: const Duration(seconds: 5)), UniqueKey());
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      final g = await tester.startGesture(tester.getCenter(find.byType(PlaceMap)));
      await g.moveBy(const Offset(0, 40));
      await g.up();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(touched.moves, isEmpty);
      expect(touched.end.zoom, kPlaceWideView.zoom);
    });

    testWidgets('editing an existing place opens on its pin at the place zoom', (tester) async {
      bigView(tester);
      final cam = _Cam();
      final d = await deps(tester, cam, fixAfter: Duration.zero);
      final nb = d.notebook;
      late NbEntry e;
      await tester.runAsync(() async {
        e = await nb.saveEntry(notebookId: book.id, occurredAt: '2026-11-11T12:00', title: 'Camp', place: const NbPlace(lat: 44.1, lon: -115.2), values: const {}, photos: const [], files: const [], private: false, props: const {});
      });
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: PlaceForm(deps: d, book: book, entry: e)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(cam.initial!.zoom, kPlaceZoom);
      expect(cam.initial!.target.latitude, 44.1);
    });

    testWidgets('the picker: "Where I am" goes to the place zoom; a tap keeps the zoom', (tester) async {
      bigView(tester);
      final cam = _Cam();
      final d = await deps(tester, cam, fixAfter: const Duration(seconds: 5));
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.light),
        home: MapSpotPicker(map: d.placesDeps!.pickerMap!, places: d.places, start: null, icon: Icons.place, tint: Colors.red, pinStyle: PinStyle.icon),
      ));
      // The opening position fix is slow; the person has the map open on the fallback and presses "Where I am".
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(cam.initial!.zoom, kPlaceWideView.zoom);
      await tester.tap(find.byKey(const ValueKey('picker-here')));
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      _expectClose(cam);
      cam.tapped!(LatLng(43.6, -112.1));
      await tester.pump();
      expect(cam.moves.last.$2, isNull);
      expect(cam.end.zoom, kPlaceZoom);
    });

    testWidgets('the picker opening on a fix that arrives in time: opens close in', (tester) async {
      bigView(tester);
      final cam = _Cam();
      final d = await deps(tester, cam, fixAfter: const Duration(milliseconds: 600), style: const Duration(milliseconds: 100));
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.light),
        home: MapSpotPicker(map: d.placesDeps!.pickerMap!, places: d.places, start: null, icon: Icons.place, tint: Colors.red, pinStyle: PinStyle.icon),
      ));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      _expectClose(cam);
    });

    testWidgets('the picker from the wide view: the first tap zooms in and leaves the spot unset, the next sets it', (tester) async {
      bigView(tester);
      final cam = _Cam();
      final d = await deps(tester, cam, fixAfter: Duration.zero, fix: false);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.light),
        home: MapSpotPicker(map: d.placesDeps!.pickerMap!, places: d.places, start: null, icon: Icons.place, tint: Colors.red, pinStyle: PinStyle.icon),
      ));
      await tester.pump(kPlaceFixWait + const Duration(milliseconds: 100));
      await tester.pump();
      expect(cam.initial!.zoom, kPlaceWideView.zoom);
      cam.tapped!(LatLng(43.5, -112.0));
      await tester.pump();
      expect(cam.moves.single.$2, kPrecisePlaceZoom);
      expect(find.text('Move the map to the spot'), findsOneWidget);
      cam.tapped!(LatLng(43.51, -112.01));
      await tester.pump();
      expect(find.text('43.51000, -112.01000'), findsOneWidget);
    });
  });
}
