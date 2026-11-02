import 'dart:math' as math;

import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/tile_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the accuracy circle closes and has the right radius', () {
    final ring = circleRing(42.5, -113.8, 100);
    expect(ring.first, ring.last);
    expect(ring.length, 65);
    // Distance from the centre to every point is the radius (haversine).
    for (final p in ring) {
      final dLat = (p[1] - 42.5) * math.pi / 180;
      final dLon = (p[0] + 113.8) * math.pi / 180;
      final a = math.pow(math.sin(dLat / 2), 2) + math.cos(42.5 * math.pi / 180) * math.cos(p[1] * math.pi / 180) * math.pow(math.sin(dLon / 2), 2);
      final d = 2 * 6371008.8 * math.asin(math.sqrt(a));
      expect(d, closeTo(100, 0.5));
    }
  });

  test('meters per point halves with each zoom and shrinks toward the poles', () {
    expect(metersPerPoint(0, 0), closeTo(78271.5, 1));
    expect(metersPerPoint(0, 1), closeTo(metersPerPoint(0, 0) / 2, 0.01));
    expect(metersPerPoint(60, 5), closeTo(metersPerPoint(0, 5) / 2, 1));
  });

  test('nice lengths are 1, 2 or 5 times a power of ten', () {
    expect(niceLength(1), 1);
    expect(niceLength(130), 100);
    expect(niceLength(250), 200);
    expect(niceLength(740), 500);
    expect(niceLength(9999), 5000);
  });

  test('scale bars fit and say feet, miles, metres and kilometres', () {
    // Zoom 15 at the equator: about 2.39 m per point.
    final mpp = metersPerPoint(0, 15);
    final si = metricScale(mpp, 120);
    final us = imperialScale(mpp, 120);
    expect(si.widthPoints, lessThanOrEqualTo(120));
    expect(us.widthPoints, lessThanOrEqualTo(120));
    expect(si.label, endsWith(' m'));
    expect(us.label, endsWith(' ft'));
    final far = metersPerPoint(40, 6);
    expect(metricScale(far, 120).label, endsWith(' km'));
    expect(imperialScale(far, 120).label, endsWith(' mi'));
    // A bar is the length it says: 200 m at 2 m per point is 100 points.
    expect(metricScale(2, 120).label, '200 m');
    expect(metricScale(2, 120).widthPoints, closeTo(100, 0.001));
  });

  test('tile maths: the world is one tile at zoom 0, counts grow four-fold', () {
    const world = GeoBounds(south: -80, west: -170, north: 80, east: 170);
    expect(TileMath.count(world, 0), 1);
    expect(TileMath.count(world, 1), 4);
    expect(TileMath.tileX(-180, 3), 0);
    expect(TileMath.tileX(179.999, 3), 7);
    expect(TileMath.tileY(0, 1), 1);
    const small = GeoBounds(south: 42.50, west: -113.80, north: 42.55, east: -113.74);
    expect(TileMath.countRange(small, 0, 4), 5);
    expect(TileMath.tiles(small, 10, 10).length, TileMath.count(small, 10));
  });
}
