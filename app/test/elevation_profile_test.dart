import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cache/nav/elevation/elevation_profile.dart';
import 'package:cache/nav/elevation/route_elevation.dart';
import 'package:cache/nav/elevation/route_sampler.dart';
import 'package:cache_search/cache_search.dart' show MapRoute;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'nav_fakes.dart';

/// The synthetic route: 8 km in straight stretches of known grade (metres along, height).
///   0-1000 flat at 1000 m; 1000-3000 up 3%; 3000-3800 up 9%; 3800-4800 flat; 4800-6300 down 6%; 6300-6800 up 5%; 6800-8000 flat.
/// True climb 60 + 72 + 25 = 157 m, true descent 90 m, highest 1132 m (3800-4800), lowest 1000 m (0-1000).
const _corners = [(0.0, 1000.0), (1000.0, 1000.0), (3000.0, 1060.0), (3800.0, 1132.0), (4800.0, 1132.0), (6300.0, 1042.0), (6800.0, 1067.0), (8000.0, 1067.0)];

double _truth(double d) {
  for (var i = 1; i < _corners.length; i++) {
    final (a, ea) = _corners[i - 1];
    final (b, eb) = _corners[i];
    if (d <= b) return ea + (eb - ea) * (d - a) / (b - a);
  }
  return _corners.last.$2;
}

/// Samples every 40 m with noise of up to [noise] metres either way (fixed seed), as tiles give: small steps and pixel noise.
(List<double>, List<double>) _samples({double noise = 2.0, bool Function(double d)? missing}) {
  final r = math.Random(7);
  final d = <double>[], e = <double>[];
  for (var x = 0.0; x <= 8000; x += kProfileStepM) {
    d.add(x);
    e.add(missing != null && missing(x) ? double.nan : _truth(x) + (r.nextDouble() * 2 - 1) * noise);
  }
  return (d, e);
}

