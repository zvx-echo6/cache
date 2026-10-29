import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../settings/data_policy.dart';
import '../geo.dart';
import 'layer_def.dart';
import 'layer_engine.dart';
import 'tile_math.dart';

/// The layer engine in the Rust core (cs_layers_*, see packages/cache_search/DESIGN-LAYERS.md): the catalogue and
/// the starter definitions, the tile server on 127.0.0.1 the map reads from, area downloads into one merged tile
/// store per layer, and the contours the core makes on the phone.
class CoreLayerEngine extends LayerEngine {
  CoreLayerEngine({
    required this.openCore,
    required this.layersConfig,
    Future<bool> Function()? connected,
    this.pollEvery = const Duration(milliseconds: 600),
    this.maxDownloadBytes = 800 * 1024 * 1024,
    this.policy,
  }) : _connected = connected ?? _platformConnected;

  /// The search core once it is open (null when it could not open).
  final Future<SearchCore?> Function() openCore;

  /// The "layers" section of the core's config, which a download job takes along.
  final Map<String, dynamic> Function() layersConfig;

  final Future<bool> Function() _connected;
  final Duration pollEvery;

  /// The mobile data rule for downloads and catalogue updates; null: no rule.
  final DataPolicy? policy;

  /// A download bigger than this is not offered; the estimate steps down to less detail until it fits.
  final int maxDownloadBytes;

  SearchCore? _core;
  int _port = 0;
  bool _ready = false;
  bool _online = true;
  String? _problem;
  bool _blocked = false;
  DateTime _lastProbe = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  List<LayerDef> _layers = [];
  final Map<String, Map<String, dynamic>> _entries = {};
  final Map<String, DownloadedArea> _areas = {};
  final Map<String, String> _areaLayer = {};
  final Map<String, _Run> _running = {};
  Timer? _poll;
  bool _disposed = false;
  double _cacheBytes = 0;

  static Future<bool> _platformConnected() async {
    try {
      final r = await Connectivity().checkConnectivity();
      return r.any((c) => c != ConnectivityResult.none);
    } catch (_) {
      return true;
    }
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

  int get port => _port;

  @override
  Future<void> start() async {
    _problem = null;
    _blocked = false;
    try {
      final core = _core ??= await openCore();
      if (core == null) {
        _problem = 'Layers are not available on this device';
        notifyListeners();
        return;
      }
      _online = await _connected();
      final s = await core.layers('server', jsonEncode({'online': _online}));
      _port = (s['port'] as num).toInt();
      await _reload();
      _ready = true;
      notifyListeners();
      unawaited(refreshCatalogue());
    } catch (e, st) {
      debugPrint('CoreLayerEngine.start failed: $e\n$st');
      final m = e.toString().toLowerCase();
      _blocked = m.contains('operation not permitted') || m.contains('permission denied') || m.contains('os error 1)');
      _problem = 'Layers are not available on this device';
      notifyListeners();
    }
  }

  /// Calls that were already waiting on the core when the engine was disposed end here, not in a listener that is gone.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    // Nothing will look at the running downloads again, so nobody may wait for them (a cancel in progress returns).
    for (final r in _running.values) {
      if (!r.done.isCompleted) r.done.complete();
    }
    super.dispose();
  }

  // ---- catalogue ----------------------------------------------------------------------------------------

  /// Reads the catalogue and what is installed from the core.
  Future<void> _reload() async {
    final core = _core!;
    final j = await core.layers('list');
    _entries.clear();
    final defs = <LayerDef>[];
    for (final e in (j['layers'] as List? ?? const [])) {
      final entry = (e as Map).cast<String, dynamic>();
      try {
        final def = LayerDef.fromJson((entry['definition'] as Map).cast<String, dynamic>());
        _entries[def.id] = entry;
        defs.add(def);
      } catch (_) {
        // One definition the app cannot read does not take the others down.
      }
    }
    _layers = _ordered(_withDerivedZooms(defs));
    final vc = j['viewed_cache'];
    _cacheBytes = vc is Map ? ((vc['bytes'] as num?) ?? 0).toDouble() : 0;
    _readAreas();
  }

