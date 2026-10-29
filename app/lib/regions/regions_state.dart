import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';

import '../files.dart';
import '../maps/layers/layer_def.dart';
import '../maps/maps_state.dart';
import '../search/core_config.dart';
import '../settings/data_policy.dart';
import 'region_catalogue.dart';
import 'regions_core.dart';

/// The file next to the core's region folder where the app keeps what each region holds (its parts and the map areas it
/// downloaded).
const String kRegionsAppFile = 'regions-app.json';

/// What downloading one part of a region (road routing, or places and addresses) costs, from the core's plan.
class PartPlan {
  const PartPlan({required this.tiles, required this.bytes, required this.downloadBytes, required this.sharedTiles});

  final int tiles;
  final int bytes;

  /// Only what is not on the phone yet.
  final int downloadBytes;
  final int sharedTiles;

  factory PartPlan.fromJson(Map<String, dynamic> j) => PartPlan(
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
  const RegionPlan({this.routing, this.routingProblem, this.places, this.placesProblem, this.map = const [], this.mapProblem});

  final PartPlan? routing;
  final String? routingProblem;
  final PartPlan? places;
  final String? placesProblem;
  final List<MapLayerPlan> map;
  final String? mapProblem;

  /// The map layers that can be downloaded for this box.
  List<MapLayerPlan> get mapAllowed => [for (final m in map) if (m.estimate.allowed) m];

  int get mapBytes => mapAllowed.fold(0, (s, m) => s + m.estimate.bytes);
  int get mapBytesAlready => mapAllowed.fold(0, (s, m) => s + m.estimate.bytesAlready);
}

const String _needsConnection = 'Needs a connection to work out the size.';

/// What one region holds on this phone.
enum RegionPhase { downloading, ready, paused, failed }

/// A region on this phone: its road routing and its places (from the core's status) and its map areas (from the layer engine).
class LocalRegion {
  LocalRegion({
    required this.id,
    required this.name,
    this.routing,
    this.places,
    this.areas = const [],
    this.wantsRouting = false,
    this.wantsPlaces = false,
  });

  final String id;
  final String name;

  /// The core's status of this region's road routing part, or null when the region has none.
  final Map<String, dynamic>? routing;

  /// The core's status of this region's places part (`parts.places`), or null when the region has none.
  final Map<String, dynamic>? places;
  final List<DownloadedArea> areas;

  /// Road routing was asked for (it may not be in the core's status yet).
  final bool wantsRouting;

  /// Places were asked for (they may not be in the core's status yet).
  final bool wantsPlaces;

  bool get hasRouting => wantsRouting || routing != null;
  bool get hasPlaces => wantsPlaces || places != null;
  bool get hasMap => areas.isNotEmpty;

  String? get routingState => routing?['state'] as String?;
  String? get placesState => places?['state'] as String?;

  static int _partBytes(Map<String, dynamic>? p) {
    if (p == null) return 0;
    return ((p['state'] == 'ready' ? p['bytes'] : p['done_bytes']) as num?)?.toInt() ?? 0;
  }

  int get routingBytes => _partBytes(routing);
  int get placesBytes => _partBytes(places);

  int get mapBytes => areas.fold(0, (s, a) => s + a.bytes);

  /// What it uses on the phone (a tile two regions need is counted in both, but kept once).
  int get bytes => routingBytes + placesBytes + mapBytes;

  RegionPhase get phase {
    final states = [routingState, placesState];
    if (states.contains('failed') || areas.any((a) => a.phase == AreaPhase.failed)) return RegionPhase.failed;
    if (states.contains('paused')) return RegionPhase.paused;
    if (states.contains('downloading') || areas.any((a) => a.phase == AreaPhase.running)) return RegionPhase.downloading;
    if ((wantsRouting && routing == null) || (wantsPlaces && places == null)) return RegionPhase.downloading;
    return RegionPhase.ready;
  }

