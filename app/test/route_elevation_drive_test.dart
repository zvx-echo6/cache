// The elevation of the route being driven is read once for the whole route, kept across progress updates and maneuvers, and on a
// re-route the profile on screen stays until the new route's is ready (it never goes back to the reading state once there is
// something to show). RouteElevation.request(following: true), the drive screen, the phone's dock and the car's climb card all read
// the one RouteElevation.

import 'dart:async';

import 'package:cache/car/car_trip.dart';
import 'package:cache/nav/elevation/elevation_profile.dart';
import 'package:cache/nav/elevation/route_elevation.dart';
import 'package:cache_search/cache_search.dart' show MapRoute;
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'support/drive_rig.dart';

/// Jobs by hand: the test finishes each one, and each says when it was stopped.
class _Jobs {
  final List<String> started = [];
  final List<String> stopped = [];
  final Map<String, Completer<ElevationProfile>> _results = {};

  ElevationJob start(MapRoute route) {
    final id = route.routeId;
    started.add(id);
    final result = _results[id] = Completer<ElevationProfile>();
    return ElevationJob(result.future, onStop: () => stopped.add(id));
  }

  void finish(String id, ElevationProfile p) => _results[id]!.complete(p);
}

ElevationProfile _profile(double total, {double base = 1000}) {
  final d = [for (var x = 0.0; x <= total; x += kProfileStepM) x];
  return ElevationProfile.fromSamples(d, [for (final x in d) base + x / 100], totalM: total);
}

