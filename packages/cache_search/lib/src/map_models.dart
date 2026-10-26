// The map calls of the core (cs_map_search, cs_map_route, cs_map_progress) as Dart values. The JSON shapes are
// documented in native/include/cache_search.h; these classes only read them.
/// A point on the earth, in degrees.
class GeoPoint {
  const GeoPoint(this.lat, this.lon);

  final double lat;
  final double lon;

  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon};

  @override
  bool operator ==(Object other) => other is GeoPoint && other.lat == lat && other.lon == lon;

  @override
  int get hashCode => Object.hash(lat, lon);

  @override
  String toString() => '$lat,$lon';
}

double? _d(Object? v) => v is num ? v.toDouble() : null;
int? _i(Object? v) => v is num ? v.round() : null;
String? _s(Object? v) => v is String && v.isNotEmpty ? v : null;
Map<String, dynamic> _m(Object? v) => v is Map ? v.cast<String, dynamic>() : const {};
List<dynamic> _l(Object? v) => v is List ? v : const [];

/// Polyline6 (Google's polyline algorithm at 1e-6 degrees, as Valhalla writes route shapes) to points.
List<GeoPoint> decodePolyline6(String encoded) {
  final out = <GeoPoint>[];
  var i = 0, lat = 0, lon = 0;
  while (i < encoded.length) {
    for (var axis = 0; axis < 2; axis++) {
      var shift = 0, result = 0;
      int c;
      do {
        if (i >= encoded.length) return out;
        c = encoded.codeUnitAt(i++) - 63;
        result |= (c & 0x1f) << shift;
        shift += 5;
      } while (c >= 0x20);
      final delta = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      if (axis == 0) {
        lat += delta;
      } else {
        lon += delta;
      }
    }
    out.add(GeoPoint(lat / 1e6, lon / 1e6));
  }
  return out;
}

/// A query vector made by the app's embedder: the model id (it must equal the one the places pack was embedded with)
/// and the vector.
class MapQueryVector {
  const MapQueryVector(this.model, this.vector);

  final String model;
  final List<double> vector;

  Map<String, dynamic> toJson() => {'model': model, 'vector': vector};
}

/// One row of the search box's answer: a place, a town, a category, or a point from coordinates.
class MapPlace {
  const MapPlace({
    required this.id,
    required this.type,
    required this.name,
    required this.kind,
    this.category,
    this.address = '',
    required this.lat,
    required this.lon,
    this.distanceM,
    this.direction,
    this.bearingDeg,
    this.matched = '',
    this.score = 0,
    this.phone,
    this.hours,
    this.website,
    this.summary,
    this.wikipediaTitle,
    this.wikidataId,
    this.formats = const {},
    this.format,
    this.precisionM,
  });

  factory MapPlace.fromJson(Map<String, dynamic> j) => MapPlace(
        id: j['id'] as String,
        type: (j['type'] ?? 'place') as String,
        name: (j['name'] ?? '') as String,
        kind: (j['kind'] ?? '') as String,
        category: _s(j['category']),
        address: (j['address'] ?? '') as String,
        lat: _d(j['lat']) ?? 0,
        lon: _d(j['lon']) ?? 0,
        distanceM: _d(j['distance_m']),
        direction: _s(j['direction']),
        bearingDeg: _i(j['bearing_deg']),
        matched: (j['matched'] ?? '') as String,
        score: _d(j['score']) ?? 0,
        phone: _s(j['phone']),
        hours: _s(j['hours']),
        website: _s(j['website']),
        summary: _s(j['summary']),
        wikipediaTitle: _s(j['wikipedia_title']),
        wikidataId: _s(j['wikidata_id']),
        formats: {for (final e in _m(j['formats']).entries) e.key: e.value.toString()},
        format: _s(j['format']),
        precisionM: _d(j['precision_m']),
      );

  /// A point the user dropped on the map (long-press): shown as "Dropped pin" with its coordinates.
  factory MapPlace.pin(double lat, double lon, {Map<String, String> formats = const {}}) => MapPlace(
        id: 'loc:${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}',
        type: 'coordinates',
        name: 'Dropped pin',
        kind: 'Coordinates',
        lat: lat,
        lon: lon,
        matched: 'pin',
        formats: formats,
      );

