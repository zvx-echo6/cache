import 'package:cache_search/cache_search.dart';

/// What the regions state needs from the region engine in the core (road routing and places tiles, fetched once and shared by
/// every region that needs them). The real one is RegionsCore in cache_search; tests give a fake. Methods and answers are JSON:
///   status -> {"build","tile_dir","regions":[{"id","name","state","tiles","bytes","done_tiles","done_bytes","error","parts"?}],
///              "stream":{"tiles","bytes","cap"},"update":{"build","download_bytes"}|null,"paused":reason|null,
///              "places"?:{"build","db","tiles","generation",...},"updates"?:{"routing","places"}}
///   plan {id,name,geometry} -> {"tiles","bytes","download_bytes","shared_tiles","parts"?:{"routing","places"}}
///              (code "offline" when the index is out of reach; a part that cannot be planned has {"error","code"})
///   add {id,name,geometry,parts?} · remove {id} · set_policy {"network":bool} · check_update · update {component?}
/// The places additions (`parts`, `places`, `updates`, `component`) are in docs/PLACES-TILES.md.
abstract class RegionsCoreLike {
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> args]);
  Future<void> close();
}

typedef RegionsOpener = Future<RegionsCoreLike> Function(Map<String, Object?> config);

/// Opens the core's region engine with {"dir","base_url"}: the same engine the search core's navigate tool routes on (one per
/// folder in the process).
Future<RegionsCoreLike> openRealRegions(Map<String, Object?> config) async => _RealRegions(await RegionsCore.open(config));

class _RealRegions implements RegionsCoreLike {
  _RealRegions(this._c);

  final RegionsCore _c;

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> args = const {}]) => _c.call(method, args);

  @override
  Future<void> close() => _c.close();
}
