import 'road_geo.dart';

/// Where an event came from.
enum RoadEventSource { event511, workZone }

/// What kind of event it is, for the map: a closure, a crash or incident, or work.
enum RoadEventKind { closure, crash, work }

/// A direction of travel, with the short and long forms of the same direction being one.
enum Heading { north, south, east, west }

/// Reads a direction of travel as the sites write it: "Westbound", "West", "westbound", "W". `None`, `Unknown`, "undefined", "both" and
/// empty mean no direction (null). A compass word, not natural language: the sites' own enumerations.
Heading? headingOf(Object? v) {
  if (v is! String) return null;
  final t = v.trim().toLowerCase();
  if (t.isEmpty) return null;
  const words = {'north': Heading.north, 'northbound': Heading.north, 'n': Heading.north, 'nb': Heading.north, 'south': Heading.south, 'southbound': Heading.south, 's': Heading.south, 'sb': Heading.south, 'east': Heading.east, 'eastbound': Heading.east, 'e': Heading.east, 'eb': Heading.east, 'west': Heading.west, 'westbound': Heading.west, 'w': Heading.west, 'wb': Heading.west};
  return words[t];
}

/// One road event as the map draws it, read from what a source stored (a 511 event's `app` values, or a WZDx feature's).
class RoadEvent {
  const RoadEvent({
    required this.id,
    required this.source,
    required this.sourceId,
    required this.kind,
    required this.road,
    required this.line,
    required this.point,
    this.heading,
    this.fullClosure = false,
    this.detour = const [],
    this.startUnix,
    this.endUnix,
    this.fields = const {},
    this.detourSteps = const [],
    this.updated,
    this.credit = '',
    this.stale = false,
    this.age,
  });

  /// A stable id: the source's id and the event's key.
  final String id;
  final RoadEventSource source;

  /// The id of the connector that stored it (`idaho511-events`).
  final String sourceId;
  final RoadEventKind kind;
  final String road;

  /// The stretch, decoded; empty when the event is a point.
  final List<LL> line;

  /// The event's point (a closure's middle is where its chip goes).
  final LL point;
  final Heading? heading;
  final bool fullClosure;
  final List<LL> detour;
  final int? startUnix;
  final int? endUnix;

  /// The card's lines, by label (what the source wrote for people: Details, Lanes affected, Detour, ...).
  final Map<String, String> fields;
  final List<String> detourSteps;
  final String? updated;

  /// "Road events: Idaho 511".
  final String credit;

  /// The stored copy it came from is out of date (past its validity): drawn dimmed, never hidden.
  final bool stale;

  /// How old the stored copy is, as the core words it ("40 minutes old").
  final String? age;

  /// Every point of the geometry the event has (the line, or its point).
  List<LL> get geometry => line.isEmpty ? [point] : line;

  /// The chip's place: the middle of a stretch, or the point.
  LL get chipAt => line.isEmpty ? point : middleOf(line);
}
