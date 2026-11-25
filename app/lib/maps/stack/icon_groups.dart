// Stacked icons grouped (map-icon-stack-1.2): icons the app draws that the person did not put there (a repeater list's repeaters, road
// events, public places) that overlap are shown as one marker with a count; a tap fans them out. This file is the grouping and the
// fan's geometry, with no map or widget in it.

import 'dart:math' as math;

/// What an icon is. The order is the tie-break for a mixed group's marker: a road event, then a repeater, then a public place.
enum StackKind { roadEvent, repeater, poi }

/// One icon that may be grouped: its identity, where it truly is and where that is on the map's plane at the current zoom, in points
/// ([x], [y]: only their differences matter, so any fixed origin will do).
class StackIcon {
  const StackIcon({required this.id, required this.kind, required this.name, required this.lat, required this.lon, required this.x, required this.y});

  /// Unique among all icons (`repeater:<list>/<item>`, `road:<id>`).
  final String id;
  final StackKind kind;
  final String name;
  final double lat;
  final double lon;
  final double x;
  final double y;
}

/// Two or more icons drawn as one marker.
class IconGroup {
  const IconGroup({required this.members, required this.kind, required this.lat, required this.lon, required this.sameSpot});

  /// Every member, in a fixed order (by id).
  final List<StackIcon> members;

  /// The kind the marker shows: the most numerous among the members; a tie goes to the road event, then the repeater, then the public place.
  final StackKind kind;

  /// The average of the members' true points: where the marker is drawn.
  final double lat;
  final double lon;

  /// Every member has the very same coordinates (several repeaters at one site): such a group never splits, at any zoom.
  final bool sameSpot;

  int get count => members.length;

  /// More than [kFanMost] members: a list sheet opens instead of a fan.
  bool get needsSheet => members.length > kFanMost;

  /// The group's name: its sorted member ids joined.
  String get key => members.map((m) => m.id).join('|');

  /// What the count badge says: the number, or "99+".
  String get badge => count > 99 ? '99+' : '$count';
}

/// The most icons a fan shows (more: a list sheet).
const int kFanMost = 8;

/// How far the pairs of an earlier group may be apart before it splits: this many diameters (a small pinch does not flicker).
const double kSplitAt = 1.15;

/// Groups [icons] whose centres are closer than one drawn [diameter] (points). A plain grid whose cell is one diameter, not a chain
/// of neighbours, so a long string of icons does not melt into one huge group. Icons with identical coordinates are one spot and are
/// never apart. [previous] is the last result: a group of it whose members are all still within [kSplitAt] diameters of each other
/// stays one group (hysteresis). Only groups of two or more are returned.
List<IconGroup> groupIcons(Iterable<StackIcon> icons, {required double diameter, List<IconGroup> previous = const []}) {
  final list = icons.toList();
  if (list.length < 2 || diameter <= 0) return const [];
  final byId = {for (final i in list) i.id: i};
  final parent = <String, String>{for (final i in list) i.id: i.id};
  String find(String a) {
    while (parent[a] != a) {
      parent[a] = parent[parent[a]!]!;
      a = parent[a]!;
    }
    return a;
  }

  void union(String a, String b) {
    final ra = find(a), rb = find(b);
    if (ra != rb) parent[ra] = rb;
  }

  // The very same spot: one group at every zoom.
  final spots = <(double, double), String>{};
  for (final i in list) {
    final first = spots.putIfAbsent((i.lat, i.lon), () => i.id);
    if (first != i.id) union(first, i.id);
  }
  // The grid: icons in one cell are one group.
  final cells = <(int, int), String>{};
  for (final i in list) {
    final first = cells.putIfAbsent(((i.x / diameter).floor(), (i.y / diameter).floor()), () => i.id);
    if (first != i.id) union(first, i.id);
  }
  // Hysteresis: an earlier group whose members are all still within kSplitAt diameters of each other stays together.
  for (final g in previous) {
    final here = [for (final m in g.members) if (byId.containsKey(m.id)) byId[m.id]!];
    if (here.length < 2) continue;
    var far = 0.0;
    for (var a = 0; a < here.length; a++) {
      for (var b = a + 1; b < here.length; b++) {
        far = math.max(far, math.sqrt(math.pow(here[a].x - here[b].x, 2) + math.pow(here[a].y - here[b].y, 2)));
      }
    }
    if (far <= diameter * kSplitAt) {
      for (var k = 1; k < here.length; k++) {
        union(here.first.id, here[k].id);
      }
    }
  }

  final byRoot = <String, List<StackIcon>>{};
  for (final i in list) {
    (byRoot[find(i.id)] ??= []).add(i);
  }
  final out = <IconGroup>[];
  for (final members in byRoot.values) {
    if (members.length < 2) continue;
    members.sort((a, b) => a.id.compareTo(b.id));
    out.add(IconGroup(
      members: members,
      kind: markerKind(members),
      lat: members.map((m) => m.lat).reduce((a, b) => a + b) / members.length,
      lon: members.map((m) => m.lon).reduce((a, b) => a + b) / members.length,
      sameSpot: members.every((m) => m.lat == members.first.lat && m.lon == members.first.lon),
    ));
  }
  out.sort((a, b) => a.key.compareTo(b.key));
  return out;
}

