import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cache_search/cache_search.dart';

import 'nav_backend.dart';

/// A stand-in for the core that replays answers the real core gave (recorded with `cs serve` from the Idaho data), for screenshots
/// on a phone or an emulator that has no routing library. It reads a folder with a `demo.json` index:
///
///  * `searches`: the first words of a query -> a recorded answer of `cs_map_search`;
///  * `routes`: destination name and way of travel -> a recorded `cs_map_route` answer, with the recorded `cs_map_progress` answers
///    along it (`progress`, and `alt_progress` for each alternative); a fix gets the recorded answer whose matched point is nearest,
///    and a fix far from every one of them gets an off-route answer.
///
/// It is used only when the app is built with `--dart-define=CACHE_NAV_DEMO=<folder>`; the real app never reads it.
class DemoMapBackend implements MapBackend {
  DemoMapBackend(this.dir);

  final Directory dir;
  final Map<String, String> _progressFileOf = {};
  final Map<String, List<Map<String, dynamic>>> _samples = {};

  Map<String, dynamic> _json(String name) => (jsonDecode(File('${dir.path}/$name').readAsStringSync()) as Map).cast<String, dynamic>();

  @override
  bool get available => true;

  @override
  Future<MapSearchResponse> search(String query, {GeoPoint? near, int limit = 10, bool meaning = true}) async {
    final q = query.trim().toLowerCase();
    final searches = (_json('demo.json')['searches'] as Map).cast<String, dynamic>();
    String? file;
    for (final e in searches.entries) {
      if (q.startsWith(e.key.toLowerCase())) file = e.value as String;
    }
    if (file == null) return MapSearchResponse(query: query, kind: 'text', meaning: 'off', results: const []);
    return MapSearchResponse.fromJson(_json(file));
  }

  @override
  Future<MapRoute> route({Map<String, dynamic>? from, required Map<String, dynamic> to, List<Map<String, dynamic>> via = const [], String mode = 'drive', String? landAccess, int alternatives = 2}) async {
    final name = ((to['name'] ?? '') as String).toLowerCase();
    final routes = ((_json('demo.json')['routes']) as List).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
    final hit = routes.where((r) => name.contains(r['to'] as String) && r['mode'] == mode).firstOrNull ?? routes.where((r) => name.contains(r['to'] as String)).firstOrNull;
    if (hit == null) throw const CacheSearchException('unsupported', 'No recorded route for this place');
    final j = _json(hit['file'] as String);
    _progressFileOf[j['route_id'] as String] = hit['progress'] as String;
    final alts = ((hit['alt_progress'] as List?) ?? const []).cast<String>();
    final altJson = (j['alternatives'] as List?)?.cast<Map>() ?? const [];
    for (var i = 0; i < altJson.length && i < alts.length; i++) {
      _progressFileOf[altJson[i]['route_id'] as String] = alts[i];
    }
    return MapRoute.fromJson(j);
  }

  @override
  Future<MapProgress> progress(MapRoute route, {required double lat, required double lon, double? accuracyM, DateTime? now, bool reset = false, bool sendRoute = false}) async {
    final file = _progressFileOf[route.routeId];
    if (file == null) throw const CacheSearchException('not_found', 'no route');
    final list = _samples.putIfAbsent(file, () => (jsonDecode(File('${dir.path}/$file').readAsStringSync()) as List).map((e) => (e as Map).cast<String, dynamic>()).toList());
    Map<String, dynamic>? best;
    var bestD = double.infinity;
    for (final m in list) {
      final mm = (m['matched'] as Map).cast<String, dynamic>();
      final d = _dist(lat, lon, (mm['lat'] as num).toDouble(), (mm['lon'] as num).toDouble());
      if (d < bestD) {
        bestD = d;
        best = m;
      }
    }
    final out = Map<String, dynamic>.from(best!);
    if (bestD > 150) {
      out['on_route'] = false;
      out['off_route'] = true;
      out['off_route_count'] = 3;
    }
    if (now != null && out['remaining'] is Map) {
      final r = Map<String, dynamic>.from(out['remaining'] as Map);
      r['eta'] = now.add(Duration(seconds: (r['duration_s'] as num).round())).toIso8601String();
      out['remaining'] = r;
    }
    return MapProgress.fromJson(out);
  }

  @override
  Future<void> savePlace({required String name, required double lat, required double lon, String? label}) async {}

  static double _dist(double lat1, double lon1, double lat2, double lon2) {
    final k = math.cos(lat1 * math.pi / 180);
    final dx = (lon2 - lon1) * k * 111320, dy = (lat2 - lat1) * 110574;
    return math.sqrt(dx * dx + dy * dy);
  }
}