void main() {
  group('smoothing and totals', () {
    test('climb and descent come out near the truth, not inflated by the noise', () {
      final (d, e) = _samples();
      final p = ElevationProfile.fromSamples(d, e);
      expect(p.hasData, isTrue);
      expect(p.partial, isFalse);
      expect(p.climbM, closeTo(157, 157 * 0.05));
      expect(p.descentM, closeTo(90, 90 * 0.05));
      // The same noisy heights summed step by step (no smoothing, no dead band) add a lot of false climb.
      var rawUp = 0.0;
      for (var i = 1; i < e.length; i++) {
        rawUp += math.max(0, e[i] - e[i - 1]);
      }
      expect(rawUp, greaterThan(157 * 1.25));
    });

    test('smoothing keeps a flat profile flat and leaves no false climb', () {
      final d = [for (var x = 0.0; x <= 4000; x += 40) x];
      final r = math.Random(3);
      final e = [for (final _ in d) 500 + (r.nextDouble() * 2 - 1) * 2.5];
      final p = ElevationProfile.fromSamples(d, e);
      expect(p.climbM, lessThan(5));
      expect(p.descentM, lessThan(5));
      expect(p.climbs, isEmpty);
    });

    test('smoothing does not pull the ends of a stretch towards a gap', () {
      final d = [for (var x = 0.0; x <= 1000; x += 40) x];
      final e = [for (final x in d) x < 400 ? 800.0 : (x < 600 ? double.nan : 900.0)];
      final s = smoothProfile(d, e);
      expect(s[0], closeTo(800, 1e-9));
      expect(s[9], closeTo(800, 1e-9)); // 360 m, next to the gap
      expect(s[10].isNaN, isTrue);
      expect(s[15], closeTo(900, 1e-9)); // 600 m, the other side
    });

    test('the dead band counts a steady climb in full', () {
      final t = climbAndDescent([for (var i = 0; i <= 100; i++) 100 + i * 0.5]);
      expect(t.climb, closeTo(50, 1e-9));
      expect(t.descent, 0);
    });
  });

  group('highest, lowest and the steepest climb', () {
    test('highest and lowest points and their places', () {
      final (d, e) = _samples();
      final p = ElevationProfile.fromSamples(d, e);
      expect(p.highest!.elevM, closeTo(1132, 3));
      expect(p.highest!.distM, inInclusiveRange(3700, 4900));
      expect(p.lowest!.elevM, closeTo(1000, 3));
      expect(p.lowest!.distM, inInclusiveRange(0, 1100));
    });

    test('the steepest climb ahead of the start is the 9% stretch', () {
      final (d, e) = _samples();
      final p = ElevationProfile.fromSamples(d, e);
      final c = p.steepestClimbAhead(0)!;
      // Smoothing rounds the corners of a stretch, so its grade reads a little under the true 9%.
      expect(c.grade, inInclusiveRange(0.07, 0.095));
      expect(c.startM, inInclusiveRange(2800, 3200));
      expect(c.lengthM, inInclusiveRange(600, 950));
    });

    test('on the climb, it counts from the position', () {
      final (d, e) = _samples();
      final p = ElevationProfile.fromSamples(d, e);
      final c = p.steepestClimbAhead(3300)!;
      expect(c.startM, 3300);
      expect(c.grade, inInclusiveRange(0.07, 0.095));
    });

    test('past the big climbs, the next one is the 5% stretch', () {
      final (d, e) = _samples();
      final p = ElevationProfile.fromSamples(d, e);
      final c = p.steepestClimbAhead(4500)!;
      // A short stretch (500 m) loses more of its grade to the rounded corners.
      expect(c.grade, inInclusiveRange(0.035, 0.06));
      expect(c.startM, inInclusiveRange(6200, 6450));
    });

    test('no climb is left after the last one', () {
      final (d, e) = _samples();
      expect(ElevationProfile.fromSamples(d, e).steepestClimbAhead(7000), isNull);
    });
  });

  group('no data and partial data', () {
    test('a route with no elevation anywhere has no data and no numbers', () {
      final d = [for (var x = 0.0; x <= 2000; x += 40) x];
      final p = ElevationProfile.fromSamples(d, [for (final _ in d) double.nan]);
      expect(p.hasData, isFalse);
      expect(p.partial, isFalse);
      expect(p.climbM, 0);
      expect(p.highest, isNull);
      expect(p.steepestClimbAhead(0), isNull);
      expect(ElevationProfile.none(1500).hasData, isFalse);
    });

    test('a gap is left out of the totals and reported as missing', () {
      final (d, e) = _samples(missing: (x) => x > 2000 && x < 2600);
      final p = ElevationProfile.fromSamples(d, e);
      expect(p.hasData, isTrue);
      expect(p.partial, isTrue);
      expect(p.runs.length, 2);
      expect(p.missingM, closeTo(600, 60));
      // 600 m of the 3% climb (18 m) has no data; the rest is counted, never bridged across the gap.
      expect(p.climbM, closeTo(157 - 18, 10));
      expect(p.descentM, closeTo(90, 6));
    });
  });

  group('sampling the route from Terrarium tiles', () {
    test('the route is walked every 40 m, both ends included', () {
      final pts = [(42.5, -114.0), (42.5, -113.99), (42.51, -113.99)];
      final s = resampleRoute(pts);
      final total = haversineM(42.5, -114.0, 42.5, -113.99) + haversineM(42.5, -113.99, 42.51, -113.99);
      expect(s.first.distM, 0);
      expect(s.last.distM, closeTo(total, 1e-6));
      for (var i = 1; i < s.length - 1; i++) {
        expect(s[i].distM - s[i - 1].distM, closeTo(40, 1e-6));
        // Each point lies on the route where its distance says.
        final along = s[i].distM;
        final first = haversineM(42.5, -114.0, 42.5, -113.99);
        if (along < first) {
          expect(s[i].lat, closeTo(42.5, 1e-9));
        } else {
          expect(s[i].lon, closeTo(-113.99, 1e-9));
        }
      }
    });

    test('heights are read bilinearly across tile edges, and missing tiles give no data', () async {
      const zoom = 12, size = 256;
      // A plane: each pixel column is half a metre higher than the one west of it (pixel centres), from 1000 m at column 192000
      // (the west edge of tile x=750), so the heights stay inside what Terrarium allows.
      double heightAtPixel(double gx) => 1000 + 0.5 * (gx - 192000);
      final tiles = _PlaneTiles(size: size, heightAtColumn: (gx) => heightAtPixel(gx.toDouble()), missingX: {});
      // Across the edge between tiles x=749 and x=750 (lon about -114.17).
      final n = 1 << zoom;
      final edgeLon = 750 / n * 360 - 180;
      final pts = [for (var i = -5; i <= 5; i++) (lat: 42.55, lon: edgeLon + i * 0.0002, distM: 0.0)];
      final h = await sampleHeights(pts, tiles, zoom: zoom);
      for (var i = 0; i < pts.length; i++) {
        final fx = (pts[i].lon + 180) / 360 * n;
        expect(h[i], closeTo(heightAtPixel(fx * size - 0.5), 0.02), reason: 'point $i');
      }

      // Without the east tile, points whose pixels reach into it have no height.
      final half = _PlaneTiles(size: size, heightAtColumn: (gx) => heightAtPixel(gx.toDouble()), missingX: {750});
      final h2 = await sampleHeights(pts, half, zoom: zoom);
      expect(h2.first.isNaN, isFalse);
      expect(h2.last.isNaN, isTrue);
    });

    test('a route over tiles that are partly missing gives a partial profile', () async {
      const zoom = 12;
      final n = 1 << zoom;
      double lonOf(int x) => x / n * 360 - 180;
      final tiles = _PlaneTiles(size: 256, heightAtColumn: (gx) => 1200 + 0.1 * (gx - 192000), missingX: {751});
      final pts = [(42.55, lonOf(750) + 0.001), (42.55, lonOf(753) - 0.001)];
      final p = await buildRouteProfile(pts, tiles, zoom: zoom);
      expect(p.hasData, isTrue);
      expect(p.partial, isTrue);
      expect(p.runs.length, 2);
      final none = await buildRouteProfile(pts, _PlaneTiles(size: 256, heightAtColumn: (gx) => 0, missingX: {750, 751, 752, 753}), zoom: zoom);
      expect(none.hasData, isFalse);
    });
  });

  // Bug: a route's job kept every decoded tile it crossed until it ended (about 1 MB for each 7 km: hundreds of MB for a long
  // route). Only the tiles around the points being read are kept now; the numbers must be the same as before.
  group('the tiles kept while sampling', () {
    const zoom = 12, size = 256;
    const n = 1 << zoom;
    double lonOf(int x) => x / n * 360 - 180;

    test('the numbers are the same as when every tile of the route was held: the routes above', () async {
      // The points across the edge between two tiles, with every tile and with the east tile missing.
      double plane(int gx) => 1000 + 0.5 * (gx - 192000);
      final edge = [for (var i = -5; i <= 5; i++) (lat: 42.55, lon: lonOf(750) + i * 0.0002, distM: 0.0)];
      for (final missing in [<int>{}, {750}]) {
        final tiles = _PlaneTiles(size: size, heightAtColumn: plane, missingX: missing);
        _expectSame(await sampleHeights(edge, tiles, zoom: zoom), await _sampleHoldingEveryTile(edge, tiles, zoom: zoom), 'across the edge, missing $missing');
      }
      // The route over tiles that are partly missing, and over no tiles at all, as whole profiles.
      final pts = [(42.55, lonOf(750) + 0.001), (42.55, lonOf(753) - 0.001)];
      final partly = _PlaneTiles(size: size, heightAtColumn: (gx) => 1200 + 0.1 * (gx - 192000), missingX: {751});
      _expectSameProfile(await buildRouteProfile(pts, partly, zoom: zoom), await _profileHoldingEveryTile(pts, partly, zoom: zoom), 'partly missing');
      final none = _PlaneTiles(size: size, heightAtColumn: (gx) => 0, missingX: {750, 751, 752, 753});
      _expectSameProfile(await buildRouteProfile(pts, none, zoom: zoom), await _profileHoldingEveryTile(pts, none, zoom: zoom), 'no tiles');
    });

    test('a long route out and back with four tiles kept: tiles are dropped and read again, and the numbers are the same', () async {
      // Hills, not a plane, so a wrong tile or a wrong pixel would show; one column of tiles is not there.
      final hills = _PlaneTiles(size: size, heightAtColumn: (gx) => 1500 + 300 * math.sin(gx / 700), missingX: {755});
      // East over twelve tiles and across rows of tiles, and back the same way: about 180 km.
      final out = [(42.50, lonOf(748) + 0.001), (42.62, lonOf(754)), (42.50, lonOf(760) - 0.001)];
      final pts = [...out, ...out.reversed.skip(1)];
      final before = await _profileHoldingEveryTile(pts, hills, zoom: zoom);
      final counted = _CountingTiles(hills);
      final now = await buildRouteProfile(pts, counted, zoom: zoom, keep: 4);
      _expectSameProfile(now, before, 'out and back');
      expect(now.hasData, isTrue);
      expect(now.partial, isTrue, reason: 'the missing column');
      expect(now.distM.length, greaterThan(4000));
      // Tiles dropped on the way out were read again on the way back...
      expect(counted.asked.values.any((times) => times > 1), isTrue);
      // ...but a tile that was not there is asked for once, as before.
      final missing = [for (final e in counted.asked.entries) if (e.key.startsWith('755/')) e.value];
      expect(missing, isNotEmpty);
      expect(missing.every((times) => times == 1), isTrue);
    });

    test('however many tiles a route crosses, no more than the number kept are held', () async {
      final tiles = _CountingTiles(_PlaneTiles(size: size, heightAtColumn: (gx) => 1000, missingX: {}));
      final window = DemGridWindow(tiles, zoom, keep: 4);
      for (var x = 700; x < 740; x++) {
        expect(await window.grid(x, 1500), isNotNull);
        expect(window.held, lessThanOrEqualTo(4));
      }
      expect(window.mostHeld, 4);
      expect(tiles.total, 40);
      // The four used last are still held: asking for them reads nothing.
      for (var x = 736; x < 740; x++) {
        await window.grid(x, 1500);
      }
      expect(tiles.total, 40);
      // One dropped long ago is read again, and is the same tile.
      final again = await window.grid(700, 1500);
      expect(tiles.total, 41);
      expect(again!.at(0, 0), 1000);
      expect(window.held, 4);
      // Above and below the world there is no tile, and nothing is asked.
      expect(await window.grid(700, -1), isNull);
      expect(await window.grid(700, n), isNull);
      expect(tiles.total, 41);
    });

    test('eight are kept unless told otherwise: about 8 MB of 512 pixel tiles', () async {
      expect(kDemGridsKept, 8);
      final window = DemGridWindow(_PlaneTiles(size: size, heightAtColumn: (gx) => 1000, missingX: {}), zoom);
      for (var x = 700; x < 720; x++) {
        await window.grid(x, 1500);
      }
      expect(window.mostHeld, 8);
    });
  });

  // Bug: the job of a route that had been replaced or dropped ran on to its end (minutes of one core for a long route), and a
  // route that kept being replaced left one job running for every route it had been.
  group('the job of the route shown', () {
    MapRoute route(String id) => MapRoute.fromJson(fakeRouteJson(id: id));
    ElevationProfile profile(double total) {
      final d = [for (var x = 0.0; x <= total; x += kProfileStepM) x];
      return ElevationProfile.fromSamples(d, [for (final x in d) 1000 + x / 100], totalM: total);
    }

    test('a route that replaces another stops the other\'s job, and a profile that still comes from it is not shown', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      el.request(route('a'));
      expect(jobs.started, ['a']);
      expect(jobs.stopped, isEmpty);
      expect(el.loading, isTrue);
      el.request(route('b'));
      expect(jobs.started, ['a', 'b']);
      expect(jobs.stopped, ['a']);
      jobs.finish('a', profile(1000));
      await pumpEventQueue();
      expect(el.profile, isNull);
      expect(el.loading, isTrue);
      final b = profile(2000);
      jobs.finish('b', b);
      await pumpEventQueue();
      expect(el.profile, same(b));
      expect(el.loading, isFalse);
      expect(jobs.stopped, ['a'], reason: 'a job that finished is not stopped');
    });

    test('a route that is dropped stops its job', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      el.request(route('a'));
      el.request(null);
      expect(jobs.stopped, ['a']);
      expect(el.loading, isFalse);
      jobs.finish('a', profile(1000));
      await pumpEventQueue();
      expect(el.profile, isNull);
      // The same route asked for again is a new job.
      el.request(route('a'));
      expect(jobs.started, ['a', 'a']);
    });

    test('the same route again starts nothing and stops nothing', () {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      final a = route('a');
      el.request(a);
      el.request(a);
      el.request(route('a'));
      expect(jobs.started, ['a']);
      expect(jobs.stopped, isEmpty);
    });

    test('a route replaced ten times over leaves one job, the last route\'s', () async {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      addTearDown(el.dispose);
      for (var i = 0; i < 10; i++) {
        el.request(route('r$i'));
        expect(jobs.running, ['r$i'], reason: 'one job at a time');
      }
      expect(jobs.started.length, 10);
      expect(jobs.stopped, [for (var i = 0; i < 9; i++) 'r$i']);
      final last = profile(3000);
      jobs.finish('r9', last);
      await pumpEventQueue();
      expect(el.profile, same(last));
    });

    test('going away stops the job', () {
      final jobs = _Jobs();
      final el = RouteElevation(start: jobs.start);
      el.request(route('a'));
      el.dispose();
      expect(jobs.stopped, ['a']);
    });

    test('a job that fails, or cannot start, shows no elevation instead of loading for ever', () async {
      final failing = RouteElevation(start: (r) => ElevationJob(Future<ElevationProfile>.error(StateError('no tiles'))));
      addTearDown(failing.dispose);
      failing.request(route('a'));
      await pumpEventQueue();
      expect(failing.loading, isFalse);
      expect(failing.profile!.hasData, isFalse);
      final unstartable = RouteElevation(start: (r) => throw StateError('no isolate'));
      addTearDown(unstartable.dispose);
      unstartable.request(route('a'));
      expect(unstartable.loading, isFalse);
      expect(unstartable.profile!.hasData, isFalse);
    });

    test('a loader that cannot be stopped is still shown only for its own route', () async {
      final done = <String, Completer<ElevationProfile>>{};
      final el = RouteElevation(loader: (r) => (done[r.routeId] = Completer<ElevationProfile>()).future);
      addTearDown(el.dispose);
      el.request(route('a'));
      el.request(route('b'));
      done['a']!.complete(profile(1000));
      await pumpEventQueue();
      expect(el.profile, isNull);
      final b = profile(2000);
      done['b']!.complete(b);
      await pumpEventQueue();
      expect(el.profile, same(b));
    });
  });

  // The real job: a background isolate that reads the tiles from the phone's own tile server, here a server of the test's.
  group('the job in the page (a browser has no isolates)', () {
    const zoom = 12, size = 256;
    const n = 1 << zoom;
    double lonOf(int x) => x / n * 360 - 180;
    final pts = [(42.55, lonOf(750) + 0.001), (42.56, lonOf(753) - 0.001)];

    test('its profile is the same as the one worked out with every tile held, and its chunks cover it', () async {
      final tiles = _PlaneTiles(size: size, heightAtColumn: (gx) => 1500 + 300 * math.sin(gx / 700), missingX: {751});
      final job = profileJobHere(tiles, zoom, pts);
      final seen = <int, double>{};
      final done = job.chunks!.listen((c) {
        for (var i = 0; i < c.heights.length; i++) {
          seen[c.first + i] = c.heights[i];
        }
      }).asFuture<void>();
      final p = await job.result;
      await done;
      _expectSameProfile(p, await _profileHoldingEveryTile(pts, tiles, zoom: zoom), 'in the page');
      expect(p.hasData, isTrue);
      expect(p.partial, isTrue);
      expect(seen, isNotEmpty);
    });

    test('stopped while it waits for a tile, it ends there', () async {
      final asked = Completer<void>();
      final job = profileJobHere(_NeverTiles(asked), zoom, pts);
      await asked.future;
      job.stop();
      await expectLater(job.result, throwsA(isA<ElevationStopped>()));
      job.stop();
    });

    test('with no tiles at all, the profile has no elevation and the job still ends well', () async {
      final p = await profileJobHere(_PlaneTiles(size: size, heightAtColumn: (_) => 0, missingX: {750, 751, 752, 753}), zoom, pts).result;
      expect(p.hasData, isFalse);
      expect(p.totalM, greaterThan(20000));
    });
  });

  group('the job in its isolate', () {
    const zoom = 12, size = 256;
    const n = 1 << zoom;
    double lonOf(int x) => x / n * 360 - 180;
    final pts = [(42.55, lonOf(750) + 0.001), (42.56, lonOf(753) - 0.001)];
    String urlOf(HttpServer server) => 'http://127.0.0.1:${server.port}/layers/dem/{z}/{x}/{y}';
    const slow = Timeout(Duration(minutes: 2));

    test('its profile is the same as the one worked out here with every tile held', () async {
      final tiles = _PlaneTiles(size: size, heightAtColumn: (gx) => 1500 + 300 * math.sin(gx / 700), missingX: {751});
      final server = await _serveTiles(tiles);
      addTearDown(() => server.close(force: true));
      final p = await profileJob(urlOf(server), zoom, pts).result;
      _expectSameProfile(p, await _profileHoldingEveryTile(pts, tiles, zoom: zoom), 'through the isolate');
      expect(p.hasData, isTrue);
      expect(p.partial, isTrue);
    }, timeout: slow);

    test('stopped while it waits for a tile, it ends there', () async {
      final asked = Completer<void>();
      final server = await _serveTiles(null, asked: asked);
      addTearDown(() => server.close(force: true));
      final job = profileJob(urlOf(server), zoom, pts);
      // The isolate is running and has asked for its first tile, which never comes.
      await asked.future;
      job.stop();
      // The result ends with "stopped" only when the isolate itself has ended.
      await expectLater(job.result, throwsA(isA<ElevationStopped>()));
      // Stopping again is harmless.
      job.stop();
    }, timeout: slow);

    test('stopped before its isolate has started, it never runs', () async {
      final asked = Completer<void>();
      final server = await _serveTiles(null, asked: asked);
      addTearDown(() => server.close(force: true));
      final job = profileJob(urlOf(server), zoom, pts);
      job.stop();
      await expectLater(job.result, throwsA(isA<ElevationStopped>()));
    }, timeout: slow);

    test('with no tile server to reach, the profile has no elevation and the job still ends well', () async {
      final server = await _serveTiles(null);
      final url = urlOf(server);
      await server.close(force: true);
      final p = await profileJob(url, zoom, pts).result;
      expect(p.hasData, isFalse);
      expect(p.totalM, greaterThan(20000));
    }, timeout: slow);
  });
}