  /// `place:<id>`, `town:<id>`, `loc:<lat>,<lon>` or `category:<id>`; what cs_map_route takes as an end.
  final String id;

  /// "place", "town", "category" or "coordinates".
  final String type;
  final String name;

  /// "Pharmacy", "City", "Coordinates": what it is, in plain words.
  final String kind;
  final String? category;
  final String address;
  final double lat;
  final double lon;
  final double? distanceM;
  final String? direction;
  final int? bearingDeg;

  /// "name", "category", "meaning", "coordinates" (or "pin").
  final String matched;
  final double score;
  final String? phone;
  final String? hours;
  final String? website;

  /// The first paragraph of the place's Wikipedia article, where the pack has one.
  final String? summary;
  final String? wikipediaTitle;
  final String? wikidataId;

  /// For coordinates: decimal, dms, usng, plus_code.
  final Map<String, String> formats;
  final String? format;
  final double? precisionM;

  bool get isCategory => type == 'category';
  bool get isCoordinates => type == 'coordinates';
  GeoPoint get point => GeoPoint(lat, lon);

  /// The end object cs_map_route takes.
  Map<String, dynamic> toEnd() => {if (!isCategory) 'id': id, 'lat': lat, 'lon': lon, 'name': name};
}

class MapSearchResponse {
  const MapSearchResponse({
    required this.query,
    required this.kind,
    this.anchorName,
    this.categories = const [],
    required this.meaning,
    required this.results,
    this.warning,
  });

  factory MapSearchResponse.fromJson(Map<String, dynamic> j) {
    final interp = _m(j['interpreted']);
    return MapSearchResponse(
      query: (j['query'] ?? '') as String,
      kind: (interp['kind'] ?? 'text') as String,
      anchorName: _s(_m(interp['anchor'])['name']),
      categories: [for (final c in _l(interp['categories'])) c.toString()],
      meaning: (j['meaning'] ?? 'off') as String,
      results: [for (final r in _l(j['results'])) MapPlace.fromJson(_m(r))],
      warning: _s(j['warning']),
    );
  }

  final String query;

  /// "coordinates", "text" or "empty".
  final String kind;

  /// The town the query named ("pharmacy near Burley" -> "Burley").
  final String? anchorName;
  final List<String> categories;

  /// "used", "off", "no_embedder", "no_vectors" or "model_mismatch": whether the meaning step ran.
  final String meaning;
  final List<MapPlace> results;
  final String? warning;
}

/// A stretch of the route drawn one way: "road" (Valhalla), "offroad" (straight legs over the grid) or "follow"
/// (along a mapped track or trail).
class RouteSegment {
  const RouteSegment({required this.kind, required this.travel, required this.startIndex, required this.endIndex, required this.distanceM});

  factory RouteSegment.fromJson(Map<String, dynamic> j) => RouteSegment(
        kind: (j['kind'] ?? 'road') as String,
        travel: (j['travel'] ?? '') as String,
        startIndex: _i(j['start_index']) ?? 0,
        endIndex: _i(j['end_index']) ?? 0,
        distanceM: _d(j['distance_m']) ?? 0,
      );

  final String kind;

  /// drive/walk/bike for road stretches; foot, 2w, 4w, vehicle off-road.
  final String travel;
  final int startIndex;
  final int endIndex;
  final double distanceM;

  bool get isRoad => kind == 'road';
}

class Maneuver {
  const Maneuver({
    required this.index,
    required this.kind,
    required this.type,
    required this.instruction,
    this.streetNames = const [],
    required this.distanceM,
    required this.durationS,
    required this.lat,
    required this.lon,
    required this.beginIndex,
    required this.endIndex,
    this.bearingDeg,
    this.cardinal,
    this.travel,
    this.gradeClass,
    this.elevGainM,
    this.elevLossM,
    this.terrain,
  });

