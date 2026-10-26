import 'dart:async';
import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache_search/cache_search.dart';
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

MapPlace place(String id, String name, {String type = 'place', double lat = 42.5, double lon = -113.5, String kind = 'Hospital'}) =>
    MapPlace(id: id, type: type, name: name, kind: kind, address: '1501 Hiland Ave, Burley, ID', lat: lat, lon: lon, matched: 'name');

Future<void> settle([int ms = 40]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late LocationService location;
  late FakeBackend backend;
  late FakeSpeaker speaker;
  late FakeNavPosition gps;
  late List<FollowMode> follows;
  late NavState nav;
  late List<NavEvent> events;
  var now = DateTime(2026, 10, 26, 12);

  final routeJson = fakeRouteJson();

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('nav');
    location = LocationService(source: _NoSource(), settingsDirOverride: dir);
    await location.init();
    backend = FakeBackend();
    speaker = FakeSpeaker();
    gps = FakeNavPosition();
    follows = [];
    events = [];
    now = DateTime(2026, 10, 26, 12);
    nav = NavState(
      backend: backend,
      location: location,
      speaker: speaker,
      positionSource: gps,
      fmt: const Fmt(UnitSystem.imperial),
      onFollow: follows.add,
      clock: () => now,
      searchDebounce: const Duration(milliseconds: 5),
      meaningDebounce: const Duration(milliseconds: 25),
      rerouteCooldown: const Duration(seconds: 8),
    );
    nav.events.listen(events.add);
  });

  tearDown(() {
    nav.dispose();
    location.dispose();
    dir.deleteSync(recursive: true);
  });

  group('search', () {
    test('typing shows the quick answer first and the answer by meaning when typing pauses', () async {
      backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(
            query: q,
            kind: 'text',
            meaning: meaning == true ? 'used' : 'off',
            results: [place('place:1', meaning == true ? 'By meaning' : 'By name')],
          );
      nav.setMapCentre(42.5, -113.8);
      nav.onQueryChanged('doctor');
      expect(nav.searching, isTrue);
      await settle(15);
      expect(nav.results.single.name, 'By name');
      await settle(60);
      expect(nav.results.single.name, 'By meaning');
      expect(backend.calls, ['search:doctor:k', 'search:doctor:m']);
      expect(nav.searching, isFalse);
    });

    test('an older answer never replaces a newer one, and typing on cancels the wait', () async {
      final slow = Completer<MapSearchResponse>();
      backend.onSearch = (q, {near, meaning}) {
        if (q == 'bur') return slow.future;
        return Future.value(MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: [place('place:2', 'Burley')]));
      };
      nav.onQueryChanged('bur');
      await settle(12);
      nav.onQueryChanged('burley');
      await settle(60);
      slow.complete(MapSearchResponse(query: 'bur', kind: 'text', meaning: 'off', results: [place('place:9', 'Old')]));
      await settle();
      expect(nav.results.map((r) => r.name), ['Burley']);
    });

    test('clearing the field empties the list and closes nothing else', () async {
      backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: [place('place:1', 'X')]);
      nav.onQueryChanged('x');
      await settle(60);
      nav.onQueryChanged('');
      expect(nav.results, isEmpty);
      expect(nav.searching, isFalse);
      expect(nav.searchOpen, isTrue);
    });

    test('a failed search says so; missing meaning search is told plainly', () async {
      backend.onSearch = (q, {near, meaning}) async => throw const CacheSearchException('not_configured', 'map search needs a places pack');
      nav.onQueryChanged('x');
      await settle(60);
      expect(nav.searchError, 'map search needs a places pack');
      backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(query: q, kind: 'text', meaning: 'no_embedder', results: [place('place:1', 'X')]);
      await nav.submitSearch();
      expect(nav.searchError, isNull);
      expect(nav.searchNote, contains('Matching words only'));
      // coordinates never get the note
      backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(query: q, kind: 'coordinates', meaning: 'off', results: const []);
      await nav.submitSearch();
      expect(nav.searchNote, isNull);
    });

    test('choosing a result selects it and closes the list; choosing a category lists that kind of place', () async {
      backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: [place('place:1', 'Walgreens', kind: 'Pharmacy')]);
      nav.select(place('place:1', 'Walgreens', kind: 'Pharmacy'));
      expect(nav.selected!.name, 'Walgreens');
      expect(nav.searchOpen, isFalse);
      nav.select(MapPlace(id: 'category:pharmacy', type: 'category', name: 'Pharmacy', kind: 'Category', lat: 0, lon: 0));
      expect(nav.query, 'Pharmacy');
      expect(nav.searchOpen, isTrue);
      await settle(60);
      expect(backend.calls.last, 'search:Pharmacy:m');
    });
  });

  group('the selected place', () {
    test('a dropped pin shows coordinates at once and the grid and Plus Code when the core answers', () async {
      backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(query: q, kind: 'coordinates', meaning: 'off', results: [
            MapPlace(id: 'loc:1', type: 'coordinates', name: '43.6, -116.2', kind: 'Coordinates', address: '3.2 mi NE of Boise, ID', lat: 43.6, lon: -116.2, formats: {
              'decimal': '43.60000, -116.20000',
              'usng': '11T NK 12345 67890',
              'plus_code': '85M9G8VC+MM',
            }),
          ]);
      final done = nav.dropPin(43.6, -116.2);
      expect(nav.selected!.name, 'Dropped pin');
      expect(nav.selectedIsPin, isTrue);
      expect(nav.selected!.formats.keys, containsAll(['decimal', 'dms']));
      expect(nav.selected!.formats.containsKey('usng'), isFalse);
      await done;
      expect(nav.selected!.formats['usng'], '11T NK 12345 67890');
      expect(nav.selected!.formats['plus_code'], '85M9G8VC+MM');
      expect(nav.selected!.formats['dms'], contains('N'));
      expect(nav.selected!.address, '3.2 mi NE of Boise, ID');
      expect(nav.selected!.name, 'Dropped pin');
    });

    test('a pin still works when the core cannot answer', () async {
      backend.onSearch = (q, {near, meaning}) async => throw const CacheSearchException('not_configured', 'x');
      await nav.dropPin(43.6, -116.2);
      expect(nav.selected!.formats.keys, ['decimal', 'dms']);
    });

    test('distance is from the phone; clearing needs the map, not a route', () async {
      location.publish(fixAt(42.5, -113.8));
      final p = place('place:1', 'Far', lat: 42.5, lon: -113.5);
      nav.select(p);
      expect(nav.distanceFromHere(p)!, closeTo(24600, 800));
      nav.clearSelection();
      expect(nav.selected, isNull);
    });

    test('Save place saves it; Add to Home sends the stub event; an old core says it cannot', () async {
      final p = place('place:1', 'Walgreens', kind: 'Pharmacy');
      await nav.savePlace(p);
      await settle(5);
      expect(backend.saved.single.$1, 'Walgreens');
      expect(events.whereType<PlaceSaved>().single.place.id, 'place:1');
      nav.addToHome(p);
      await settle(5);
      expect(events.whereType<AddToHomeRequested>().single.place.name, 'Walgreens');
      backend.saveFails = true;
      await nav.savePlace(p);
      await settle(5);
      expect((events.last as NavNotice).text, contains('not available'));
    });
  });

  group('directions', () {
    test('routes come from the phone to the place, with their alternatives', () async {
      location.publish(fixAt(42.5, -113.8));
      final alt = fakeRouteJson(id: 'r2', alt: 1);
      backend.onRoute = (to, mode, from) async => MapRoute.fromJson({...routeJson, 'alternatives': [alt]});
      await nav.openDirections(place('place:4', 'Cassia Regional Hospital'));
      expect(nav.phase, NavPhase.previewing);
      expect(nav.routes.map((r) => r.routeId), ['r1', 'r2']);
      expect(nav.route!.routeId, 'r1');
      nav.selectRoute(1);
      expect(nav.route!.routeId, 'r2');
      nav.selectRoute(7);
      expect(nav.route!.routeId, 'r2');
      expect(backend.calls.single, 'route:drive:Cassia Regional Hospital:from');
    });

    test('changing the way of travel asks again', () async {
      location.publish(fixAt(42.5, -113.8));
      backend.onRoute = (to, mode, from) async => MapRoute.fromJson(fakeRouteJson(id: 'r-$mode', mode: mode));
      await nav.openDirections(place('place:4', 'Cassia Regional Hospital'));
      await nav.setMode('walk');
      await nav.setMode('bike');
      expect(nav.route!.routeId, 'r-bike');
      expect(backend.calls, ['route:drive:Cassia Regional Hospital:from', 'route:walk:Cassia Regional Hospital:from', 'route:bike:Cassia Regional Hospital:from']);
      await nav.setMode('bike');
      expect(backend.calls.length, 3);
    });

    test('no position is said plainly; a route that cannot be made is explained', () async {
      await nav.openDirections(place('place:4', 'Far'));
      expect(nav.routeError, contains('position is not known'));
      expect(nav.routes, isEmpty);
      location.publish(fixAt(42.5, -113.8));
      backend.onRoute = (to, mode, from) async => MapRoute.fromJson({
            'ok': false, 'route_id': 'x', 'mode': 'drive', 'errors': [{'code': 'no_route', 'message': 'No route found'}],
          });
      await nav.setMode('walk');
      await nav.openDirections(place('place:4', 'Far'));
      expect(nav.routeError, 'No way found between these places');
      backend.onRoute = (to, mode, from) async => throw const CacheSearchException('unsupported', 'x');
      await nav.openDirections(place('place:4', 'Far'));
      expect(nav.routeError, contains('not available in this build'));
    });

    test('an off-road route with no off-road data on the phone is flagged', () async {
      location.publish(fixAt(42.5, -113.8));
      backend.onRoute = (to, mode, from) async => MapRoute.fromJson({...routeJson, 'warnings': [{'code': 'offroad_unavailable', 'end': 'to', 'gap_m': 900}]});
      await nav.openDirections(place('place:4', 'Far'));
      await settle(5);
      expect((events.last as NavNotice).text, contains('off the roads'));
    });

    test('backing out returns to the map with the place still chosen', () async {
      location.publish(fixAt(42.5, -113.8));
      backend.onRoute = (to, mode, from) async => MapRoute.fromJson(routeJson);
      await nav.openDirections(place('place:4', 'Far'));
      nav.cancelDirections();
      expect(nav.phase, NavPhase.browsing);
      expect(nav.selected!.name, 'Far');
      expect(nav.routes, isEmpty);
    });
  });

  group('guidance', () {
    Future<void> startOn(Map<String, dynamic> json) async {
      location.publish(fixAt(42.5, -113.8));
      backend.onRoute = (to, mode, from) async => MapRoute.fromJson(json);
      await nav.openDirections(place('place:4', 'Cassia Regional Hospital'));
      await nav.start();
    }

    MapProgress p(Map<String, dynamic> json, double f, {double offset = 0, bool off = false, int count = 0, bool arrived = false}) =>
        MapProgress.fromJson(fakeProgressJson(json, f, offset: offset, offRoute: off, offCount: count, arrived: arrived));

    test('Start turns the map to the heading, starts the position service with its notification, and speaks the opening', () async {
      await startOn(routeJson);
      expect(nav.phase, NavPhase.guiding);
      expect(follows, [FollowMode.headingUp]);
      expect(gps.starts, 1);
      expect(gps.title, 'Cassia Regional Hospital'.isEmpty ? '' : 'Cache navigation');
      expect(gps.text, contains('Cassia Regional Hospital'));
      backend.progressQueue.add(p(routeJson, 0.01));
      gps.controller.add(fixAt(42.5, -113.797, heading: 90));
      await settle();
      expect(nav.progress!.current.index, 0);
      expect(speaker.said.first, startsWith('Starting navigation to Cassia Regional Hospital.'));
      expect(speaker.said.first, contains('Drive east on Main Street.'));
      // the fix went on to the map's position
      expect(location.fix!.lon, -113.797);
    });

    test('each turn is announced as it comes, once per stage', () async {
      await startOn(routeJson);
      for (final f in [0.01, 0.2, 0.3, 0.31, 0.32, 0.325, 0.33]) {
        backend.progressQueue.add(p(routeJson, f));
        gps.controller.add(fixAt(42.5, -113.8 + 0.3 * f));
        await settle(15);
      }
      final turns = speaker.said.skip(1).toList();
      // total 24.6 km: the turn at 13/40 is 8 km along; the stages are 800, 300 and 90 m before it
      expect(turns.where((t) => t.contains('turn left onto Road 1')).length, greaterThanOrEqualTo(1));
      expect(turns.toSet().length, turns.length, reason: 'nothing is said twice');
    });

    test('the voice can be switched off and on; End stops the speech', () async {
      await startOn(routeJson);
      nav.toggleVoice();
      expect(nav.voiceOn, isFalse);
      expect(speaker.stops, 1);
      backend.progressQueue.add(p(routeJson, 0.01));
      gps.controller.add(fixAt(42.5, -113.799));
      await settle();
      expect(speaker.said, isEmpty);
      nav.toggleVoice();
      expect(nav.voiceOn, isTrue);
    });

    test('leaving the route for a few fixes asks for a new one from the fix, once, and says so', () async {
      await startOn(routeJson);
      backend.progressQueue.add(p(routeJson, 0.1));
      gps.controller.add(fixAt(42.5, -113.77));
      await settle();
      final newRoute = fakeRouteJson(id: 'r-new');
      backend.onRoute = (to, mode, from) async => MapRoute.fromJson(newRoute);
      backend.progressQueue.add(p(routeJson, 0.12, offset: 200, off: true, count: 3));
      gps.controller.add(fixAt(42.51, -113.76));
      await settle(60);
      expect(speaker.said, contains('Rerouting.'));
      expect(nav.route!.routeId, 'r-new');
      expect(nav.rerouting, isFalse);
      expect(backend.calls.where((c) => c.startsWith('route:')).length, 2);
      // the new route is sent whole to the core with the next fix
      backend.onProgress = (r, lat, lon) async => p(newRoute, 0.0);
      gps.controller.add(fixAt(42.51, -113.76));
      await settle();
      expect(backend.calls.last, 'progress:send');
      expect(nav.progress!.routeId, 'r-new');
    });

    test('a second off-route answer inside the cooldown does not reroute again', () async {
      await startOn(routeJson);
      backend.onRoute = (to, mode, from) async => MapRoute.fromJson(fakeRouteJson(id: 'r-new'));
      backend.onProgress = (r, lat, lon) async => p(routeJson, 0.12, offset: 200, off: true, count: 4);
      gps.controller.add(fixAt(42.51, -113.76));
      await settle(40);
      // the new route is also "off" in this stand-in core
      gps.controller.add(fixAt(42.512, -113.76));
      await settle(40);
      expect(backend.calls.where((c) => c.startsWith('route:')).length, 2, reason: 'one to preview, one reroute');
      now = now.add(const Duration(seconds: 20));
      gps.controller.add(fixAt(42.513, -113.76));
      await settle(40);
      expect(backend.calls.where((c) => c.startsWith('route:')).length, 3);
    });

    test('arriving says so, shows it, and Done clears the place', () async {
      await startOn(routeJson);
      backend.progressQueue.add(p(routeJson, 1.0, arrived: true));
      gps.controller.add(fixAt(42.5, -113.5));
      await settle();
      expect(nav.arrived, isTrue);
      expect(speaker.said.last, 'You have arrived at Cassia Regional Hospital.');
      await nav.finish();
      expect(nav.phase, NavPhase.browsing);
      expect(nav.selected, isNull);
      expect(gps.stops, greaterThanOrEqualTo(1));
      expect(follows.last, FollowMode.follow);
    });

    test('End stops the position service and the voice and leaves the place selected', () async {
      await startOn(routeJson);
      await nav.end();
      expect(nav.phase, NavPhase.browsing);
      expect(nav.selected!.name, 'Cassia Regional Hospital');
      expect(gps.stops, 1);
      expect(speaker.stops, 1);
      // fixes after the end are ignored
      final before = backend.calls.where((c) => c.startsWith('progress')).length;
      gps.controller.add(fixAt(42.5, -113.7));
      await settle();
      expect(backend.calls.where((c) => c.startsWith('progress')).length, before);
    });

    test('fixes that come while the core is busy are not queued up: the newest one is used', () async {
      await startOn(routeJson);
      final gate = Completer<void>();
      final seen = <double>[];
      backend.onProgress = (r, lat, lon) async {
        seen.add(lon);
        if (seen.length == 1) await gate.future;
        return p(routeJson, 0.1);
      };
      gps.controller.add(fixAt(42.5, -113.79));
      await settle(10);
      gps.controller.add(fixAt(42.5, -113.78));
      gps.controller.add(fixAt(42.5, -113.77));
      gps.controller.add(fixAt(42.5, -113.76));
      await settle(10);
      gate.complete();
      await settle(40);
      expect(seen, [-113.79, -113.76]);
    });

    test('a core that lost the route is sent it again', () async {
      await startOn(routeJson);
      var calls = 0;
      backend.onProgress = (r, lat, lon) async {
        calls++;
        if (calls == 2) throw const CacheSearchException('not_found', 'no route');
        return p(routeJson, 0.1);
      };
      gps.controller.add(fixAt(42.5, -113.79));
      await settle(20);
      gps.controller.add(fixAt(42.5, -113.78));
      await settle(20);
      gps.controller.add(fixAt(42.5, -113.77));
      await settle(20);
      // (the first call is the one Start makes with the fix it already has; the stand-in had no answer for it)
      expect(backend.calls.where((c) => c.startsWith('progress')).toList().skip(1), ['progress:send', 'progress:id', 'progress:send']);
    });

    test('an off-road leg is announced when it begins, with the way to head', () async {
      final off = fakeRouteJson(offroad: true);
      await startOn(off);
      for (final f in [0.05, 0.6, 0.76, 0.8]) {
        backend.progressQueue.add(p(off, f));
        gps.controller.add(fixAt(42.5, -113.8 + 0.3 * f));
        await settle(15);
      }
      expect(speaker.said.any((s) => s.toLowerCase().contains('leave the road and head east')), isTrue, reason: speaker.said.join(' | '));
      expect(speaker.said.any((s) => s.contains('climbing')), isTrue);
    });
  });
}
