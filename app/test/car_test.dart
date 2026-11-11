import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cache/car/car_bridge.dart';
import 'package:cache/car/car_drive.dart';
import 'package:cache/app_state.dart';
import 'package:cache/car/car_overlay.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/nav/elevation/elevation_profile.dart';
import 'package:cache/theme.dart';
import 'package:cache/car/car_trip.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/notebook/pin_image.dart' show PinStyle;
import 'package:cache/nav/nav_backend.dart' show CoreMapBackend;
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/painting.dart' show Color, HSLColor;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'support/test_layer_engine.dart';

/// A layer engine whose connection count the test moves (a reconnect).
class _GenEngine extends TestLayerEngine {
  int gen = 0;
  @override
  int get sourcesGeneration => gen;
  void reconnect() {
    gen++;
    notifyListeners();
  }
}

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

MapPlace _place(String id, String name, {double lat = 42.5, double lon = -113.5}) =>
    MapPlace(id: id, type: 'place', name: name, kind: 'Hospital', address: '1501 Hiland Ave, Burley, ID', lat: lat, lon: lon, matched: 'name');

Future<void> settle([int ms = 40]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('co.cache/car');
  late Directory dir;
  late LocationService location;
  late FakeBackend backend;
  late FakeSpeaker speaker;
  late FakeNavPosition gps;
  late CarDriveSource drive;
  late NavState nav;
  final routeJson = fakeRouteJson();

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('car');
    location = LocationService(source: _NoSource(), settingsDirOverride: dir);
    await location.init();
    backend = FakeBackend();
    speaker = FakeSpeaker();
    gps = FakeNavPosition();
    drive = CarDriveSource(gps, route: () => nav.route, tick: const Duration(milliseconds: 10));
    nav = NavState(
      backend: backend,
      location: location,
      speaker: speaker,
      positionSource: drive,
      simulatedDrive: () => drive.simulating,
      fmt: const Fmt(UnitSystem.imperial),
      clock: () => DateTime(2026, 11, 8, 12),
      searchDebounce: const Duration(milliseconds: 5),
      meaningDebounce: const Duration(milliseconds: 25),
    );
  });

  tearDown(() async {
    await nav.end();
    nav.dispose();
    location.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> preview() async {
    location.publish(fixAt(42.5, -113.8));
    backend.onRoute = (to, mode, from) async => MapRoute.fromJson(routeJson);
    await nav.openDirections(_place('place:4', 'Cassia Regional Hospital'));
  }

  group('carTrip: the car shows the phone guidance', () {
    test('a preview lists the routes with their distance, time and main road', () async {
      await preview();
      final t = carTrip(nav);
      expect(t['phase'], 'previewing');
      expect(t['units'], 'imperial');
      expect((t['destination'] as Map)['name'], 'Cassia Regional Hospital');
      final routes = t['routes'] as List;
      expect(routes, hasLength(1));
      expect((routes.first as Map)['distanceM'], closeTo((routeJson['distance_m'] as num).toDouble(), 0.01));
      expect((routes.first as Map)['via'], 'Via Road 0');
      expect(t.containsKey('step'), isFalse);
    });

    test('while guiding: the next maneuver, the one after, and what is left', () async {
      await preview();
      backend.progressQueue.add(MapProgress.fromJson(fakeProgressJson(routeJson, 0.1)));
      await nav.start();
      gps.controller.add(fixAt(42.5, -113.77, heading: 90));
      await settle();
      final t = carTrip(nav);
      expect(t['phase'], 'guiding');
      final step = t['step'] as Map;
      expect(step['turn'], 'left');
      expect(step['cue'], 'Turn left onto Road 1.');
      expect(step['road'], 'Road 1');
      expect(step['distanceM'], greaterThan(0));
      expect((t['then'] as Map)['turn'], 'right');
      expect(t['remainingM'], closeTo((routeJson['distance_m'] as num) * 0.9, 1));
      expect(t['remainingS'], isNotNull);
      expect(t['currentRoad'], 'Road 0');
    });

    test('an off-road maneuver reads as the way to head and how far, in the phone units', () async {
      final m = ProgressManeuver.fromJson({
        'index': 3, 'kind': 'offroad', 'type': 'none', 'instruction': 'Off-road E 0.1 mi', 'street_names': const [], 'lat': 42.5,
        'lon': -113.6, 'distance_m': 200.0, 'length_m': 1609.344, 'cardinal': 'NE', 'bearing_deg': 45,
      });
      final s = carStep(m, const Fmt(UnitSystem.imperial));
      expect(s['turn'], 'offroad');
      expect(s['cue'], 'Head northeast for 1.0 mi');
      expect(s['road'], isNull);
    });

    test('no position: the car says it is waiting, and never asks for the phone', () async {
      backend.onRoute = (to, mode, from) async => MapRoute.fromJson(routeJson);
      await nav.openDirections(_place('place:4', 'Cassia Regional Hospital'));
      expect(nav.routeError, isNotNull);
      final t = carTrip(nav);
      expect(t['error'], 'Waiting for your position');
      expect('${t['error']}'.toLowerCase(), isNot(contains('phone')));
    });
  });

  group('test drive (onAutoDriveEnabled)', () {
    test('a simulated drive goes along the route, heading the way it goes, and stays at the end', () async {
      final pts = [const GeoPoint(42.5, -113.8), const GeoPoint(42.5, -113.799), const GeoPoint(42.501, -113.799)];
      final d = SimulatedDrive(pts, speedMps: 4000, tick: const Duration(milliseconds: 10));
      final fixes = <Fix>[];
      final sub = d.start().listen(fixes.add);
      await settle(120);
      d.stop();
      await sub.cancel();
      expect(fixes.first.lat, 42.5);
      expect(fixes.first.lon, -113.8);
      expect(fixes.first.heading, closeTo(90, 1));
      expect(fixes.last.lat, closeTo(42.501, 1e-9));
      expect(fixes.last.lon, closeTo(-113.799, 1e-9));
      for (var i = 1; i < fixes.length; i++) {
        expect(fixes[i].lat >= fixes[i - 1].lat - 1e-12, isTrue);
      }
    });

    test('guidance runs on the drive instead of the GPS while the car asks for it', () async {
      await preview();
      backend.onProgress = (r, lat, lon) async => MapProgress.fromJson(fakeProgressJson(r.raw, ((lon + 113.8) / 0.3).clamp(0.0, 1.0)));
      drive.simulate = true;
      await nav.start();
      expect(gps.starts, 0, reason: 'the GPS is not used for a test drive');
      expect(drive.simulating, isTrue);
      await settle(80);
      expect(nav.progress, isNotNull);
      expect(backend.calls.where((c) => c.startsWith('progress')), isNotEmpty);
      await nav.end();
      expect(drive.simulating, isFalse);
    });

    test('without the request, guidance uses the GPS as always', () async {
      await preview();
      await nav.start();
      expect(gps.starts, 1);
      expect(drive.simulating, isFalse);
    });

    test('the speed is the route average, at least walking pace', () {
      final r = MapRoute.fromJson(routeJson);
      expect(simulatedSpeed(r), closeTo(r.distanceM / r.durationS, 1e-9));
    });
  });

  group('the climb card and the route mini map (car_overlay.dart)', () {
    // Sample data: a gentle rise for 9 km, then 2 km at about 9%, then flat.
    ElevationProfile profile(double total) {
      final dist = <double>[], h = <double>[];
      for (var d = 0.0; d <= total; d += 40) {
        dist.add(d);
        h.add(1000 + (d < 9000 ? d * 0.02 : d < 11000 ? 180 + (d - 9000) * 0.09 : 360));
      }
      return ElevationProfile.fromSamples(dist, h, totalM: total);
    }

    Future<void> guide(double fraction) async {
      await preview();
      backend.progressQueue.add(MapProgress.fromJson(fakeProgressJson(routeJson, fraction)));
      await nav.start();
      gps.controller.add(fixAt(42.5, -113.8 + 0.3 * fraction, heading: 90));
      await settle();
    }

    test('no elevation data: no climb block, but the mini map and palette still go', () async {
      await guide(0.1);
      final t = carTrip(nav);
      expect(t.containsKey('climb'), isFalse);
      expect(t['overview'], isNotNull);
      expect(t['palette'], isNotNull);
      expect(t['overlay'], {'climb': kCarClimbAheadDefault, 'miniMap': kCarRouteMiniMapDefault});
      final none = ElevationProfile.none(24000);
      expect(none.hasData, isFalse);
      expect(carClimb(none, distanceAlongM: 0, routeM: 24000), isNull);
      expect(carClimb(null, distanceAlongM: 0, routeM: 24000), isNull);
      expect(carTrip(nav, elevation: none).containsKey('climb'), isFalse);
    });

    test('the climb block: climb ahead, steepest grade and how far, heights and the steep span', () async {
      final total = (routeJson['distance_m'] as num).toDouble();
      final p = profile(total);
      final c = carClimb(p, distanceAlongM: 0, routeM: total)!;
      expect((c['heightsM'] as List), hasLength(kClimbSamples));
      expect((c['heightsM'] as List).first, closeTo(1000, 2));
      expect(c['climbAheadM'] as double, closeTo(360, 30));
      expect(c['gradePct'] as double, closeTo(9, 1.5));
      expect(c['steepestInM'] as double, closeTo(9000, 700));
      final from = c['steepFrom'] as int, to = c['steepTo'] as int;
      expect(from, lessThan(to));
      expect(to, lessThanOrEqualTo(kClimbSamples - 1));
      expect(c['windowM'] as double, greaterThanOrEqualTo(8000));

      // Further along: the steep part is nearer, the heights start at the position, and less climb is left.
      final later = carClimb(p, distanceAlongM: 4000, routeM: total)!;
      expect(later['steepestInM'] as double, lessThan(c['steepestInM'] as double));
      expect(later['climbAheadM'] as double, lessThan(c['climbAheadM'] as double));
      expect((later['heightsM'] as List).first, closeTo(1000 + 4000 * 0.02, 3));

      // On the steep part: it counts from the position, and it is 0 m away.
      final on = carClimb(p, distanceAlongM: 10000, routeM: total)!;
      expect(on['steepestInM'], 0);
      // Past it: no steep climb, so no grade and no span.
      final past = carClimb(p, distanceAlongM: 12000, routeM: total)!;
      expect(past['gradePct'], isNull);
      expect(past['steepFrom'], isNull);
    });

    test('the climb block is in the trip while guiding, with the heights and the overview', () async {
      await guide(0.1);
      final total = nav.route!.distanceM;
      final t = carTrip(nav, elevation: profile(total));
      expect(t['climb'], isNotNull);
      expect((t['climb'] as Map)['heightsM'], hasLength(kClimbSamples));
    });

    test('the overview: the route simplified, the driven fraction, the steepest point and the destination', () async {
      await guide(0.33);
      final total = nav.route!.distanceM;
      final t = carTrip(nav, elevation: profile(total));
      final o = t['overview'] as Map;
      expect(o['drivenFraction'], closeTo(0.33, 0.001));
      expect((o['points'] as List).length, lessThanOrEqualTo(kOverviewMaxPoints));
      final steep = o['steep'] as Map;
      expect(steep['gradePct'] as double, closeTo(9, 1.5));
      // The steep part is about 9 to 11 km of 24.6 km along a straight east line.
      expect(steep['lon'] as double, greaterThan(-113.8 + 0.3 * 0.35));
      expect(steep['lon'] as double, lessThan(-113.8 + 0.3 * 0.5));
      expect((o['destination'] as Map)['lon'], -113.5);
      // Without elevation there is no steep point.
      expect((carTrip(nav)['overview'] as Map)['steep'], isNull);
    });

    test('a long route is cut to at most 150 points and keeps both ends', () {
      final pts = [for (var i = 0; i < 3000; i++) GeoPoint(42.5 + 0.0002 * i + 0.00005 * ((i * 37) % 11), -113.8 + 0.0003 * i + 0.00008 * ((i * 17) % 7))];
      final s = simplifyRoute(pts, kOverviewMaxPoints);
      expect(s.length, lessThanOrEqualTo(kOverviewMaxPoints));
      expect(s.first, pts.first);
      expect(s.last, pts.last);
    });

    test('no route: no overview', () {
      expect(carOverview(null, distanceAlongM: 0), isNull);
    });

    test('the car map style: Tactical at night when Tactical is chosen, otherwise Light by day and Dark by night', () {
      expect(carMapTheme(dark: true, chosen: CacheThemeId.tactical), CacheThemeId.tactical);
      expect(carMapTheme(dark: false, chosen: CacheThemeId.tactical), CacheThemeId.light);
      expect(carMapTheme(dark: true, chosen: CacheThemeId.dark), CacheThemeId.dark);
      expect(carMapTheme(dark: true, chosen: CacheThemeId.light), CacheThemeId.dark);
      expect(carMapTheme(dark: false, chosen: CacheThemeId.parchment), CacheThemeId.light);
    });

    test('day and night themes: the chosen theme when it fits, else Light by day and Dark by night', () {
      expect(carDayTheme(CacheThemeId.parchment), CacheThemeId.parchment);
      expect(carDayTheme(CacheThemeId.light), CacheThemeId.light);
      expect(carDayTheme(CacheThemeId.dark), CacheThemeId.light);
      expect(carDayTheme(CacheThemeId.tactical), CacheThemeId.light);
      expect(carNightTheme(CacheThemeId.tactical), CacheThemeId.tactical);
      expect(carNightTheme(CacheThemeId.dark), CacheThemeId.dark);
      expect(carNightTheme(CacheThemeId.light), CacheThemeId.dark);
      expect(carNightTheme(CacheThemeId.parchment), CacheThemeId.dark);
      final p = carOverlayPalette(CacheThemeId.tactical);
      expect((p['day'] as Map)['theme'], 'light');
      expect((p['night'] as Map)['theme'], 'tactical');
    });

    test('palette colors come from the theme tokens: one route color, a white badge, and Tactical all red', () {
      for (final id in [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.parchment]) {
        final c = carOverlayColors(id);
        expect(c['route'], mapPaletteFor(id == CacheThemeId.parchment ? CacheThemeId.light : id).css('route'));
        final hsl = HSLColor.fromColor(Color(int.parse('FF${c['route']!.substring(1)}', radix: 16)));
        expect(hsl.hue, inInclusiveRange(180, 260), reason: '${id.name} route is blue, never a traffic color');
      }
      // Parchment on the car: Light's blue for the route and everything made from it; the phone's Parchment map stays brown.
      final pc = carOverlayColors(CacheThemeId.parchment);
      expect(pc['route'], carOverlayColors(CacheThemeId.light)['route']);
      expect(pc['posRing'], pc['route']);
      expect(pc['badgeEdge'], pc['route']);
      expect(mapPaletteFor(CacheThemeId.parchment).css('route'), '#7a4e1d');
      expect((carOverlayPalette(CacheThemeId.parchment)['day'] as Map)['route'], carOverlayColors(CacheThemeId.light)['route']);
      expect(carOverlayColors(CacheThemeId.light)['badge'], '#ffffff');
      expect(carOverlayColors(CacheThemeId.dark)['badgeGlyph'], '#161b20');
      final t = carOverlayColors(CacheThemeId.tactical);
      expect(t['route'], '#ff5a4a');
      for (final e in t.entries) {
        final r = int.parse(e.value.substring(1, 3), radix: 16), g = int.parse(e.value.substring(3, 5), radix: 16), b = int.parse(e.value.substring(5, 7), radix: 16);
        expect(r >= g && r >= b, isTrue, reason: 'tactical ${e.key} ${e.value} is on the red ramp');
        expect(g < 0xC0 && b < 0xC0, isTrue, reason: 'tactical ${e.key} is not white');
      }
      // The host's guidance card: the theme surface, and a dark red in Tactical.
      expect(carOverlayColors(CacheThemeId.dark)['hostCard'], carOverlayColors(CacheThemeId.dark)['card']);
      expect(t['hostCard'], '#3a0b07');
      // Inverted badge: a dark red glyph on a light red pill.
      expect(t['badge'], isNot(t['badgeGlyph']));
      expect(t['routeDriven'], isNot(t['route']));
    });

    test('text on the climb card reads at 4.5:1 or better in all four themes, and Tactical stays red', () {
      double contrast(String a, String b) {
        double lum(String h) => Color(int.parse('FF${h.substring(1)}', radix: 16)).computeLuminance();
        final x = lum(a), y = lum(b);
        return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
      }

      for (final id in CacheThemeId.values) {
        final c = carOverlayColors(id);
        expect(contrast(c['cardText']!, c['card']!), greaterThanOrEqualTo(4.5), reason: '${id.name} figures on the card');
        expect(contrast(c['cardSecondary']!, c['card']!), greaterThanOrEqualTo(4.5), reason: '${id.name} label on the card');
      }
      // Tactical: the label is the theme's text red, the figures its brightest red; nothing else on the card changed.
      final t = carOverlayColors(CacheThemeId.tactical);
      expect(t['cardSecondary'], '#e0473c');
      expect(t['cardText'], '#ff5a4a');
      expect(t['card'], '#120404');
      // The other three keep their theme's text and secondary.
      expect(carOverlayColors(CacheThemeId.dark)['cardText'], '#dcc9a3');
      expect(carOverlayColors(CacheThemeId.light)['cardSecondary'], '#55594f');
      expect(carOverlayColors(CacheThemeId.parchment)['cardSecondary'], '#4a4638');
    });

    test('the Kotlin tests read the same palette: the fixture is these colors', () {
      final f = File('android/app/src/test/resources/car/overlay_palette.json');
      final now = {for (final id in CacheThemeId.values) id.name: {'theme': id.name, ...carOverlayColors(id)}};
      if (Platform.environment['CAR_AA_WRITE_FIXTURE'] == '1') {
        f.createSync(recursive: true);
        f.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(now)}\n');
      }
      expect(jsonDecode(f.readAsStringSync()), now, reason: 'run once with CAR_AA_WRITE_FIXTURE=1 to rewrite it');
    });
  });

  test('the car switches default to the constants and are kept with the app settings', () async {
    final d = Directory.systemTemp.createTempSync('carset');
    addTearDown(() => d.deleteSync(recursive: true));
    final a = AppState(settingsDirOverride: d, modelsDirOverride: d);
    await a.init();
    expect(a.carClimbAhead, kCarClimbAheadDefault);
    expect(a.carRouteMiniMap, kCarRouteMiniMapDefault);
    await a.setCarClimbAhead(false);
    await a.setCarRouteMiniMap(false);
    final b = AppState(settingsDirOverride: d, modelsDirOverride: d);
    await b.init();
    expect(b.carClimbAhead, isFalse);
    expect(b.carRouteMiniMap, isFalse);
    a.dispose();
    b.dispose();
  });

  group('CarBridge over the platform channel', () {
    late MapsState maps;
    late List<MethodCall> toCar;
    late CarBridge bridge;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    Future<Object?> fromCar(String method, [Object? args]) async {
      final c = Completer<Object?>();
      await messenger.handlePlatformMessage(channel.name, const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)), (data) {
        c.complete(data == null ? null : const StandardMethodCodec().decodeEnvelope(data));
      });
      return c.future;
    }

    setUp(() async {
      maps = MapsState(engine: TestLayerEngine(), settingsDirOverride: dir);
      toCar = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        toCar.add(call);
        if (call.method == 'hello') return {'connected': true};
        return null;
      });
      bridge = CarBridge(nav: nav, maps: maps, drive: drive, throttle: const Duration(milliseconds: 5), glyphs: () async => 'file:///g/{fontstack}/{range}.pbf');
      await bridge.start();
    });

    tearDown(() {
      bridge.dispose();
      maps.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('the car map style at night is the full Tactical style when Tactical is chosen, else Dark', () async {
      await maps.engine.start();
      Future<Map<String, Object?>?> styleFor(CacheThemeId t, {required bool dark}) =>
          CarBridge(nav: nav, maps: maps, drive: drive, theme: () => t, glyphs: () async => 'file:///g/{fontstack}/{range}.pbf').style(dark: dark);
      final tac = await styleFor(CacheThemeId.tactical, dark: true);
      expect((tac!['colors'] as Map)['route'], mapPaletteFor(CacheThemeId.tactical).css('route'));
      final dk = await styleFor(CacheThemeId.light, dark: true);
      expect((dk!['colors'] as Map)['route'], mapPaletteFor(CacheThemeId.dark).css('route'));
      final day = await styleFor(CacheThemeId.tactical, dark: false);
      expect((day!['colors'] as Map)['route'], mapPaletteFor(CacheThemeId.light).css('route'));
      expect(tac['style'], isNot(dk['style']));
    });

    test('the car map reloads for its own look only: not a reconnect or an opacity change, but pins and layers', () async {
      final eng = _GenEngine();
      final m = MapsState(engine: eng, settingsDirOverride: dir);
      addTearDown(m.dispose);
      await m.init();
      final b = CarBridge(nav: nav, maps: m, drive: drive, throttle: const Duration(milliseconds: 5), glyphs: () async => 'g');
      await b.start();
      await fromCar('connected', {'on': true});
      expect(m.uses, isNotEmpty);
      await b.style(dark: true); // the car's own first style: the key is recorded as the car loads it
      int count() => toCar.where((c) => c.method == 'styleChanged').length;
      toCar.clear();
      // The connection came back: the phone's key moves, the car's does not.
      final keyBefore = m.styleKey;
      eng.reconnect();
      await settle();
      expect(m.styleKey, isNot(keyBefore));
      expect(count(), 0);
      // A layer's opacity.
      m.setOpacity(m.uses.first.def.id, 0.5);
      await settle();
      expect(count(), 0);
      // The pin style.
      m.setPinStyle(m.pinStyle == PinStyle.icon ? PinStyle.teardrop : PinStyle.icon);
      await settle();
      expect(count(), 1);
      // A layer switched off, then on again.
      final on = m.layersOn;
      m.setLayersOn(on.take(on.length - 1));
      await settle();
      expect(count(), 2);
      m.setLayersOn(on);
      await settle();
      expect(count(), 3);
      b.dispose();
    });

    test('a new phone theme makes the car reload its map style, without reconnecting', () async {
      await maps.engine.start();
      var chosen = CacheThemeId.dark;
      final changed = ValueNotifier(0);
      final b = CarBridge(
          nav: nav, maps: maps, drive: drive, throttle: const Duration(milliseconds: 5), settings: changed, theme: () => chosen,
          glyphs: () async => 'g');
      await b.start();
      await fromCar('connected', {'on': true});
      toCar.clear();
      // Something else changed: no style refresh.
      changed.value++;
      await settle();
      expect(toCar.where((c) => c.method == 'styleChanged'), isEmpty);
      chosen = CacheThemeId.tactical;
      changed.value++;
      await settle();
      expect(toCar.where((c) => c.method == 'styleChanged'), hasLength(1));
      // The car's own style request then builds the Tactical night style.
      final st = await b.style(dark: true);
      expect((st!['colors'] as Map)['route'], mapPaletteFor(CacheThemeId.tactical).css('route'));
      b.dispose();
    });

    test('car search goes by name and address only: meaning false, and the search model is never asked for a vector', () async {
      final asked = <bool?>[];
      backend.onSearch = (q, {near, meaning}) async {
        asked.add(meaning);
        return MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: [_place('place:9', 'Home Depot')]);
      };
      await fromCar('search', {'query': 'coffee'});
      await fromCar('navigateTo', {'query': 'pharmacy', 'start': false});
      expect(asked, isNotEmpty);
      expect(asked, everyElement(isFalse), reason: 'every car search path asks with meaning off');

      // The real backend: with meaning off it never calls the embedder (the search model); with it on (the phone) it does.
      var embedded = 0;
      final real = CoreMapBackend(() => throw StateError('no core in this test'), embedder: (q) async {
        embedded++;
        return null;
      });
      await expectLater(real.search('coffee', meaning: false), throwsStateError);
      expect(embedded, 0);
      await expectLater(real.search('coffee'), throwsStateError);
      expect(embedded, 1, reason: 'control: the phone path does use the embedder');
    });

    test('the two car switches reach the car in the trip within one update', () async {
      final climb = ValueNotifier(true);
      final mini = ValueNotifier(true);
      final changed = ValueNotifier(0);
      final b = CarBridge(
          nav: nav, maps: maps, drive: drive, throttle: const Duration(milliseconds: 5), settings: changed,
          overlay: () => carOverlaySwitches(climb: climb.value, miniMap: mini.value), glyphs: () async => 'g');
      await b.start();
      await fromCar('connected', {'on': true});
      await preview();
      backend.progressQueue.add(MapProgress.fromJson(fakeProgressJson(routeJson, 0.2)));
      await nav.start();
      gps.controller.add(fixAt(42.5, -113.74, heading: 90));
      await settle();
      Map lastOverlay() => (toCar.lastWhere((c) => c.method == 'trip').arguments as Map)['overlay'] as Map;
      expect(lastOverlay(), {'climb': true, 'miniMap': true});
      climb.value = false;
      changed.value++;
      await settle();
      expect(lastOverlay(), {'climb': false, 'miniMap': true});
      mini.value = false;
      changed.value++;
      await settle();
      expect(lastOverlay(), {'climb': false, 'miniMap': false});
      b.dispose();
    });

    test('places wait for the core when the car started the app', () async {
      final open = Completer<void>();
      final waiting = CarBridge(nav: nav, maps: maps, drive: drive, channel: const MethodChannel('co.cache/car-wait'), ready: () => open.future);
      messenger.setMockMethodCallHandler(const MethodChannel('co.cache/car-wait'), (call) async => null);
      await waiting.start();
      backend.saved.add(('Home', 42.6, -113.7));
      Object? answer;
      final reply = Completer<void>();
      unawaited(messenger.handlePlatformMessage('co.cache/car-wait', const StandardMethodCodec().encodeMethodCall(const MethodCall('saved')), (data) {
        answer = const StandardMethodCodec().decodeEnvelope(data!);
        reply.complete();
      }));
      await settle();
      expect(reply.isCompleted, isFalse, reason: 'no answer before the core is open');
      open.complete();
      await reply.future;
      expect([for (final p in answer as List) (p as Map)['name']], ['Home']);
      waiting.dispose();
      messenger.setMockMethodCallHandler(const MethodChannel('co.cache/car-wait'), null);
    });

    test('hello: a car session that is already there connects the bridge', () {
      expect(toCar.first.method, 'hello');
      expect(bridge.connected.value, isTrue);
    });

    test('the trip and the route line are pushed as guidance changes', () async {
      await preview();
      await settle();
      final trips = toCar.where((c) => c.method == 'trip').toList();
      expect(trips, isNotEmpty);
      expect((trips.last.arguments as Map)['phase'], 'previewing');
      final route = toCar.lastWhere((c) => c.method == 'route');
      expect((route.arguments as Map)['geojson'], contains('LineString'));
    });

    test('the car disconnecting stops the pushes and ends a test drive request', () async {
      drive.simulate = true;
      await fromCar('connected', {'on': false});
      expect(bridge.connected.value, isFalse);
      expect(drive.simulate, isFalse);
      toCar.clear();
      await preview();
      await settle();
      expect(toCar.where((c) => c.method == 'trip'), isEmpty);
    });

    test('saved places come first when searching by their name; a tap picks that place for directions', () async {
      backend.saved.add(('Home', 42.6, -113.7));
      backend.onSearch = (q, {near, meaning}) async =>
          MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: [_place('place:9', 'Home Depot')]);
      final r = (await fromCar('search', {'query': 'home'})) as List;
      expect([for (final p in r) (p as Map)['name']], ['Home', 'Home Depot']);
      location.publish(fixAt(42.5, -113.8));
      backend.onRoute = (to, mode, from) async => MapRoute.fromJson(routeJson);
      expect(await fromCar('directions', {'id': (r.last as Map)['id']}), isTrue);
      await settle();
      expect(nav.phase, NavPhase.previewing);
      expect(nav.selected!.name, 'Home Depot');
    });

    test('a navigation request with coordinates starts guidance; Stop ends it at once', () async {
      location.publish(fixAt(42.5, -113.8));
      backend.onRoute = (to, mode, from) async => MapRoute.fromJson(routeJson);
      backend.onProgress = (r, lat, lon) async => MapProgress.fromJson(fakeProgressJson(r.raw, 0.05));
      final r = (await fromCar('navigateTo', {'lat': 42.5, 'lon': -113.5, 'query': 'Hospital'})) as Map;
      expect(r['started'], isTrue);
      expect(nav.guiding, isTrue);
      await fromCar('stop');
      expect(nav.guiding, isFalse);
      expect(gps.stops, greaterThan(0));
      expect(speaker.stops, greaterThan(0));
    });

    test('a navigation request by a name that is not saved returns the places found, without starting', () async {
      backend.onSearch = (q, {near, meaning}) async =>
          MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: [_place('place:9', 'Burley Library')]);
      final r = (await fromCar('navigateTo', {'query': 'library'})) as Map;
      expect([for (final p in r['places'] as List) (p as Map)['name']], ['Burley Library']);
      expect(nav.phase, NavPhase.browsing);
    });

    test('autoDrive and voice from the car', () async {
      await fromCar('autoDrive', {'on': true});
      expect(drive.simulate, isTrue);
      expect(await fromCar('voice', {'on': false}), isFalse);
      expect(nav.voiceOn, isFalse);
    });

    test('the voice takes the car audio focus only while a car is connected', () async {
      final s = CarAwareSpeaker(speaker, car: () => bridge);
      await s.speak('Turn left.');
      expect(toCar.where((c) => c.method == 'prompt').single.arguments, {'text': 'Turn left.'});
      expect(speaker.said, ['Turn left.']);
      await fromCar('connected', {'on': false});
      await s.speak('Turn right.');
      expect(toCar.where((c) => c.method == 'prompt'), hasLength(1));
      expect(speaker.said, ['Turn left.', 'Turn right.']);
    });
  });
}