  String? get error =>
      (routing?['error'] as String?) ?? (places?['error'] as String?) ?? areas.where((a) => a.error != null).map((a) => a.error).firstOrNull;

  /// 0..1: the mean of the parts (road routing and places by bytes, the map by tiles).
  double get fraction {
    final parts = <double>[];
    for (final (p, wanted) in [(routing, wantsRouting), (places, wantsPlaces)]) {
      if (p != null) {
        final total = (p['bytes'] as num?)?.toInt() ?? 0;
        final done = (p['done_bytes'] as num?)?.toInt() ?? 0;
        parts.add(p['state'] == 'ready' ? 1 : (total == 0 ? 0 : done / total));
      } else if (wanted) {
        parts.add(0);
      }
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

/// Regions and downloads: the region catalogue, the core's road routing and places tiles and the map layers' area downloads, as
/// one list of regions. A region is a bundle of parts (road routing, places and addresses, and map); every part is stored once
/// and shared by the regions that need it, so a plan counts only what is new.
class RegionsState extends ChangeNotifier {
  RegionsState({
    required this.policy,
    required this.supportDir,
    required this.catalogue,
    required this.maps,
    RegionsOpener? opener,
    this.baseUrl = kRoutingBaseUrl,
    this.placesBaseUrl = kPlacesBaseUrl,
    this.onPlacesChanged,
  }) : _opener = opener ?? openRealRegions;

  final DataPolicy policy;
  final Future<Directory> Function() supportDir;
  final RegionCatalogue catalogue;
  final MapsState maps;
  final RegionsOpener _opener;
  final String baseUrl;
  final String placesBaseUrl;

  /// Called when the places on the phone changed (a tile was merged or removed, or a new build switched in: the core's
  /// `places.generation`), so the search core reads them again and an open search runs again.
  final Future<void> Function()? onPlacesChanged;
  int? _placesGen;
  DateTime? _watchPlacesUntil;

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
      _core = await _opener(regionsConfig(support, routingBaseUrl: baseUrl, placesBaseUrl: placesBaseUrl));
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
    _placesCheck();
    notifyListeners();
  }

  /// Tells [onPlacesChanged] when the core's places generation moved (the first status only sets where it starts).
  void _placesCheck() {
    final g = placesGeneration;
    if (g == null) return;
    final before = _placesGen;
    _placesGen = g;
    if (before != null && before != g) onPlacesChanged?.call().catchError((_) {});
  }

  /// The core's places generation: one more on every merge, removal and build switch. Null when places are not enabled.
  int? get placesGeneration => ((status['places'] as Map?)?['generation'] as num?)?.toInt();

  /// A map search is waiting for places tiles of its area (they are fetched around it): status is read for a while, so the
  /// search runs again when they land.
  void watchPlaces({Duration span = const Duration(seconds: 30)}) {
    if (_core == null) return;
    _watchPlacesUntil = DateTime.now().add(span);
    _schedulePoll();
  }

  /// Status is read every 2 seconds while something downloads (or a search waits for places), and not otherwise.
  void _schedulePoll() {
    final watching = _watchPlacesUntil != null && DateTime.now().isBefore(_watchPlacesUntil!);
    final busy = watching ||
        _routingRegions.any((r) => r['state'] == 'downloading') ||
        _kept.values.any((k) => (k.routing || k.places) && _statusOf(k.id) == null) ||
        placesUpdate?['downloading'] == true;
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
    final ready = [for (final r in _routingRegions) if (_routingOf(r)?['state'] == 'ready') r]..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    final dir = status['tile_dir'] as String?;
    final key = '${status['build']}|$dir|${ready.map((r) => r['id']).join(',')}';
    if (key == _routingKey) return;
    _routingKey = key;
    await _save();
  }

  List<Map<String, dynamic>> get _routingRegions => [for (final r in (status['regions'] as List? ?? const [])) (r as Map).cast<String, dynamic>()];

  Map<String, dynamic>? _statusOf(String id) => _routingRegions.where((r) => r['id'] == id).firstOrNull;

  /// A region's road routing part: `parts.routing`, or the entry itself from a core without parts.
  static Map<String, dynamic>? _routingOf(Map<String, dynamic>? entry) {
    final parts = entry?['parts'];
    if (parts is! Map) return entry;
    return (parts['routing'] as Map?)?.cast<String, dynamic>();
  }

  static Map<String, dynamic>? _placesOf(Map<String, dynamic>? entry) => ((entry?['parts'] as Map?)?['places'] as Map?)?.cast<String, dynamic>();

  /// The core downloads places with regions (its config has a places address and it knows the places part).
  bool get placesAvailable => _core != null && status['places'] is Map;

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

  /// A new places build: {"build","download_bytes","downloading"}, or null.
  Map<String, dynamic>? get placesUpdate => ((status['updates'] as Map?)?['places'] as Map?)?.cast<String, dynamic>();

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
      routing: _routingOf(r),
      places: _placesOf(r),
      areas: k == null ? const [] : _areasOf(k),
      wantsRouting: k?.routing ?? false,
      wantsPlaces: k?.places ?? false,
    );
  }

