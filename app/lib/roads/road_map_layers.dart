import 'dart:math' as math;

import '../maps/palette/map_palette.dart';
import 'road_event.dart';
import 'road_geo.dart';

/// The map's road event layers: closures, crashes and work zones from the data the sources already stored. One GeoJSON source
/// ([kRoadEventSource]) and a few style layers, drawn above the base map's roads and labels so an event is never under a name:
/// each event line is drawn beside the road it is on (MapLibre `line-offset`, growing with zoom), on the travel side, with the same casing
/// the route has; the road and its name stay readable. The chips sit on the road and win a tap over the name under them.

/// The source and layer ids.
const String kRoadEventSource = 'cache-road-events';
const String kRoadEventCasing = 'road-event-casing';
const String kRoadEventClosure = 'road-event-closure';
const String kRoadEventWork = 'road-event-work';
const String kRoadEventDetour = 'road-event-detour';
const String kRoadEventSelected = 'road-event-selected';
const String kRoadEventChips = 'road-event-chips';

/// What a tap on an event can hit: the chip and the three kinds of line, in the order the tap asks (a chip first).
const List<String> roadEventTapLayers = [kRoadEventChips, kRoadEventClosure, kRoadEventWork, kRoadEventDetour];

/// The chip images the style names: a block sign for a closure, a car crash for a crash or incident, a construction sign for work.
const String kRoadChipClosure = 'road-chip-closure';
const String kRoadChipCrash = 'road-chip-crash';
const String kRoadChipWork = 'road-chip-work';

/// The image of the chip of [kind].
String roadChipImage(RoadEventKind kind) => switch (kind) {
  RoadEventKind.closure => kRoadChipClosure,
  RoadEventKind.crash => kRoadChipCrash,
  RoadEventKind.work => kRoadChipWork,
};

/// The palette role of the colour of [kind]: closure and crash chips `eventClosure`, work `eventWork`.
String roadEventRole(RoadEventKind kind) => kind == RoadEventKind.work ? 'eventWork' : 'eventClosure';

/// Zoom from which each layer shows (from the design's render; to be tuned on a phone).
const double kRoadEventMinZoom = 9;
const double kRoadDetourMinZoom = 11;

/// The side of its geometry's own direction an event line is drawn on: 1 for the right, -1 for the left (MapLibre's `line-offset` is
/// positive to the right of the line's direction). An event with a heading is drawn on the right-hand side of its direction of travel:
/// when the geometry runs the other way, that is the geometry's left. With no heading it is on the right of the geometry's direction.
int sideOf(List<LL> line, Heading? heading) {
  if (heading == null || line.length < 2) return 1;
  final a = line.first, b = line.last;
  final de = (b.lon - a.lon) * math.cos(a.lat * math.pi / 180); // east
  final dn = b.lat - a.lat; // north
  final (he, hn) = switch (heading) {
    Heading.north => (0.0, 1.0),
    Heading.south => (0.0, -1.0),
    Heading.east => (1.0, 0.0),
    Heading.west => (-1.0, 0.0),
  };
  return de * he + dn * hn < 0 ? -1 : 1;
}

List<List<double>> _coords(List<LL> line) => [for (final p in line) [p.lon, p.lat]];

/// The GeoJSON the source holds: for each event its line (closure or work), its detour, and its chip.
///
/// A line is drawn for a closure (or a full closure), a work zone, and a detour; a crash or incident has its chip only. An event whose copy
/// is out of date is drawn dimmed (`dim`), not hidden: a closure that vanished because the phone was off the network would be a wrong answer
/// about a road. [selectedId] marks the chip and the lines of the tapped event (`sel`), which the selection ring and a wider line use.
Map<String, dynamic> roadEventsGeoJson(List<RoadEvent> events, {String? selectedId}) {
  final features = <Map<String, dynamic>>[];
  for (final e in events) {
    final sel = e.id == selectedId;
    final dim = e.stale;
    final side = sideOf(e.line, e.heading);
    if (e.line.length > 1) {
      final role = e.kind == RoadEventKind.work ? 'work' : (e.kind == RoadEventKind.closure || e.fullClosure ? 'closure' : null);
      if (role != null) {
        features.add({
          'type': 'Feature',
          'properties': {'id': e.id, 'role': role, 'side': side, 'dim': dim, 'sel': sel},
          'geometry': {'type': 'LineString', 'coordinates': _coords(e.line)},
        });
      }
    }
    if (e.detour.length > 1) {
      features.add({
        'type': 'Feature',
        'properties': {'id': e.id, 'role': 'detour', 'side': 1, 'dim': dim, 'sel': sel},
        'geometry': {'type': 'LineString', 'coordinates': _coords(e.detour)},
      });
    }
    final at = e.chipAt;
    features.add({
      'type': 'Feature',
      'properties': {'id': e.id, 'role': 'chip', 'kind': e.kind.name, 'icon': roadChipImage(e.kind), 'dim': dim, 'sel': sel},
      'geometry': {'type': 'Point', 'coordinates': [at.lon, at.lat]},
    });
  }
  return {'type': 'FeatureCollection', 'features': features};
}

