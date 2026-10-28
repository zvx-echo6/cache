import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';

import '../files.dart';
import '../maps/layers/layer_def.dart';
import '../maps/maps_state.dart';
import '../settings/data_policy.dart';
import 'region_catalogue.dart';
import 'regions_core.dart';

/// Where the core fetches road routing tiles from.
const String kRoutingBaseUrl = 'https://cache.echo6.co/routing/';

/// The file next to the core's region folder where the app keeps what each region holds (its parts and the map areas it
/// downloaded).
const String kRegionsAppFile = 'regions-app.json';

/// What downloading the road routing part of a region costs, from the core's plan.
class RoutingPlan {
  const RoutingPlan({required this.tiles, required this.bytes, required this.downloadBytes, required this.sharedTiles});

  final int tiles;
  final int bytes;

  /// Only what is not on the phone yet.
  final int downloadBytes;
  final int sharedTiles;

  factory RoutingPlan.fromJson(Map<String, dynamic> j) => RoutingPlan(
    tiles: (j['tiles'] as num?)?.toInt() ?? 0,
    bytes: (j['bytes'] as num?)?.toInt() ?? 0,
    downloadBytes: (j['download_bytes'] as num?)?.toInt() ?? 0,
    sharedTiles: (j['shared_tiles'] as num?)?.toInt() ?? 0,
  );
}

/// One map layer of a region's map part and the layer engine's estimate for the region's box.
class MapLayerPlan {
  const MapLayerPlan(this.def, this.estimate);

  final LayerDef def;
  final AreaEstimate estimate;
}

/// What a region would cost, part by part, before anything is downloaded. A part that cannot be worked out says why.
class RegionPlan {
  const RegionPlan({this.routing, this.routingProblem, this.map = const [], this.mapProblem});

  final RoutingPlan? routing;
  final String? routingProblem;
  final List<MapLayerPlan> map;
  final String? mapProblem;

  /// The map layers that can be downloaded for this box.
  List<MapLayerPlan> get mapAllowed => [for (final m in map) if (m.estimate.allowed) m];

  int get mapBytes => mapAllowed.fold(0, (s, m) => s + m.estimate.bytes);
  int get mapBytesAlready => mapAllowed.fold(0, (s, m) => s + m.estimate.bytesAlready);
}

/// What one region holds on this phone.
enum RegionPhase { downloading, ready, paused, failed }

/// A region on this phone: its road routing (from the core's status) and its map areas (from the layer engine).
class LocalRegion {
  LocalRegion({required this.id, required this.name, this.routing, this.areas = const [], this.wantsRouting = false});

  final String id;
  final String name;

  /// The core's status entry for this region, or null when the region has no road routing part.
  final Map<String, dynamic>? routing;
  final List<DownloadedArea> areas;

  /// Road routing was asked for (it may not be in the core's status yet).
  final bool wantsRouting;

  bool get hasRouting => wantsRouting || routing != null;
  bool get hasMap => areas.isNotEmpty;

  String? get routingState => routing?['state'] as String?;

  int get routingBytes {
    final r = routing;
    if (r == null) return 0;
    return ((r['state'] == 'ready' ? r['bytes'] : r['done_bytes']) as num?)?.toInt() ?? 0;
  }

  int get mapBytes => areas.fold(0, (s, a) => s + a.bytes);

  /// What it uses on the phone (a tile two regions need is counted in both, but kept once).
  int get bytes => routingBytes + mapBytes;

  RegionPhase get phase {
    if (routingState == 'failed' || areas.any((a) => a.phase == AreaPhase.failed)) return RegionPhase.failed;
    if (routingState == 'paused') return RegionPhase.paused;
    if (routingState == 'downloading' || areas.any((a) => a.phase == AreaPhase.running)) return RegionPhase.downloading;
    if (wantsRouting && routing == null) return RegionPhase.downloading;
    return RegionPhase.ready;
  }

  String? get error => (routing?['error'] as String?) ?? areas.where((a) => a.error != null).map((a) => a.error).firstOrNull;

  /// 0..1: the mean of the parts (road routing by bytes, the map by tiles).
  double get fraction {
    final parts = <double>[];
    final r = routing;
    if (r != null) {
      final total = (r['bytes'] as num?)?.toInt() ?? 0;
      final done = (r['done_bytes'] as num?)?.toInt() ?? 0;
      parts.add(r['state'] == 'ready' ? 1 : (total == 0 ? 0 : done / total));
    } else if (wantsRouting) {
      parts.add(0);
    }
    if (areas.isNotEmpty) {
      final total = areas.fold(0, (s, a) => s + a.totalTiles);
      final done = areas.fold(0, (s, a) => s + a.doneTiles);
      parts.add(total == 0 ? 1 : done / total);
    }
    if (parts.isEmpty) return 0;
    return (parts.reduce((a, b) => a + b) / parts.length).clamp(0, 1).toDouble();
  }

