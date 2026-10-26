import 'package:cache_search/cache_search.dart';

/// The map's three calls to the core, behind a seam so the screens and tests do not need a native library. The real one is
/// [CoreMapBackend] (cs_map_search, cs_map_route, cs_map_progress); tests give a fake.
abstract class MapBackend {
  /// True when the core can search and route (a places pack and the routing data are installed and the core is new enough).
  bool get available;

  Future<MapSearchResponse> search(String query, {GeoPoint? near, int limit, bool meaning});

  /// The complete route; [from] is where to start (the app sends its own GPS fix). A route that cannot be made comes back
  /// with `ok` false and its errors.
  Future<MapRoute> route({Map<String, dynamic>? from, required Map<String, dynamic> to, List<Map<String, dynamic>> via, String mode, String? landAccess, int alternatives});

  Future<MapProgress> progress(MapRoute route, {required double lat, required double lon, double? accuracyM, DateTime? now, bool reset, bool sendRoute});

  /// Saves a place to the user's saved places.
  Future<void> savePlace({required String name, required double lat, required double lon, String? label});
}

/// The query as the phone's embedder (bge-m3) makes it, or null when the embedder is not loaded: the core then searches by
/// keywords and says so.
typedef QueryEmbedder = Future<MapQueryVector?> Function(String text);

/// [MapBackend] on the search core.
class CoreMapBackend implements MapBackend {
  CoreMapBackend(this._core, {this.embedder, bool Function()? isAvailable}) : _isAvailable = isAvailable ?? (() => true);

  final SearchCore Function() _core;
  final QueryEmbedder? embedder;
  final bool Function() _isAvailable;

  @override
  bool get available => _isAvailable();

  @override
  Future<MapSearchResponse> search(String query, {GeoPoint? near, int limit = 10, bool meaning = true}) async {
    MapQueryVector? vector;
    if (meaning && embedder != null && query.trim().isNotEmpty) {
      try {
        vector = await embedder!(query);
      } catch (_) {
        vector = null;
      }
    }
    return _core().mapSearch(query, near: near, limit: limit, meaning: meaning, queryVector: vector);
  }

  @override
  Future<MapRoute> route({Map<String, dynamic>? from, required Map<String, dynamic> to, List<Map<String, dynamic>> via = const [], String mode = 'drive', String? landAccess, int alternatives = 2}) =>
      _core().mapRoute(from: from, to: to, via: via, mode: mode, landAccess: landAccess, alternatives: alternatives);

  @override
  Future<MapProgress> progress(MapRoute route, {required double lat, required double lon, double? accuracyM, DateTime? now, bool reset = false, bool sendRoute = false}) =>
      _core().mapProgress(route, lat: lat, lon: lon, accuracyM: accuracyM, now: now, reset: reset, sendRoute: sendRoute);

  @override
  Future<void> savePlace({required String name, required double lat, required double lon, String? label}) async {
    await _core().savePlace(name: name, lat: lat, lon: lon, label: label);
  }
}
