// The nudge of group markers and pins off city and town names (lib/maps/stack/label_nudge.dart). Every name is made up.

import 'dart:math' as math;
import 'dart:ui';

import 'package:cache/maps/stack/label_nudge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const view = Rect.fromLTWH(0, 0, 400, 800);

  group('the nudge', () {
    test('an item that touches no name does not move', () {
      final m = nudgeOffLabels(items: {'a': Rect.fromCenter(center: const Offset(100, 100), width: 44, height: 44)}, labels: [Rect.fromCenter(center: const Offset(300, 400), width: 50, height: 18)], viewport: view);
      expect(m, isEmpty);
    });

    test('an item on a name moves just clear of it (plus the padding), on one axis only', () {
      final label = Rect.fromCenter(center: const Offset(200, 400), width: 50, height: 18);
      final item = Rect.fromCenter(center: const Offset(200, 400), width: 44, height: 44);
      final m = nudgeOffLabels(items: {'a': item}, labels: [label], viewport: view);
      final moved = item.shift(m['a']!);
      expect(label.inflate(kNudgePadding).overlaps(moved), isFalse, reason: 'clear of the name and its padding');
      expect(m['a']!.dx == 0 || m['a']!.dy == 0, isTrue);
      // The least move that clears: vertical here (22 + 9 + 4 = 35), not the 25 + 22 + 4 = 51 sideways.
      expect(m['a']!.distance, closeTo(35, 0.01));
    });

    test('to the roomier side: near the left edge it goes right, near the right edge it goes left', () {
      final label = Rect.fromCenter(center: const Offset(60, 400), width: 100, height: 18);
      final item = Rect.fromCenter(center: const Offset(60, 400), width: 20, height: 300); // much taller than wide: sideways is the short way
      final left = nudgeOffLabels(items: {'a': item}, labels: [label], viewport: view)['a']!;
      expect(left.dx, greaterThan(0), reason: 'more room on the right');
      final label2 = Rect.fromCenter(center: const Offset(340, 400), width: 100, height: 18);
      final item2 = Rect.fromCenter(center: const Offset(340, 400), width: 20, height: 300);
      final right = nudgeOffLabels(items: {'a': item2}, labels: [label2], viewport: view)['a']!;
      expect(right.dx, lessThan(0), reason: 'more room on the left');
    });

    test('the camera projects a point and takes it back', () {
      const cam = NudgeCamera(centreScreen: Offset(195, 422), lat: 43.6, lon: -116.2, zoom: 8.3, bearing: 37);
      final p = cam.project(43.9, -115.8);
      final (la, lo) = cam.unproject(p);
      expect(la, closeTo(43.9, 1e-6));
      expect(lo, closeTo(-115.8, 1e-6));
      expect(cam.project(43.6, -116.2), const Offset(195, 422));
      // Facing east (bearing 90), a point to the east is straight up.
      const east = NudgeCamera(centreScreen: Offset(200, 400), lat: 40, lon: -110, zoom: 10, bearing: 90);
      final e = east.project(40, -109.9);
      expect(e.dx, closeTo(200, 1e-6));
      expect(e.dy, lessThan(400));
    });

    test('speed: about 500 icons and 50 names in well under 16 ms', () {
      final rnd = math.Random(5);
      final items = {for (var i = 0; i < 500; i++) 'i$i': Rect.fromCenter(center: Offset(rnd.nextDouble() * 400, rnd.nextDouble() * 800), width: 44, height: 44)};
      final labels = [for (var i = 0; i < 50; i++) labelBox('Town$i', Offset(rnd.nextDouble() * 400, rnd.nextDouble() * 800))];
      nudgeOffLabels(items: items, labels: labels, viewport: view);
      final sw = Stopwatch()..start();
      const runs = 20;
      late Map<String, Offset> m;
      for (var i = 0; i < runs; i++) {
        m = nudgeOffLabels(items: items, labels: labels, viewport: view);
      }
      final ms = sw.elapsedMicroseconds / runs / 1000;
      // ignore: avoid_print
      print('nudgeOffLabels: ${items.length} icons, ${labels.length} names, ${m.length} moved, ${ms.toStringAsFixed(2)} ms per call');
      expect(ms, lessThan(16));
    });
  });
}