  /// The newest map download's date.
  DateTime? get fetchedAt {
    DateTime? t;
    for (final a in areas) {
      final f = a.fetchedAt;
      if (f != null && (t == null || f.isAfter(t))) t = f;
    }
    return t;
  }
}

/// Regions and downloads: the region catalogue, the core's road routing tiles and the map layers' area downloads, as one list
/// of regions. A region is a bundle of parts (road routing and map in this phase); every part is stored once and shared by the
/// regions that need it, so a plan counts only what is new.
class RegionsState extends ChangeNotifier {
  RegionsState({
    required this.policy,
    required this.supportDir,
    required this.catalogue,
    required this.maps,
    RegionsOpener? opener,
    this.baseUrl = kRoutingBaseUrl,
  }) : _opener = opener ?? openRealRegions;

  final DataPolicy policy;
  final Future<Directory> Function() supportDir;
  final RegionCatalogue catalogue;
  final MapsState maps;
  final RegionsOpener _opener;
  final String baseUrl;

  RegionsCoreLike? _core;
  bool _started = false;

  /// Why road routing downloads cannot be used here (the core has no region engine), or null.
  String? routingUnavailable;
  Map<String, dynamic> status = const {};
  Timer? _poll;
  StreamSubscription<ConnectionKind>? _net;
  bool _networkOk = true;
  ConnectionKind _kind = ConnectionKind.wifi;
  final Map<String, _Kept> _kept = {};
  String? _routingKey;

  bool get routingAvailable => _core != null;

  Future<File> _appFile() async => File('${(await supportDir()).path}/$kRegionsAppFile');

  /// Reads what the regions hold and starts the core's region engine.
  Future<void> init() async {
    if (_started) return;
    _started = true;
    maps.addListener(_onMaps);
    try {
      final f = await _appFile();
      if (await f.exists()) {
        final j = (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>();
        for (final e in ((j['regions'] as Map?) ?? const {}).entries) {
          _kept[e.key as String] = _Kept.fromJson(e.key as String, (e.value as Map).cast<String, dynamic>());
        }
        final r = j['routing'];
        if (r is Map) _routingKey = r['key'] as String?;
      }
    } catch (_) {}
    try {
      final support = await supportDir();
      _core = await _opener({'dir': '${support.path}/regions', 'base_url': baseUrl});
    } catch (e) {
      routingUnavailable = e is CacheSearchException ? e.message : 'Road routing downloads are not available: $e';
      notifyListeners();
      return;
    }
    await _applyPolicy();
    _net = policy.probe.changes.listen((_) => _applyPolicy().catchError((_) {}));
    // Switching mobile data for downloads on or off applies at once, mid-download too.
    policy.settings.addListener(_onSettings);
    await refresh();
  }

  void _onMaps() => notifyListeners();

  bool? _lastMobile;

  void _onSettings() {
    if (_lastMobile == policy.settings.mobileForDownloads) return;
    _lastMobile = policy.settings.mobileForDownloads;
    _applyPolicy().catchError((_) {});
  }

  /// The same rule as sharing and every other download: Wi-Fi and other connections always, mobile data only when downloads
  /// may use it.
  Future<void> _applyPolicy() async {
    final kind = _kind = await policy.probe.current();
    final ok = _networkOk = kind != ConnectionKind.none && !(kind == ConnectionKind.mobile && !policy.settings.mobileForDownloads);
    await _core?.call('set_policy', {'network': ok});
    notifyListeners();
  }

  Future<void> refresh() async {
    final c = _core;
    if (c == null) return;
    try {
      status = await c.call('status');
    } catch (_) {
      return;
    }
    _schedulePoll();
    await _routingCheck();
    notifyListeners();
  }

  /// Status is read every 2 seconds while something downloads, and not otherwise.
  void _schedulePoll() {
    final busy = _routingRegions.any((r) => r['state'] == 'downloading') || _kept.values.any((k) => k.routing && _statusOf(k.id) == null);
    if (busy && _poll == null) {
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => refresh());
    } else if (!busy) {
      _poll?.cancel();
      _poll = null;
    }
  }

