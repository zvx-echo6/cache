import 'dart:async';

import 'package:flutter/foundation.dart';

import '../weather/live_view.dart';
import '../weather/weather_state.dart';
import 'road_dedupe.dart';
import 'road_event.dart';
import 'road_geo.dart';
import 'road_state.dart';

/// What the map draws: the road events (a 511 site's closures, crashes and road work; WZDx work zones) already stored for the places
/// the weather part watches and the regions on the device. Nothing is fetched here, and nothing as the map pans: this only reads what the
/// sources stored for their downloads ([WeatherState.viewFor]). The same stored data feeds the weather list and the assistant.

/// 511 `EventType` values: `roadwork`, `closures`, `accidentsAndIncidents`; anything else is read as roadwork-less "other" (not drawn as
/// a closure or work, kept as a crash-style chip so a new type on one site never hides an event).
RoadEventKind kindOf511(Object? type, Object? full) {
  final t = '$type';
  if (t == 'closures') return RoadEventKind.closure;
  if (t == 'roadwork') return RoadEventKind.work;
  if (t == 'accidentsAndIncidents') return RoadEventKind.crash;
  return full == true || full == 1 || '$full' == 'true' ? RoadEventKind.closure : RoadEventKind.crash;
}

bool _isTrue(Object? v) => v == true || v == 1 || '$v'.toLowerCase() == 'true';

int? _unix(Object? v) {
  final n = v is num ? v.toInt() : int.tryParse('$v');
  return n == null || n <= 0 ? null : n;
}

