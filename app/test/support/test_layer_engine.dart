import 'dart:async';
import 'dart:convert';

import 'package:cache/maps/geo.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/layers/layer_engine.dart';
import 'package:cache/maps/layers/tile_math.dart';

import 'layer_fixtures.dart';

/// A layer engine for the screens' tests: definitions in memory (the test catalogue plus any [published] ones and what
/// the user adds), areas that "download" in a few milliseconds, no network and no core.
class TestLayerEngine extends LayerEngine {
  TestLayerEngine({this.published = const [], this.canBind, this.policy, Set<String> held = const {}}) : _held = {...held};

  /// Ids of the test catalogue that are not there until [release] (the published catalogue arriving after start).
  final Set<String> _held;

  /// The held definitions arrive, as a catalogue refresh brings them.
  void release() {
    _held.clear();
    _rebuild();
    notifyListeners();
  }

  /// The mobile data rule, as the real engine applies it.
  final DataPolicy? policy;

  final List<Map<String, dynamic>> published;
  final List<Map<String, dynamic>> _user = [];

  /// False pretends the system refuses the server socket.
  final bool Function()? canBind;

  bool _ready = false;
  bool _blocked = false;
  bool _online = true;
  String? _problem;
  List<LayerDef> _layers = [];
  final List<DownloadedArea> _areas = [];
  int _next = 0;

  set online(bool v) {
    _online = v;
    notifyListeners();
  }

  @override
  String? get problem => _problem;
  @override
  bool get ready => _ready;
  @override
  bool get blockedByPermission => _blocked;
  @override
  List<LayerDef> get layers => List.unmodifiable(_layers);
  @override
  bool get online => _online;

  void _rebuild() {
    final byId = <String, Map<String, dynamic>>{};
    for (final j in [...testCatalogue, ...published, ..._user]) {
      if (_held.contains(j['id'])) continue;
      byId[j['id'] as String] = j;
    }
    _layers = [for (final j in byId.values) LayerDef.fromJson(Map<String, dynamic>.from(j))];
  }

  @override
  Future<void> start() async {
    _problem = null;
    _blocked = false;
    if (canBind != null && !canBind!()) {
      _blocked = true;
      _problem = 'Layers are not available on this device';
    } else {
      _rebuild();
      _ready = true;
    }
    notifyListeners();
  }

  @override
  String tilesUrl(String id) => 'http://127.0.0.1:1/layers/$id/{z}/{x}/{y}';

  @override
  String tileJsonUrl(String id) => 'http://127.0.0.1:1/layers/$id/tilejson.json';

  @override
  Future<void> refreshOnline({bool force = false}) async {}

  @override
  Future<bool> hasTiles(String layerId, GeoBounds view, int zoom) async {
    final def = layer(layerId);
    if (def == null) return false;
    return _areas.any((a) =>
        a.phase != AreaPhase.failed && layer(a.layerId)?.groupKey == def.groupKey && a.bounds.contains(view.centerLat, view.centerLon));
  }

  @override
  Future<AreaEstimate> estimate(String layerId, GeoBounds area, {int? zoom}) async {
    final def = layer(layerId) ?? (throw StateError('Unknown layer'));
    if (def.onlineOnly) {
      return const AreaEstimate(tiles: 0, bytes: 0, maxZoom: 0, allowed: false, problem: "This layer's terms do not allow keeping it offline.");
    }
    if (def.raw['fake_unavailable'] == true) {
      return const AreaEstimate(tiles: 0, bytes: 0, maxZoom: 0, allowed: false, problem: 'This layer cannot be downloaded.');
    }
    final perTile = (def.raw['approx_tile_bytes'] as num?)?.toInt() ?? 30000;
    final maxTiles = (def.raw['download_limit_tiles'] as num?)?.toInt() ?? 3000;
    final maxBytes = (def.raw['download_limit_bytes'] as num?)?.toInt() ?? 50 * 1024 * 1024;
    if (zoom != null) {
      final n = TileMath.countRange(area, zoom, zoom);
      return AreaEstimate(tiles: n, bytes: n * perTile, maxZoom: zoom, allowed: true);
    }
    for (var z = def.maxZoom; z >= def.minZoom; z--) {
      final n = TileMath.countRange(area, def.minZoom, z);
      if (n <= maxTiles && n * perTile <= maxBytes) {
        if (z < (def.minZoom + 10).clamp(def.minZoom, def.maxZoom)) break;
        return AreaEstimate(tiles: n, bytes: n * perTile, maxZoom: z, allowed: true);
      }
    }
    return AreaEstimate(
      tiles: 0,
      bytes: 0,
      maxZoom: def.minZoom,
      allowed: false,
      problem: 'This area is too big for one download (the source allows $maxTiles tiles or ${maxBytes ~/ (1024 * 1024)} MB). '
          'Zoom in or draw a smaller area.',
    );
  }

