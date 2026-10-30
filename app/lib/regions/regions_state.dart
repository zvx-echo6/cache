import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';

import '../browse/zim_download.dart';
import '../files.dart';
import '../maps/geo.dart';
import '../maps/layers/layer_def.dart';
import '../maps/maps_state.dart';
import '../search/core_config.dart';
import '../settings/damaged_files.dart';
import '../settings/data_policy.dart';
import 'offroad_catalogue.dart';
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

/// One off-road pack a region needs, whether it is on the phone (or on its way for another region), and the z12 elevation over the
/// part of the region it covers (the layer engine's estimate: only the tiles not on the phone yet).
class OffroadPackPlan {
  const OffroadPackPlan(this.pack, {required this.onPhone, required this.elevation});

  final OffroadPack pack;
  final bool onPhone;
  final AreaEstimate elevation;
}

/// What a region's off-road part costs: its packs (usually one: the state or province it is in) and their terrain heights.
class OffroadPlan {
  const OffroadPlan(this.packs);

  final List<OffroadPackPlan> packs;

  /// Every pack's elevation can be downloaded (the size could be worked out).
  bool get allowed => packs.every((p) => p.elevation.allowed);
  String? get problem => packs.map((p) => p.elevation.problem).whereType<String>().firstOrNull;

  /// Every pack is on the phone already (another region brought it): the packs add nothing.
  bool get packsOnPhone => packs.every((p) => p.onPhone);

  /// Only what is not on the phone yet.
  int get downloadBytes => packs.fold(0, (s, p) => s + (p.onPhone ? 0 : p.pack.bytes) + p.elevation.bytes);
  int get bytesAlready => packs.fold(0, (s, p) => s + (p.onPhone ? p.pack.bytes : 0) + p.elevation.bytesAlready);
}

/// The box the off-road terrain heights of a region are downloaded for: the region's box where the pack covers it.
GeoBounds terrainBox(GeoBounds region, GeoBounds pack) => GeoBounds(
  south: region.south > pack.south ? region.south : pack.south,
  west: region.west > pack.west ? region.west : pack.west,
  north: region.north < pack.north ? region.north : pack.north,
  east: region.east < pack.east ? region.east : pack.east,
);

/// What a region would cost, part by part, before anything is downloaded. A part that cannot be worked out says why. No
/// [offroad] and no [offroadProblem]: no off-road pack covers the region, so it has no off-road part.
class RegionPlan {
  const RegionPlan({
    this.routing,
    this.routingProblem,
    this.places,
    this.placesProblem,
    this.map = const [],
    this.mapProblem,
    this.offroad,
    this.offroadProblem,
  });

  final PartPlan? routing;
  final String? routingProblem;
  final PartPlan? places;
  final String? placesProblem;
  final List<MapLayerPlan> map;
  final String? mapProblem;
  final OffroadPlan? offroad;
  final String? offroadProblem;

  /// The off-road part can be downloaded.
  bool get offroadAllowed => offroad != null && offroad!.allowed;

  /// The map layers that can be downloaded for this box.
  List<MapLayerPlan> get mapAllowed => [for (final m in map) if (m.estimate.allowed) m];

  int get mapBytes => mapAllowed.fold(0, (s, m) => s + m.estimate.bytes);
  int get mapBytesAlready => mapAllowed.fold(0, (s, m) => s + m.estimate.bytesAlready);
}

const String _needsConnection = 'Needs a connection to work out the size.';

/// Which part of a region a problem is about, for [regionPartWords].
enum RegionPart { routing, places }

/// Plain words for a problem the core reports with a region part. The core's message is for the log: it holds addresses
/// like "HTTP 404 from https://…". A file the server does not have (404 or 410) is a part not published for the area yet.
String regionPartWords(RegionPart part, String? code, String message) {
  if (code == 'offline') return 'Needs a connection.';
  if (code == 'no_space') return 'There is not enough free space on this phone.';
  // The core's HTTP failure reads "HTTP <status> from <address>" (cache_regions/src/http.rs).
  final status = int.tryParse(RegExp(r'^HTTP (\d{3}) ').firstMatch(message)?.group(1) ?? '');
  if (status == 404 || status == 410) {
    return switch (part) {
      RegionPart.places => "Places for this area aren't available yet.",
      RegionPart.routing => "Road routing for this area isn't available yet.",
    };
  }
  if (status != null) return "The download server couldn't send it just now. Try again later.";
  if (message.contains('://')) return "Couldn't be downloaded. Try again later.";
  return message;
}

