import 'package:cache_search/cache_search.dart';

import 'units.dart';

/// The picture for a maneuver: Valhalla's maneuver type names (and "via" for a stop) choose it.
enum TurnIcon { start, straight, slightLeft, left, sharpLeft, slightRight, right, sharpRight, uTurn, roundabout, merge, ramp, exit, ferry, via, arrive, offroad }

TurnIcon turnIconFor(String type, {bool offroad = false}) {
  if (offroad) return TurnIcon.offroad;
  if (type.startsWith('destination')) return TurnIcon.arrive;
  if (type.startsWith('start')) return TurnIcon.start;
  if (type.startsWith('uturn')) return TurnIcon.uTurn;
  if (type.startsWith('roundabout')) return TurnIcon.roundabout;
  if (type.startsWith('ferry')) return TurnIcon.ferry;
  if (type.startsWith('merge')) return TurnIcon.merge;
  if (type.startsWith('ramp')) return TurnIcon.ramp;
  if (type.startsWith('exit')) return TurnIcon.exit;
  return switch (type) {
    'slight_left' || 'stay_left' => TurnIcon.slightLeft,
    'left' => TurnIcon.left,
    'sharp_left' => TurnIcon.sharpLeft,
    'slight_right' || 'stay_right' => TurnIcon.slightRight,
    'right' => TurnIcon.right,
    'sharp_right' => TurnIcon.sharpRight,
    'via' => TurnIcon.via,
    _ => TurnIcon.straight,
  };
}

/// "Turn left onto Main Street." as the end of a sentence: first letter lower case, no full stop.
String _asClause(String instruction) {
  var t = instruction.trim();
  if (t.endsWith('.')) t = t.substring(0, t.length - 1);
  return t.isEmpty ? t : t[0].toLowerCase() + t.substring(1);
}

String _sentence(String clause) => clause.isEmpty ? clause : '${clause[0].toUpperCase()}${clause.substring(1)}.';

/// What to say, and when. Fed every progress update, it returns the prompts that are due: each maneuver is announced as the
/// distance to it falls through three stages (far, near, at it), a stage is never said twice, and a stage that was already
/// passed when the first fix came is skipped. Off-road legs are announced when they begin, with the way to head.
class GuidanceEngine {
  GuidanceEngine({required this.fmt, required this.mode, required this.destination});

  final Fmt fmt;
  final String mode;
  final String destination;

  final Map<int, int> _stage = {};
  int? _lastCurrent;
  bool _arrivedSaid = false;

  /// The distances (metres) at which the far, near and at-it prompts are due, for the way of travel.
  List<double> get stages => switch (mode) {
        'walk' => const [150, 60, 20],
        'bike' => const [300, 120, 40],
        _ => const [800, 300, 90],
      };

  /// How to say what a maneuver asks, as a clause ("turn left onto Main Street"). [arriveAt] says it for an arrival.
  String clauseFor(ProgressManeuver m) {
    if (m.isArrival) return 'you reach your destination';
    if (m.type == 'via') return _asClause(m.instruction);
    if (m.kind == 'offroad_follow') {
      final what = m.followName ?? 'the ${m.trailKind == 'road' ? 'road' : m.trailKind == 'track' ? 'track' : 'trail'}';
      return 'follow $what ${cardinalWord(m.cardinal)} for ${fmt.spoken(m.lengthM)}'.replaceAll('  ', ' ');
    }
    if (m.kind == 'offroad') return 'leave the road and head ${cardinalWord(m.cardinal)} for ${fmt.spoken(m.lengthM)}${_climb(m)}'.replaceAll('  ', ' ');
    return _asClause(m.instruction);
  }

  String _climb(ProgressManeuver m) {
    final g = m.elevGainM ?? 0, l = m.elevLossM ?? 0;
    if (g >= 15 && g >= l) return ', climbing ${fmt.spokenHeight(g)}';
    if (l >= 15) return ', descending ${fmt.spokenHeight(l)}';
    return '';
  }

  /// The first thing said when guidance starts.
  String opening(MapRoute route, ProgressManeuver first) {
    final lead = 'Starting navigation to ${destination.isEmpty ? 'your destination' : destination}.';
    final where = '${fmt.spokenDuration(route.durationS)}, ${fmt.spoken(route.distanceM)}.';
    final firstStep = first.isOffroad ? _sentence(clauseFor(first)) : _sentence(_asClause(first.instruction));
    return '$lead $where $firstStep';
  }

  /// The prompts due for this update, in the order to say them.
  List<String> update(MapProgress p) {
    final out = <String>[];
    if (p.arrived) {
      if (!_arrivedSaid) {
        _arrivedSaid = true;
        out.add('You have arrived${destination.isEmpty ? '' : ' at $destination'}.');
      }
      return out;
    }
    if (!p.onRoute) return out;
    final cur = p.current;
    if (_lastCurrent != cur.index) {
      final first = _lastCurrent == null;
      _lastCurrent = cur.index;
      // A leg off the roads begins: say where to head (the very first leg is part of the opening).
      if (cur.isOffroad && !first) out.add(_sentence(clauseFor(cur)));
    }
    final next = p.next;
    if (next == null) return out;
    final st = stages;
    final d = p.next!.distanceM;
    var due = -1;
    for (var i = 0; i < st.length; i++) {
      if (d <= st[i]) due = i;
    }
    if (due < 0) return out;
    final said = _stage[next.index] ?? -1;
    if (due <= said) return out;
    _stage[next.index] = due;
    final clause = clauseFor(next);
    if (due == st.length - 1 && !next.isArrival) {
      out.add(_sentence(clause));
    } else if (next.isArrival && due == st.length - 1) {
      out.add(_sentence(_asClause(next.instruction)));
    } else {
      out.add(_sentence('in ${fmt.spoken(d)}, $clause'));
    }
    return out;
  }
}