  @override
  List<DownloadedArea> areasOf(String layerId) => [for (final a in _areas) if (a.layerId == layerId) a];

  @override
  Future<DownloadedArea> download(String layerId, GeoBounds area, {required String label, bool anyway = false, int? zoom}) async {
    await policy?.checkDownload(anyway: anyway);
    final def = layer(layerId) ?? (throw StateError('Unknown layer'));
    final est = await estimate(layerId, area, zoom: zoom);
    if (!est.allowed) throw StateError(est.problem ?? 'This area cannot be downloaded');
    final a = DownloadedArea(
      id: 'a${_next++}',
      layerId: layerId,
      bounds: area,
      label: label,
      minZoom: zoom ?? def.minZoom,
      maxZoom: est.maxZoom,
      totalTiles: est.tiles,
    );
    _areas.add(a);
    _finish(a);
    notifyListeners();
    return a;
  }

  void _finish(DownloadedArea a) {
    Timer(const Duration(milliseconds: 20), () {
      if (!_areas.contains(a) || a.phase != AreaPhase.running) return;
      a
        ..doneTiles = a.totalTiles
        ..bytes = a.totalTiles * 1000
        ..phase = AreaPhase.done
        ..fetchedAt = DateTime.now();
      notifyListeners();
    });
  }

  @override
  Future<void> cancel(String areaId) async {
    final a = _areas.where((x) => x.id == areaId).firstOrNull;
    if (a == null) return;
    if (a.fetchedAt == null) {
      _areas.remove(a);
    } else {
      a.phase = AreaPhase.done;
    }
    notifyListeners();
  }

  @override
  Future<void> delete(String areaId) async {
    _areas.removeWhere((a) => a.id == areaId);
    notifyListeners();
  }

  @override
  Future<void> update(String areaId, {bool anyway = false}) async {
    await policy?.checkDownload(anyway: anyway);
    final a = _areas.where((x) => x.id == areaId).firstOrNull;
    if (a == null || a.phase == AreaPhase.running) return;
    a
      ..phase = AreaPhase.running
      ..doneTiles = 0;
    _finish(a);
    notifyListeners();
  }

  @override
  int storageOf(String layerId) => areasOf(layerId).fold(0, (s, a) => s + a.bytes);

  @override
  int get storageTotal => _areas.fold(0, (s, a) => s + a.bytes);

  @override
  Future<void> saveDefinition(String json) async {
    final def = LayerDef.parse(json);
    _user.removeWhere((j) => j['id'] == def.id);
    _user.add(def.toJson());
    _rebuild();
    notifyListeners();
  }

  @override
  bool canRemove(String id) => _user.any((j) => j['id'] == id);

  @override
  Future<void> removeDefinition(String id) async {
    _user.removeWhere((j) => j['id'] == id);
    _rebuild();
    notifyListeners();
  }

  /// A copy of the published catalogue fixture as a list of definitions.
  static List<Map<String, dynamic>> layersOf(String catalogueJson) =>
      [for (final e in (jsonDecode(catalogueJson) as Map)['layers'] as List) Map<String, dynamic>.from(e as Map)];
}