/// The sampling as it was before the tiles kept were bounded: every decoded tile of the route is held until the end. Kept here
/// as it was, as what the sampling is compared with.
Future<List<double>> _sampleHoldingEveryTile(List<RouteSample> points, DemTiles tiles, {int zoom = 12}) async {
  final grids = <int, DemGrid?>{};
  final n = 1 << zoom;
  Future<DemGrid?> grid(int x, int y) async {
    if (y < 0 || y >= n) return null;
    final wx = ((x % n) + n) % n;
    final key = wx * n + y;
    if (grids.containsKey(key)) return grids[key];
    final bytes = await tiles.tile(zoom, wx, y);
    DemGrid? g;
    if (bytes != null && bytes.isNotEmpty) {
      try {
        g = DemGrid.decode(bytes);
      } catch (_) {
        g = null;
      }
    }
    return grids[key] = g;
  }

  final out = <double>[];
  for (final p in points) {
    final lat = p.lat.clamp(-85.0511287798, 85.0511287798);
    final fx = (p.lon + 180) / 360 * n;
    final l = lat * math.pi / 180;
    final fy = (1 - math.log(math.tan(l) + 1 / math.cos(l)) / math.pi) / 2 * n;
    final tx = fx.floor(), ty = fy.floor();
    final g0 = await grid(tx, ty);
    if (g0 == null) {
      out.add(double.nan);
      continue;
    }
    final size = g0.size;
    final px = fx * size - 0.5, py = fy * size - 0.5;
    final x0 = px.floor(), y0 = py.floor();
    final ax = px - x0, ay = py - y0;
    Future<double> h(int gx, int gy) async {
      final g = await grid((gx / size).floor(), (gy / size).floor());
      if (g == null || g.size != size) return double.nan;
      return g.at(gx - (gx / size).floor() * size, gy - (gy / size).floor() * size);
    }

    final h00 = await h(x0, y0), h10 = await h(x0 + 1, y0), h01 = await h(x0, y0 + 1), h11 = await h(x0 + 1, y0 + 1);
    final top = h00 + (h10 - h00) * ax;
    final bottom = h01 + (h11 - h01) * ax;
    out.add(top + (bottom - top) * ay);
  }
  return out;
}