/// The kind a group's marker shows: the most numerous; on a tie the road event, then the repeater, then the public place.
StackKind markerKind(Iterable<StackIcon> members) {
  final n = <StackKind, int>{};
  for (final m in members) {
    n[m.kind] = (n[m.kind] ?? 0) + 1;
  }
  StackKind? best;
  for (final k in StackKind.values) {
    final c = n[k] ?? 0;
    if (c == 0) continue;
    if (best == null || c > n[best]!) best = k;
  }
  return best!;
}

/// Where the discs of a fan of [n] sit: on a circle of [radius] around [centre], the first at 12 o'clock, then clockwise at equal angles.
/// [from] are the members' true screen points: the discs are given out in the angular order of those points around the centre, so the
/// leader lines do not cross. Returns, for each member (in the order of [from]), its disc's centre.
List<({double x, double y})> fanDiscs({required ({double x, double y}) centre, required List<({double x, double y})> from, double? radius}) {
  final n = from.length;
  radius ??= fanRadius(n);
  double angle(({double x, double y}) p) {
    final a = math.atan2(p.x - centre.x, -(p.y - centre.y)); // clockwise from 12 o'clock
    return a < 0 ? a + 2 * math.pi : a;
  }

  final order = List<int>.generate(n, (i) => i)..sort((a, b) => angle(from[a]).compareTo(angle(from[b])));
  final out = List<({double x, double y})>.filled(n, centre);
  for (var slot = 0; slot < n; slot++) {
    final t = 2 * math.pi * slot / n;
    out[order[slot]] = (x: centre.x + radius * math.sin(t), y: centre.y - radius * math.cos(t));
  }
  return out;
}

/// The radius of the circle of a fan of [n] discs: 34 points, wider where that would put neighbours (27 points across) less than 5
/// points apart (from 6 discs up).
double fanRadius(int n) => n < 3 ? 34 : math.max(34, (kFanDisc + 5) / 2 / math.sin(math.pi / n));

/// A fanned disc is drawn this many points across (the full size of an icon, whatever the zoom).
const double kFanDisc = 27;

/// The centre of a fan moved so that its discs (each [reach] from the circle's edge) stay inside [free] (left, top, right, bottom).
({double x, double y}) fanCentre(({double x, double y}) want, {required ({double left, double top, double right, double bottom}) free, double radius = 34, double reach = 22}) {
  final r = radius + reach;
  return (
    x: want.x.clamp(free.left + r, math.max(free.left + r, free.right - r)),
    y: want.y.clamp(free.top + r, math.max(free.top + r, free.bottom - r)),
  );
}

/// Points of leaders that are within [within] points of each other share one dot: returns the dot each point uses (the first of its
/// cluster), by index.
List<int> sharedDots(List<({double x, double y})> points, {double within = 4}) {
  final out = List<int>.generate(points.length, (i) => i);
  for (var i = 0; i < points.length; i++) {
    for (var j = 0; j < i; j++) {
      if (out[j] != j) continue;
      final dx = points[i].x - points[j].x, dy = points[i].y - points[j].y;
      if (math.sqrt(dx * dx + dy * dy) <= within) {
        out[i] = j;
        break;
      }
    }
  }
  return out;
}
