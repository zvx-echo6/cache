import 'dart:convert';

import 'package:cache_search/cache_search.dart' show MapPlace;

import 'poi_chips.dart' show poiKindName;
import 'user_layers.dart' show RepeaterNotebookSource;

/// What a tap on the phone's map can land on, beyond the screen's own pins and lines (notebook pins, repeaters, search results'
/// pins, the route preview's lines): a label of the base map (a place, a town, a point of interest, a road's name), a line of an
/// overlay or of a file imported into a Places notebook, or an area of either.
enum TapTier { label, line, area }

/// Where a tapped feature was drawn from.
enum TapSource { basemap, imported, overlay }

/// One feature under a tap, as the map's query of rendered features gave it, read into what a card needs.
class TapFeature {
  const TapFeature({required this.source, required this.tier, required this.name, required this.kind, required this.lat, required this.lon, this.notebookId, this.poi = false});

  final TapSource source;
  final TapTier tier;

  /// The feature's own name from its properties; null when it has none.
  final String? name;

  /// What it is, as the map already names its layer: an overlay's title, an imported file's notebook; empty for the base map.
  final String kind;

  /// Where Directions go: a label's own point, else the tapped spot.
  final double lat;
  final double lon;

  /// The Places notebook an imported line or area belongs to (its "Open").
  final String? notebookId;

  /// A public place of the base map's POI layer (a chip), which wins a tap over a town or road name beside it.
  final bool poi;

  bool get named => name != null && name!.isNotEmpty;
}

/// What a tap opens: the place card of [place]; [notebookId] gives it Open to that notebook (a feature of an imported file).
class TapChoice {
  const TapChoice(this.place, {this.notebookId});

  final MapPlace place;
  final String? notebookId;
}

/// The property keys that hold a feature's name in the tiles the app draws (machine field names of the tile schemas, not words):
/// the base map's `name` (OpenMapTiles and Protomaps), and the overlays' published fields (Forest Service trails and roads, MVUM,
/// BLM routes, PAD-US units).
const List<String> kFeatureNameKeys = ['name', 'NAME', 'name:latin', 'name_en', 'TRAIL_NAME', 'ROUTE_PRMRY_NM', 'Unit_Nm', 'Loc_Nm'];