  factory Maneuver.fromJson(Map<String, dynamic> j) => Maneuver(
        index: _i(j['index']) ?? 0,
        kind: (j['kind'] ?? 'road') as String,
        type: (j['type'] ?? '') as String,
        instruction: (j['instruction'] ?? '') as String,
        streetNames: [for (final s in _l(j['street_names'])) s.toString()],
        distanceM: _d(j['distance_m']) ?? 0,
        durationS: _i(j['duration_s']) ?? 0,
        lat: _d(j['lat']) ?? 0,
        lon: _d(j['lon']) ?? 0,
        beginIndex: _i(j['begin_index']) ?? 0,
        endIndex: _i(j['end_index']) ?? 0,
        bearingDeg: _i(j['bearing_deg']),
        cardinal: _s(j['cardinal']),
        travel: _s(j['travel']),
        gradeClass: _s(j['grade_class']),
        elevGainM: _i(j['elev_gain_m']),
        elevLossM: _i(j['elev_loss_m']),
        terrain: _s(j['terrain']),
      );

  final int index;

  /// "road", "offroad" or "offroad_follow".
  final String kind;

  /// Valhalla's maneuver type ("left", "destination", "roundabout_enter", ...), "via" for a stop.
  final String type;
  final String instruction;
  final List<String> streetNames;
  final double distanceM;
  final int durationS;
  final double lat;
  final double lon;
  final int beginIndex;
  final int endIndex;
  final int? bearingDeg;
  final String? cardinal;
  final String? travel;
  final String? gradeClass;
  final int? elevGainM;
  final int? elevLossM;
  final String? terrain;

  bool get isOffroad => kind != 'road';
  bool get isArrival => type.startsWith('destination');
}

class RouteTotals {
  const RouteTotals({required this.distanceM, required this.durationS, required this.roadM, required this.offroadM, required this.ascentM, required this.descentM});

  factory RouteTotals.fromJson(Map<String, dynamic> j) => RouteTotals(
        distanceM: _d(j['distance_m']) ?? 0,
        durationS: _i(j['duration_s']) ?? 0,
        roadM: _d(j['road_m']) ?? 0,
        offroadM: _d(j['offroad_m']) ?? 0,
        ascentM: _i(j['ascent_m']) ?? 0,
        descentM: _i(j['descent_m']) ?? 0,
      );

  final double distanceM;
  final int durationS;
  final double roadM;
  final double offroadM;
  final int ascentM;
  final int descentM;
}

class RouteWarning {
  const RouteWarning({required this.code, this.end, this.gapM});

  final String code;
  final String? end;
  final int? gapM;
}

/// A route error: the router's own code (no_route, too_far, out_of_coverage, route_too_long, ...).
class RouteError {
  const RouteError(this.code, this.message);

  final String code;
  final String message;
}

/// The complete route of cs_map_route (or one of its alternatives).
class MapRoute {
  MapRoute._({
    required this.ok,
    required this.routeId,
    required this.mode,
    required this.landAccess,
    required this.routing,
    required this.distanceM,
    required this.durationS,
    required this.totals,
    required this.geometry,
    required this.segments,
    required this.maneuvers,
    required this.warnings,
    required this.alternatives,
    required this.errors,
    required this.from,
    required this.to,
    required this.via,
    required this.raw,
  });

  factory MapRoute.fromJson(Map<String, dynamic> j) {
    final ok = j['ok'] != false;
    return MapRoute._(
      ok: ok,
      routeId: (j['route_id'] ?? '') as String,
      mode: (j['mode'] ?? 'drive') as String,
      landAccess: (j['land_access'] ?? 'pragmatic') as String,
      routing: (j['routing'] ?? 'road') as String,
      distanceM: _d(j['distance_m']) ?? 0,
      durationS: _i(j['duration_s']) ?? 0,
      totals: RouteTotals.fromJson(_m(j['totals'])),
      geometry: (j['geometry'] ?? '') as String,
      segments: [for (final s in _l(j['segments'])) RouteSegment.fromJson(_m(s))],
      maneuvers: [for (final m in _l(j['maneuvers'])) Maneuver.fromJson(_m(m))],
      warnings: [
        for (final w in _l(j['warnings']))
          RouteWarning(code: (_m(w)['code'] ?? '') as String, end: _s(_m(w)['end']), gapM: _i(_m(w)['gap_m'])),
      ],
      alternatives: [for (final a in _l(j['alternatives'])) MapRoute.fromJson(_m(a))],
      errors: [for (final e in _l(j['errors'])) RouteError((_m(e)['code'] ?? 'internal') as String, (_m(e)['message'] ?? '') as String)],
      from: _m(j['from']),
      to: _m(j['to']),
      via: [for (final v in _l(j['via'])) _m(v)],
      raw: j,
    );
  }

