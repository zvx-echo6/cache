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
import 'problem_words.dart';
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

/// What one region holds on this phone: every part ready; downloading (or waiting to start); paused (no connection downloads may
/// use, it goes on by itself); stopped part way with nothing wrong (Cache was closed, or an older build left it), which "Carry on"
/// starts again; or failed, with a reason, which "Try again" starts again.
enum RegionPhase { downloading, ready, paused, stopped, failed }

/// Where one part of a region stands.
enum PartState { ready, downloading, waiting, paused, stopped, failed }

/// The parts of a region, in the order they are shown.
enum RegionPartKind { map, directions, places, offroad }

/// One part of a region on this phone: where it stands, how far it got, what it holds, and, when it failed, why (in plain words).
class RegionPartStatus {
  const RegionPartStatus(this.kind, this.state, {this.fraction, this.bytes = 0, this.totalBytes, this.problem});

  final RegionPartKind kind;
  final PartState state;

  /// 0..1 while it downloads or after it stopped; null when not known.
  final double? fraction;

  /// What it holds on the phone now, and (when known) when it is complete.
  final int bytes;
  final int? totalBytes;
  final String? problem;

  String get name => switch (kind) {
    RegionPartKind.map => 'Map',
    RegionPartKind.directions => 'Directions',
    RegionPartKind.places => 'Places',
    RegionPartKind.offroad => 'Off-road',
  };

  /// "40%", "waiting", "stopped at 40%": the state as a few words after the part's name.
  String get words {
    String pct() => '${((fraction ?? 0) * 100).clamp(0, 99).floor()}%';
    return switch (state) {
      PartState.ready => 'ready',
      PartState.downloading => fraction == null ? 'downloading' : pct(),
      PartState.waiting => 'waiting',
      PartState.paused => 'paused',
      PartState.stopped => (fraction ?? 0) > 0 ? 'stopped at ${pct()}' : 'stopped',
      PartState.failed => "couldn't finish",
    };
  }

  bool get ready => state == PartState.ready;
}

/// The words for a part's state shown on its own (a region's page): "Ready", "40%", "Waiting", "Stopped at 40%: no connection".
String partStateWords(RegionPartStatus p) {
  final w = p.words;
  final first = w[0].toUpperCase() + w.substring(1);
  return p.problem == null || p.state == PartState.ready ? first : '$first: ${_lowerFirst(p.problem!)}';
}

String _lowerFirst(String s) {
  final t = s.endsWith('.') ? s.substring(0, s.length - 1) : s;
  if (t.length > 1 && t[1] == t[1].toUpperCase() && t[1] != t[1].toLowerCase()) return t; // "HTTP", "USB"
  return t.isEmpty ? t : t[0].toLowerCase() + t.substring(1);
}

/// One off-road pack of a region on this phone: on the phone ([done]), downloading, stopped part way ([stopped]: it carries on), or
/// failed with an [error].
class OffroadPackState {
  const OffroadPackState({required this.name, required this.bytes, required this.doneBytes, required this.done, this.error, this.stopped = false});