  /// The map areas of the regions, for the Updates tab.
  List<LocalRegion> get withMap => [for (final l in local) if (l.hasMap) l];

  /// What [r] would cost, part by part. Only what is not on the phone yet is counted.
  Future<RegionPlan> plan(RegionRecord r) async {
    PartPlan? routing, places;
    String? routingProblem, placesProblem;
    final core = _core;
    if (core == null) {
      routingProblem = routingUnavailable ?? 'Road routing downloads are not available.';
    } else {
      try {
        final geometry = await catalogue.geometry(r);
        final j = await core.call('plan', {'id': r.id, 'name': r.name, 'geometry': geometry});
        final parts = j['parts'];
        if (parts is Map) {
          (routing, routingProblem) = _partPlan(parts['routing']);
          (places, placesProblem) = _partPlan(parts['places']);
        } else {
          // A core without parts plans road routing only.
          routing = PartPlan.fromJson(j);
        }
      } on CacheSearchException catch (e) {
        routingProblem = placesProblem = e.code == 'offline' ? _needsConnection : e.message;
      } catch (_) {
        routingProblem = placesProblem = _needsConnection;
      }
    }
    RegionPlan done({List<MapLayerPlan> map = const [], String? mapProblem}) => RegionPlan(
      routing: routing,
      routingProblem: routingProblem,
      places: places,
      placesProblem: placesProblem,
      map: map,
      mapProblem: mapProblem,
    );
    final bounds = r.bounds;
    if (bounds == null) return done(mapProblem: 'This region has no outline yet.');
    final layers = mapLayers;
    if (layers.isEmpty) return done(mapProblem: 'No map layer that can be kept offline is switched on.');
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
    return done(map: map, mapProblem: mapProblem);
  }

  /// One part's entry of the core's plan: its cost, or why it cannot be worked out. Nothing when the part is not there.
  static (PartPlan?, String?) _partPlan(Object? e) {
    if (e is! Map) return (null, null);
    final j = e.cast<String, dynamic>();
    if (j['error'] != null) {
      return (null, j['code'] == 'offline' ? _needsConnection : '${j['error']}');
    }
    return (PartPlan.fromJson(j), null);
  }