  final bool ok;
  final String routeId;
  final String mode;
  final String landAccess;

  /// "road" or "offroad" (the route has off-road legs).
  final String routing;
  final double distanceM;
  final int durationS;
  final RouteTotals totals;

  /// Polyline6; [points] decodes it.
  final String geometry;
  final List<RouteSegment> segments;
  final List<Maneuver> maneuvers;
  final List<RouteWarning> warnings;
  final List<MapRoute> alternatives;
  final List<RouteError> errors;
  final Map<String, dynamic> from;
  final Map<String, dynamic> to;
  final List<Map<String, dynamic>> via;

  /// The route object as the core wrote it: cs_map_progress is given this again after a restart.
  final Map<String, dynamic> raw;

  List<GeoPoint>? _points;

  List<GeoPoint> get points => _points ??= decodePolyline6(geometry);

  bool get hasOffroad => segments.any((s) => !s.isRoad);

  String get destinationName => (to['name'] ?? '') as String;
  GeoPoint get destination => GeoPoint(_d(to['lat']) ?? points.last.lat, _d(to['lon']) ?? points.last.lon);

  /// The points of a segment, ends included.
  List<GeoPoint> segmentPoints(RouteSegment s) => points.sublist(s.startIndex.clamp(0, points.length - 1), (s.endIndex + 1).clamp(1, points.length));

  /// The bounding box of the route: south, west, north, east.
  List<double> get bounds {
    var s = 90.0, w = 180.0, n = -90.0, e = -180.0;
    for (final p in points) {
      if (p.lat < s) s = p.lat;
      if (p.lat > n) n = p.lat;
      if (p.lon < w) w = p.lon;
      if (p.lon > e) e = p.lon;
    }
    return [s, w, n, e];
  }
}

class ProgressManeuver {
  const ProgressManeuver({
    required this.index,
    required this.kind,
    required this.type,
    required this.instruction,
    this.streetNames = const [],
    this.travel,
    required this.lat,
    required this.lon,
    required this.distanceM,
    this.lengthM = 0,
    this.cardinal,
    this.bearingDeg,
    this.elevGainM,
    this.elevLossM,
    this.gradeClass,
    this.followName,
    this.trailKind,
  });

  factory ProgressManeuver.fromJson(Map<String, dynamic> j) => ProgressManeuver(
        index: _i(j['index']) ?? 0,
        kind: (j['kind'] ?? 'road') as String,
        type: (j['type'] ?? '') as String,
        instruction: (j['instruction'] ?? '') as String,
        streetNames: [for (final s in _l(j['street_names'])) s.toString()],
        travel: _s(j['travel']),
        lat: _d(j['lat']) ?? 0,
        lon: _d(j['lon']) ?? 0,
        distanceM: _d(j['distance_m']) ?? 0,
        lengthM: _d(j['length_m']) ?? 0,
        cardinal: _s(j['cardinal']),
        bearingDeg: _i(j['bearing_deg']),
        elevGainM: _i(j['elev_gain_m']),
        elevLossM: _i(j['elev_loss_m']),
        gradeClass: _s(j['grade_class']),
        followName: _s(_m(j['follow'])['name']),
        trailKind: _s(_m(j['follow'])['trail_kind']),
      );

  final int index;
  final String kind;
  final String type;
  final String instruction;
  final List<String> streetNames;
  final String? travel;
  final double lat;
  final double lon;

  /// To this maneuver from the fix (for `next`), or from `next` to it (for `then`).
  final double distanceM;

  /// How long the stretch that starts at this maneuver is.
  final double lengthM;
  final String? cardinal;
  final int? bearingDeg;
  final int? elevGainM;
  final int? elevLossM;
  final String? gradeClass;

  /// A leg that follows a mapped track or trail: its name (null when it has none) and kind (road, track, trail).
  final String? followName;
  final String? trailKind;

  bool get isOffroad => kind != 'road';
  bool get isArrival => type.startsWith('destination');
}

/// Off-road leg guidance: where to head from here.
class OffroadLeg {
  const OffroadLeg({required this.kind, required this.target, required this.bearingDeg, required this.cardinal, required this.distanceM, this.climbM, this.descentM, this.gradeClass, this.travel});