  final String name;
  final int bytes;
  final int doneBytes;
  final bool done;
  final String? error;
  final bool stopped;
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
    this.kind,
    this.bbox,
  });

  final String id;
  final String name;

  /// [kDrawnRegionKind] for an area drawn on the map, [kAreaRegionKind] for map downloads kept from before regions; null for a
  /// region of the catalogue.
  final String? kind;

  /// [west, south, east, north], when known.
  final List<double>? bbox;

  /// Map downloads from before regions, kept as one area: map only.
  bool get isArea => kind == kAreaRegionKind;

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

  /// Each part this region has, in order (map, directions, places, off-road), with where it stands.
  List<RegionPartStatus> get parts {
    RegionPartStatus? tiles(RegionPartKind kind, List<DownloadedArea> l) {
      if (l.isEmpty) return null;
      final done = l.fold<int>(0, (s, a) => s + a.doneTiles), total = l.fold<int>(0, (s, a) => s + a.totalTiles);
      final f = total == 0 ? null : (done / total).clamp(0.0, 1.0);
      final bytes = l.fold<int>(0, (s, a) => s + a.bytes);
      final failed = l.where((a) => a.phase == AreaPhase.failed && !a.interrupted).firstOrNull;
      if (failed != null) return RegionPartStatus(kind, PartState.failed, fraction: f, bytes: bytes, problem: areaProblemWords(failed.error));
      if (l.any((a) => a.phase == AreaPhase.failed)) return RegionPartStatus(kind, PartState.stopped, fraction: f, bytes: bytes);
      if (l.any((a) => a.phase == AreaPhase.running)) return RegionPartStatus(kind, PartState.downloading, fraction: f, bytes: bytes);
      return RegionPartStatus(kind, PartState.ready, fraction: 1, bytes: bytes);
    }

    RegionPartStatus? core(RegionPartKind kind, RegionPart which, Map<String, dynamic>? p, bool wanted) {
      if (p == null) return wanted ? RegionPartStatus(kind, PartState.waiting, fraction: 0) : null;
      final total = (p['bytes'] as num?)?.toInt() ?? 0, done = (p['done_bytes'] as num?)?.toInt() ?? 0;
      final f = p['state'] == 'ready' ? 1.0 : (total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0));
      final e = p['error'];
      return switch (p['state']) {
        'ready' => RegionPartStatus(kind, PartState.ready, fraction: 1, bytes: total, totalBytes: total),
        'failed' => RegionPartStatus(kind, PartState.failed, fraction: f, bytes: done, totalBytes: total,
            problem: e is String && e.isNotEmpty ? regionPartWords(which, p['code'] as String?, e) : null),
        'paused' => RegionPartStatus(kind, PartState.paused, fraction: f, bytes: done, totalBytes: total),
        _ => RegionPartStatus(kind, PartState.downloading, fraction: f, bytes: done, totalBytes: total),
      };
    }

    RegionPartStatus? off() {
      if (offroad.isEmpty) return null;
      final total = offroad.fold<int>(0, (s, p) => s + p.bytes), done = offroad.fold<int>(0, (s, p) => s + p.doneBytes);
      final f = total == 0 ? null : (done / total).clamp(0.0, 1.0);
      final bytes = done + terrain.fold<int>(0, (s, a) => s + a.bytes);
      final err = offroad.map((p) => p.error).whereType<String>().firstOrNull ??
          terrain.where((a) => a.phase == AreaPhase.failed && !a.interrupted).map((a) => areaProblemWords(a.error)).firstOrNull;
      if (err != null) return RegionPartStatus(RegionPartKind.offroad, PartState.failed, fraction: f, bytes: bytes, totalBytes: total, problem: err);
      if (offroad.any((p) => p.stopped) || terrain.any((a) => a.phase == AreaPhase.failed)) {
        return RegionPartStatus(RegionPartKind.offroad, PartState.stopped, fraction: f, bytes: bytes, totalBytes: total);
      }
      if (offroad.every((p) => p.done) && terrain.every((a) => a.phase == AreaPhase.done)) {
        return RegionPartStatus(RegionPartKind.offroad, PartState.ready, fraction: 1, bytes: bytes, totalBytes: total);
      }
      return RegionPartStatus(RegionPartKind.offroad, done == 0 ? PartState.waiting : PartState.downloading, fraction: f, bytes: bytes, totalBytes: total);
    }

    return [
      ?tiles(RegionPartKind.map, areas),
      ?core(RegionPartKind.directions, RegionPart.routing, routing, wantsRouting),
      ?core(RegionPartKind.places, RegionPart.places, places, wantsPlaces),
      ?off(),
    ];
  }

  RegionPhase get phase {
    final states = {for (final p in parts) p.state};
    if (states.contains(PartState.failed)) return RegionPhase.failed;
    if (states.contains(PartState.stopped)) return RegionPhase.stopped;
    if (states.contains(PartState.paused)) return RegionPhase.paused;
    if (states.contains(PartState.downloading) || states.contains(PartState.waiting)) return RegionPhase.downloading;
    return RegionPhase.ready;
  }

  /// The first reason a part failed, in plain words, or null.
  String? get error => parts.map((p) => p.problem).whereType<String>().firstOrNull;

  /// 0..1: the mean of the parts (road routing and places by bytes, the map by tiles).
  double get fraction {
    final ps = parts;
    if (ps.isEmpty) return 0;
    return (ps.fold<double>(0, (s, p) => s + (p.ready ? 1 : (p.fraction ?? 0))) / ps.length).clamp(0, 1).toDouble();
  }

  /// The parts that are not ready yet and where each stands, in one short line: "Places 40% · Off-road waiting". A part is used the
  /// moment its tiles are saved, so the parts that are ready are not named. Empty when every part is ready.
  String get partsLine => [for (final p in parts) if (!p.ready) '${p.name} ${p.words}'].join(' · ');

  /// What the bar under a region says: "62% of 1.8 GB" style is left to the screen; this is the part being downloaded now, if any.
  RegionPartStatus? get downloadingPart => parts.where((p) => p.state == PartState.downloading).firstOrNull;

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
    unawaited(migrateOldDownloads().catchError((_) {}));
    _net = policy.probe.changes.listen((_) => _applyPolicy().catchError((_) {}));
    // Switching mobile data for downloads on or off applies at once, mid-download too.
    policy.settings.addListener(_onSettings);
    await refresh();
  }

  void _onMaps() {
    if (!_migrated && maps.engine.ready && _started) unawaited(migrateOldDownloads().catchError((_) {}));
    notifyListeners();
  }

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
    if (ok && _carryOnWaiting.isNotEmpty) {
      final go = List.of(_carryOnWaiting);
      _carryOnWaiting.clear();
      for (final id in go) {
        unawaited(carryOn(id).catchError((_) {}));
      }
    }
    if (ok && _waiting.isNotEmpty) {
      final go = List.of(_waiting);
      _waiting.clear();
      for (final w in go) {
        await download(w.$1, routing: w.$2, map: w.$3, places: w.$4, offroad: w.$5);
      }
    }
    notifyListeners();
  }

  /// Regions to carry on once the connection allows it ("Wait for Wi-Fi" in the carry-on pop-up).
  final Set<String> _carryOnWaiting = {};

  /// Carries on with [id] once on Wi-Fi: now if the connection already allows it.
  void carryOnOnWifi(String id) {
    if (_networkOk) {
      unawaited(carryOn(id).catchError((_) {}));
    } else {
      _carryOnWaiting.add(id);
      notifyListeners();
    }
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

  /// The map areas a region holds, each once (an elevation area lists under elevation, hillshade and contour lines: counted three
  /// times, its size was three times too big).
  List<DownloadedArea> _areasOf(_Kept k) => [for (final a in maps.engine.allAreas) if (k.areas.contains(a.id)) a];

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
      kind: k?.kind ?? (id.startsWith('drawn-') ? kDrawnRegionKind : null),
      bbox: k?.bbox,
      routing: _routingOf(r),
      places: _placesOf(r),
      areas: k == null ? const [] : _areasOf(k),
      // A part asked for is waited for until the core lists the region; once it does, a part it does not have was never added
      // (1.0.27 waited for places the core had left out, "Places waiting" for ever).
      wantsRouting: (k?.routing ?? false) && (r == null || _routingOf(r) != null),
      wantsPlaces: (k?.places ?? false) && (r == null || _placesOf(r) != null),
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
      error: run?.error,
      // Not on the phone and not downloading (Cache was closed while it ran): it carries on.
      stopped: run == null && !done,
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
    k.bbox ??= r.bbox;
    if (r.isDrawn || r.kind == kAreaRegionKind) k.kind ??= r.kind;
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
        // One download per layer the tiles are kept in: hillshade and contour lines both read the elevation layer's tiles, and
        // 1.0.27 downloaded them twice (two areas, listed four times).
        final asked = <String>{for (final a in _areasOf(k)) maps.engine.downloadLayerOf(a.layerId)};
        for (final card in mapLayers) {
          final def = maps.downloadDefFor(card, bounds);
          if (!asked.add(maps.engine.downloadLayerOf(def.id))) continue;
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

  /// The region [id] as a record to download or carry on: its own box for an area drawn on the map or kept from before regions, else
  /// the catalogue's record (read from the copy on the phone when there is one), else a record made from the box it was downloaded
  /// for. Null when none of these is known.
  Future<RegionRecord?> recordOf(String id) async {
    final k = _kept[id];
    final box = k?.bbox ?? _boxOfAreas(k);
    if (k != null && (k.kind == kDrawnRegionKind || k.kind == kAreaRegionKind || id.startsWith('drawn-')) && box != null) {
      return RegionRecord(id: id, name: k.name, kind: k.kind ?? kDrawnRegionKind, bbox: box);
    }
    try {
      final r = await catalogue.record(id);
      if (r != null) return r;
    } catch (_) {}
    return box == null ? null : RegionRecord(id: id, name: k?.name ?? id, kind: 'region', bbox: box);
  }

  /// The box around a region's map areas, or null when it has none.
  static List<double>? _boxOfAreasStatic(List<DownloadedArea> areas) {
    if (areas.isEmpty) return null;
    var w = 180.0, s = 90.0, e = -180.0, n = -90.0;
    for (final a in areas) {
      final b = a.bounds;
      if (b.west < w) w = b.west;
      if (b.south < s) s = b.south;
      if (b.east > e) e = b.east;
      if (b.north > n) n = b.north;
    }
    return [w, s, e, n];
  }

  List<double>? _boxOfAreas(_Kept? k) => k == null ? null : _boxOfAreasStatic(_areasOf(k));

  /// Starts again what stopped or failed in region [id], and only that: map areas that stopped part way carry on from the tiles they
  /// have, off-road packs that are not on the phone download again, and directions or places that failed are asked for again (the
  /// core keeps the tiles it has). Nothing that is ready is fetched again (1.0.27's Update fetched the whole map again).
  Future<void> carryOn(String id, {bool anyway = false}) async {
    await policy.checkDownload(anyway: anyway);
    final l = regionOf(id);
    if (l == null) return;
    final k = _kept[id];
    for (final a in [...l.areas, ...l.terrain]) {
      if (a.phase == AreaPhase.failed) await maps.engine.update(a.id, anyway: anyway);
    }
    for (final p in k?.offroad ?? const <_KeptPack>[]) {
      if (!_packOnPhone(p.path) && _packRuns[p.path]?.running != true) unawaited(_fetchPack(p));
    }
    final core = _core;
    final again = [
      if (l.places?['state'] == 'failed' || (k?.places == true && l.places == null && _statusOf(id) == null)) 'places',
      if (_routingOf(_statusOf(id))?['state'] == 'failed' || (k?.routing == true && _statusOf(id) == null)) 'routing',
    ];
    if (core != null && again.isNotEmpty) {
      final rec = await recordOf(id);
      if (rec == null) throw const CacheSearchException('not_found', 'This region could not be read. Connect and try again.');
      final near = nearFor(rec);
      await core.call('add', {
        'id': rec.id,
        'name': rec.name,
        'geometry': await catalogue.geometry(rec),
        if (placesAvailable) 'parts': again,
        if (near != null) 'near': [near.lat, near.lon],
      });
    }
    await _save();
    await refresh();
    notifyListeners();
  }

  /// What a part of [r] weighs from the catalogue's sizes, for the parts this phone would download: road routing, places (only once
  /// they are published), the map layers on the map (each layer the tiles are kept in once), and off-road (the terrain heights over
  /// the region, and each pack that is not on the phone yet: a state's pack is downloaded once and shared).
  RegionCost costOf(RegionRecord r) {
    final sz = r.sizes;
    final bounds = r.bounds;
    final layers = mapLayers;
    int? map;
    if (sz != null && bounds != null && layers.isNotEmpty) {
      // Each layer the tiles are kept in once; a regional cut of a layer (an Idaho extract) has the size of the layer it is cut
      // from when the catalogue names only that one.
      final byKey = <String, int?>{};
      for (final card in layers) {
        final key = maps.engine.downloadLayerOf(maps.downloadDefFor(card, bounds).id);
        byKey.putIfAbsent(key, () => sz.map[key] ?? sz.map[maps.engine.downloadLayerOf(card.id)]);
      }
      final known = [for (final b in byKey.values) ?b];
      map = known.isEmpty ? null : known.fold<int>(0, (a, b) => a + b);
    }
    int? offroad;
    var shared = false;
    if (sz != null && sz.hasOffroad && offroadCatalogue != null) {
      var o = sz.offroadTerrain ?? 0;
      for (final e in sz.offroadPacks.entries) {
        if (_packIdHere(e.key)) {
          shared = true;
        } else {
          o += e.value;
        }
      }
      offroad = o;
    }
    return RegionCost(
      routing: _core == null ? null : sz?.routing,
      places: placesAvailable ? sz?.places : null,
      map: map,
      offroad: offroad,
      offroadShared: shared,
    );
  }

  /// The catalogue's record of [id] when its country's file is read already (no waiting), or null.
  RegionRecord? loadedRecord(String id) {
    for (final s in catalogue.loadedShards) {
      final r = s[id];
      if (r != null) return r;
    }
    return null;
  }

  /// What region [l] holds when complete, from the catalogue's sizes (null when they are not known): the bar's "of 1.8 GB".
  int? totalBytesOf(LocalRegion l) {
    final r = loadedRecord(l.id);
    final sz = r?.sizes;
    if (r == null || sz == null) return null;
    final c = costOf(r);
    int? sum = 0;
    for (final p in l.parts) {
      final b = switch (p.kind) {
        RegionPartKind.map => c.map ?? (p.ready ? p.bytes : null),
        RegionPartKind.directions => sz.routing ?? p.totalBytes,
        RegionPartKind.places => sz.places ?? p.totalBytes,
        RegionPartKind.offroad => (sz.offroadTerrain ?? 0) + sz.offroadPacks.values.fold<int>(0, (a, b) => a + b),
      };
      sum = b == null || sum == null ? null : sum + b;
    }
    return sum;
  }

  /// The regions on the phone whose off-road data [r] would share (the state's pack is downloaded once).
  List<String> offroadSharedWith(RegionRecord r) {
    final ids = r.sizes?.offroadPacks.keys.toSet() ?? const <String>{};
    return [
      for (final k in _kept.values)
        if (k.id != r.id && k.offroad.any((p) => ids.contains(p.path.split('/').elementAtOrNull(1)))) k.name,
    ];
  }

  /// The off-road pack [id] is on the phone, or on its way for another region.
  bool _packIdHere(String id) => _kept.values.any((k) => k.offroad.any((p) => p.path.split('/').elementAtOrNull(1) == id));

  /// What tapping [r] offers: download it (its parts and size from the catalogue: nothing is worked out on the phone), carry on with
  /// what stopped, add the parts it does not have yet (off-road, or places once they are published), or nothing to do.
  RegionOffer offer(RegionRecord r) {
    final cost = costOf(r);
    final here = regionOf(r.id);
    final sized = r.sizes != null;
    final canOffroad = offroadCatalogue != null && (r.sizes?.hasOffroad ?? true) && r.bounds != null;
    final canMap = r.bounds != null && mapLayers.isNotEmpty;
    if (here == null) {
      final routing = _core != null && (!sized || cost.routing != null);
      final places = cost.places != null;
      final parts = [if (canMap) cost.map, if (routing) cost.routing, if (places) cost.places, if (canOffroad) cost.offroad];
      return RegionOffer(
        RegionOfferKind.download,
        routing: routing,
        map: canMap,
        places: places,
        offroad: canOffroad,
        bytes: sized && parts.every((b) => b != null) ? parts.fold<int>(0, (a, b) => a + b!) : null,
        offroadShared: cost.offroadShared,
      );
    }
    final missingOffroad = !here.hasOffroad && !here.isArea && canOffroad;
    final missingPlaces = !here.hasPlaces && !here.isArea && cost.places != null;
    final add = (missingOffroad ? cost.offroad ?? 0 : 0) + (missingPlaces ? cost.places ?? 0 : 0);
    switch (here.phase) {
      case RegionPhase.stopped || RegionPhase.failed:
        // What is left: each part's size in the catalogue (or as the core counts it) for the share of it not on the phone yet.
        int? left = 0;
        for (final p in here.parts.where((p) => !p.ready)) {
          final whole = switch (p.kind) {
            RegionPartKind.map => cost.map,
            RegionPartKind.directions => cost.routing ?? p.totalBytes,
            RegionPartKind.places => cost.places ?? p.totalBytes,
            RegionPartKind.offroad => (r.sizes?.offroadTerrain ?? 0) + (r.sizes?.offroadPacks.values.fold<int>(0, (a, b) => a + b) ?? p.totalBytes ?? 0),
          };
          left = whole == null || left == null ? null : left + (whole * (1 - (p.fraction ?? 0))).round();
        }
        return RegionOffer(
          here.phase == RegionPhase.failed ? RegionOfferKind.tryAgain : RegionOfferKind.carryOn,
          bytes: left,
          already: here.bytes,
          offroad: missingOffroad,
          places: missingPlaces,
          addBytes: add,
          offroadShared: cost.offroadShared,
        );
      case RegionPhase.downloading || RegionPhase.paused:
        return RegionOffer(RegionOfferKind.busy, already: here.bytes);
      case RegionPhase.ready:
        if (missingOffroad || missingPlaces) {
          return RegionOffer(RegionOfferKind.addParts, offroad: missingOffroad, places: missingPlaces, bytes: sized ? add : null, already: here.bytes, offroadShared: cost.offroadShared);
        }
        return RegionOffer(RegionOfferKind.onPhone, already: here.bytes);
    }
  }

  /// Adds the parts [r] is missing ([offroad], [places]) to a region on the phone.
  Future<void> addParts(RegionRecord r, {bool offroad = false, bool places = false, bool anyway = false}) =>
      download(r, routing: false, map: false, places: places, offroad: offroad, anyway: anyway);

  // ---- map downloads from before regions -----------------------------------------------------------------------------------

  bool _migrated = false;
  bool _migrating = false;

  /// Said once after old map downloads were tidied up ("Removed 2 duplicate map downloads..."); the screen that shows it clears it.
  String? tidyNote;

  /// Map downloads made before regions (1.0.0 builds downloaded each layer for an area on its own) and duplicates of the same layer
  /// over the same box. Each old download inside a region on the phone (downloaded or partly downloaded) joins that region; the rest
  /// are grouped by their box, one area each, listed with the regions. Nothing is deleted except an exact duplicate (the same layer,
  /// box and zooms as another download the region keeps), whose tiles stay because the other one covers them. Runs once the map
  /// layers are read, and only once.
  @visibleForTesting
  Future<void> migrateOldDownloads() async {
    if (_migrated || _migrating || !maps.engine.ready) return;
    _migrating = true;
    try {
      final engine = maps.engine;
      final held = <String>{for (final k in _kept.values) ...[...k.areas, ...k.terrain]};
      final loose = [for (final a in engine.allAreas) if (!held.contains(a.id) && a.phase != AreaPhase.running) a];
      // Each region's box: kept with it, else around its map areas, else the catalogue's.
      final boxes = <String, List<double>>{};
      for (final k in _kept.values) {
        var b = k.bbox ?? _boxOfAreas(k);
        if (b == null && k.kind == null) {
          try {
            b = (await catalogue.record(k.id))?.bbox;
          } catch (_) {}
        }
        if (b != null) {
          k.bbox ??= b;
          boxes[k.id] = b;
        }
      }
      bool inside(GeoBounds a, List<double> b) =>
          a.west >= b[0] - 0.01 && a.south >= b[1] - 0.01 && a.east <= b[2] + 0.01 && a.north <= b[3] + 0.01;
      double size(List<double> b) => (b[2] - b[0]) * (b[3] - b[1]);
      var moved = 0;
      for (final a in loose) {
        final into = [for (final e in boxes.entries) if (inside(a.bounds, e.value)) e]..sort((x, y) => size(x.value).compareTo(size(y.value)));
        if (into.isNotEmpty) {
          _kept[into.first.key]!.areas.add(a.id);
          moved++;
          continue;
        }
        final b = a.bounds;
        String r(double v) => v.toStringAsFixed(3);
        final id = 'area-${_safeId('${r(b.west)}_${r(b.south)}_${r(b.east)}_${r(b.north)}')}';
        final k = _kept[id] ??= _Kept(id: id, name: a.label, kind: kAreaRegionKind, bbox: [b.west, b.south, b.east, b.north]);
        k.areas.add(a.id);
        moved++;
      }
      // Exact duplicates: the same layer's tiles, box and zooms. The one kept is the finished one (else the one furthest along).
      var removed = 0;
      for (final k in _kept.values) {
        final groups = <String, List<DownloadedArea>>{};
        for (final a in _areasOf(k)) {
          final b = a.bounds;
          final key = '${engine.downloadLayerOf(a.layerId)}|${b.west.toStringAsFixed(4)}|${b.south.toStringAsFixed(4)}|'
              '${b.east.toStringAsFixed(4)}|${b.north.toStringAsFixed(4)}|${a.minZoom}|${a.maxZoom}';
          (groups[key] ??= []).add(a);
        }
        for (final g in groups.values.where((g) => g.length > 1)) {
          if (g.any((a) => a.phase == AreaPhase.running)) continue;
          g.sort((x, y) {
            final done = (y.phase == AreaPhase.done ? 1 : 0) - (x.phase == AreaPhase.done ? 1 : 0);
            return done != 0 ? done : y.doneTiles.compareTo(x.doneTiles);
          });
          for (final extra in g.skip(1)) {
            try {
              await engine.delete(extra.id);
              k.areas.remove(extra.id);
              removed++;
            } catch (_) {}
          }
        }
      }
      if (moved > 0 || removed > 0) await _save();
      if (removed > 0) {
        tidyNote = removed == 1
            ? 'Removed 1 duplicate map download. Its tiles are kept by the other one.'
            : 'Removed $removed duplicate map downloads. Their tiles are kept by the others.';
      }
      _migrated = true;
      notifyListeners();
    } finally {
      _migrating = false;
    }
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
  bool missesPlaces(LocalRegion l) => placesPublished && !l.isArea && !l.hasPlaces && (l.hasRouting || l.hasMap);

  /// The places server has a build (the core read its current.json). Until places are published, no region is offered them: a
  /// part asked for then could only fail.
  bool get placesPublished => placesAvailable && (status['places'] as Map?)?['build'] != null;

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
  _Kept({required this.id, required this.name, this.routing = false, this.places = false, List<String>? areas, List<_KeptPack>? offroad, List<String>? terrain, this.kind, this.bbox})
    : areas = areas ?? [],
      offroad = offroad ?? [],
      terrain = terrain ?? [];

  final String id;
  final String name;

  /// [kDrawnRegionKind] or [kAreaRegionKind]; null for a catalogue region.
  String? kind;

  /// [west, south, east, north]: kept so a region can be carried on, and old map downloads matched to it, without the catalogue.
  List<double>? bbox;
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
    'kind': ?kind,
    'bbox': ?bbox,
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
    kind: j['kind'] as String?,
    bbox: j['bbox'] is List && (j['bbox'] as List).length == 4 ? [for (final v in j['bbox'] as List) (v as num).toDouble()] : null,
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

/// What each part of a region would download, from the catalogue's sizes (null: not known, or not downloaded here).
class RegionCost {
  const RegionCost({this.routing, this.places, this.map, this.offroad, this.offroadShared = false});

  final int? routing;
  final int? places;
  final int? map;

  /// The terrain heights and the packs not on the phone yet.
  final int? offroad;

  /// A pack the region needs is on the phone already (another region brought it).
  final bool offroadShared;
}

/// What tapping a region offers.
enum RegionOfferKind {
  /// Not on the phone: download it.
  download,

  /// Stopped part way: carry on.
  carryOn,

  /// A part failed: try again.
  tryAgain,

  /// On the phone without off-road (or places): add them.
  addParts,

  /// Downloading or paused: nothing to start.
  busy,

  /// All of it is on the phone.
  onPhone,
}

/// What tapping a region offers, with its parts and sizes.
class RegionOffer {
  const RegionOffer(this.kind, {this.routing = false, this.map = false, this.places = false, this.offroad = false, this.bytes, this.already = 0, this.addBytes = 0, this.offroadShared = false});

  final RegionOfferKind kind;

  /// The parts it downloads (for [RegionOfferKind.download]), or adds (off-road and places, for [RegionOfferKind.addParts] and as
  /// an extra with carry on).
  final bool routing, map, places, offroad;

  /// What it downloads (for carry on, what is left); null when the catalogue has no size for it.
  final int? bytes;

  /// What of the region is on the phone already.
  final int already;

  /// What adding the missing parts downloads, with carry on.
  final int addBytes;
  final bool offroadShared;
}

/// [s] as safe characters for an id (letters, digits, `-`, `_`, `.`).
String _safeId(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
