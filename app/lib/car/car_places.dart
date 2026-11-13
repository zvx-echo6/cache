import 'package:cache_search/cache_search.dart';

/// Where the car reads the saved places and searches the map (car_bridge.dart).
///
/// Every call to a core handle goes through that handle's one worker, one call after another (cache_search's
/// transport_isolate.dart). The app's main core also does the library work (searches of the libraries, reading, setting the
/// sources), so a car call sent to it waits behind all of that: on a phone with many libraries the saved places took many
/// seconds. These are not meaning searches and need no library, so the car has a handle of its own for them.
abstract interface class CarPlaces {
  /// The user's saved places.
  Future<List<SavedPlaceRecord>> savedPlaces();

  /// The map search by name, address and category word (never by meaning).
  Future<MapSearchResponse> search(String query, {GeoPoint? near, int limit});

  /// Lets the handle go; the next call opens it again.
  Future<void> close();
}

/// The sections of the main core's cs_open config the car's handle needs: the saved places (`user`), the map search
/// (`places`) and the region engine its places come from (`regions`; the process's one engine for that folder is shared,
/// cache_regions' open_shared). No sources, no libraries, no layers, no live data.
Map<String, dynamic> carPlacesConfig(Map<String, dynamic> extra) => {
      for (final k in const ['user', 'places', 'regions'])
        if (extra[k] != null) k: extra[k],
    };

/// [CarPlaces] on a core handle of its own, opened at the car's first call with [config] (the main core's config, built
/// before the main core opens: it does not wait for the main core or its libraries).
class CoreCarPlaces implements CarPlaces {
  CoreCarPlaces({required this.config, Future<SearchCore> Function(Map<String, dynamic> extra)? open})
      : _open = open ?? ((extra) => SearchCore.open(const [], extra: extra));

  /// The main core's config sections (SourcesState.whenConfigReady); null: none could be built.
  final Future<Map<String, dynamic>?> Function() config;
  final Future<SearchCore> Function(Map<String, dynamic> extra) _open;
  Future<SearchCore>? _core;

  /// The handle, opened at the first call; an open that failed is tried again at the next call.
  Future<SearchCore> _handle() async {
    final pending = _core ??= _start();
    try {
      return await pending;
    } catch (_) {
      if (identical(_core, pending)) _core = null;
      rethrow;
    }
  }

  Future<SearchCore> _start() async {
    final extra = await config();
    final picked = extra == null ? const <String, dynamic>{} : carPlacesConfig(extra);
    if (!picked.containsKey('user')) throw StateError("No config for the car's places");
    return _open(picked);
  }

  @override
  Future<List<SavedPlaceRecord>> savedPlaces() async => (await _handle()).savedPlaces();

  @override
  Future<MapSearchResponse> search(String query, {GeoPoint? near, int limit = 10}) async =>
      (await _handle()).mapSearch(query, near: near, limit: limit, meaning: false);

  @override
  Future<void> close() async {
    final c = _core;
    _core = null;
    if (c == null) return;
    try {
      final core = await c;
      await core.close();
    } catch (_) {}
  }
}