  factory OffroadLeg.fromJson(Map<String, dynamic> j) {
    final t = _m(j['target']);
    return OffroadLeg(
      kind: (j['kind'] ?? 'offroad') as String,
      target: GeoPoint(_d(t['lat']) ?? 0, _d(t['lon']) ?? 0),
      bearingDeg: _i(j['bearing_deg']) ?? 0,
      cardinal: (j['cardinal'] ?? '') as String,
      distanceM: _d(j['distance_m']) ?? 0,
      climbM: _i(j['climb_m']),
      descentM: _i(j['descent_m']),
      gradeClass: _s(j['grade_class']),
      travel: _s(j['travel']),
    );
  }

  final String kind;
  final GeoPoint target;
  final int bearingDeg;
  final String cardinal;
  final double distanceM;
  final int? climbM;
  final int? descentM;
  final String? gradeClass;
  final String? travel;
}

/// Where a GPS fix is on the route (cs_map_progress).
class MapProgress {
  const MapProgress({
    required this.routeId,
    required this.matched,
    required this.distanceAlongM,
    required this.offsetM,
    required this.routeBearingDeg,
    required this.onRoute,
    required this.offRoute,
    required this.offRouteCount,
    required this.arrived,
    required this.fraction,
    required this.remainingM,
    required this.remainingS,
    this.eta,
    required this.totalM,
    required this.totalS,
    required this.current,
    this.next,
    this.then,
    this.leg,
  });

  factory MapProgress.fromJson(Map<String, dynamic> j) {
    final m = _m(j['matched']);
    final r = _m(j['remaining']);
    final t = _m(j['total']);
    return MapProgress(
      routeId: (j['route_id'] ?? '') as String,
      matched: GeoPoint(_d(m['lat']) ?? 0, _d(m['lon']) ?? 0),
      distanceAlongM: _d(m['distance_along_m']) ?? 0,
      offsetM: _d(m['offset_m']) ?? 0,
      routeBearingDeg: _i(m['route_bearing_deg']) ?? 0,
      onRoute: j['on_route'] == true,
      offRoute: j['off_route'] == true,
      offRouteCount: _i(j['off_route_count']) ?? 0,
      arrived: j['arrived'] == true,
      fraction: _d(j['progress']) ?? 0,
      remainingM: _d(r['distance_m']) ?? 0,
      remainingS: _i(r['duration_s']) ?? 0,
      eta: _s(r['eta']) == null ? null : DateTime.tryParse(r['eta'] as String),
      totalM: _d(t['distance_m']) ?? 0,
      totalS: _i(t['duration_s']) ?? 0,
      current: ProgressManeuver.fromJson(_m(j['current'])),
      next: j['next'] is Map ? ProgressManeuver.fromJson(_m(j['next'])) : null,
      then: j['then'] is Map ? ProgressManeuver.fromJson(_m(j['then'])) : null,
      leg: j['leg'] is Map ? OffroadLeg.fromJson(_m(j['leg'])) : null,
    );
  }

  final String routeId;
  final GeoPoint matched;
  final double distanceAlongM;
  final double offsetM;
  final int routeBearingDeg;
  final bool onRoute;

  /// True after several fixes in a row off the route: the app asks for a new route from here.
  final bool offRoute;
  final int offRouteCount;
  final bool arrived;
  final double fraction;
  final double remainingM;
  final int remainingS;
  final DateTime? eta;
  final double totalM;
  final int totalS;
  final ProgressManeuver current;
  final ProgressManeuver? next;
  final ProgressManeuver? then;
  final OffroadLeg? leg;
}

/// A saved place of the core (cs_place_save / cs_places_list).
class SavedPlaceRecord {
  const SavedPlaceRecord({required this.key, required this.name, required this.lat, required this.lon, this.label});

  factory SavedPlaceRecord.fromJson(Map<String, dynamic> j) => SavedPlaceRecord(
        key: (j['key'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        lat: _d(j['lat']) ?? 0,
        lon: _d(j['lon']) ?? 0,
        label: _s(j['label']),
      );

  final String key;
  final String name;
  final double lat;
  final double lon;
  final String? label;
}
