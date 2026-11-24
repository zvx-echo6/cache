import 'road_event.dart';
import 'road_geo.dart';

/// De-duplication of a 511 event and a WZDx work zone that describe the same work zone: it is drawn once, and the 511 version is kept.
///
/// "Same" is decided by data rules only, never by text: the two geometries overlap, and their date ranges overlap.
///
/// * **Geometry.** Each geometry is a line (or a point). The strip of half-width [bufferM] around each line is the "buffer". The two are
///   the same place when each one's length lies at least [minCoverage] inside the other's buffer, measured at points every [stepM]
///   metres along it (mutual coverage, so a short zone inside a long closure is not the same zone as the closure). A point is the same
///   place as a line when it is within [bufferM] of it; two points when they are within [bufferM] of each other.
/// * **Dates.** The ranges [start, end] overlap. A missing start or end (the sites write 0 or leave it out for "no time given") is an open
///   end, so a range with no dates overlaps every range: it cannot rule a match out.
/// * **Only work.** A 511 event is a candidate only when it is roadwork or a closure (the 511 `EventType` values `roadwork` and `closures`);
///   a crash or incident is never a work zone. A WZDx item is always a work zone.
class DedupeRules {
  const DedupeRules({this.bufferM = 50, this.minCoverage = 0.5, this.stepM = 10});

  /// Half-width of the strip around each geometry, in metres.
  final double bufferM;

  /// The least share (0 to 1) of each line that must lie inside the other's strip.
  final double minCoverage;

  /// Spacing of the points the coverage is measured at, in metres.
  final double stepM;
}

/// The thresholds in use.
const DedupeRules kDedupeRules = DedupeRules();

/// A time far enough from any real one to stand for an open end (kept under 2^53 so a browser's numbers hold it).
const int _open = 4000000000000000;

/// True when the date ranges overlap (a missing end is open).
bool dateRangesOverlap(int? startA, int? endA, int? startB, int? endB) {
  final sa = startA ?? -_open, ea = endA ?? _open, sb = startB ?? -_open, eb = endB ?? _open;
  return sa <= eb && sb <= ea;
}

/// True when the geometries are the same place under [rules].
bool geometriesOverlap(List<LL> a, List<LL> b, {DedupeRules rules = kDedupeRules}) {
  if (a.isEmpty || b.isEmpty) return false;
  if (a.length == 1 && b.length == 1) return distanceM(a.first, b.first) <= rules.bufferM;
  if (a.length == 1) return pointToLineM(a.first, b) <= rules.bufferM;
  if (b.length == 1) return pointToLineM(b.first, a) <= rules.bufferM;
  final ab = coverage(a, b, bufferM: rules.bufferM, stepM: rules.stepM);
  if (ab < rules.minCoverage) return false;
  return coverage(b, a, bufferM: rules.bufferM, stepM: rules.stepM) >= rules.minCoverage;
}

/// True when [e511] (a 511 event) and [zone] (a WZDx work zone) are the same work zone.
bool sameWorkZone(RoadEvent e511, RoadEvent zone, {DedupeRules rules = kDedupeRules}) {
  if (e511.source != RoadEventSource.event511 || zone.source != RoadEventSource.workZone) return false;
  if (e511.kind == RoadEventKind.crash) return false;
  if (!dateRangesOverlap(e511.startUnix, e511.endUnix, zone.startUnix, zone.endUnix)) return false;
  return geometriesOverlap(e511.geometry, zone.geometry, rules: rules);
}

/// [events] with each WZDx work zone that a 511 event also describes left out. Order is kept.
List<RoadEvent> dedupeWorkZones(List<RoadEvent> events, {DedupeRules rules = kDedupeRules}) {
  final e511 = [for (final e in events) if (e.source == RoadEventSource.event511 && e.kind != RoadEventKind.crash) e];
  if (e511.isEmpty) return events;
  return [
    for (final e in events)
      if (e.source != RoadEventSource.workZone || !e511.any((x) => sameWorkZone(x, e, rules: rules))) e,
  ];
}