/// The feature's name from [properties]: the first of [kFeatureNameKeys] with text; null when none has.
String? featureName(Object? properties) {
  if (properties is! Map) return null;
  for (final k in kFeatureNameKeys) {
    final v = properties[k];
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  return null;
}

/// Reads one feature of the map's query ([raw], a GeoJSON feature) drawn from [source]. A base-map feature is a label whatever its
/// geometry (a road's name runs along its line); the others are a line or an area by their geometry. Null for a feature that cannot
/// be read, a point of an overlay (the map draws none), or a base-map label with no name.
TapFeature? tapFeatureFrom(Object? raw, {required TapSource source, required String kind, required double tapLat, required double tapLon, String? notebookId, bool poi = false}) {
  if (raw is! Map) return null;
  final g = raw['geometry'];
  final type = g is Map ? '${g['type']}' : '';
  final name = featureName(raw['properties']);
  final TapTier tier;
  if (source == TapSource.basemap) {
    if (name == null) return null;
    tier = TapTier.label;
  } else if (type.endsWith('LineString')) {
    tier = TapTier.line;
  } else if (type.endsWith('Polygon')) {
    tier = TapTier.area;
  } else {
    return null;
  }
  var lat = tapLat, lon = tapLon;
  if (type == 'Point' && g is Map && g['coordinates'] is List) {
    final c = g['coordinates'] as List;
    if (c.length >= 2 && c[0] is num && c[1] is num) {
      lon = (c[0] as num).toDouble();
      lat = (c[1] as num).toDouble();
    }
  }
  if (poi) {
    final props = raw['properties'];
    kind = poiKindName(props is Map ? props['kind'] as String? : null);
  }
  return TapFeature(source: source, tier: tier, name: name, kind: kind, lat: lat, lon: lon, notebookId: notebookId, poi: poi);
}

/// The base map's label layers in a style ([styleJson], as the screen applied it): its symbol layers drawn from the base map's
/// source (not the app's own sources, nor an overlay's contour labels).
List<String> basemapLabelLayers(String styleJson, {required String basemapSource}) {
  try {
    final s = jsonDecode(styleJson);
    final layers = s is Map ? s['layers'] : null;
    if (layers is! List) return const [];
    return [
      for (final l in layers)
        if (l is Map && l['type'] == 'symbol' && l['source'] == basemapSource && l['id'] is String) l['id'] as String,
    ];
  } catch (_) {
    return const [];
  }
}

/// The base map's line layers in a style ([styleJson], as the screen applied it): its paths, tracks, roads, rivers, from the base
/// map's source. A feature of one with a name is a tap on that road or path; one without opens nothing.
List<String> basemapLineLayers(String styleJson, {required String basemapSource}) {
  try {
    final s = jsonDecode(styleJson);
    final layers = s is Map ? s['layers'] : null;
    if (layers is! List) return const [];
    return [
      for (final l in layers)
        if (l is Map && l['type'] == 'line' && l['source'] == basemapSource && l['id'] is String) l['id'] as String,
    ];
  } catch (_) {
    return const [];
  }
}

/// The line and area layers an overlay drew into a style ([styleJson], as the screen applied it): its layers of type line (the
/// route's line and its casing) and fill, from its source. What a tap asks for is what the style has, not the ids worked out again.
List<String> overlayHitLayers(String styleJson, {required String source}) {
  try {
    final s = jsonDecode(styleJson);
    final layers = s is Map ? s['layers'] : null;
    if (layers is! List) return const [];
    return [
      for (final l in layers)
        if (l is Map && (l['type'] == 'line' || l['type'] == 'fill') && l['source'] == source && l['id'] is String) l['id'] as String,
    ];
  } catch (_) {
    return const [];
  }
}

/// The one feature a tap opens among [hits]: a label first (a public place's chip before a town or road name), then a line, then an
/// area; within each, a named one first, then the base map, a file the user imported (drawn above the overlays), an overlay, each in
/// the order the map gave them. Null: none. (The user's own pins and routes are asked before any of this, by the screen.)
TapFeature? pickTapFeature(List<TapFeature> hits) {
  TapFeature? best;
  int rank(TapFeature f) => f.tier.index * 100 + (f.poi ? 0 : 20) + (f.named ? 0 : 10) + f.source.index;
  for (final f in hits) {
    if (best == null || rank(f) < rank(best)) best = f;
  }
  return best;
}

/// How far from a label's point a place of the places data may be and still be that label's place, in points on the screen.
const double kLabelMatchReach = 60;

/// The least such distance in metres, whatever the zoom.
const double kLabelMatchFloorM = 300;

String _norm(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// The place of the places data that a base-map label is ([candidates], the core's map search for the label's name near it): one
/// of the same name (letter case and spacing aside) within [reachM] of the label's point, the nearest. Null: none.
MapPlace? matchLabelPlace(TapFeature label, List<MapPlace> candidates, {required double reachM}) {
  if (!label.named) return null;
  final want = _norm(label.name!);
  MapPlace? best;
  var bestM = double.infinity;
  for (final p in candidates) {
    if (p.isCategory || p.isCoordinates || _norm(p.name) != want) continue;
    final d = RepeaterNotebookSource.metresBetween(label.lat, label.lon, p.lat, p.lon);
    if (d <= reachM && d < bestM) {
      best = p;
      bestM = d;
    }
  }
  return best;
}

/// The `matched` mark of the card of a chip the places data did not have.
const String kPoiMatched = 'poi';

/// What [f] opens: the matched place of the places data ([match]) for a label, with its details and Directions as a search
/// result has; else a card naming the feature at its point, so Directions go there. An imported feature's card has Open to its
/// notebook (and no Save: it is in that notebook already).
TapChoice tapChoiceFor(TapFeature f, {MapPlace? match}) {
  if (f.source == TapSource.basemap && match != null) return TapChoice(match);
  final at = '${f.lat.toStringAsFixed(6)},${f.lon.toStringAsFixed(6)}';
  final imported = f.source == TapSource.imported;
  return TapChoice(
    MapPlace(
      // `notebook:` keeps Save off an imported feature's card; `loc:` is the spot as cs_map_route takes it.
      id: imported ? 'notebook:layer:${f.notebookId ?? ''}@$at' : 'loc:$at',
      type: 'place',
      name: f.named ? f.name! : f.kind,
      kind: f.named ? f.kind : '',
      lat: f.lat,
      lon: f.lon,
      // A chip with no place of the places data: its card says so ([kPoiNoMatch]) instead of being bare.
      matched: f.poi ? kPoiMatched : '',
    ),
    notebookId: imported ? f.notebookId : null,
  );
}

/// The whole choice for a tap: the feature [pickTapFeature] takes from [hits], matched against [candidates] when it is a label.
/// Null when the tap is on nothing.
TapChoice? chooseMapTap(List<TapFeature> hits, {List<MapPlace> candidates = const [], double reachM = kLabelMatchFloorM}) {
  final f = pickTapFeature(hits);
  if (f == null) return null;
  return tapChoiceFor(f, match: f.tier == TapTier.label ? matchLabelPlace(f, candidates, reachM: reachM) : null);
}