  /// Starts downloading the parts of [r] that were picked. Throws [MobileDataBlocked] before anything starts when the phone is on
  /// mobile data and downloads may not use it, unless [anyway].
  Future<void> download(RegionRecord r, {required bool routing, required bool map, bool places = false, bool anyway = false}) async {
    await policy.checkDownload(anyway: anyway);
    places = places && placesAvailable;
    final k = _kept[r.id] ??= _Kept(id: r.id, name: r.name);
    if (routing || places) {
      final core = _core ?? (throw CacheSearchException('unsupported', routingUnavailable ?? 'Road routing downloads are not available.'));
      final geometry = await catalogue.geometry(r);
      await core.call('add', {
        'id': r.id,
        'name': r.name,
        'geometry': geometry,
        // Places first: the core downloads them before road routing, as they are small.
        if (placesAvailable) 'parts': [if (places) 'places', if (routing) 'routing'],
      });
      if (routing) k.routing = true;
      if (places) k.places = true;
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
    if (!k.routing && !k.places && k.areas.isEmpty) _kept.remove(r.id);
    await _save();
    await refresh();
    notifyListeners();
  }

  /// Removes the region. Tiles another region still needs stay (the core and the layer engine keep shared tiles once).
  Future<void> remove(String id) async {
    final k = _kept.remove(id);
    if ((k?.routing ?? false) || (k?.places ?? false) || _statusOf(id) != null) await _core?.call('remove', {'id': id});
    for (final a in k?.areas ?? const <String>[]) {
      await maps.engine.delete(a);
    }
    await _save();
    await refresh();
    notifyListeners();
  }

  /// Asks the core whether a newer road routing or places build is out.
  Future<void> checkUpdates() async {
    await _core?.call('check_update');
    await refresh();
  }

  /// Fetches the region's map again and, when a newer road routing or places build is out, that too. A region downloaded before
  /// places were part of regions gets its places part here.
  Future<void> updateRegion(String id, {bool anyway = false}) async {
    await policy.checkDownload(anyway: anyway);
    final k = _kept[id];
    final l = regionOf(id);
    if (routingUpdate != null && (k?.routing ?? false)) await _core?.call('update', {'component': 'routing'});
    if (placesUpdate != null && placesUpdate!['downloading'] != true && (l?.hasPlaces ?? false)) {
      await _core?.call('update', {'component': 'places'});
    }
    if (l != null && missesPlaces(l)) await _addPlaces(l);
    for (final a in k?.areas ?? const <String>[]) {
      await maps.engine.update(a, anyway: anyway);
    }
    await refresh();
  }

  /// A region on the phone that has no places part while places can be downloaded (one downloaded before they were part of
  /// regions). Update adds it; it is never downloaded without being asked.
  bool missesPlaces(LocalRegion l) => placesAvailable && !l.hasPlaces && (l.hasRouting || l.hasMap);

  Future<void> _addPlaces(LocalRegion l) async {
    final core = _core;
    if (core == null) return;
    RegionRecord? rec;
    try {
      rec = await catalogue.record(l.id);
    } catch (_) {}
    if (rec == null) throw const CacheSearchException('not_found', 'This region could not be read. Connect and try again.');
    await core.call('add', {'id': rec.id, 'name': rec.name, 'geometry': await catalogue.geometry(rec), 'parts': ['places']});
    (_kept[l.id] ??= _Kept(id: l.id, name: l.name)).places = true;
    await _save();
  }

  /// Everything at once: the new road routing and places builds and every region's map.
  Future<void> updateAll({bool anyway = false}) async {
    await policy.checkDownload(anyway: anyway);
    if (routingUpdate != null) await _core?.call('update', {'component': 'routing'});
    if (placesUpdate != null && placesUpdate!['downloading'] != true) await _core?.call('update', {'component': 'places'});
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
      final ready = [for (final r in _routingRegions) if (_routingOf(r)?['state'] == 'ready') r['name'] as String? ?? r['id'] as String];
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
  _Kept({required this.id, required this.name, this.routing = false, this.places = false, List<String>? areas}) : areas = areas ?? [];

  final String id;
  final String name;
  bool routing;
  bool places;
  final List<String> areas;

  Map<String, dynamic> toJson() => {'name': name, 'routing': routing, 'places': places, 'areas': areas};

  factory _Kept.fromJson(String id, Map<String, dynamic> j) => _Kept(
    id: id,
    name: j['name'] as String? ?? '',
    routing: j['routing'] == true,
    places: j['places'] == true,
    areas: [for (final a in (j['areas'] as List? ?? const [])) a as String],
  );
}
