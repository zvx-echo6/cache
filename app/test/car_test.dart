import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/car/car_bridge.dart';
import 'package:cache/car/car_drive.dart';
import 'package:cache/car/car_trip.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/nav/nav_geojson.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'support/test_layer_engine.dart';

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

    // The iPhone car side (app/ios/Runner/CarPlay) is tested on recorded messages (tools/carplay-harness/recorded). They are
    // held here to the shape of what carTrip really sends: the same keys, and the same kind of value under each.
    test('the trips recorded for the iPhone car tests have the shape of what the phone sends', () async {
      String kind(Object? v) => switch (v) {
            null => 'null',
            bool() => 'bool',
            num() => 'number',
            String() => 'text',
            List() => 'list',
            Map() => 'map',
            _ => 'other',
          };
      void sameShape(Map<dynamic, dynamic> sent, Map<dynamic, dynamic> recorded, String where) {
        expect(recorded.keys.toSet(), sent.keys.toSet(), reason: '$where: the keys');
        for (final key in sent.keys) {
          final a = sent[key], b = recorded[key];
          if (a == null || b == null) continue;
          expect(kind(b), kind(a), reason: '$where: $key');
          if (a is Map && b is Map) sameShape(a, b, '$where.$key');
          if (a is List && b is List && a.isNotEmpty && b.isNotEmpty && a.first is Map && b.first is Map) {
            sameShape(a.first as Map, b.first as Map, '$where.$key[0]');
          }
        }
      }

      Map<String, dynamic> recorded(String name) =>
          jsonDecode(File('../tools/carplay-harness/recorded/$name.json').readAsStringSync()) as Map<String, dynamic>;

      await preview();
      sameShape(carTrip(nav, position: const GeoPoint(10.5, 20.2), heading: 90), recorded('trip_previewing'), 'previewing');
      backend.progressQueue.add(MapProgress.fromJson(fakeProgressJson(routeJson, 0.1)));
      await nav.start();
      gps.controller.add(fixAt(42.5, -113.77, heading: 90));
      await settle();
      sameShape(carTrip(nav, position: const GeoPoint(10.5, 20.23), heading: 90), recorded('trip_guiding'), 'guiding');
    });

    // The same for the recorded route messages: each stretch of the line carries what routeGeoJson marks it with (the car map
    // draws by those marks), and the bounds are in MapRoute.bounds' order, which the car's camera reads by position.
    test('the routes recorded for the iPhone car tests have the shape of what the phone sends', () async {
      Map<String, dynamic> recorded(String name) =>
          jsonDecode(File('../tools/carplay-harness/recorded/$name.json').readAsStringSync()) as Map<String, dynamic>;
      const marks = {'alt', 'kind', 'route'};

      await preview();
      expect(nav.routes, isNotEmpty);
      for (final f in routeGeoJson(nav.routes, nav.routeIndex)['features'] as List) {
        expect(((f as Map)['properties'] as Map).keys.toSet(), marks, reason: 'what routeGeoJson marks a stretch with');
      }
      expect(nav.routes[nav.routeIndex].bounds, hasLength(4));

      for (final name in const ['route_previewing', 'route_guiding']) {
        final message = recorded(name);
        expect(message.keys.toSet(), {'geojson', 'bounds'}, reason: name);
        final line = jsonDecode(message['geojson'] as String) as Map<String, dynamic>;
        final features = line['features'] as List;
        expect(features, isNotEmpty, reason: name);
        var south = 90.0, west = 180.0, north = -90.0, east = -180.0;
        for (final f in features) {
          final properties = (f as Map)['properties'] as Map;
          final geometry = f['geometry'] as Map;
          expect(properties.keys.toSet(), marks, reason: '$name: what marks a stretch');
          expect(properties['alt'], isA<bool>(), reason: name);
          expect(properties['kind'], isA<String>(), reason: name);
          expect(geometry['type'], 'LineString', reason: name);
          if (properties['alt'] == true) continue;
          for (final c in geometry['coordinates'] as List) {
            final lon = ((c as List)[0] as num).toDouble();
            final lat = (c[1] as num).toDouble();
            if (lat < south) south = lat;
            if (lat > north) north = lat;
            if (lon < west) west = lon;
            if (lon > east) east = lon;
          }
        }
        expect(message['bounds'], [south, west, north, east], reason: '$name: the chosen route, south, west, north, east');
      }

      final none = recorded('route_none');
      expect(none['bounds'], isNull);
      expect(jsonDecode(none['geojson'] as String), routeGeoJson(const [], 0));
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
