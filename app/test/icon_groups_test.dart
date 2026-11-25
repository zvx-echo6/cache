// The grouping of stacked icons and the fan's geometry (lib/maps/stack/icon_groups.dart). Every name is made up.

import 'dart:math' as math;

import 'package:cache/maps/stack/icon_groups.dart';
import 'package:flutter_test/flutter_test.dart';

StackIcon icon(String id, double x, double y, {StackKind kind = StackKind.repeater, double? lat, double? lon}) =>
    StackIcon(id: id, kind: kind, name: id, lat: lat ?? 40 + y / 1000, lon: lon ?? -110 + x / 1000, x: x, y: y);

void main() {
  group('who is grouped', () {
    test('two icons in one cell (closer than a diameter) are one group; far ones are alone', () {
      final g = groupIcons([icon('a', 10, 10), icon('b', 20, 15), icon('c', 200, 200)], diameter: 28);
      expect(g, hasLength(1));
      expect(g.single.members.map((m) => m.id), ['a', 'b']);
      expect(g.single.count, 2);
      expect(g.single.badge, '2');
    });

    test('a grid, not a chain: a long string of icons does not melt into one group', () {
      final line = [for (var i = 0; i < 20; i++) icon('i$i', i * 20.0, 5)];
      final g = groupIcons(line, diameter: 28);
      expect(g.length, greaterThan(1));
      expect(g.every((x) => x.count <= 3), isTrue, reason: 'cells of one diameter hold at most two or three of these');
    });

    test('identical coordinates are one spot: they group at every zoom, however small the diameter', () {
      final icons = [icon('a', 0, 0, lat: 1, lon: 2), icon('b', 500, 500, lat: 1, lon: 2), icon('c', 900, 900, lat: 3, lon: 4)];
      for (final d in [4.0, 28.0, 71.0]) {
        final g = groupIcons(icons, diameter: d);
        expect(g, hasLength(1), reason: 'diameter $d');
        expect(g.single.sameSpot, isTrue);
        expect(g.single.members.map((m) => m.id), ['a', 'b']);
      }
    });

    test('hysteresis: a group stays together up to 1.15 diameters, and splits beyond', () {
      final near = [icon('a', 10, 10), icon('b', 20, 15)];
      final first = groupIcons(near, diameter: 28);
      expect(first, hasLength(1));
      // Moved apart across a cell border but within 1.15 diameters (32 points): still one group.
      final apart = [icon('a', 10, 10), icon('b', 38, 15)]; // 28.4 apart, in another cell
      expect(groupIcons(apart, diameter: 28), isEmpty, reason: 'without a history they are two icons');
      expect(groupIcons(apart, diameter: 28, previous: first), hasLength(1), reason: 'with the earlier group they stay one');
      final wide = [icon('a', 10, 10), icon('b', 45, 15)]; // 35 apart: beyond 1.15 x 28 = 32.2
      expect(groupIcons(wide, diameter: 28, previous: first), isEmpty);
    });

    test('the marker is at the average of the true points', () {
      final g = groupIcons([icon('a', 10, 10, lat: 10, lon: 20), icon('b', 12, 12, lat: 12, lon: 24)], diameter: 28).single;
      expect(g.lat, 11);
      expect(g.lon, 22);
    });

    test('fewer than two icons, or no size: no groups', () {
      expect(groupIcons([icon('a', 0, 0)], diameter: 28), isEmpty);
      expect(groupIcons([icon('a', 0, 0), icon('b', 1, 1)], diameter: 0), isEmpty);
    });
  });

  group('which kind the marker shows', () {
    test('the most numerous', () {
      final m = [icon('a', 0, 0), icon('b', 1, 1), icon('c', 2, 2, kind: StackKind.roadEvent)];
      expect(markerKind(m), StackKind.repeater);
    });

    test('a tie: road event, then repeater, then public place', () {
      expect(markerKind([icon('a', 0, 0), icon('b', 1, 1, kind: StackKind.roadEvent)]), StackKind.roadEvent);
      expect(markerKind([icon('a', 0, 0), icon('b', 1, 1, kind: StackKind.poi)]), StackKind.repeater);
      expect(markerKind([icon('a', 0, 0, kind: StackKind.poi), icon('b', 1, 1, kind: StackKind.roadEvent)]), StackKind.roadEvent);
    });
  });

  group('the badge and the list sheet', () {
    IconGroup many(int n) => groupIcons([for (var i = 0; i < n; i++) icon('i${i.toString().padLeft(3, '0')}', i * 0.1, 0)], diameter: 28).single;

    test('up to 99 the number, above it 99+', () {
      expect(many(99).badge, '99');
      expect(many(100).badge, '99+');
    });

    test('more than 8 members: a list sheet, not a fan', () {
      expect(many(8).needsSheet, isFalse);
      expect(many(9).needsSheet, isTrue);
    });
  });

  group('the fan', () {
    test('discs on a circle of 34 points, the first at 12 o\'clock, clockwise at equal angles', () {
      const c = (x: 100.0, y: 100.0);
      final from = [for (var i = 0; i < 4; i++) (x: 100 + 5 * math.sin(i * math.pi / 2), y: 100 - 5 * math.cos(i * math.pi / 2))];
      final d = fanDiscs(centre: c, from: from);
      expect(d[0].x, closeTo(100, 1e-9));
      expect(d[0].y, closeTo(66, 1e-9));
      expect(d[1].x, closeTo(134, 1e-9));
      expect(d[1].y, closeTo(100, 1e-9));
      expect(d[2].y, closeTo(134, 1e-9));
      expect(d[3].x, closeTo(66, 1e-9));
    });

    test('given out in the angular order of the true points, so the leaders do not cross', () {
      const c = (x: 0.0, y: 0.0);
      // True points: east, north, west (given in this order): the discs follow their angles, north first.
      final d = fanDiscs(centre: c, from: [(x: 5, y: 0), (x: 0, y: -5), (x: -5, y: 0)]);
      expect(d[1].y, lessThan(0), reason: 'the northern point gets the 12 o\'clock disc');
      expect(d[1].x.abs(), lessThan(1e-9));
      expect(d[0].x, greaterThan(0), reason: 'east next, clockwise');
      expect(d[2].x, lessThan(0));
    });

    test('neighbouring discs are at least 5 points apart for up to 8', () {
      for (var n = 2; n <= 8; n++) {
        final d = fanDiscs(centre: (x: 0, y: 0), from: [for (var i = 0; i < n; i++) (x: math.sin(i.toDouble()), y: -math.cos(i.toDouble()))]);
        for (var i = 0; i < n; i++) {
          final j = (i + 1) % n;
          final gap = math.sqrt(math.pow(d[i].x - d[j].x, 2) + math.pow(d[i].y - d[j].y, 2)) - kFanDisc;
          if (n > 2) expect(gap, greaterThanOrEqualTo(5 - 1e-9), reason: 'n=$n');
        }
      }
    });

    test('the centre moves so the fan stays inside the free area', () {
      const free = (left: 0.0, top: 100.0, right: 400.0, bottom: 700.0);
      final a = fanCentre((x: 10, y: 20), free: free);
      expect(a.x, 56);
      expect(a.y, 156);
      final b = fanCentre((x: 200, y: 400), free: free);
      expect((b.x, b.y), (200, 400));
    });

    test('leader points within 4 points of each other share one dot', () {
      final dots = sharedDots([(x: 0, y: 0), (x: 3, y: 0), (x: 50, y: 50), (x: 52, y: 51), (x: 100, y: 0)]);
      expect(dots, [0, 0, 2, 2, 4]);
    });
  });
}
