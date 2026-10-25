// FAKE: a small Dart stand-in for the layer engine in the Rust core (branch layers-core).
//
// It serves the same address shape the real engine will (`GET /layers/{id}/{z}/{x}/{y}` on 127.0.0.1, plus a
// TileJSON per layer) and passes the layers it can reach through from their public hosts: OpenFreeMap for the
// base map and Mapterhorn for elevation. Downloads really fetch and keep tiles, within OpenFreeMap's terms
// (at most 3,000 tiles or 50 MB per download, 4 requests at a time, an app User-Agent). Layers that need the
// Rust core (contours, area cuts, prebuilt vector tiles) are in the catalogue but cannot be served here.
//
// Nothing in this file is meant to ship: when the core's C ABI is bound, a `CoreLayerEngine` replaces it and
// this file and fake_catalogue.dart are deleted.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../geo.dart';
import 'fake_catalogue.dart';
import 'layer_def.dart';
import 'layer_engine.dart';
import 'tile_math.dart';

/// One tile as fetched from a public host.
class FetchedTile {
  const FetchedTile(this.bytes, {this.contentType, this.gzip = false});
  final List<int> bytes;
  final String? contentType;

  /// The bytes are gzip-compressed (vector tiles are kept and served compressed).
  final bool gzip;
}

/// Fetches [url]; null when the host has no such tile (404 or 204). Throws when there is no connection.
typedef TileFetcher = Future<FetchedTile?> Function(Uri url);

/// A unique User-Agent, as OpenFreeMap asks. It names the app and its public repository, nobody's person.
const String kMapsUserAgent = 'Cache-Offline-Maps/0.1 (+https://github.com/zvx-echo6/cache)';

Future<FetchedTile?> defaultTileFetcher(Uri url) async {
  final client = HttpClient()
    ..userAgent = kMapsUserAgent
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(url);
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
    final res = await req.close();
    if (res.statusCode == 404 || res.statusCode == 204) {
      await res.drain<void>();
      return null;
    }
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('HTTP ${res.statusCode}', uri: url);
    }
    final bytes = <int>[];
    await for (final c in res) {
      bytes.addAll(c);
    }
    return FetchedTile(bytes,
        contentType: res.headers.contentType?.mimeType, gzip: res.headers.value(HttpHeaders.contentEncodingHeader) == 'gzip');
  } finally {
    client.close(force: true);
  }
}

class FakeLayerEngine extends LayerEngine {
  FakeLayerEngine({this.dirOverride, TileFetcher? fetcher, Future<bool> Function()? onlineProbe, this.canBind})
      : _fetch = fetcher ?? defaultTileFetcher,
        _probe = onlineProbe;

  /// Test hook: false pretends the system refuses the server socket.
  final bool Function()? canBind;

  /// Test hook: where tiles and settings live.
  final Directory? dirOverride;
  final TileFetcher _fetch;
  final Future<bool> Function()? _probe;

  late Directory _dir;
  HttpServer? _server;
  List<LayerDef> _layers = [];
  final List<DownloadedArea> _areas = [];
  final Map<String, String> _tileJsonTemplates = {};
  final Set<String> _cancelled = {};
  bool _ready = false;
  bool _online = true;
  DateTime _lastProbe = DateTime.fromMillisecondsSinceEpoch(0);
  String? _problem;
  bool _blocked = false;

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

  int get port => _server!.port;