/// The line offset beside the road: [near] pixels at zoom 9 growing to [far] at zoom 15, times the feature's side (1 or -1).
List<Object> _offset(double near, double far) => [
  'interpolate',
  ['linear'],
  ['zoom'],
  9,
  ['*', ['get', 'side'], near],
  15,
  ['*', ['get', 'side'], far],
];

List<Object> _width(double near, double far) => [
  'interpolate',
  ['linear'],
  ['zoom'],
  9,
  near,
  15,
  far,
];

/// The style layers of the road events, for [p]'s theme. They go above every base-map layer, under the route and the pins.
List<Map<String, dynamic>> roadEventLayers(MapPalette p) {
  final dimOpacity = ['case', ['get', 'dim'], 0.45, 1.0];
  final isLine = ['==', ['geometry-type'], 'LineString'];
  return [
    {
      'id': kRoadEventCasing,
      'type': 'line',
      'source': kRoadEventSource,
      'minzoom': kRoadEventMinZoom,
      'filter': ['all', isLine, ['in', ['get', 'role'], ['literal', ['closure', 'work', 'detour']]]],
      'layout': {'line-cap': 'round', 'line-join': 'round'},
      'paint': {'line-color': p.css('routeCasing'), 'line-width': _width(5, 11), 'line-offset': _offset(3, 13), 'line-opacity': dimOpacity},
    },
    {
      'id': kRoadEventClosure,
      'type': 'line',
      'source': kRoadEventSource,
      'minzoom': kRoadEventMinZoom,
      'filter': ['all', isLine, ['==', ['get', 'role'], 'closure']],
      'layout': {'line-cap': 'round', 'line-join': 'round'},
      'paint': {'line-color': p.css('eventClosure'), 'line-width': ['case', ['get', 'sel'], 8, 4], 'line-offset': _offset(3, 13), 'line-opacity': dimOpacity},
    },
    {
      'id': kRoadEventWork,
      'type': 'line',
      'source': kRoadEventSource,
      'minzoom': kRoadEventMinZoom,
      'filter': ['all', isLine, ['==', ['get', 'role'], 'work']],
      'layout': {'line-cap': 'butt', 'line-join': 'round'},
      'paint': {'line-color': p.css('eventWork'), 'line-width': ['case', ['get', 'sel'], 8, 4], 'line-dasharray': [2, 1.5], 'line-offset': _offset(3, 13), 'line-opacity': dimOpacity},
    },
    {
      'id': kRoadEventDetour,
      'type': 'line',
      'source': kRoadEventSource,
      'minzoom': kRoadDetourMinZoom,
      'filter': ['all', isLine, ['==', ['get', 'role'], 'detour']],
      'layout': {'line-cap': 'butt', 'line-join': 'round'},
      'paint': {'line-color': p.css('route'), 'line-width': 4, 'line-dasharray': [2, 1.5], 'line-offset': _offset(3, 13), 'line-opacity': dimOpacity},
    },
    {
      'id': kRoadEventSelected,
      'type': 'circle',
      'source': kRoadEventSource,
      'minzoom': kRoadEventMinZoom,
      'filter': ['all', ['==', ['geometry-type'], 'Point'], ['==', ['get', 'sel'], true]],
      'paint': {'circle-radius': 19, 'circle-color': 'rgba(0,0,0,0)', 'circle-stroke-width': 3, 'circle-stroke-color': p.css('pin')},
    },
    {
      'id': kRoadEventChips,
      'type': 'symbol',
      'source': kRoadEventSource,
      'minzoom': kRoadEventMinZoom,
      'filter': ['all', ['==', ['geometry-type'], 'Point'], ['==', ['get', 'role'], 'chip']],
      'layout': {
        'icon-image': ['get', 'icon'],
        'icon-size': ['interpolate', ['linear'], ['zoom'], 9, 0.8, 15, 1.15],
        'icon-allow-overlap': true,
        'icon-ignore-placement': true,
      },
      'paint': {'icon-opacity': dimOpacity},
    },
  ];
}

/// Which event a tap chose, from the events the query found around the tapped point (their `id` values, nearest first as the query
/// gives them). Where two overlap the tap, the full closure wins, then the nearest: the first of [hitIds] that is a full closure, else the first.
String? pickEvent(List<String> hitIds, List<RoadEvent> events) {
  if (hitIds.isEmpty) return null;
  final byId = {for (final e in events) e.id: e};
  final known = [for (final id in hitIds) if (byId.containsKey(id)) id];
  if (known.isEmpty) return null;
  for (final id in known) {
    if (byId[id]!.fullClosure) return id;
  }
  return known.first;
}
