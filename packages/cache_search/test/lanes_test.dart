import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> maneuver([Object? lanes = _absent]) => {
      'index': 3, 'kind': 'road', 'type': 'left', 'instruction': 'Turn left.', 'lat': 42.5, 'lon': -113.8, 'distance_m': 120.0,
      if (!identical(lanes, _absent)) 'lanes': lanes,
    };
const Object _absent = Object();

void main() {
  group('turn lanes', () {
    test('absent or empty is no lanes, as an empty list', () {
      expect(ProgressManeuver.fromJson(maneuver()).lanes, isEmpty);
      expect(ProgressManeuver.fromJson(maneuver(<dynamic>[])).lanes, isEmpty);
      expect(ProgressManeuver.fromJson(maneuver(null)).lanes, isEmpty);
      expect(ProgressManeuver.fromJson(maneuver('x')).lanes, isEmpty);
      expect(const ProgressManeuver(index: 0, kind: 'road', type: 'x', instruction: '', lat: 0, lon: 0, distanceM: 0).lanes, isEmpty);
    });

    test('the live sample with an active lane', () {
      final l = ProgressManeuver.fromJson(maneuver([
        {'directions': 8, 'active': 8},
        {'directions': 2},
        {'directions': 66},
      ])).lanes;
      expect(l, hasLength(3));
      expect(l[0].directions, {LaneDirection.left});
      expect(l[0].active, LaneDirection.left);
      expect(l[0].valid, isNull);
      expect(l[1].directions, {LaneDirection.through});
      expect(l[1].active, isNull);
      expect(l[2].directions, {LaneDirection.through, LaneDirection.right});
    });

    test('the live sample with active and valid lanes', () {
      final l = ProgressManeuver.fromJson(maneuver([
        {'directions': 16},
        {'directions': 48, 'active': 32},
        {'directions': 32, 'valid': 32},
      ])).lanes;
      expect(l[0].directions, {LaneDirection.slightLeft});
      expect(l[1].directions, {LaneDirection.slightLeft, LaneDirection.slightRight});
      expect(l[1].active, LaneDirection.slightRight);
      expect(l[1].valid, isNull);
      expect(l[2].directions, {LaneDirection.slightRight});
      expect(l[2].valid, LaneDirection.slightRight);
      expect(l[2].active, isNull);
    });

    test('every bit of turnlanes.h, and an empty lane', () {
      const bits = {1: LaneDirection.none, 2: LaneDirection.through, 4: LaneDirection.sharpLeft, 8: LaneDirection.left, 16: LaneDirection.slightLeft, 32: LaneDirection.slightRight, 64: LaneDirection.right, 128: LaneDirection.sharpRight, 256: LaneDirection.reverse, 512: LaneDirection.mergeToLeft, 1024: LaneDirection.mergeToRight};
      bits.forEach((b, d) => expect(Lane.fromJson({'directions': b, 'active': b}), Lane(directions: {d}, active: d)));
      expect(Lane.fromJson({'directions': 0}).directions, isEmpty);
      expect(Lane.fromJson(const {}).directions, isEmpty);
    });

    test('some maneuvers with lanes, some without, in a progress update', () {
      final p = MapProgress.fromJson({
        'route_id': 'r', 'matched': {'lat': 1, 'lon': 2}, 'on_route': true,
        'current': maneuver(),
        'next': maneuver([{'directions': 8, 'active': 8}]),
        'then': maneuver(),
      });
      expect(p.current.lanes, isEmpty);
      expect(p.next!.lanes.single.active, LaneDirection.left);
      expect(p.then!.lanes, isEmpty);
    });
  });
}