  @override
  Future<void> start() async {
    _problem = null;
    _blocked = false;
    try {
      _dir = dirOverride ?? Directory('${(await getApplicationSupportDirectory()).path}/fake_layers');
      await _dir.create(recursive: true);
      if (_layers.isEmpty) {
        _loadDefs();
        _loadAreas();
      }
      if (_server == null) {
        if (canBind != null && !canBind!()) {
          throw const SocketException('Failed to create server socket', osError: OSError('Operation not permitted', 1));
        }
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        _server!.listen(_handle, onError: (Object _) {});
      }
      _ready = true;
      await refreshOnline(force: true);
    } catch (e, st) {
      debugPrint('FakeLayerEngine.start failed: $e\n$st');
      // EPERM on the server socket: the system has network access switched off for the app.
      _blocked = e is SocketException && e.osError?.errorCode == 1;
      _problem = 'Layers are not available on this device';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  // ---- catalogue ----------------------------------------------------------------------------------------

  File get _defsFile => File('${_dir.path}/definitions.json');
  File get _areasFile => File('${_dir.path}/areas.json');

  void _loadDefs() {
    List<Map<String, dynamic>> raw = fakeCatalogue;
    try {
      if (_defsFile.existsSync()) {
        raw = [for (final e in jsonDecode(_defsFile.readAsStringSync()) as List) Map<String, dynamic>.from(e as Map)];
      }
    } catch (_) {}
    _layers = [for (final j in raw) LayerDef.fromJson(j)];
  }

  void _saveDefs() => _defsFile.writeAsStringSync(jsonEncode([for (final l in _layers) l.toJson()]));

  @override
  Future<void> saveDefinition(String json) async {
    final def = LayerDef.parse(json);
    final i = _layers.indexWhere((l) => l.id == def.id);
    if (i >= 0) {
      _layers[i] = def;
    } else {
      _layers.add(def);
    }
    _tileJsonTemplates.remove(def.id);
    _saveDefs();
    notifyListeners();
  }

  @override
  Future<void> removeDefinition(String id) async {
    _layers.removeWhere((l) => l.id == id);
    _saveDefs();
    notifyListeners();
  }

  // ---- addresses ----------------------------------------------------------------------------------------

  @override
  String tilesUrl(String id) => 'http://127.0.0.1:$port/layers/$id/{z}/{x}/{y}';

  // The real engine's TileJSON address is its to decide; this is the guess the fake serves.
  @override
  String tileJsonUrl(String id) => 'http://127.0.0.1:$port/layers/$id.json';

  // ---- connection ---------------------------------------------------------------------------------------

  @override
  Future<void> refreshOnline({bool force = false}) async {
    if (!force && DateTime.now().difference(_lastProbe) < const Duration(seconds: 8)) return;
    _lastProbe = DateTime.now();
    bool now;
    try {
      if (_probe != null) {
        now = await _probe();
      } else {
        final r = await InternetAddress.lookup('tiles.openfreemap.org').timeout(const Duration(seconds: 4));
        now = r.isNotEmpty;
      }
    } catch (_) {
      now = false;
    }
    if (now != _online) {
      _online = now;
      notifyListeners();
    }
  }

  // ---- tile server --------------------------------------------------------------------------------------

  Future<void> _handle(HttpRequest r) async {
    final res = r.response;
    try {
      final seg = r.uri.pathSegments;
      if (seg.length == 2 && seg[0] == 'layers' && seg[1].endsWith('.json')) {
        final def = layer(seg[1].substring(0, seg[1].length - 5));
        if (def == null) return _status(res, 404);
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'tilejson': '3.0.0',
          'name': def.title,
          'attribution': def.attribution,
          'minzoom': def.minZoom,
          'maxzoom': def.maxZoom,
          'tiles': [tilesUrl(def.id)],
        }));
        return _close(res);
      }
      if (seg.length != 5 || seg[0] != 'layers') return _status(res, 404);
      final def = layer(seg[1]);
      final z = int.tryParse(seg[2]);
      final x = int.tryParse(seg[3]);
      final y = int.tryParse(seg[4].split('.').first);
      if (def == null || z == null || x == null || y == null) return _status(res, 404);
      final tile = await _tile(def, z, x, y);
      if (tile == null) return _status(res, 204);
      res.headers.contentType = ContentType.parse(tile.contentType ?? 'application/octet-stream');
      if (tile.gzip) res.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
      res.add(tile.bytes);
      await _close(res);
    } catch (_) {
      // No connection and nothing kept: the map shows what it has.
      try {
        res.statusCode = 503;
      } catch (_) {}
      await _close(res);
    }
  }

  Future<void> _status(HttpResponse res, int code) {
    res.statusCode = code;
    return _close(res);
  }

  Future<void> _close(HttpResponse res) async {
    try {
      await res.close();
    } catch (_) {}
  }

  String _contentTypeOf(LayerDef def, Uri? upstream) {
    final p = upstream?.path.toLowerCase() ?? '';
    if (p.endsWith('.webp')) return 'image/webp';
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'image/jpeg';
    return 'application/x-protobuf';
  }

  bool _isVector(LayerDef d) => d.kind == LayerKind.basemap || d.kind == LayerKind.contours || d.kind == LayerKind.vector;

  File _cacheFile(String id, int z, int x, int y) => File('${_dir.path}/cache/$id/$z/$x/$y');
  File _areaFile(String areaId, int z, int x, int y) => File('${_dir.path}/areas/$areaId/$z/$x/$y');

  File? _localTile(LayerDef def, int z, int x, int y) {
    for (final a in _areas) {
      if (a.layerId != def.id || a.phase == AreaPhase.failed && a.doneTiles == 0) continue;
      final f = _areaFile(a.id, z, x, y);
      if (f.existsSync()) return f;
    }
    final c = _cacheFile(def.id, z, x, y);
    return c.existsSync() ? c : null;
  }

  Future<FetchedTile?> _tile(LayerDef def, int z, int x, int y) async {
    final local = _localTile(def, z, x, y);
    if (local != null) {
      return FetchedTile(await local.readAsBytes(),
          contentType: _isVector(def) ? 'application/x-protobuf' : _contentTypeOf(def, await _upstream(def, z, x, y)),
          gzip: _isVector(def));
    }
    final up = await _upstream(def, z, x, y);
    if (up == null) return null;
    final t = await _fetch(up);
    if (t == null) return null;
    // Tiles seen on the map are kept (the app caches what is viewed).
    final f = _cacheFile(def.id, z, x, y);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(_isVector(def) ? _gz(t) : t.bytes);
    return FetchedTile(_isVector(def) ? _gz(t) : t.bytes,
        contentType: t.contentType ?? _contentTypeOf(def, up), gzip: _isVector(def));
  }

  List<int> _gz(FetchedTile t) => t.gzip ? t.bytes : gzip.encode(t.bytes);

  /// The public address of one tile of [def], or null when the fake cannot reach this layer.
  Future<Uri?> _upstream(LayerDef def, int z, int x, int y) async {
    if (def.raw['fake_unavailable'] == true || def.sourceUrl.isEmpty) return null;
    var template = def.sourceUrl;
    if (!template.contains('{z}')) {
      // A TileJSON address: read it once for the real (versioned) tile template.
      final known = _tileJsonTemplates[def.id];
      if (known != null) {
        template = known;
      } else {
        final t = await _fetch(Uri.parse(def.sourceUrl));
        if (t == null) return null;
        final body = utf8.decode(t.gzip ? gzip.decode(t.bytes) : t.bytes);
        template = ((jsonDecode(body) as Map)['tiles'] as List).first as String;
        _tileJsonTemplates[def.id] = template;
      }
    }
    return Uri.parse(template.replaceAll('{z}', '$z').replaceAll('{x}', '$x').replaceAll('{y}', '$y'));
  }

  // ---- coverage -----------------------------------------------------------------------------------------

  @override
  Future<bool> hasTiles(String layerId, GeoBounds view, int zoom) async {
    final def = layer(layerId);
    if (def == null) return false;
    final z = zoom.clamp(def.minZoom, def.maxZoom);
    final x = TileMath.tileX(view.centerLon, z);
    final y = TileMath.tileY(view.centerLat, z);
    return _localTile(def, z, x, y) != null;
  }

  // ---- areas --------------------------------------------------------------------------------------------

  @override
  Future<AreaEstimate> estimate(String layerId, GeoBounds area) async {
    final def = layer(layerId) ?? (throw StateError('Unknown layer'));
    if (def.onlineOnly) {
      return const AreaEstimate(
          tiles: 0, bytes: 0, maxZoom: 0, allowed: false, problem: 'This layer\'s terms do not allow keeping it offline.');
    }
    if (def.raw['fake_unavailable'] == true) {
      return const AreaEstimate(
          tiles: 0,
          bytes: 0,
          maxZoom: 0,
          allowed: false,
          problem: 'The layer engine is not connected yet, so this layer cannot be downloaded.');
    }
    final perTile = (def.raw['approx_tile_bytes'] as num?)?.toInt() ?? 30000;
    final maxTiles = (def.raw['download_limit_tiles'] as num?)?.toInt() ?? 3000;
    final maxBytes = (def.raw['download_limit_bytes'] as num?)?.toInt() ?? 50 * 1024 * 1024;
    // Take the most detail that stays inside the source's limits.
    for (var z = def.maxZoom; z >= def.minZoom; z--) {
      final n = TileMath.countRange(area, def.minZoom, z);
      if (n <= maxTiles && n * perTile <= maxBytes) {
        // Less than this much detail is not worth a download.
        final floor = (def.minZoom + 10).clamp(def.minZoom, def.maxZoom);
        if (z < floor) break;
        return AreaEstimate(tiles: n, bytes: n * perTile, maxZoom: z, allowed: true);
      }
    }
    final n = TileMath.countRange(area, def.minZoom, (def.minZoom + 10).clamp(def.minZoom, def.maxZoom));
    return AreaEstimate(
      tiles: n,
      bytes: n * perTile,
      maxZoom: def.minZoom,
      allowed: false,
      problem: 'This area is too big for one download (the source allows $maxTiles tiles or '
          '${maxBytes ~/ (1024 * 1024)} MB). Zoom in or draw a smaller area.',
    );
  }

  @override
  List<DownloadedArea> areasOf(String layerId) => [for (final a in _areas) if (a.layerId == layerId) a];

  @override
  Future<DownloadedArea> download(String layerId, GeoBounds area, {required String label}) async {
    final def = layer(layerId) ?? (throw StateError('Unknown layer'));
    final est = await estimate(layerId, area);
    if (!est.allowed) throw StateError(est.problem ?? 'This area cannot be downloaded');
    final a = DownloadedArea(
      id: 'a${DateTime.now().microsecondsSinceEpoch}',
      layerId: layerId,
      bounds: area,
      label: label,
      minZoom: def.minZoom,
      maxZoom: est.maxZoom,
      totalTiles: est.tiles,
    );
    _areas.add(a);
    _saveAreas();
    notifyListeners();
    unawaited(_run(a, def, a.id));
    return a;
  }

  @override
  Future<void> cancel(String areaId) async {
    final a = _areas.where((x) => x.id == areaId).firstOrNull;
    if (a == null) return;
    _cancelled.add(areaId);
    // A first download that is cancelled leaves nothing; a cancelled update keeps the old copy.
    if (a.fetchedAt == null) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  @override
  Future<void> delete(String areaId) async {
    _cancelled.add(areaId);
    _areas.removeWhere((a) => a.id == areaId);
    _saveAreas();
    _rm(Directory('${_dir.path}/areas/$areaId'));
    _rm(Directory('${_dir.path}/areas/$areaId.new'));
    notifyListeners();
  }

  @override
  Future<void> update(String areaId) async {
    final a = _areas.where((x) => x.id == areaId).firstOrNull;
    final def = a == null ? null : layer(a.layerId);
    if (a == null || def == null || a.phase == AreaPhase.running) return;
    a
      ..phase = AreaPhase.running
      ..doneTiles = 0
      ..error = null;
    a.fetchedAt ??= DateTime.now();
    _cancelled.remove(areaId);
    notifyListeners();
    unawaited(_run(a, def, '$areaId.new'));
  }

  void _rm(Directory d) {
    try {
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// Fetches every tile of [a] into `areas/[folder]`, four at a time. A first download lives in its own folder
  /// from the start; an update goes to `<id>.new` and replaces the old copy only when complete.
  Future<void> _run(DownloadedArea a, LayerDef def, String folder) async {
    final isUpdate = folder != a.id;
    final iter = TileMath.tiles(a.bounds, a.minZoom, a.maxZoom).iterator;
    var bytes = 0;
    var done = 0;
    String? failure;
    var lastNotify = DateTime.now();

    Future<void> worker() async {
      while (failure == null && !_cancelled.contains(a.id)) {
        if (!iter.moveNext()) return;
        final (z, x, y) = iter.current;
        final file = File('${_dir.path}/areas/$folder/$z/$x/$y');
        try {
          if (!file.existsSync() || isUpdate) {
            final up = await _upstream(def, z, x, y);
            if (up == null) throw const HttpException('no source');
            final t = await _fetch(up);
            if (t != null) {
              await file.parent.create(recursive: true);
              final data = _isVector(def) ? _gz(t) : t.bytes;
              await file.writeAsBytes(data);
              bytes += data.length;
            }
          } else {
            bytes += file.lengthSync();
          }
          done++;
          if (!isUpdate) {
            a
              ..doneTiles = done
              ..bytes = bytes;
          }
          if (DateTime.now().difference(lastNotify) > const Duration(milliseconds: 300)) {
            lastNotify = DateTime.now();
            if (isUpdate) a.doneTiles = done;
            notifyListeners();
          }
        } on SocketException {
          failure = 'No connection. Connect and tap Update to continue.';
        } on TimeoutException {
          failure = 'No connection. Connect and tap Update to continue.';
        } catch (e) {
          failure = 'Download stopped: ${e is HttpException ? e.message : e}';
        }
      }
    }

    await Future.wait([for (var i = 0; i < 4; i++) worker()]);

    if (!_areas.contains(a)) {
      // Deleted while running.
      _rm(Directory('${_dir.path}/areas/$folder'));
      return;
    }
    if (_cancelled.remove(a.id)) {
      if (isUpdate) {
        _rm(Directory('${_dir.path}/areas/$folder'));
        a.phase = AreaPhase.done;
        a.doneTiles = a.totalTiles;
      } else {
        _areas.remove(a);
        _rm(Directory('${_dir.path}/areas/$folder'));
      }
    } else if (failure != null) {
      a.phase = AreaPhase.failed;
      a.error = failure;
      if (isUpdate) {
        _rm(Directory('${_dir.path}/areas/$folder'));
        a.doneTiles = a.totalTiles;
        a.phase = AreaPhase.done;
        a.error = failure;
      }
    } else {
      if (isUpdate) {
        _rm(Directory('${_dir.path}/areas/${a.id}'));
        Directory('${_dir.path}/areas/$folder').renameSync('${_dir.path}/areas/${a.id}');
      }
      a
        ..bytes = bytes
        ..doneTiles = a.totalTiles
        ..phase = AreaPhase.done
        ..error = null
        ..fetchedAt = DateTime.now();
    }
    _saveAreas();
    notifyListeners();
  }

  void _loadAreas() {
    try {
      if (_areasFile.existsSync()) {
        for (final j in jsonDecode(_areasFile.readAsStringSync()) as List) {
          final a = DownloadedArea.fromJson(Map<String, dynamic>.from(j as Map));
          if (a.phase == AreaPhase.running) {
            a.phase = a.fetchedAt == null ? AreaPhase.failed : AreaPhase.done;
            a.error = 'Stopped when the app closed. Tap Update to continue.';
          }
          _areas.add(a);
        }
      }
    } catch (_) {}
  }

  void _saveAreas() {
    try {
      _areasFile.writeAsStringSync(jsonEncode([for (final a in _areas) a.toJson()]));
    } catch (_) {}
  }

  // ---- storage ------------------------------------------------------------------------------------------

  int _dirBytes(Directory d) {
    var n = 0;
    try {
      if (!d.existsSync()) return 0;
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        n += f.lengthSync();
      }
    } catch (_) {}
    return n;
  }

  final Map<String, (DateTime, int)> _cacheMemo = {};

  /// The size of the viewed-tile cache; walking the folder is slow, so it is remembered for a few seconds.
  int _cacheBytes(String layerId) {
    final m = _cacheMemo[layerId];
    if (m != null && DateTime.now().difference(m.$1) < const Duration(seconds: 5)) return m.$2;
    final n = _dirBytes(Directory('${_dir.path}/cache/$layerId'));
    _cacheMemo[layerId] = (DateTime.now(), n);
    return n;
  }

  @override
  int storageOf(String layerId) {
    var n = 0;
    for (final a in _areas) {
      if (a.layerId == layerId) n += a.bytes;
    }
    return n + _cacheBytes(layerId);
  }

  @override
  int get storageTotal => _layers.fold(0, (s, l) => s + storageOf(l.id));
}
