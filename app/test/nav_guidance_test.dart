import 'package:cache/nav/guidance.dart';
import 'package:cache/nav/units.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';

void main() {
  const fmt = Fmt(UnitSystem.imperial);
  final route = fakeRouteJson();
  final off = fakeRouteJson(offroad: true);

  MapProgress at(Map<String, dynamic> r, double f, {bool arrived = false, double offset = 0, bool offRoute = false}) =>
      MapProgress.fromJson(fakeProgressJson(r, f, arrived: arrived, offset: offset, offRoute: offRoute));

  group('prompts', () {
    test('a turn is announced at three stages, each once, nearest last', () {
      final g = GuidanceEngine(fmt: fmt, mode: 'drive', destination: 'Cassia Regional Hospital');
      final total = (route['distance_m'] as num).toDouble();
      // the first turn is 13/40 of the way; 700 m before it, then 250 m, then 60 m, then it again
      double f(double metersBefore) => 13 / 40 - metersBefore / total;
      expect(g.update(at(route, 0.0)), isEmpty, reason: 'far from the turn');
      final far = g.update(at(route, f(700)));
      expect(far, hasLength(1));
      expect(far.single, startsWith('In '));
      expect(far.single, contains('turn left onto Road 1'));
      expect(g.update(at(route, f(690))), isEmpty, reason: 'the same stage is not repeated');
      final near = g.update(at(route, f(250)));
      expect(near.single, 'In 800 feet, turn left onto Road 1.');
      final now = g.update(at(route, f(60)));
      expect(now.single, 'Turn left onto Road 1.');
      expect(g.update(at(route, f(40))), isEmpty);
    });

    test('a stage already passed when the first fix came is skipped, and only the nearest due one is said', () {
      final g = GuidanceEngine(fmt: fmt, mode: 'drive', destination: 'X');
      final total = (route['distance_m'] as num).toDouble();
      final said = g.update(at(route, 13 / 40 - 200 / total));
      expect(said, hasLength(1));
      expect(said.single, startsWith('In '));
    });

    test('walking is announced closer in than driving', () {
      final drive = GuidanceEngine(fmt: fmt, mode: 'drive', destination: 'X');
      final walk = GuidanceEngine(fmt: fmt, mode: 'walk', destination: 'X');
      expect(drive.stages, [800, 300, 90]);
      expect(walk.stages, [150, 60, 20]);
      expect(GuidanceEngine(fmt: fmt, mode: 'bike', destination: 'X').stages, [300, 120, 40]);
      final total = (route['distance_m'] as num).toDouble();
      final f = 13 / 40 - 500 / total;
      expect(drive.update(at(route, f)), isNotEmpty);
      expect(walk.update(at(route, f)), isEmpty);
    });

    test('the arrival is said once, and nothing else is said after it', () {
      final g = GuidanceEngine(fmt: fmt, mode: 'drive', destination: 'Cassia Regional Hospital');
      expect(g.update(at(route, 1.0, arrived: true)), ['You have arrived at Cassia Regional Hospital.']);
      expect(g.update(at(route, 1.0, arrived: true)), isEmpty);
      final blank = GuidanceEngine(fmt: fmt, mode: 'drive', destination: '');
      expect(blank.update(at(route, 1.0, arrived: true)), ['You have arrived.']);
    });

    test('the destination itself is announced as ahead, then with the core\'s own words', () {
      final g = GuidanceEngine(fmt: fmt, mode: 'drive', destination: 'X');
      final total = (route['distance_m'] as num).toDouble();
      final far = g.update(at(route, 1 - 700 / total));
      expect(far.single, 'In half a mile, you reach your destination.');
      final end = g.update(at(route, 1 - 60 / total));
      expect(end.single, 'You have arrived at your destination.');
    });

    test('a fix off the route says nothing', () {
      final g = GuidanceEngine(fmt: fmt, mode: 'drive', destination: 'X');
      expect(g.update(at(route, 0.32, offset: 200, offRoute: true)), isEmpty);
    });

    test('an off-road stretch is announced when it begins, and again as the turn onto it comes', () {
      final g = GuidanceEngine(fmt: fmt, mode: 'drive', destination: 'X');
      final total = (off['distance_m'] as num).toDouble();
      // on the road: 800 m before the off-road leg (at 30/40), the next maneuver is that leg
      final heads = g.update(at(off, 30 / 40 - 700 / total));
      expect(heads.single, startsWith('In '));
      expect(heads.single, contains('leave the road and head east for'));
      expect(heads.single, contains('climbing'));
      // inside the leg: where to head, once
      final inside = g.update(at(off, 30 / 40 + 0.02));
      expect(inside.single, startsWith('Leave the road and head east'));
      expect(g.update(at(off, 30 / 40 + 0.03)), isEmpty);
    });

    test('a leg along a trail names it', () {
      final g = GuidanceEngine(fmt: fmt, mode: 'walk', destination: 'X');
      const m = ProgressManeuver(index: 3, kind: 'offroad_follow', type: 'offroad_follow', instruction: 'x', lat: 0, lon: 0, distanceM: 100, lengthM: 805, cardinal: 'NW', followName: 'Iron Creek Trail', trailKind: 'trail');
      expect(g.clauseFor(m), 'follow Iron Creek Trail northwest for half a mile');
      const unnamed = ProgressManeuver(index: 3, kind: 'offroad_follow', type: 'offroad_follow', instruction: 'x', lat: 0, lon: 0, distanceM: 100, lengthM: 805, cardinal: 'N', trailKind: 'road');
      expect(g.clauseFor(unnamed), 'follow the road north for half a mile');
    });

    test('the opening gives the destination, the trip, and the first instruction', () {
      final g = GuidanceEngine(fmt: fmt, mode: 'drive', destination: 'Cassia Regional Hospital');
      final r = MapRoute.fromJson(route);
      final said = g.opening(r, at(route, 0).current);
      expect(said, 'Starting navigation to Cassia Regional Hospital. 21 minutes, 15 miles. Drive east on Main Street.');
    });
  });

  test('maneuver types pick their picture', () {
    expect(turnIconFor('left'), TurnIcon.left);
    expect(turnIconFor('sharp_right'), TurnIcon.sharpRight);
    expect(turnIconFor('slight_left'), TurnIcon.slightLeft);
    expect(turnIconFor('uturn_right'), TurnIcon.uTurn);
    expect(turnIconFor('roundabout_enter'), TurnIcon.roundabout);
    expect(turnIconFor('destination_left'), TurnIcon.arrive);
    expect(turnIconFor('start_left'), TurnIcon.start);
    expect(turnIconFor('merge_right'), TurnIcon.merge);
    expect(turnIconFor('ramp_right'), TurnIcon.ramp);
    expect(turnIconFor('exit_left'), TurnIcon.exit);
    expect(turnIconFor('continue'), TurnIcon.straight);
    expect(turnIconFor('becomes'), TurnIcon.straight);
    expect(turnIconFor('via'), TurnIcon.via);
    expect(turnIconFor('offroad_leg', offroad: true), TurnIcon.offroad);
  });
}