/// The whole profile as it was built before, on [_sampleHoldingEveryTile].
Future<ElevationProfile> _profileHoldingEveryTile(List<(double, double)> points, DemTiles tiles, {int zoom = 12}) async {
  final samples = resampleRoute(points);
  if (samples.length < 2) return ElevationProfile.none(samples.isEmpty ? 0 : samples.last.distM);
  final heights = await _sampleHoldingEveryTile(samples, tiles, zoom: zoom);
  return ElevationProfile.fromSamples([for (final s in samples) s.distM], heights, totalM: samples.last.distM);
}

/// The same numbers, one for one (a point with no height is NaN in both).
void _expectSame(List<double> now, List<double> before, String what) {
  expect(now.length, before.length, reason: what);
  for (var i = 0; i < now.length; i++) {
    if (before[i].isNaN) {
      expect(now[i].isNaN, isTrue, reason: '$what, point $i');
    } else {
      expect(now[i], before[i], reason: '$what, point $i');
    }
  }
}

/// The same profile: every list one for one, and everything measured on it.
void _expectSameProfile(ElevationProfile now, ElevationProfile before, String what) {
  _expectSame(now.distM, before.distM, '$what: distances');
  _expectSame(now.rawM, before.rawM, '$what: heights read');
  _expectSame(now.elevM, before.elevM, '$what: heights smoothed');
  expect(now.totalM, before.totalM, reason: what);
  expect(now.climbM, before.climbM, reason: what);
  expect(now.descentM, before.descentM, reason: what);
  expect(now.coveredM, before.coveredM, reason: what);
  expect(now.runs, before.runs, reason: what);
  expect(now.highest, before.highest, reason: what);
  expect(now.lowest, before.lowest, reason: what);
  expect(
    [for (final c in now.climbs) (c.startM, c.endM, c.startElevM, c.endElevM)],
    [for (final c in before.climbs) (c.startM, c.endM, c.startElevM, c.endElevM)],
    reason: what,
  );
}