  /// Hillshade and contours have no source of their own: they take their zooms and tile size from the elevation layer
  /// they are made from (contours are served from zoom 3 to 15, see DESIGN-LAYERS.md).
  List<LayerDef> _withDerivedZooms(List<LayerDef> defs) {
    final byId = {for (final d in defs) d.id: d};
    return [
      for (final d in defs)
        if (d.kind == LayerKind.hillshade || d.kind == LayerKind.contours)
          d.derivedFrom(byId[d.raw['derived_from']], minZoom: d.kind == LayerKind.contours ? 3 : null, maxZoom: d.kind == LayerKind.contours ? 15 : null)
        else
          d,
    ];
  }

  /// Drawing order, bottom first: the base map, pictures, shading, other vector layers, contours.
  List<LayerDef> _ordered(List<LayerDef> defs) {
    int rank(LayerDef d) => switch (d.kind) {
          LayerKind.basemap => 0,
          LayerKind.elevation => 1,
          LayerKind.raster => 2,
          LayerKind.hillshade => 3,
          LayerKind.vector => 4,
          LayerKind.contours => 5,
        };
    final indexed = [for (var i = 0; i < defs.length; i++) (i, defs[i])];
    indexed.sort((a, b) {
      final r = rank(a.$2).compareTo(rank(b.$2));
      return r != 0 ? r : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  /// Fetches the published catalogue and each layer's latest version (needs a connection); the last copy stays in use
  /// offline.
  Future<void> refreshCatalogue() async {
    final core = _core;
    if (core == null || !_online) return;
    // A small update: skipped (quietly; the downloaded copy stays in use) on mobile data when updates on mobile data are off.
    if (policy != null && await policy!.blocksUpdate()) return;
    if (DateTime.now().difference(_lastRefresh) < const Duration(seconds: 20)) return;
    _lastRefresh = DateTime.now();
    try {
      await core.layers('refresh');
      await _reload();
      notifyListeners();
    } catch (e) {
      debugPrint('Layer catalogue refresh: $e');
    }
  }

  @override
  Future<void> saveDefinition(String json) async {
    LayerDef.parse(json); // FormatException for what is not a definition
    try {
      await _core!.layers('save', json);
    } on CacheSearchException catch (e) {
      throw FormatException(e.message);
    }
    await _reload();
    notifyListeners();
  }

  @override
  bool canRemove(String id) => _entries[id]?['origin'] == 'user';

  @override
  Future<void> removeDefinition(String id) async {
    await _core!.layers('remove', id);
    await _reload();
    notifyListeners();
  }

  // ---- addresses ----------------------------------------------------------------------------------------

  @override
  String tilesUrl(String id) => 'http://127.0.0.1:$_port/layers/$id/{z}/{x}/{y}';

  @override
  String tileJsonUrl(String id) => 'http://127.0.0.1:$_port/layers/$id/tilejson.json';

  // ---- connection ---------------------------------------------------------------------------------------

  @override
  Future<void> refreshOnline({bool force = false}) async {
    if (!force && DateTime.now().difference(_lastProbe) < const Duration(seconds: 3)) return;
    _lastProbe = DateTime.now();
    final now = await _connected();
    if (now == _online) return;
    _online = now;
    // The engine uses the network only when told it may.
    try {
      await _core?.layers('server', jsonEncode({'online': now}));
    } catch (_) {}
    notifyListeners();
    if (now) unawaited(refreshCatalogue());
  }

  @override
  Future<bool> hasTiles(String layerId, GeoBounds view, int zoom) async {
    final def = layer(layerId);
    if (def == null || _port == 0) return false;
    final z = zoom.clamp(def.minZoom, def.maxZoom);
    final x = TileMath.tileX(view.centerLon, z);
    final y = TileMath.tileY(view.centerLat, z);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$_port/layers/$layerId/$z/$x/$y'));
      final res = await req.close().timeout(const Duration(seconds: 8));
      await res.drain<void>();
      return res.statusCode == 200 || res.statusCode == 204;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  // ---- areas --------------------------------------------------------------------------------------------

  void _readAreas() {
    final seen = <String>{};
    for (final entry in _entries.entries) {
      final id = entry.key;
      final e = entry.value;
      final downloadLayer = (e['download_layer'] as String?) ?? id;
      final installed = e['installed'];
      if (installed is! Map) continue;
      for (final a in (installed['areas'] as List? ?? const [])) {
        final m = (a as Map).cast<String, dynamic>();
        final aid = m['id'] as String;
        final existing = _areas[_key(id, aid)];
        final run = _running[aid];
        final bbox = [for (final v in (m['bbox'] as List? ?? const [-180, -85, 180, 85])) (v as num).toDouble()];
        final area = existing ?? DownloadedArea(
          id: aid,
          layerId: id,
          bounds: GeoBounds(south: bbox[1], west: bbox[0], north: bbox[3], east: bbox[2]),
          label: (m['name'] as String?)?.isNotEmpty == true ? m['name'] as String : aid,
          minZoom: (m['minzoom'] as num?)?.toInt() ?? 0,
          maxZoom: (m['maxzoom'] as num?)?.toInt() ?? 0,
          totalTiles: (m['tiles_requested'] as num?)?.toInt() ?? 0,
        );
        area
          ..bytes = (m['bytes'] as num?)?.toInt() ?? area.bytes
          ..fetchedAt = _date(m['created']) ?? area.fetchedAt;
        if (run == null || !run.update) {
          area
            ..doneTiles = (m['tiles_present'] as num?)?.toInt() ?? area.totalTiles
            ..phase = AreaPhase.done
            ..error = run == null ? null : area.error;
        }
        _areas[_key(id, aid)] = area;
        _areaLayer[aid] = downloadLayer;
        seen.add(_key(id, aid));
      }
      for (final p in (installed['partial'] as List? ?? const [])) {
        final m = (p as Map).cast<String, dynamic>();
        final aid = m['area'] as String;
        if (_running.containsKey(aid)) continue;
        final saved = _saved[aid];
        final area = _areas[_key(id, aid)] ??
            DownloadedArea(
              id: aid,
              layerId: id,
              bounds: saved?.bounds ?? const GeoBounds(south: -85, west: -180, north: 85, east: 180),
              label: (m['name'] as String?)?.isNotEmpty == true ? m['name'] as String : aid,
              minZoom: saved?.minZoom ?? 0,
              maxZoom: saved?.maxZoom ?? 0,
              totalTiles: (m['tiles_total'] as num?)?.toInt() ?? 0,
            );
        area
          ..phase = AreaPhase.failed
          ..error = area.error ?? 'Stopped before it finished. Tap Update to continue.';
        _areas[_key(id, aid)] = area;
        _areaLayer[aid] = downloadLayer;
        seen.add(_key(id, aid));
      }
    }
    // Areas that were deleted, or belong to a layer that is gone, drop out unless a download is still running.
    _areas.removeWhere((k, a) => !seen.contains(k) && !_running.containsKey(a.id));
    for (final r in _running.values) {
      _areas.putIfAbsent(_key(r.area.layerId, r.area.id), () => r.area);
    }
  }

  String _key(String layer, String area) => '$layer/$area';

  /// What was asked for, kept to carry on a download that stopped (the core's list does not hold the shape of an
  /// unfinished one).
  final Map<String, _Saved> _saved = {};

  static DateTime? _date(Object? v) {
    if (v is String) return DateTime.tryParse(v);
    if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000);
    return null;
  }

  @override
  List<DownloadedArea> areasOf(String layerId) => [for (final a in _areas.values) if (a.layerId == layerId) a];

  @override
  int storageOf(String layerId) => ((_entries[layerId]?['installed'] as Map?)?['bytes'] as num?)?.toInt() ?? 0;

  @override
  int get storageTotal {
    final seen = <String>{};
    var total = 0;
    for (final e in _entries.entries) {
      if (seen.add((e.value['download_layer'] as String?) ?? e.key)) total += storageOf(e.key);
    }
    return total + _cacheBytes.toInt();
  }

  @override
  Future<AreaEstimate> estimate(String layerId, GeoBounds area) async {
    final def = layer(layerId) ?? (throw StateError('Unknown layer'));
    final entry = _entries[layerId];
    if (def.onlineOnly || entry?['downloadable'] == false) {
      return const AreaEstimate(tiles: 0, bytes: 0, maxZoom: 0, allowed: false, problem: "This layer's terms do not allow keeping it offline.");
    }
    final bbox = [area.west, area.south, area.east, area.north];
    final top = def.maxZoom;
    final floor = (top - 5).clamp(def.minZoom, top);
    Map<String, dynamic>? last;
    String? problem;
    for (var z = top; z >= floor; z--) {
      final Map<String, dynamic> plan;
      try {
        plan = await _core!.layers('plan', jsonEncode({'layer': layerId, 'bbox': bbox, 'minzoom': def.minZoom, 'maxzoom': z}));
      } on CacheSearchException catch (e) {
        if (e.code == 'offline') {
          return AreaEstimate(tiles: 0, bytes: 0, maxZoom: z, allowed: false, problem: 'The size is worked out from the source, which needs a connection.');
        }
        return AreaEstimate(tiles: 0, bytes: 0, maxZoom: z, allowed: false, problem: e.message);
      }
      last = plan;
      final bytes = (plan['estimated_bytes'] as num?)?.toInt() ?? 0;
      final problems = [for (final p in (plan['problems'] as List? ?? const [])) (p as Map).cast<String, dynamic>()];
      if (problems.any((p) => p['code'] == 'no_space')) {
        problem = 'There is not enough free space on this phone for this download.';
        break;
      }
      final ok = plan['ok_to_start'] == true && bytes <= maxDownloadBytes;
      if (ok) return _estimateOf(plan, z, true, null);
      problem = problems.isNotEmpty ? (problems.first['message'] as String?) : 'This area is too big for one download.';
    }
    return _estimateOf(last ?? const {}, floor, false,
        problem ?? 'This area is too big for one download. Zoom in or draw a smaller area.');
  }

  AreaEstimate _estimateOf(Map<String, dynamic> plan, int zoom, bool allowed, String? problem) => AreaEstimate(
        tiles: (plan['tiles_to_download'] as num?)?.toInt() ?? 0,
        bytes: (plan['estimated_bytes'] as num?)?.toInt() ?? 0,
        maxZoom: zoom,
        allowed: allowed,
        problem: problem,
        tilesAlready: (plan['tiles_already'] as num?)?.toInt() ?? 0,
        bytesAlready: (plan['already_bytes'] as num?)?.toInt() ?? 0,
      );

  @override
  Future<DownloadedArea> download(String layerId, GeoBounds area, {required String label, bool anyway = false}) async {
    await policy?.checkDownload(anyway: anyway);
    final def = layer(layerId) ?? (throw StateError('Unknown layer'));
    final est = await estimate(layerId, area);
    if (!est.allowed) throw StateError(est.problem ?? 'This area cannot be downloaded');
    final id = 'a${DateTime.now().millisecondsSinceEpoch}';
    final a = DownloadedArea(
      id: id,
      layerId: layerId,
      bounds: area,
      label: label,
      minZoom: def.minZoom,
      maxZoom: est.maxZoom,
      totalTiles: est.tiles,
    );
    _saved[id] = _Saved(area, def.minZoom, est.maxZoom);
    await _start(a, {
      'layer': layerId,
      'area': id,
      'name': label,
      'bbox': [area.west, area.south, area.east, area.north],
      'minzoom': def.minZoom,
      'maxzoom': est.maxZoom,
    }, update: false);
    return a;
  }

  Future<void> _start(DownloadedArea a, Map<String, dynamic> request, {required bool update}) async {
    final core = _core!;
    final job = await core.startJob('layer_download', {'layers': layersConfig(), ...request});
    a
      ..phase = AreaPhase.running
      ..error = null
      ..doneTiles = update ? 0 : a.doneTiles;
    _areaLayer[a.id] = (_entries[a.layerId]?['download_layer'] as String?) ?? a.layerId;
    _running[a.id] = _Run(a, job, update);
    _areas[_key(a.layerId, a.id)] = a;
    _poll ??= Timer.periodic(pollEvery, (_) => _tick());
    notifyListeners();
  }

  /// One look at every running download. The timer fires every [pollEvery] whether or not the last look has finished, and a look
  /// awaits the core several times, so two looks used to overlap: both saw the same finished job, both freed it, and a reload in
  /// one put back (as an unfinished download) the area the other had just deleted. One look at a time now: a look that finds
  /// another still running skips, and the next timer tick comes back to it.
  Future<void> _tick() async {
    if (_disposed || _ticking) return;
    _ticking = true;
    try {
      await _look();
    } finally {
      _ticking = false;
    }
  }

  bool _ticking = false;

  Future<void> _look() async {
    var changed = false;
    var reload = false;
    final settled = <_Run>[];
    for (final r in List.of(_running.values)) {
      if (_disposed) return;
      JobProgress p;
      try {
        p = await r.job.progress();
      } catch (_) {
        continue;
      }
      if (_disposed) return;
      final a = r.area;
      if (p.total > 0) {
        if (!r.update) {
          a
            ..totalTiles = a.totalTiles == 0 ? p.total : a.totalTiles
            ..doneTiles = p.done;
        } else {
          a
            ..totalTiles = p.total
            ..doneTiles = p.done;
        }
      }
      if (p.bytes != null && !r.update) a.bytes = p.bytes!;
      changed = true;
      if (!p.isFinished) continue;
      _running.remove(a.id);
      settled.add(r);
      try {
        await r.job.free();
      } catch (_) {}
      if (_disposed) return;
      switch (p.state) {
        case JobState.done:
          a.error = null;
        case JobState.cancelled:
          if (!r.update) {
            // A first download that is cancelled leaves nothing behind.
            try {
              await _core!.layers('delete', jsonEncode({'layer': _areaLayer[a.id] ?? a.layerId, 'area': a.id}));
            } catch (_) {}
            if (_disposed) return;
            _areas.remove(_key(a.layerId, a.id));
          }
        default:
          a.error = words(p.errorCode, p.errorMessage);
          if (r.update) a.phase = AreaPhase.done;
      }
      reload = true;
    }
    if (reload) {
      try {
        await _reload();
      } catch (_) {}
    }
    if (_disposed) return;
    if (_running.isEmpty) {
      _poll?.cancel();
      _poll = null;
    }
    if (changed) notifyListeners();
    // A cancel is waiting for exactly this: the job ended, its leftovers are deleted and the lists are read again.
    for (final r in settled) {
      if (!r.done.isCompleted) r.done.complete();
    }
  }

  @visibleForTesting
  static String words(String? code, String? message) => switch (code) {
        'no_space' => 'There is not enough free space on this phone.',
        'limit_exceeded' => "This area is too big for the layer's source.",
        'offline' || 'fetch_failed' => 'No connection. Connect and tap Update to continue.',
        // A message that holds an address (an HTTP failure) is for the log, not the row.
        _ => message == null || message.isEmpty || message.contains('://') ? 'The download stopped. Tap Update to continue.' : 'The download stopped: $message',
      };

  /// Stops a download and returns when it has ended: the core has stopped the job, a first download's partial files are deleted
  /// and the areas are listed again, so nothing of it is left to appear later.
  @override
  Future<void> cancel(String areaId) async {
    final r = _running[areaId];
    if (r == null) return;
    await r.job.cancel();
    await r.done.future;
  }

  @override
  Future<void> delete(String areaId) async {
    final r = _running[areaId];
    if (r != null) {
      await r.job.cancel();
      await r.done.future;
    }
    final layer = _areaLayer[areaId] ?? _areas.values.where((a) => a.id == areaId).firstOrNull?.layerId;
    if (layer == null) return;
    await _core!.layers('delete', jsonEncode({'layer': layer, 'area': areaId}));
    _areas.removeWhere((k, a) => a.id == areaId);
    await _reload();
    notifyListeners();
  }

  @override
  Future<void> update(String areaId, {bool anyway = false}) async {
    await policy?.checkDownload(anyway: anyway);
    final a = _areas.values.where((x) => x.id == areaId).firstOrNull;
    if (a == null || _running.containsKey(areaId)) return;
    final partial = a.phase == AreaPhase.failed;
    final saved = _saved[areaId];
    if (partial && saved == null) {
      // An unfinished download from before the app was closed: the shape was not kept.
      a.error = 'This download cannot be continued. Delete it and start again.';
      notifyListeners();
      return;
    }
    await _start(
      a,
      partial
          ? {'layer': a.layerId, 'area': areaId, 'name': a.label, 'bbox': [saved!.bounds.west, saved.bounds.south, saved.bounds.east, saved.bounds.north], 'minzoom': saved.minZoom, 'maxzoom': saved.maxZoom}
          : {'layer': a.layerId, 'area': areaId, 'update': true},
      update: !partial,
    );
  }
}

class _Run {
  _Run(this.area, this.job, this.update);

  /// Completes when the download has ended and been cleaned up (or the engine is disposed).
  final Completer<void> done = Completer<void>();
  final DownloadedArea area;
  final CoreJobHandle job;
  final bool update;
}

class _Saved {
  _Saved(this.bounds, this.minZoom, this.maxZoom);
  final GeoBounds bounds;
  final int minZoom;
  final int maxZoom;
}
