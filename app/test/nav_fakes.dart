import 'dart:async';
import 'dart:math' as math;

import 'package:cache/location/position_source.dart';
import 'package:cache/nav/nav_backend.dart';
import 'package:cache/nav/nav_position.dart';
import 'package:cache/nav/speaker.dart';
import 'package:cache_search/cache_search.dart';

/// polyline6 encoder, so the tests can write the geometry the core writes.
String encodePolyline6(List<GeoPoint> pts) {
  final out = StringBuffer();
  var plat = 0, plon = 0;
  void put(int v) {
    var x = v < 0 ? ~(v << 1) : (v << 1);
    while (x >= 0x20) {
      out.writeCharCode(((0x20 | (x & 0x1f)) + 63));
      x >>= 5;
    }
    out.writeCharCode(x + 63);
  }

  for (final p in pts) {
    final la = (p.lat * 1e6).round(), lo = (p.lon * 1e6).round();
    put(la - plat);
    put(lo - plon);
    plat = la;
    plon = lo;
  }
  return out.toString();
}

double metersBetween(GeoPoint a, GeoPoint b) {
  final k = math.cos(a.lat * math.pi / 180);
  final dx = (b.lon - a.lon) * k * 111320, dy = (b.lat - a.lat) * 110574;
  return math.sqrt(dx * dx + dy * dy);
}

/// A route east along 42.5N from -113.8, with a stretch of open ground in the middle when [offroad]: maneuvers are
/// start, left onto Road 1, right onto Road 2, (off-road leg), arrival.
Map<String, dynamic> fakeRouteJson({String id = 'r1', String mode = 'drive', bool offroad = false, int alt = 0, String name = 'Cassia Regional Hospital'}) {
  const n = 40;
  final pts = [for (var i = 0; i <= n; i++) GeoPoint(42.5 + (alt > 0 ? 0.002 * alt * math.sin(i / n * math.pi) : 0), -113.8 + 0.3 * i / n)];
  final total = metersBetween(pts.first, pts.last);
  double at(int i) => total * i / n;
  final cuts = offroad ? [0, 10, 20, 30, n] : [0, 13, 27, n];
  final types = offroad ? ['start', 'left', 'right', 'none', 'destination'] : ['start', 'left', 'right', 'destination'];
  final kinds = offroad ? ['road', 'road', 'road', 'offroad', 'road'] : ['road', 'road', 'road', 'road'];
  final instr = offroad
      ? ['Drive east on Main Street.', 'Turn left onto Road 1.', 'Turn right onto Road 2.', 'Off-road E 0.1 mi, steep (+30 m)', 'You have arrived at your destination.']
      : ['Drive east on Main Street.', 'Turn left onto Road 1.', 'Turn right onto Road 2.', 'You have arrived at your destination.'];
  final maneuvers = <Map<String, dynamic>>[];
  for (var i = 0; i < types.length; i++) {
    final b = cuts[math.min(i, cuts.length - 1)];
    final e = i + 1 < cuts.length ? cuts[i + 1] : cuts.last;
    final isOff = kinds[i] == 'offroad';
    maneuvers.add({
      'index': i, 'kind': isOff ? 'offroad' : 'road', 'type': types[i], 'instruction': instr[i], 'street_names': isOff ? [] : ['Road $i'],
      'distance_m': at(e) - at(b), 'duration_s': ((at(e) - at(b)) / 20).round(), 'lat': pts[b].lat, 'lon': pts[b].lon,
      'begin_index': b, 'end_index': e, 'bearing_deg': 90, 'cardinal': 'E', 'travel': isOff ? 'foot' : mode,
      if (isOff) ...{'grade_class': 'steep', 'elev_gain_m': 30, 'elev_loss_m': 0, 'terrain': 'shrubland'},
    });
  }
  final segments = <Map<String, dynamic>>[
    if (!offroad) {'kind': 'road', 'travel': mode, 'start_index': 0, 'end_index': n, 'distance_m': total}
    else ...[
      {'kind': 'road', 'travel': mode, 'start_index': 0, 'end_index': 30, 'distance_m': at(30)},
      {'kind': 'offroad', 'travel': 'foot', 'start_index': 30, 'end_index': n, 'distance_m': total - at(30)},
    ],
  ];
  return {
    'ok': true, 'route_id': id, 'mode': mode, 'land_access': 'pragmatic', 'routing': offroad ? 'offroad' : 'road',
    'from': {'id': null, 'name': 'Your location', 'lat': 42.5, 'lon': -113.8, 'snap_distance_m': 3},
    'via': <Object>[],
    'to': {'id': 'place:osm:n4', 'name': name, 'lat': 42.5, 'lon': -113.5, 'snap_distance_m': 5},
    'distance_m': total, 'duration_s': (total / 20).round(),
    'totals': {'distance_m': total, 'duration_s': (total / 20).round(), 'road_m': offroad ? at(30) : total, 'offroad_m': offroad ? total - at(30) : 0.0, 'ascent_m': offroad ? 30 : 0, 'descent_m': 0},
    'geometry': encodePolyline6(pts), 'point_count': pts.length, 'segments': segments, 'maneuvers': maneuvers,
    'major_roads': [{'name': 'Road $alt', 'distance_km': total / 1000}], 'warnings': <Object>[], 'alternatives': <Object>[],
  };
}