/// Counts what is asked of [inner], tile by tile ("x/y").
class _CountingTiles implements DemTiles {
  _CountingTiles(this.inner);

  final DemTiles inner;
  final Map<String, int> asked = {};

  int get total => asked.values.fold(0, (sum, times) => sum + times);

  @override
  Future<Uint8List?> tile(int z, int x, int y) {
    asked.update('$x/$y', (times) => times + 1, ifAbsent: () => 1);
    return inner.tile(z, x, y);
  }
}

/// Jobs by hand: the test finishes each one, and each says when it was stopped.
class _Jobs {
  final List<String> started = [];
  final List<String> stopped = [];
  final List<String> finished = [];
  final Map<String, Completer<ElevationProfile>> _results = {};

  ElevationJob start(MapRoute route) {
    final id = route.routeId;
    started.add(id);
    final result = _results[id] = Completer<ElevationProfile>();
    return ElevationJob(result.future, onStop: () => stopped.add(id));
  }

  void finish(String id, ElevationProfile profile) {
    finished.add(id);
    _results[id]!.complete(profile);
  }

  /// The jobs started and neither stopped nor finished.
  List<String> get running {
    final left = [...started];
    for (final id in [...stopped, ...finished]) {
      left.remove(id);
    }
    return left;
  }
}