MapRoute _route(String id) => MapRoute.fromJson(fakeRouteJson(id: id));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RouteElevation while following a route', () {
    test('a re-route keeps the profile on screen until the new route\'s is ready, then swaps', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      final changes = <ElevationProfile?>[];
      el.addListener(() => changes.add(el.profile));
      el.request(_route('a'), following: true);
      expect(el.profile, isNull);
      expect(el.loading, isTrue, reason: 'nothing to show yet: the reading state');
      final pa = _profile(1000);
      jobs.finish('a', pa);
      await pumpEventQueue();
      expect(el.profile, same(pa));
      changes.clear();

      el.request(_route('b'), following: true);
      expect(el.profile, same(pa), reason: 'the old profile stays');
      expect(el.stale, isTrue);
      expect(el.loading, isTrue);
      expect(jobs.started, ['a', 'b']);
      expect(jobs.stopped, isEmpty);
      expect(changes, everyElement(isNotNull), reason: 'it never goes back to nothing');

      final pb = _profile(2000);
      jobs.finish('b', pb);
      await pumpEventQueue();
      expect(el.profile, same(pb));
      expect(el.stale, isFalse);
      expect(el.loading, isFalse);
      expect(changes, everyElement(isNotNull));
    });

    test('the same route again (progress updates, maneuvers) never restarts the read', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      final r = _route('a');
      for (var i = 0; i < 20; i++) {
        el.request(r, following: true);
      }
      jobs.finish('a', _profile(1000));
      await pumpEventQueue();
      for (var i = 0; i < 20; i++) {
        el.request(_route('a'), following: true);
      }
      expect(jobs.started, ['a']);
      expect(el.loading, isFalse);
    });

    test('a re-route before the first read is done does not stop it; it is shown (stale) when done and the new one is read next', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      el.request(_route('a'), following: true);
      el.request(_route('b'), following: true);
      expect(jobs.stopped, isEmpty, reason: 'the running read is not thrown away');
      expect(jobs.started, ['a']);
      expect(el.profile, isNull);
      final pa = _profile(1000);
      jobs.finish('a', pa);
      await pumpEventQueue();
      expect(el.profile, same(pa));
      expect(el.stale, isTrue);
      expect(jobs.started, ['a', 'b']);
      final pb = _profile(900);
      jobs.finish('b', pb);
      await pumpEventQueue();
      expect(el.profile, same(pb));
      expect(el.stale, isFalse);
    });

    test('only the newest route is read after the running one', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      el.request(_route('a'), following: true);
      for (final id in ['b', 'c', 'd']) {
        el.request(_route(id), following: true);
      }
      jobs.finish('a', _profile(1000));
      await pumpEventQueue();
      expect(jobs.started, ['a', 'd']);
    });

    test('the position stays where it was on the old profile while the new one is read', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      el.request(_route('a'), following: true);
      jobs.finish('a', _profile(10000));
      await pumpEventQueue();
      final before = el.positionOnProfile(4000, 10000);
      expect(before, closeTo(4000, 1));
      el.request(_route('b'), following: true);
      // The new route's own metres along (it starts here) do not move the marker on the old profile.
      expect(el.positionOnProfile(50, 6000), before);
      jobs.finish('b', _profile(6000));
      await pumpEventQueue();
      expect(el.positionOnProfile(50, 6000), closeTo(50, 1));
    });

    test('a read that finds no data does not take the place of a profile that has data', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      el.request(_route('a'), following: true);
      final pa = _profile(1000);
      jobs.finish('a', pa);
      await pumpEventQueue();
      el.request(_route('b'), following: true);
      jobs.finish('b', ElevationProfile.none(900));
      await pumpEventQueue();
      expect(el.profile, same(pa));
      expect(el.loading, isFalse);
    });

    test('guidance ending drops it all and stops the job', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      el.request(_route('a'), following: true);
      el.request(null, following: true);
      expect(jobs.stopped, ['a']);
      expect(el.profile, isNull);
      expect(el.loading, isFalse);
    });

    test('not following (the preview): another route clears the profile and stops the other\'s job, as before', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      el.request(_route('a'));
      el.request(_route('b'));
      expect(jobs.stopped, ['a']);
      expect(el.profile, isNull);
    });
  });

  group('over a drive', () {
    late DriveRig rig;
    setUp(() async {
      rig = DriveRig();
      await rig.setUp();
    });
    tearDown(() => rig.tearDown());

    test('progress updates and maneuvers of a route with a stop read one profile, once', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      // What the Maps screen and the car bridge do on every change of guidance.
      rig.nav.addListener(() => el.request(rig.nav.route, following: rig.nav.guiding));
      await rig.guide(); // a route with a stop
      for (final (next, m) in [(1, 600.0), (1, 300.0), (2, 900.0), (3, 150.0), (4, 1200.0), (5, 500.0), (6, 100.0)]) {
        rig.at(next, m, stopsReached: next > 3 ? 1 : 0);
      }
      expect(jobs.started, ['drive1'], reason: 'one profile for the whole route, however many stops, turns and updates');
    });

    test('the car\'s climb card does not blink at a re-route', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      rig.nav.addListener(() => el.request(rig.nav.route, following: rig.nav.guiding));
      await rig.guide(withStop: false);
      rig.at(2, 640);
      jobs.finish('drive1', driveProfile());
      await pumpEventQueue();
      Map<String, dynamic> trip() => carTrip(
            rig.nav,
            elevation: el.profile,
            elevationAlong: el.carPosition(rig.nav.progress!.distanceAlongM, rig.nav.route!.distanceM),
          );
      final before = trip()['climb'] as Map?;
      expect(before, isNotNull);

      // A re-route: a new route from here, whose metres along start at zero.
      rig.route = driveRouteJson(withStop: false, id: 'drive2');
      rig.nav.routes = [MapRoute.fromJson(rig.route)];
      rig.at(1, 300);
      expect(el.stale, isTrue);
      final during = trip()['climb'] as Map?;
      expect(during, isNotNull, reason: 'the climb card stays while the new profile is read');
      expect((during!['steepestInM'] as double), closeTo(before!['steepestInM'] as double, 100));
      expect(trip()['overview'], isNotNull);

      jobs.finish('drive2', driveProfile());
      await pumpEventQueue();
      expect(el.stale, isFalse);
      expect(trip()['climb'], isNotNull);
    });
  });
}