/// What one region holds on this phone.
enum RegionPhase { downloading, ready, paused, failed }

/// One off-road pack of a region on this phone: on the phone ([done]), downloading, or stopped with an [error].
class OffroadPackState {
  const OffroadPackState({required this.name, required this.bytes, required this.doneBytes, required this.done, this.error});

  final String name;
  final int bytes;
  final int doneBytes;
  final bool done;
  final String? error;
}

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
    this.offroad = const [],
    this.terrain = const [],
  });

  final String id;
  final String name;

  /// The region's off-road packs: on the phone, downloading or failed.
  final List<OffroadPackState> offroad;

  /// The terrain heights its off-road packs read (z12 elevation areas).
  final List<DownloadedArea> terrain;

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
  bool get hasOffroad => offroad.isNotEmpty;

  String? get routingState => routing?['state'] as String?;
  String? get placesState => places?['state'] as String?;

  static int _partBytes(Map<String, dynamic>? p) {
    if (p == null) return 0;
    return ((p['state'] == 'ready' ? p['bytes'] : p['done_bytes']) as num?)?.toInt() ?? 0;
  }

  int get routingBytes => _partBytes(routing);
  int get placesBytes => _partBytes(places);

  int get mapBytes => areas.fold(0, (s, a) => s + a.bytes);

  int get offroadBytes => offroad.fold(0, (s, p) => s + p.doneBytes) + terrain.fold(0, (s, a) => s + a.bytes);

  /// What it uses on the phone (a tile two regions need is counted in both, but kept once).
  int get bytes => routingBytes + placesBytes + mapBytes + offroadBytes;

  RegionPhase get phase {
    final states = [routingState, placesState];
    final all = [...areas, ...terrain];
    if (states.contains('failed') || all.any((a) => a.phase == AreaPhase.failed) || offroad.any((p) => p.error != null)) {
      return RegionPhase.failed;
    }
    if (states.contains('paused')) return RegionPhase.paused;
    if (states.contains('downloading') || all.any((a) => a.phase == AreaPhase.running) || offroad.any((p) => !p.done)) {
      return RegionPhase.downloading;
    }
    if ((wantsRouting && routing == null) || (wantsPlaces && places == null)) return RegionPhase.downloading;
    return RegionPhase.ready;
  }

  String? get error {
    String? part(RegionPart which, Map<String, dynamic>? p) {
      final e = p?['error'];
      return e is String && e.isNotEmpty ? regionPartWords(which, p?['code'] as String?, e) : null;
    }

    return part(RegionPart.routing, routing) ??
        part(RegionPart.places, places) ??
        [...areas, ...terrain].where((a) => a.error != null).map((a) => a.error).firstOrNull ??
        offroad.map((p) => p.error).whereType<String>().firstOrNull;
  }

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
    for (final list in [areas, terrain]) {
      if (list.isEmpty) continue;
      final total = list.fold(0, (s, a) => s + a.totalTiles);
      final done = list.fold(0, (s, a) => s + a.doneTiles);
      parts.add(total == 0 ? 1 : done / total);
    }
    if (offroad.isNotEmpty) {
      final total = offroad.fold(0, (s, p) => s + p.bytes);
      parts.add(total == 0 ? 1 : offroad.fold(0, (s, p) => s + p.doneBytes) / total);
    }
    if (parts.isEmpty) return 0;
    return (parts.reduce((a, b) => a + b) / parts.length).clamp(0, 1).toDouble();
  }

  /// Each part of the region and where it stands, in one short line: "Map ready · Directions 40% · Off-road waiting". A part is
  /// used the moment its tiles are saved, so a part that is ready works while the others download.
  String get partsLine {
    String pct(num done, num total) => '${total <= 0 ? 0 : (done / total * 100).clamp(0, 99).floor()}%';
    String? core(Map<String, dynamic>? p, bool wanted) {
      if (p == null) return wanted ? 'waiting' : null;
      return switch (p['state']) {
        'ready' => 'ready',
        'failed' => 'stopped',
        'paused' => 'paused',
        _ => pct((p['done_bytes'] as num?) ?? 0, (p['bytes'] as num?) ?? 0),
      };
    }

    String? tiles(List<DownloadedArea> l) {
      if (l.isEmpty) return null;
      if (l.any((a) => a.phase == AreaPhase.failed)) return 'stopped';
      if (l.every((a) => a.phase == AreaPhase.done)) return 'ready';
      return pct(l.fold(0, (s, a) => s + a.doneTiles), l.fold(0, (s, a) => s + a.totalTiles));
    }

    String? offroadState() {
      if (offroad.isEmpty) return null;
      if (offroad.any((p) => p.error != null) || terrain.any((a) => a.phase == AreaPhase.failed)) return 'stopped';
      if (offroad.every((p) => p.done) && terrain.every((a) => a.phase == AreaPhase.done)) return 'ready';
      final done = offroad.fold(0, (s, p) => s + p.doneBytes);
      return done == 0 ? 'waiting' : pct(done, offroad.fold(0, (s, p) => s + p.bytes));
    }

    return [
      if (tiles(areas) case final m?) 'Map $m',
      if (core(routing, wantsRouting) case final d?) 'Directions $d',
      if (core(places, wantsPlaces) case final p?) 'Places $p',
      if (offroadState() case final o?) 'Off-road $o',
    ].join(' · ');
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
    this.offroadCatalogue,
    ZimDownloader? packDownloader,
    this.position,
  }) : _opener = opener ?? openRealRegions,
       _packDownloader = packDownloader ?? ZimDownloader();

  final DataPolicy policy;
  final Future<Directory> Function() supportDir;
  final RegionCatalogue catalogue;
  final MapsState maps;
  final RegionsOpener _opener;
  final String baseUrl;
  final String placesBaseUrl;

  /// The published off-road packs; null: regions have no off-road part.
  final OffroadCatalogue? offroadCatalogue;

  /// The phone's position (null while it is not known): a region downloads from there outwards.
  final ({double lat, double lon})? Function()? position;

  /// Where [r]'s parts download from: the phone, when it is known, else the region's centre.
  ({double lat, double lon})? nearFor(RegionRecord r) {
    final here = position?.call();
    if (here != null) return here;
    final b = r.bounds;
    return b == null ? null : (lat: (b.south + b.north) / 2, lon: (b.west + b.east) / 2);
  }
  final ZimDownloader _packDownloader;

  /// Off-road packs downloading or stopped, by their path under the off-road folder.
  final Map<String, _PackRun> _packRuns = {};

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
      _offroadPath = (await offroadDir()).path;
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
    if (ok) unawaited(_resumePacks());
    if (ok && _waiting.isNotEmpty) {
      final go = List.of(_waiting);
      _waiting.clear();
      for (final w in go) {
        await download(w.$1, routing: w.$2, map: w.$3, places: w.$4, offroad: w.$5);
      }
    }
    notifyListeners();
  }

  /// Regions the person chose to download once on Wi-Fi ("Wait for Wi-Fi"), with the parts picked; they start when the connection
  /// allows it (kept while the app runs).
  final List<(RegionRecord, bool, bool, bool, bool)> _waiting = [];

  /// The ids of the regions waiting for Wi-Fi.
  Set<String> get waitingIds => {for (final w in _waiting) w.$1.id};

  /// Downloads [r] once on Wi-Fi: now if the connection already allows it, else when it does.
  Future<void> downloadOnWifi(RegionRecord r, {required bool routing, required bool map, bool places = false, bool offroad = false}) async {
    if (!await policy.blocksDownload()) return download(r, routing: routing, map: map, places: places, offroad: offroad);
    _waiting
      ..removeWhere((w) => w.$1.id == r.id)
      ..add((r, routing, map, places, offroad));
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
      offroad: k == null ? const [] : [for (final p in k.offroad) _packState(p)],
      terrain: k == null ? const [] : _terrainOf(k),
    );
  }

  List<DownloadedArea> _terrainOf(_Kept k) => [for (final a in maps.engine.areasOf(kOffroadElevationLayer)) if (k.terrain.contains(a.id)) a];

  OffroadPackState _packState(_KeptPack p) {
    final run = _packRuns[p.path];
    final done = run == null && _packOnPhone(p.path);
    return OffroadPackState(
      name: p.name,
      bytes: p.bytes,
      doneBytes: done ? p.bytes : (run?.done ?? 0),
      done: done,
      error: run?.error ?? (run == null && !done ? 'Off-road data stopped downloading. Update the region to carry on.' : null),
    );
  }

  /// The folder the off-road packs are kept in, `<build>/<id>/offroad.sqlite` (the router reads every pack in it).
  Future<Directory> offroadDir() async => Directory('${(await supportDir()).path}/regions/offroad');
  String? _offroadPath;

  /// The off-road packs on the phone and what they must be (the catalogue's size and SHA-256), for Storage's damaged-file check.
  List<FileManifest> get offroadManifests {
    final dir = _offroadPath;
    if (dir == null) return const [];
    final seen = <String>{};
    return [
      for (final k in _kept.values)
        for (final p in k.offroad)
          if (_packRuns[p.path] == null && seen.add(p.path)) FileManifest('$dir/${p.path}', bytes: p.bytes, sha256: p.sha256),
    ];
  }

  /// A region on the phone has [path] among its packs (on the phone, or downloading for it).
  bool _packKept(String path) => _kept.values.any((k) => k.offroad.any((x) => x.path == path));

  /// The off-road packs on the phone or on their way, each with its size and the regions that use it (Storage > Regions lists
  /// them: a pack stays while one of them is on the phone).
  List<({String name, int bytes, bool done, List<String> usedBy})> get offroadPacks {
    final byPath = <String, ({String name, int bytes, bool done, List<String> usedBy})>{};
    for (final k in _kept.values) {
      for (final p in k.offroad) {
        final st = _packState(p);
        final had = byPath[p.path];
        byPath[p.path] = (name: p.name, bytes: st.done ? p.bytes : st.doneBytes, done: st.done, usedBy: [...?had?.usedBy, k.name]);
      }
    }
    return byPath.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  bool _packOnPhone(String path) {
    final dir = _offroadPath;
    return dir != null && File('$dir/$path').existsSync();
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
          (routing, routingProblem) = _partPlan(RegionPart.routing, parts['routing']);
          (places, placesProblem) = _partPlan(RegionPart.places, parts['places']);
        } else {
          // A core without parts plans road routing only.
          routing = PartPlan.fromJson(j);
        }
      } on CacheSearchException catch (e) {
        routingProblem = e.code == 'offline' ? _needsConnection : regionPartWords(RegionPart.routing, e.code, e.message);
        placesProblem = e.code == 'offline' ? _needsConnection : regionPartWords(RegionPart.places, e.code, e.message);
      } catch (_) {
        routingProblem = placesProblem = _needsConnection;
      }
    }
    final (offroad, offroadProblem) = await _offroadPlan(r);
    RegionPlan done({List<MapLayerPlan> map = const [], String? mapProblem}) => RegionPlan(
      routing: routing,
      routingProblem: routingProblem,
      places: places,
      placesProblem: placesProblem,
      map: map,
      mapProblem: mapProblem,
      offroad: offroad,
      offroadProblem: offroadProblem,
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

  /// The off-road part of [r]: the packs that cover it (one pack is downloaded once, whichever region brings it) and the terrain
  /// heights over the region itself, where a pack covers it. Nothing (and no problem) when no pack covers it.
  Future<(OffroadPlan?, String?)> _offroadPlan(RegionRecord r) async {
    final cat = offroadCatalogue;
    final bounds = r.bounds;
    if (cat == null || bounds == null) return (null, null);
    final List<OffroadPack> all;
    try {
      all = await cat.packs();
    } catch (_) {
      return (null, _needsConnection);
    }
    final packs = packsCovering(all, bounds);
    if (packs.isEmpty) return (null, null);
    _offroadPath ??= (await offroadDir()).path;
    if (maps.engine.layer(kOffroadElevationLayer) == null) return (null, 'Off-road needs the Elevation map layer, which is not installed.');
    final out = <OffroadPackPlan>[];
    for (final p in packs) {
      AreaEstimate e;
      try {
        e = await maps.engine.estimate(kOffroadElevationLayer, terrainBox(bounds, p.bounds), zoom: kOffroadElevationZoom);
      } catch (_) {
        e = const AreaEstimate(tiles: 0, bytes: 0, maxZoom: kOffroadElevationZoom, allowed: false, problem: 'Could not work out the size of the terrain heights.');
      }
      out.add(OffroadPackPlan(p, onPhone: _packOnPhone(p.relativePath()) || _packKept(p.relativePath()), elevation: e));
    }
    return (OffroadPlan(out), null);
  }

  /// One part's entry of the core's plan: its cost, or why it cannot be worked out. Nothing when the part is not there.
  static (PartPlan?, String?) _partPlan(RegionPart part, Object? e) {
    if (e is! Map) return (null, null);
    final j = e.cast<String, dynamic>();
    if (j['error'] != null) {
      return (null, j['code'] == 'offline' ? _needsConnection : regionPartWords(part, j['code'] as String?, '${j['error']}'));
    }
    return (PartPlan.fromJson(j), null);
  }

  /// Starts downloading the parts of [r] that were picked. Throws [MobileDataBlocked] before anything starts when the phone is on
  /// mobile data and downloads may not use it, unless [anyway].
  Future<void> download(RegionRecord r, {required bool routing, required bool map, bool places = false, bool offroad = false, bool anyway = false}) async {
    await policy.checkDownload(anyway: anyway);
    places = places && placesAvailable;
    final k = _kept[r.id] ??= _Kept(id: r.id, name: r.name);
    // Every part comes from the phone (or the region's centre) outwards, and each tile is used as soon as it is saved.
    final near = nearFor(r);
    if (routing || places) {
      final core = _core ?? (throw CacheSearchException('unsupported', routingUnavailable ?? 'Road routing downloads are not available.'));
      final geometry = await catalogue.geometry(r);
      await core.call('add', {
        'id': r.id,
        'name': r.name,
        'geometry': geometry,
        // Places first: the core downloads them before road routing, as they are small.
        if (placesAvailable) 'parts': [if (places) 'places', if (routing) 'routing'],
        if (near != null) 'near': [near.lat, near.lon],
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
          final a = await maps.engine.download(def.id, bounds, label: r.name, anyway: anyway, near: near);
          k.areas.add(a.id);
        }
      }
    }
    if (offroad) await _addOffroad(k, r, anyway: anyway);
    if (!k.routing && !k.places && k.areas.isEmpty && k.offroad.isEmpty) _kept.remove(r.id);
    await _save();
    await refresh();
    notifyListeners();
  }

  /// The off-road packs that cover [r], each checked against its published SHA-256 (a pack already on the phone is not downloaded
  /// again), and the terrain heights over the region (z12 elevation over the part of the region the pack covers).
  Future<void> _addOffroad(_Kept k, RegionRecord r, {required bool anyway}) async {
    final (plan, _) = await _offroadPlan(r);
    if (plan == null || !plan.allowed) return;
    for (final pp in plan.packs) {
      final p = pp.pack;
      final path = p.relativePath();
      if (!k.offroad.any((x) => x.path == path)) {
        k.offroad.add(_KeptPack(path: path, name: p.name, url: p.url, bytes: p.bytes, sha256: p.sha256));
      }
      // The terrain heights of the region itself (where the pack covers it), not the whole pack: tiles that two regions share are
      // kept once by the layer engine.
      final box = terrainBox(r.bounds!, p.bounds);
      final label = 'Off-road terrain for ${r.name}';
      final have = [
        for (final a in maps.engine.areasOf(kOffroadElevationLayer))
          if (k.terrain.contains(a.id) && a.phase != AreaPhase.failed) a.id,
      ].firstOrNull;
      final area = have ?? (await maps.engine.download(kOffroadElevationLayer, box, label: label, anyway: anyway, zoom: kOffroadElevationZoom, near: nearFor(r))).id;
      if (!k.terrain.contains(area)) k.terrain.add(area);
      unawaited(_fetchPack(k.offroad.firstWhere((x) => x.path == path)));
    }
  }

  /// Downloads one pack into the off-road folder: under a hidden name, checked against its SHA-256 (a file that does not match is
  /// thrown away), then renamed into place, so the router only ever sees whole packs.
  Future<void> _fetchPack(_KeptPack p) async {
    final dir = (await offroadDir()).path;
    _offroadPath = dir;
    final dest = File('$dir/${p.path}');
    if (_packRuns[p.path]?.running ?? false) return;
    if (await dest.exists()) {
      _packRuns.remove(p.path);
      return;
    }
    final run = _packRuns[p.path] = _PackRun();
    notifyListeners();
    try {
      await dest.parent.create(recursive: true);
      await _packDownloader.download(
        url: Uri.parse(p.url),
        part: File('${dest.parent.path}/.offroad.sqlite.part'),
        expectedSha256: p.sha256,
        cancel: run.cancel,
        onProgress: (done, total) {
          run.done = done;
          final now = DateTime.now();
          if (now.difference(run.told) > const Duration(milliseconds: 500)) {
            run.told = now;
            notifyListeners();
          }
        },
      );
      await File('${dest.parent.path}/.offroad.sqlite.part').rename(dest.path);
      _packRuns.remove(p.path);
    } catch (e) {
      if (run.cancel.isCancelled) {
        _packRuns.remove(p.path);
      } else {
        run
          ..running = false
          ..error = e is DownloadException ? e.message : "Off-road data couldn't be downloaded. Try again later.";
      }
    }
    notifyListeners();
  }

  /// The packs kept regions want that are not on the phone and not downloading: started again (on a connection downloads may use).
  Future<void> _resumePacks() async {
    _offroadPath ??= (await offroadDir()).path;
    for (final k in _kept.values) {
      for (final p in k.offroad) {
        if (!_packOnPhone(p.path) && !(_packRuns[p.path]?.running ?? false)) unawaited(_fetchPack(p));
      }
    }
  }

  /// Removes the region. Tiles another region still needs stay (the core and the layer engine keep shared tiles once).
  Future<void> remove(String id) async {
    final k = _kept.remove(id);
    if ((k?.routing ?? false) || (k?.places ?? false) || _statusOf(id) != null) await _core?.call('remove', {'id': id});
    for (final a in k?.areas ?? const <String>[]) {
      await maps.engine.delete(a);
    }
    // off-road packs and their terrain heights stay while another region uses them
    for (final a in k?.terrain ?? const <String>[]) {
      if (!_kept.values.any((o) => o.terrain.contains(a))) await maps.engine.delete(a);
    }
    for (final p in k?.offroad ?? const <_KeptPack>[]) {
      if (_kept.values.any((o) => o.offroad.any((x) => x.path == p.path))) continue;
      _packRuns.remove(p.path)?.cancel.cancel();
      final dir = (await offroadDir()).path;
      for (final f in [File('$dir/${p.path}'), File('${File('$dir/${p.path}').parent.path}/.offroad.sqlite.part')]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
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
    for (final p in k?.offroad ?? const <_KeptPack>[]) {
      if (_packRuns[p.path]?.running != true) unawaited(_fetchPack(p));
    }
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
  _Kept({required this.id, required this.name, this.routing = false, this.places = false, List<String>? areas, List<_KeptPack>? offroad, List<String>? terrain})
    : areas = areas ?? [],
      offroad = offroad ?? [],
      terrain = terrain ?? [];

  final String id;
  final String name;
  bool routing;
  bool places;
  final List<String> areas;

  /// Its off-road packs and the terrain-height areas they read.
  final List<_KeptPack> offroad;
  final List<String> terrain;

  Map<String, dynamic> toJson() => {
    'name': name,
    'routing': routing,
    'places': places,
    'areas': areas,
    if (offroad.isNotEmpty) 'offroad': [for (final p in offroad) p.toJson()],
    if (terrain.isNotEmpty) 'terrain': terrain,
  };

  factory _Kept.fromJson(String id, Map<String, dynamic> j) => _Kept(
    id: id,
    name: j['name'] as String? ?? '',
    routing: j['routing'] == true,
    places: j['places'] == true,
    areas: [for (final a in (j['areas'] as List? ?? const [])) a as String],
    offroad: [
      for (final p in (j['offroad'] as List? ?? const []))
        if (p is Map) _KeptPack.fromJson(p.cast<String, dynamic>()),
    ],
    terrain: [for (final a in (j['terrain'] as List? ?? const [])) a as String],
  );
}

/// An off-road pack a region downloads: where it goes, where it comes from, and the size and SHA-256 it must have.
class _KeptPack {
  const _KeptPack({required this.path, required this.name, required this.url, required this.bytes, required this.sha256});

  final String path;
  final String name;
  final String url;
  final int bytes;
  final String sha256;

  Map<String, dynamic> toJson() => {'path': path, 'name': name, 'url': url, 'bytes': bytes, 'sha256': sha256};

  factory _KeptPack.fromJson(Map<String, dynamic> j) => _KeptPack(
    path: j['path'] as String? ?? '',
    name: j['name'] as String? ?? '',
    url: j['url'] as String? ?? '',
    bytes: (j['bytes'] as num?)?.toInt() ?? 0,
    sha256: j['sha256'] as String? ?? '',
  );
}

/// One pack download: how far it got, and why it stopped.
class _PackRun {
  final CancelToken cancel = CancelToken();
  bool running = true;
  int done = 0;
  String? error;
  DateTime told = DateTime.fromMillisecondsSinceEpoch(0);
}