/// A tile server like the phone's own, on this machine: [tiles] at /layers/dem/z/x/y, a tile that is not there answered as the
/// phone's does (503). With no [tiles] nothing is ever answered: a request stays waiting. [asked] completes at the first request.
Future<HttpServer> _serveTiles(DemTiles? tiles, {Completer<void>? asked}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final first = asked;
  final served = tiles;
  server.listen((request) async {
    if (first != null && !first.isCompleted) first.complete();
    if (served == null) return;
    final parts = request.uri.pathSegments;
    final bytes = await served.tile(int.parse(parts[2]), int.parse(parts[3]), int.parse(parts[4]));
    if (bytes == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
    } else {
      request.response.add(bytes);
    }
    await request.response.close();
  });
  return server;
}

/// Terrarium PNG tiles of a plane whose height depends only on the global pixel column; tiles in [missingX] are not there.
class _PlaneTiles implements DemTiles {
  _PlaneTiles({required this.size, required this.heightAtColumn, required this.missingX});

  final int size;
  final double Function(int globalColumn) heightAtColumn;
  final Set<int> missingX;
  final Map<int, Uint8List> _made = {};

  @override
  Future<Uint8List?> tile(int z, int x, int y) async {
    if (missingX.contains(x)) return null;
    return _made[x] ??= () {
      final im = img.Image(width: size, height: size);
      for (var px = 0; px < size; px++) {
        final v = heightAtColumn(x * size + px) + 32768;
        final r = v ~/ 256, g = v.floor() % 256, b = ((v - v.floor()) * 256).floor();
        for (var py = 0; py < size; py++) {
          im.setPixelRgb(px, py, r, g, b);
        }
      }
      return img.encodePng(im);
    }();
  }
}

/// Tiles that are asked for and never come.
class _NeverTiles implements DemTiles {
  _NeverTiles(this.asked);

  final Completer<void> asked;

  @override
  Future<Uint8List?> tile(int z, int x, int y) {
    if (!asked.isCompleted) asked.complete();
    return Completer<Uint8List?>().future;
  }
}