  /// Notes the ready regions and their build. The search core routes on the same engine's tile folder, so a region that
  /// finishes is used by the next route, with nothing to reopen.
  Future<void> _routingCheck() async {
    final ready = [for (final r in _routingRegions) if (r['state'] == 'ready') r]..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    final dir = status['tile_dir'] as String?;
    final key = '${status['build']}|$dir|${ready.map((r) => r['id']).join(',')}';
    if (key == _routingKey) return;
    _routingKey = key;
    await _save();
  }

  List<Map<String, dynamic>> get _routingRegions => [for (final r in (status['regions'] as List? ?? const [])) (r as Map).cast<String, dynamic>()];

  Map<String, dynamic>? _statusOf(String id) => _routingRegions.where((r) => r['id'] == id).firstOrNull;

  /// Why downloads are paused right now, in words for people, or null.
  String? get paused {
    if (_core == null) return null;
    if (!_networkOk) {
      return _kind == ConnectionKind.none
          ? 'Paused: no connection.'
          : 'Paused: mobile data is switched off for downloads. Connect to Wi-Fi to carry on.';
    }
    return status['paused'] as String?;
  }

  /// A new road routing build: {"build","download_bytes"}, or null.
  Map<String, dynamic>? get routingUpdate => (status['update'] as Map?)?.cast<String, dynamic>();

  /// The layers a region's map part downloads: those on the map now that may be kept offline (by default the starter base
  /// map and whatever the person switched on).
  List<LayerDef> get mapLayers => [for (final l in maps.catalogueLayers) if (maps.isOn(l.id) && !l.onlineOnly) l];

  List<DownloadedArea> _areasOf(_Kept k) {
    final out = <DownloadedArea>[];
    for (final l in maps.engine.layers) {
      for (final a in maps.engine.areasOf(l.id)) {
        if (k.areas.contains(a.id)) out.add(a);
      }
    }
    return out;
  }

  /// Every region on this phone, largest first.
  List<LocalRegion> get local {
    final ids = <String>{..._kept.keys, for (final r in _routingRegions) r['id'] as String};
    final out = [for (final id in ids) regionOf(id)!];
    out.sort((a, b) => b.bytes.compareTo(a.bytes));
    return out;
  }

  /// The region [id] as it is on this phone, or null when nothing of it is here.
  LocalRegion? regionOf(String id) {
    final k = _kept[id];
    final r = _statusOf(id);
    if (k == null && r == null) return null;
    return LocalRegion(
      id: id,
      name: k?.name ?? r?['name'] as String? ?? id,
      routing: r,
      areas: k == null ? const [] : _areasOf(k),
      wantsRouting: k?.routing ?? false,
    );
  }

  /// The map areas of the regions, for the Updates tab.
  List<LocalRegion> get withMap => [for (final l in local) if (l.hasMap) l];

  /// What [r] would cost, part by part. Only what is not on the phone yet is counted.
  Future<RegionPlan> plan(RegionRecord r) async {
    RoutingPlan? routing;
    String? routingProblem;
    final core = _core;
    if (core == null) {
      routingProblem = routingUnavailable ?? 'Road routing downloads are not available.';
    } else {
      try {
        final geometry = await catalogue.geometry(r);
        routing = RoutingPlan.fromJson(await core.call('plan', {'id': r.id, 'name': r.name, 'geometry': geometry}));
      } on CacheSearchException catch (e) {
        routingProblem = e.code == 'offline' ? 'Needs a connection to work out the size.' : e.message;
      } catch (_) {
        routingProblem = 'Needs a connection to work out the size.';
      }
    }
    final bounds = r.bounds;
    if (bounds == null) return RegionPlan(routing: routing, routingProblem: routingProblem, mapProblem: 'This region has no outline yet.');
    final layers = mapLayers;
    if (layers.isEmpty) return RegionPlan(routing: routing, routingProblem: routingProblem, mapProblem: 'No map layer that can be kept offline is switched on.');
    final map = <MapLayerPlan>[];
    String? mapProblem;
    for (final card in layers) {
      final def = maps.downloadDefFor(card, bounds);
      try {
        map.add(MapLayerPlan(def, await maps.engine.estimate(def.id, bounds)));
      } catch (_) {
        mapProblem = 'Could not work out the size of the map.';
      }
    }
    if (mapProblem == null && map.isNotEmpty && map.every((m) => !m.estimate.allowed)) {
      mapProblem = map.first.estimate.problem ?? 'This region is too big to download the map in one go.';
    }
    return RegionPlan(routing: routing, routingProblem: routingProblem, map: map, mapProblem: mapProblem);
  }

