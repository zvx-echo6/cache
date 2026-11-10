import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cache/nav/elevation/elevation_profile.dart';
import 'package:cache/nav/elevation/route_sampler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

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
