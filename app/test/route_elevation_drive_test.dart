// The elevation of the route being driven is read once, in chunks, the part nearest the driver first; each chunk is drawn as it
// arrives; nothing says "reading" during a drive; a re-route keeps the chart and the new route's chunks replace it from the driver
// outward; and the climb ahead is given from partial data and kept steady while more arrives.

import 'dart:async';

import 'package:cache/car/car_trip.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/nav/elevation/elevation_profile.dart';
import 'package:cache/nav/elevation/route_elevation.dart';
import 'package:cache/nav/elevation/route_sampler.dart';
import 'package:cache/nav/ui/drive_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart' show MapRoute;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'support/drive_rig.dart';

/// Jobs by hand: the test sends each job's chunks and finishes it, and each says when it was stopped.
class _Jobs {
  final List<String> started = [];
  final List<String> stopped = [];
  final Map<String, Completer<ElevationProfile>> _results = {};
  final Map<String, StreamController<ElevationChunk>> _chunks = {};

  ElevationJob start(MapRoute route) {
    final id = route.routeId;
    started.add(id);
    final result = _results[id] = Completer<ElevationProfile>();
    final chunks = _chunks[id] = StreamController<ElevationChunk>();
    return ElevationJob(result.future, chunks: chunks.stream, onStop: () => stopped.add(id));
  }

  void chunk(String id, int first, List<double> heights) => _chunks[id]!.add((first: first, heights: heights));

  void finish(String id, ElevationProfile p) {
    _results[id]!.complete(p);
    unawaited(_chunks[id]!.close());
  }
}

MapRoute _route(String id) => MapRoute.fromJson(fakeRouteJson(id: id));

/// The samples of [r] as the isolate and RouteElevation walk it.
List<RouteSample> _samples(MapRoute r) => resampleRoute([for (final p in r.points) (p.lat, p.lon)]);

ElevationProfile _whole(MapRoute r, List<double> heights) {
  final s = _samples(r);
  return ElevationProfile.fromSamples([for (final x in s) x.distM], heights, totalM: s.last.distM);
}