  /// Starts downloading the parts of [r] that were picked. Throws [MobileDataBlocked] before anything starts when the phone is on
  /// mobile data and downloads may not use it, unless [anyway].
  Future<void> download(RegionRecord r, {required bool routing, required bool map, bool anyway = false}) async {
    await policy.checkDownload(anyway: anyway);
    final k = _kept[r.id] ??= _Kept(id: r.id, name: r.name);
    if (routing) {
      final core = _core ?? (throw CacheSearchException('unsupported', routingUnavailable ?? 'Road routing downloads are not available.'));
      final geometry = await catalogue.geometry(r);
      await core.call('add', {'id': r.id, 'name': r.name, 'geometry': geometry});
      k.routing = true;
    }
    if (map) {
      // The layer engine downloads a box: the map part covers the region's bounding box, not its exact outline.
      final bounds = r.bounds;
      if (bounds != null) {
        for (final card in mapLayers) {
          final def = maps.downloadDefFor(card, bounds);
          final est = await maps.engine.estimate(def.id, bounds);
          if (!est.allowed) continue;
          final a = await maps.engine.download(def.id, bounds, label: r.name, anyway: anyway);
          k.areas.add(a.id);
        }
      }
    }
    if (!k.routing && k.areas.isEmpty) _kept.remove(r.id);
    await _save();
    await refresh();
    notifyListeners();
  }

  /// Removes the region. Tiles another region still needs stay (the core and the layer engine keep shared tiles once).
  Future<void> remove(String id) async {
    final k = _kept.remove(id);
    if ((k?.routing ?? false) || _statusOf(id) != null) await _core?.call('remove', {'id': id});
    for (final a in k?.areas ?? const <String>[]) {
      await maps.engine.delete(a);
    }
    await _save();
    await refresh();
    notifyListeners();
  }

  /// Asks the core whether a newer road routing build is out.
  Future<void> checkUpdates() async {
    await _core?.call('check_update');
    await refresh();
  }

  /// Fetches the region's map again and, when a newer road routing build is out, that too.
  Future<void> updateRegion(String id, {bool anyway = false}) async {
    await policy.checkDownload(anyway: anyway);
    final k = _kept[id];
    if (routingUpdate != null && (k?.routing ?? false)) await _core?.call('update');
    for (final a in k?.areas ?? const <String>[]) {
      await maps.engine.update(a, anyway: anyway);
    }
    await refresh();
  }

  /// Everything at once: the new road routing build and every region's map.
  Future<void> updateAll({bool anyway = false}) async {
    await policy.checkDownload(anyway: anyway);
    if (routingUpdate != null) await _core?.call('update');
    for (final k in _kept.values) {
      for (final a in k.areas) {
        await maps.engine.update(a, anyway: anyway);
      }
    }
    await refresh();
  }

  Future<void> _save() async {
    try {
      final f = await _appFile();
      await f.parent.create(recursive: true);
      final ready = [for (final r in _routingRegions) if (r['state'] == 'ready') r['name'] as String? ?? r['id'] as String];
      await writeStringAtomic(f, jsonEncode({
        'regions': {for (final k in _kept.values) k.id: k.toJson()},
        'routing': {
          'key': _routingKey,
          if (status['tile_dir'] is String && ready.isNotEmpty) 'tile_dir': status['tile_dir'],
          'regions': ready,
        },
      }));
    } catch (_) {}
  }

  @override
  void dispose() {
    _poll?.cancel();
    _net?.cancel();
    maps.removeListener(_onMaps);
    if (_core != null) policy.settings.removeListener(_onSettings);
    _core?.close();
    super.dispose();
  }
}

/// What the app remembers of one region: its name and the parts it asked for.
class _Kept {
  _Kept({required this.id, required this.name, this.routing = false, List<String>? areas}) : areas = areas ?? [];

  final String id;
  final String name;
  bool routing;
  final List<String> areas;

  Map<String, dynamic> toJson() => {'name': name, 'routing': routing, 'areas': areas};

  factory _Kept.fromJson(String id, Map<String, dynamic> j) => _Kept(
    id: id,
    name: j['name'] as String? ?? '',
    routing: j['routing'] == true,
    areas: [for (final a in (j['areas'] as List? ?? const [])) a as String],
  );
}