DateTime? _rfc(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// The coordinates of a GeoJSON geometry as one line: a LineString's points; a Point as one point; a MultiLineString or a Multi/Point
/// collection as the points of its first part (the rest are rare in WZDx and the road events are drawn as one stretch).
List<LL> _lineOf(Object? g) {
  if (g is! Map) return const [];
  final c = g['coordinates'];
  LL? pt(Object? p) => p is List && p.length >= 2 && p[0] is num && p[1] is num ? LL((p[1] as num).toDouble(), (p[0] as num).toDouble()) : null;
  switch (g['type']) {
    case 'Point':
      final p = pt(c);
      return p == null ? const [] : [p];
    case 'LineString':
    case 'MultiPoint':
      return [if (c is List) for (final p in c) ?pt(p)];
    case 'MultiLineString':
      return c is List && c.isNotEmpty && c.first is List ? [for (final p in c.first as List) ?pt(p)] : const [];
    default:
      return const [];
  }
}

/// A 511 site's stored item as a road event; null for an item with no place to draw (no point and no line).
RoadEvent? roadEventFrom511(LiveItem item, {required String sourceId, required String credit, bool stale = false, String? age}) {
  final a = item.app;
  if (a.isEmpty && item.fields.isEmpty) return null;
  final line = decodePolyline(a['line'] is String ? a['line'] as String : null);
  final detour = decodePolyline(a['detour'] is String ? a['detour'] as String : null);
  final pt = _pointOf(item) ?? (line.isEmpty ? null : middleOf(line));
  if (pt == null) return null;
  final full = _isTrue(a['full']);
  final steps = a['steps'];
  return RoadEvent(
    id: '$sourceId/${item.key}',
    source: RoadEventSource.event511,
    sourceId: sourceId,
    kind: kindOf511(a['type'], full),
    road: a['road'] is String ? a['road'] as String : item.label.split(':').first,
    line: line,
    point: pt,
    heading: headingOf(item.fields['Direction']),
    fullClosure: full,
    detour: detour,
    startUnix: _unix(a['start']),
    endUnix: _unix(a['until']),
    fields: item.fields,
    detourSteps: steps is List ? [for (final s in steps) if ('$s'.trim().isNotEmpty) '$s'.trim()] : (steps is String && steps.trim().isNotEmpty ? [steps.trim()] : const []),
    updated: item.time,
    credit: credit,
    stale: stale,
    age: age,
  );
}

LL? _pointOf(LiveItem item) {
  final p = item.point;
  return p == null ? null : LL(p.lat, p.lon);
}

/// A WZDx feed's stored item as a road event.
RoadEvent? roadEventFromWzdx(LiveItem item, {required String sourceId, required String credit, bool stale = false, String? age}) {
  final a = item.app;
  final line = _lineOf(a['geom']);
  final pt = _pointOf(item) ?? (line.isEmpty ? null : middleOf(line));
  if (pt == null) return null;
  final road = a['road'];
  final start = _rfc(a['start']), until = _rfc(a['until']);
  return RoadEvent(
    id: '$sourceId/${item.key}',
    source: RoadEventSource.workZone,
    sourceId: sourceId,
    kind: RoadEventKind.work,
    road: road is List && road.isNotEmpty ? '${road.first}' : (road is String ? road : item.label),
    line: line.length > 1 ? line : const [],
    point: pt,
    heading: headingOf(a['dir']),
    fullClosure: a['impact'] == 'all-lanes-closed',
    startUnix: start == null ? null : start.millisecondsSinceEpoch ~/ 1000,
    endUnix: until == null ? null : until.millisecondsSinceEpoch ~/ 1000,
    fields: item.fields,
    updated: item.time,
    credit: credit,
    stale: stale,
    age: age,
  );
}

/// The state the map reads: the events, and the one a tap chose.
class RoadEventsState extends ChangeNotifier {
  /// [changes] tells when what is stored may have changed (the weather part, after a download); [read] reads the events from what is
  /// stored (see [RoadEventsState.fromWeather]). A test gives both.
  RoadEventsState({required this.changes, required this.read, this.debounce = const Duration(milliseconds: 800)}) {
    changes.addListener(_onChange);
  }

  /// The events of the road sources that are on, read from what the weather part stored for the places it watches.
  factory RoadEventsState.fromWeather(WeatherState weather, RoadSources roads) => RoadEventsState(changes: weather, read: () => readRoadEvents(weather, roads));

  final Listenable changes;
  final Future<List<RoadEvent>> Function() read;

  /// How long a burst of changes waits before the stored data is read again (the weather part notifies often; reading asks the core for
  /// every watched place).
  final Duration debounce;
  Timer? _timer;

  List<RoadEvent> _events = const [];
  String? _selectedId;
  bool _disposed = false;
  bool _reading = false;
  bool _again = false;
  String _sig = '';

  /// The events to draw: de-duplicated (a 511 event and a WZDx work zone that are the same work zone are one, the 511 one).
  List<RoadEvent> get events => _events;

  String? get selectedId => _selectedId;

  RoadEvent? get selected {
    for (final e in _events) {
      if (e.id == _selectedId) return e;
    }
    return null;
  }

  void select(String? id) {
    if (id == _selectedId) return;
    _selectedId = id;
    notifyListeners();
  }

  void _onChange() {
    if (debounce == Duration.zero) {
      unawaited(refresh());
      return;
    }
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(refresh()));
  }

  /// Reads what is stored, then tells listeners if the picture changed.
  Future<void> refresh() async {
    if (_disposed) return;
    if (_reading) {
      _again = true;
      return;
    }
    _reading = true;
    try {
      do {
        _again = false;
        final next = await read();
        final sig = next.map((e) => '${e.id}${e.stale}').join('|');
        if (_disposed) return;
        if (sig != _sig) {
          _sig = sig;
          _events = next;
          if (_selectedId != null && !next.any((e) => e.id == _selectedId)) _selectedId = null;
          notifyListeners();
        }
      } while (_again);
    } finally {
      _reading = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    changes.removeListener(_onChange);
    super.dispose();
  }
}

/// Reads every watched place's stored data for every road source that is on: 511 events (a site's winter road conditions are not
/// drawn) and WZDx work zones, one event once however many places stored it, with a 511 event and a WZDx work zone that are the same
/// work zone drawn once ([dedupeWorkZones]).
Future<List<RoadEvent>> readRoadEvents(WeatherState weather, RoadSources roads) async {
  final on = [for (final s in roads.sources) for (final c in s.connectors) if (weather.isOn(c.id)) (s, c)];
  if (on.isEmpty) return const [];
  final places = await weather.watchedPlaces();
  final found = <String, RoadEvent>{};
  for (final p in places) {
    final List<SourceView> views;
    try {
      views = await weather.viewFor(p);
    } catch (_) {
      continue;
    }
    for (final v in views) {
      final hit = [for (final (s, c) in on) if (c.id == v.source.id) (s, c)].firstOrNull;
      if (hit == null) continue;
      final (s, c) = hit;
      final isSite = s.record.isSite;
      // The site's winter road conditions are not drawn: only its events are.
      if (isSite && c.id != s.connectors.first.id) continue;
      final credit = isSite ? 'Road events: ${s.site!.name} 511' : 'Road work: ${s.feed?.publisher ?? c.provider}';
      for (final item in v.items) {
        if (item.noneActive) continue;
        final e = isSite ? roadEventFrom511(item, sourceId: c.id, credit: credit, stale: v.expired, age: v.age) : roadEventFromWzdx(item, sourceId: c.id, credit: credit, stale: v.expired, age: v.age);
        if (e != null) found.putIfAbsent(e.id, () => e);
      }
    }
  }
  return dedupeWorkZones(found.values.toList());
}