/// Heights for samples [from, to): a ramp (rising [perSample] metres each) from [start].
List<double> _ramp(int from, int to, double start, double perSample) => [for (var i = from; i < to; i++) start + (i - from) * perSample];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RouteElevation reads in chunks', () {
    test('each chunk is drawn as it arrives, in the order it comes, and the read ends with the whole profile', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      final r = _route('a');
      final n = _samples(r).length;
      expect(n, greaterThan(400));
      final seen = <double>[];
      el.addListener(() => seen.add(el.profile?.coveredM ?? 0));
      el.request(r, following: true);
      expect(el.profile, isNull, reason: 'nothing read yet');
      expect(el.loading, isTrue);

      jobs.chunk('a', 0, _ramp(0, 100, 1000, 0.5));
      await pumpEventQueue();
      final p1 = el.profile!;
      expect(p1.hasData, isTrue);
      expect(p1.elevationAt(_samples(r)[50].distM), isNotNull, reason: 'the first chunk is drawn');
      expect(p1.elevationAt(_samples(r)[300].distM), isNull, reason: 'the rest is not read yet');
      expect(el.loading, isTrue);

      jobs.chunk('a', 100, _ramp(100, 200, 1050, 0.5));
      await pumpEventQueue();
      expect(el.profile!.coveredM, greaterThan(p1.coveredM), reason: 'the chart grows along the route');
      expect(el.profile!.elevationAt(_samples(r)[150].distM), isNotNull);
      expect(seen, orderedEquals([...seen]..sort()), reason: 'it only ever grows while it is read');

      final whole = _whole(r, _ramp(0, n, 1000, 0.5));
      jobs.finish('a', whole);
      await pumpEventQueue();
      expect(el.profile, same(whole));
      expect(el.loading, isFalse);
      expect(jobs.started, ['a']);
    });

    test('chunks of a route that was replaced are ignored, and its read is stopped (one read at a time)', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      el.request(_route('a'), following: true);
      el.request(_route('b'), following: true);
      expect(jobs.stopped, ['a']);
      expect(jobs.started, ['a', 'b']);
    });

    test('the same route again (progress updates, maneuvers) never restarts the read', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      for (var i = 0; i < 20; i++) {
        el.request(_route('a'), following: true);
      }
      expect(jobs.started, ['a']);
    });

    test('a re-route keeps the chart: the road ahead is carried to the new route and the new chunks replace it from the driver outward', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      final a = _route('a');
      final n = _samples(a).length;
      el.request(a, following: true);
      final pa = _whole(a, _ramp(0, n, 1000, 1)); // rises 1 m a sample: 25 m per km
      jobs.finish('a', pa);
      await pumpEventQueue();
      final total = pa.totalM;
      expect(el.positionOnProfile(4000, total), closeTo(4000, 1));

      final changes = <bool>[];
      el.addListener(() => changes.add(el.profile != null && el.profile!.hasData));
      el.request(_route('b'), following: true);
      final seeded = el.profile;
      expect(seeded, isNotNull, reason: 'never a blank');
      expect(seeded!.hasData, isTrue);
      expect(el.loading, isTrue);
      // The new route starts where the driver was (4000 m on the old): its first height is the old one there.
      expect(seeded.elevationAt(0)!, closeTo(pa.elevationAt(4000)!, 1.5));
      final sb = _samples(_route('b'));
      expect(seeded.elevationAt(sb[300].distM)!, closeTo(pa.elevationAt(4000 + sb[300].distM)!, 1.5));

      // The new route's chunk replaces it from the driver outward.
      jobs.chunk('b', 0, _ramp(0, 100, 3000, 0));
      await pumpEventQueue();
      expect(el.profile!.elevationAt(sb[50].distM)!, closeTo(3000, 1), reason: 'replaced where the new chunk is');
      expect(el.profile!.elevationAt(sb[300].distM)!, closeTo(pa.elevationAt(4000 + sb[300].distM)!, 1.5), reason: 'the rest is still the carried chart');
      expect(changes, everyElement(isTrue), reason: 'never a blank in between');
    });

    test('a re-route in the middle of a read carries what was read, and stops that read', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      el.request(_route('a'), following: true);
      jobs.chunk('a', 0, _ramp(0, 100, 1000, 0.5));
      await pumpEventQueue();
      expect(el.positionOnProfile(0, 24000), 0);
      el.request(_route('b'), following: true);
      expect(jobs.stopped, ['a']);
      expect(el.profile, isNotNull, reason: 'what was read is carried');
      expect(el.profile!.hasData, isTrue);
    });

    test('a read that finds no data does not take the place of what a re-route carried over', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      final a = _route('a');
      el.request(a, following: true);
      final pa = _whole(a, _ramp(0, _samples(a).length, 1000, 1));
      jobs.finish('a', pa);
      await pumpEventQueue();
      el.request(_route('b'), following: true);
      jobs.finish('b', ElevationProfile.none(900));
      await pumpEventQueue();
      expect(el.profile!.hasData, isTrue);
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
      final a = _route('a');
      el.request(a);
      jobs.finish('a', _whole(a, _ramp(0, _samples(a).length, 1000, 1)));
      await pumpEventQueue();
      el.request(_route('b'));
      expect(el.profile, isNull);
      expect(el.loading, isTrue);
    });
  });

  group('the climb ahead from partial data', () {
    late _Jobs jobs;
    late RouteElevation el;
    late MapRoute r;
    late int n;
    setUp(() {
      jobs = _Jobs();
      el = RouteElevation(start: jobs.start);
      r = _route('a');
      n = _samples(r).length;
      el.request(r, following: true);
    });
    tearDown(() => el.dispose());

    /// Heights for samples [from, to) that are flat at [base] but for a climb of [perSample] metres a sample over samples
    /// [c0, c1), which then stays up.
    List<double> climb(int from, int to, double base, int c0, int c1, double perSample) =>
        [for (var i = from; i < to; i++) base + (i < c0 ? 0 : (i < c1 ? i - c0 : c1 - c0)) * perSample];

    test('the climb is given as soon as the chunks read contain one that qualifies, and a clearly steeper later one corrects it', () async {
      expect(el.climbAhead(0), isNull, reason: 'nothing read');
      jobs.chunk('a', 0, climb(0, 100, 1000, 20, 40, 2)); // 2 m a sample over 40 m: 5 %
      await pumpEventQueue();
      final first = el.climbAhead(0);
      expect(first, isNotNull, reason: 'given from the partial data');
      expect(first!.grade, closeTo(0.05, 0.02));

      jobs.chunk('a', 100, climb(100, 200, 1040, 120, 140, 4)); // 10 %
      await pumpEventQueue();
      final second = el.climbAhead(0)!;
      expect(second.grade, greaterThan(first.grade * 1.5), reason: 'corrected by a clearly steeper climb');
      expect(second.startM, greaterThan(first.startM));
    });

    test('it does not jump about: a climb that is only a little steeper does not replace the one shown, until the read is done', () async {
      jobs.chunk('a', 0, climb(0, 100, 1000, 20, 40, 4)); // 10 %
      await pumpEventQueue();
      final shown = el.climbAhead(0)!;
      jobs.chunk('a', 100, climb(100, 200, 1080, 120, 140, 4.2)); // 10.5 %: not clearly steeper
      await pumpEventQueue();
      final still = el.climbAhead(0)!;
      expect(still.startM, shown.startM, reason: 'the climb shown is kept');
      // The read is done: the whole route's answer.
      final h = [...climb(0, 100, 1000, 20, 40, 4), ...climb(100, 200, 1080, 120, 140, 4.2), ..._ramp(200, n, 1080 + 84, 0).map((x) => x)];
      jobs.finish('a', _whole(r, h));
      await pumpEventQueue();
      final done = el.climbAhead(0)!;
      expect(done.startM, greaterThan(shown.startM), reason: 'the final answer is the steepest of the whole route');
    });

    test('a climb that is behind the position is not kept', () async {
      jobs.chunk('a', 0, climb(0, 100, 1000, 20, 40, 3));
      await pumpEventQueue();
      final c = el.climbAhead(0)!;
      expect(el.climbAhead(c.endM + 200), isNull);
    });
  });

  group('on screen', () {
    late DriveRig rig;
    setUp(() async {
      rig = DriveRig();
      await rig.setUp();
    });
    tearDown(() => rig.tearDown());

    Future<void> pump(WidgetTester tester, RouteElevation el) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.dark),
        home: Scaffold(body: SizedBox(width: 300, height: 240, child: ListenableBuilder(listenable: el, builder: (context, _) => DriveElevation(nav: rig.nav, elevation: el, palette: mapPaletteFor(CacheThemeId.dark))))),
      ));
      await tester.pump();
    }

    testWidgets('during a drive there is never a reading line or a spinner: first the frame, then the chart growing, then the whole', (tester) async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      await tester.runAsync(() => rig.guide(withStop: false));
      rig.at(2, 640);
      el.request(rig.nav.route, following: true);
      await pump(tester, el);
      expect(find.textContaining('Reading'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byKey(const ValueKey('elevation-frame')), findsOneWidget, reason: 'the frame, before the first chunk');
      expect(find.text('No elevation data for this route.'), findsNothing);

      final s = _samples(rig.nav.route!);
      jobs.chunk('drive1', 0, _ramp(0, 100, 1000, 0.5));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
      expect(find.byKey(const ValueKey('elevation-chart')), findsOneWidget, reason: 'the first chunk is drawn');
      expect(find.byKey(const ValueKey('elevation-frame')), findsNothing);
      expect(find.textContaining('Reading'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      jobs.finish('drive1', _whole(rig.nav.route!, _ramp(0, s.length, 1000, 0.5)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
      expect(find.byKey(const ValueKey('elevation-chart')), findsOneWidget);
    });

    testWidgets('the line for a route with no elevation data comes only once the read has finished and found none', (tester) async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      await tester.runAsync(() => rig.guide(withStop: false));
      rig.at(2, 640);
      el.request(rig.nav.route, following: true);
      await pump(tester, el);
      expect(find.text('No elevation data for this route.'), findsNothing);
      jobs.finish('drive1', ElevationProfile.none(24600));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
      expect(find.text('No elevation data for this route.'), findsOneWidget);
    });

    testWidgets('the car\'s climb card does not blink at a re-route', (tester) async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      await tester.runAsync(() => rig.guide(withStop: false));
      el.request(rig.nav.route, following: true);
      rig.at(2, 640);
      jobs.finish('drive1', driveProfile());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      Map<String, dynamic> trip() {
        // What the car bridge does for each trip.
        final p = rig.nav.progress!;
        el.positionOnProfile(p.distanceAlongM, rig.nav.route!.distanceM);
        return carTrip(rig.nav, elevation: el.profile, climbAhead: el.climbAhead);
      }

      final before = trip()['climb'] as Map?;
      expect(before, isNotNull);

      // A re-route: a new route from here, whose metres along start at zero.
      rig.route = driveRouteJson(withStop: false, id: 'drive2');
      rig.nav.routes = [MapRoute.fromJson(rig.route)];
      el.request(rig.nav.route, following: true);
      rig.at(1, (rig.route['distance_m'] as num).toDouble() * 4 / 40);
      final during = trip()['climb'] as Map?;
      expect(during, isNotNull, reason: 'the climb card stays while the new route is read');
      expect(during!['steepestInM'] as double, closeTo(before!['steepestInM'] as double, 150));
      expect(trip()['overview'], isNotNull);
    });
  });
}