Map<String, dynamic> fakeProgressJson(Map<String, dynamic> route, double fraction, {double offset = 0, bool offRoute = false, int offCount = 0, bool arrived = false, double? now}) {
  final total = (route['distance_m'] as num).toDouble();
  final along = total * fraction;
  final mans = (route['maneuvers'] as List).cast<Map<String, dynamic>>();
  final lastReal = mans.length - 2;
  var ci = 0;
  for (var i = 0; i <= lastReal; i++) {
    final b = (route['maneuvers'][i]['begin_index'] as int) / 40 * total;
    if (b <= along + 1e-6) ci = i;
  }
  Map<String, dynamic> view(int i, double d) {
    final m = mans[i];
    return {'index': i, 'kind': m['kind'], 'type': m['type'], 'instruction': m['instruction'], 'street_names': m['street_names'], 'travel': m['travel'], 'lat': m['lat'], 'lon': m['lon'], 'distance_m': d, 'length_m': m['distance_m'], 'cardinal': 'E', 'bearing_deg': 90,
      if (m['kind'] == 'offroad') ...{'elev_gain_m': 30, 'elev_loss_m': 0, 'grade_class': 'steep', 'follow': null}};
  }

  double begin(int i) => (mans[i]['begin_index'] as int) / 40 * total;
  final next = ci + 1 < mans.length ? view(ci + 1, begin(ci + 1) - along) : null;
  final then = ci + 2 < mans.length ? view(ci + 2, begin(ci + 2) - begin(ci + 1)) : null;
  final remaining = total - along;
  final cur = mans[ci];
  return {
    'route_id': route['route_id'], 'fix': 1,
    'matched': {'lat': 42.5, 'lon': -113.8 + 0.3 * fraction, 'distance_along_m': along, 'offset_m': offset, 'segment': 1, 'route_bearing_deg': 90},
    'on_route': !offRoute && offset <= 50, 'off_route': offRoute, 'off_route_count': offCount, 'arrived': arrived, 'progress': fraction,
    'remaining': {'distance_m': remaining, 'duration_s': (remaining / 20).round()},
    'total': {'distance_m': total, 'duration_s': route['duration_s']},
    'current': view(ci, 0), 'next': next, 'then': then,
    'leg': cur['kind'] == 'offroad'
        ? {'kind': 'offroad', 'target': {'lat': 42.5, 'lon': -113.5}, 'bearing_deg': 87, 'cardinal': 'E', 'distance_m': begin(ci + 1) - along, 'climb_m': 30, 'descent_m': 0, 'grade_class': 'steep', 'travel': 'foot'}
        : null,
  };
}

class FakeBackend implements MapBackend {
  FakeBackend({this.available = true});

  @override
  bool available;

  final List<String> calls = [];

  /// The land access sent with each route call (null: none sent).
  final List<String?> landAccesses = [];
  Future<MapSearchResponse> Function(String query, {GeoPoint? near, bool? meaning})? onSearch;
  Future<MapRoute> Function(Map<String, dynamic> to, String mode, Map<String, dynamic>? from)? onRoute;
  final List<MapProgress> progressQueue = [];
  Future<MapProgress> Function(MapRoute route, double lat, double lon)? onProgress;
  final List<(String, double, double)> saved = [];
  bool saveFails = false;

  @override
  Future<MapSearchResponse> search(String query, {GeoPoint? near, int limit = 10, bool meaning = true}) async {
    calls.add('search:$query:${meaning ? 'm' : 'k'}');
    final h = onSearch;
    if (h == null) return MapSearchResponse(query: query, kind: 'text', meaning: 'off', results: const []);
    return h(query, near: near, meaning: meaning);
  }

  @override
  Future<MapRoute> route({Map<String, dynamic>? from, required Map<String, dynamic> to, List<Map<String, dynamic>> via = const [], String mode = 'drive', String? landAccess, int alternatives = 2}) async {
    calls.add('route:$mode:${to['name']}:${from == null ? 'nofrom' : 'from'}');
    landAccesses.add(landAccess);
    final h = onRoute;
    if (h == null) throw StateError('no route handler');
    return h(to, mode, from);
  }

  @override
  Future<MapProgress> progress(MapRoute route, {required double lat, required double lon, double? accuracyM, DateTime? now, bool reset = false, bool sendRoute = false}) async {
    calls.add('progress:${sendRoute ? 'send' : 'id'}');
    final h = onProgress;
    if (h != null) return h(route, lat, lon);
    return progressQueue.removeAt(0);
  }

  @override
  Future<void> savePlace({required String name, required double lat, required double lon, String? label}) async {
    if (saveFails) throw const CacheSearchException('unsupported', 'no');
    saved.add((name, lat, lon));
  }

  final List<String> deleted = [];

  @override
  Future<List<SavedPlaceRecord>> savedPlaces() async => [
        for (final (i, s) in saved.indexed)
          if (!deleted.contains('k$i')) SavedPlaceRecord(key: 'k$i', name: s.$1, lat: s.$2, lon: s.$3),
      ];

  @override
  Future<void> deletePlace(String key) async => deleted.add(key);
}

class FakeSpeaker implements Speaker {
  final List<String> said = [];
  int stops = 0;

  @override
  Future<void> speak(String text) async => said.add(text);

  @override
  Future<void> stop() async => stops++;
}

class FakeNavPosition implements NavPositionSource {
  final StreamController<Fix> controller = StreamController<Fix>.broadcast();
  int starts = 0;
  int stops = 0;
  String? title;
  String? text;

  @override
  Stream<Fix> start({required String title, required String text}) {
    starts++;
    this.title = title;
    this.text = text;
    return controller.stream;
  }

  @override
  Future<void> stop() async => stops++;
}

Fix fixAt(double lat, double lon, {double? heading, double acc = 8}) => Fix(lat: lat, lon: lon, accuracyM: acc, time: DateTime(2026, 10, 26, 12), heading: heading);
