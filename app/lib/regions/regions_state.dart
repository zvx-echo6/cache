import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';

import '../platform/app_log.dart';
import '../app_fs.dart';
import '../browse/zim_download.dart';
import '../chat/ask_focus.dart';
import '../files.dart';
import '../maps/geo.dart';
import '../maps/layers/layer_def.dart';
import '../maps/maps_state.dart';
import '../platform.dart' as plat;
import '../screens/download_confirm.dart' show downloadSpace;
import '../search/core_config.dart';
import '../settings/damaged_files.dart';
import '../settings/data_policy.dart';
import '../settings/space.dart';
import 'offroad_catalogue.dart';
import 'problem_words.dart';
import 'region_catalogue.dart';
import 'regions_core.dart';
import 'regions_share.dart';

export '../sharing/share_rules.dart' show kRegionsNotShared, kMapLayersNotShared;

/// The file next to the core's region folder where the app keeps what each region holds (its parts and the map areas it
/// downloaded).
const String kRegionsAppFile = 'regions-app.json';

/// How often a tab renews Ask's hold on the downloads while Ask answers (the server lets it go after about a minute without).
const Duration kAskLeaseRenew = Duration(seconds: 20);

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
    this.sharing = const [],
  });

  /// Layers whose tiles are counted with another layer's (contour lines with hillshade: both read the elevation store), with the
  /// layer that carries the estimate.
  final List<({LayerDef def, String ownerId})> sharing;

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

/// The words an off-road add gives when the person's Pause is on.
const String _heldOffroad = 'downloads are paused. Tap Resume, then add the off-road data.';

/// Which part of a region a problem is about, for [regionPartWords].
enum RegionPart { routing, places }

/// Plain words for a problem the core reports with a region part. The core's message is for the log: it holds addresses
/// like "HTTP 404 from https://…". A file the server does not have (404 or 410) is a part not published for the area yet.
String regionPartWords(RegionPart part, String? code, String message) {
  if (code == 'offline') return 'Needs a connection.';
  if (code == 'no_space') return 'There is not enough free space on this device.';
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

/// Where one part of a region stands. [notAvailable]: nothing is published for the area yet (places: the region catalogue or the
/// places server's current.json has none for it; directions: the published road routing has no tile over it). It is not a
/// failure: the region counts as complete and no retry is offered; a later Update adds the part once it is published.
enum PartState { ready, downloading, waiting, paused, stopped, failed, notAvailable }

/// True when the core's places error says nothing is published (the places server has no current.json: HTTP 404 or 410 for it).
/// A tile the index lists that cannot be fetched is a real failure, never this.
bool placesNotPublished(String? message) {
  if (message == null) return false;
  final m = RegExp(r'^HTTP (404|410) from (\S+)').firstMatch(message.trim());
  return m != null && m.group(2)!.endsWith('current.json');
}

/// The parts of a region, in the order they are shown.
enum RegionPartKind { map, directions, places, offroad }

/// One part of a region on this phone: where it stands, how far it got, what it holds, and, when it failed, why (in plain words).
/// How fast a part is downloading and how long it has left, from what it held over the last half minute.
class TransferRate {
  const TransferRate({this.bytesPerSecond, this.secondsLeft});

  final double? bytesPerSecond;
  final double? secondsLeft;

  /// "2.1 MB/s", "350 KB/s".
  String? get speedWords {
    final b = bytesPerSecond;
    if (b == null || b <= 0) return null;
    if (b >= 1e6) return '${(b / 1e6).toStringAsFixed(1)} MB/s';
    return '${(b / 1e3).round()} KB/s';
  }

  /// "40 s left", "6 min left", "1 h 20 min left".
  String? get leftWords {
    final s = secondsLeft;
    if (s == null || !s.isFinite || s < 0) return null;
    if (s < 60) return '${s.ceil()} s left';
    final m = (s / 60).ceil();
    if (m < 60) return '$m min left';
    return m % 60 == 0 ? '${m ~/ 60} h left' : '${m ~/ 60} h ${m % 60} min left';
  }
}

/// Measures each downloading part's speed and time left from samples of what it holds (bytes, and the share done), taken as
/// the screens read the regions: the speed over the last 30 seconds, the time left from how fast the share done grows (or the
/// bytes left, when the part's size is known). A part that is slow shows its speed instead of looking stuck.
class TransferMeter {
  TransferMeter({DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final DateTime Function() _now;
  final Map<String, List<(DateTime, int, double?)>> _samples = {};
  static const Duration window = Duration(seconds: 30);
  static const Duration least = Duration(seconds: 3);

  TransferRate sample(String key, int bytes, double? fraction, {int? totalBytes}) {
    final now = _now();
    final l = _samples.putIfAbsent(key, () => []);
    if (l.isNotEmpty && bytes < l.last.$2) l.clear(); // started again
    if (l.isEmpty || now.difference(l.last.$1) >= const Duration(milliseconds: 900)) l.add((now, bytes, fraction));
    while (l.length > 2 && now.difference(l[1].$1) >= window) {
      l.removeAt(0);
    }
    final first = l.first;
    final dt = now.difference(first.$1).inMilliseconds / 1000;
    if (dt < least.inSeconds) return const TransferRate();
    final bps = (bytes - first.$2) / dt;
    double? left;
    if (totalBytes != null && totalBytes > bytes && bps > 0) {
      left = (totalBytes - bytes) / bps;
    } else if (fraction != null && first.$3 != null && fraction > first.$3!) {
      left = (1 - fraction) / ((fraction - first.$3!) / dt);
    }
    return TransferRate(bytesPerSecond: bps > 0 ? bps : null, secondsLeft: left);
  }

  void forget(String key) => _samples.remove(key);
}

class RegionPartStatus {
  const RegionPartStatus(this.kind, this.state, {this.fraction, this.bytes = 0, this.totalBytes, this.problem, this.rate, this.noSpace = false});

  /// It failed because the phone is full: its fix is Free space, not Try again.
  final bool noSpace;

  /// Speed and time left while it downloads (null when not measured yet).
  final TransferRate? rate;

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
      PartState.downloading => [
        fraction == null ? 'downloading' : pct(),
        ?rate?.speedWords,
        ?rate?.leftWords,
      ].join(' · '),
      PartState.waiting => 'waiting',
      PartState.paused => 'paused',
      PartState.stopped => (fraction ?? 0) > 0 ? 'stopped at ${pct()}' : 'stopped',
      PartState.failed => "couldn't finish",
      PartState.notAvailable => 'not available yet',
    };
  }

  bool get ready => state == PartState.ready;

  /// Nothing more will come for this part now: ready, or not published for the area yet. The region counts it as done.
  bool get complete => state == PartState.ready || state == PartState.notAvailable;
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
    this.asked = true,
    this.meter,
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

  /// The core was asked for this region's road routing or places in this run of the app and has not listed it yet. A part the
  /// core does not list and was not asked for now is not queued behind anything (1.0.28 showed it "waiting" for ever, with no
  /// way to restart it): it is stopped, and Carry on asks again.
  final bool asked;

  /// Measures the speed and time left of the parts that are downloading (null: not shown).
  final TransferMeter? meter;

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
      // A layer the person paused stopped on purpose: it is not a failure (its row offers Resume).
      final failed = l.where((a) => a.phase == AreaPhase.failed && !a.interrupted && !a.paused).firstOrNull;
      if (failed != null) return RegionPartStatus(kind, PartState.failed, fraction: f, bytes: bytes, problem: areaProblemWords(failed.error));
      if (l.any((a) => a.phase == AreaPhase.failed)) return RegionPartStatus(kind, PartState.stopped, fraction: f, bytes: bytes);
      if (l.any((a) => a.phase == AreaPhase.running)) return RegionPartStatus(kind, PartState.downloading, fraction: f, bytes: bytes);
      return RegionPartStatus(kind, PartState.ready, fraction: 1, bytes: bytes);
    }

    RegionPartStatus? core(RegionPartKind kind, RegionPart which, Map<String, dynamic>? p, bool wanted) {
      if (p == null) return wanted ? RegionPartStatus(kind, asked ? PartState.waiting : PartState.stopped, fraction: 0) : null;
      final total = (p['bytes'] as num?)?.toInt() ?? 0, done = (p['done_bytes'] as num?)?.toInt() ?? 0;
      final f = p['state'] == 'ready' ? 1.0 : (total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0));
      final e = p['error'];
      // Nothing is published for the area: the published index has no tile over it (the core then reads "ready" with nothing to
      // fetch, for road routing as for places: an area outside the published roads read "Ready" with no road data), or, for
      // places, the server has no current.json.
      final noTiles = p['state'] == 'ready' && (p['tiles'] as num?)?.toInt() == 0;
      if (noTiles || (which == RegionPart.places && p['state'] == 'failed' && placesNotPublished(e is String ? e : null))) {
        return RegionPartStatus(kind, PartState.notAvailable);
      }
      return switch (p['state']) {
        'ready' => RegionPartStatus(kind, PartState.ready, fraction: 1, bytes: total, totalBytes: total),
        'failed' => RegionPartStatus(kind, PartState.failed, fraction: f, bytes: done, totalBytes: total,
            problem: e is String && e.isNotEmpty ? regionPartWords(which, p['code'] as String?, e) : null, noSpace: p['code'] == 'no_space'),
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

    RegionPartStatus? rated(RegionPartStatus? p) {
      final m = meter;
      if (p == null || m == null) return p;
      final key = '$id/${p.kind.name}';
      if (p.state != PartState.downloading) {
        m.forget(key);
        return p;
      }
      final r = m.sample(key, p.bytes, p.fraction, totalBytes: p.totalBytes);
      return RegionPartStatus(p.kind, p.state, fraction: p.fraction, bytes: p.bytes, totalBytes: p.totalBytes, problem: p.problem, rate: r, noSpace: p.noSpace);
    }

    return [
      ?rated(tiles(RegionPartKind.map, areas)),
      ?rated(core(RegionPartKind.directions, RegionPart.routing, routing, wantsRouting)),
      ?rated(core(RegionPartKind.places, RegionPart.places, places, wantsPlaces)),
      ?rated(off()),
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
    return (ps.fold<double>(0, (s, p) => s + (p.complete ? 1 : (p.fraction ?? 0))) / ps.length).clamp(0, 1).toDouble();
  }

  /// The places part is not published for this region's area yet (see [PartState.notAvailable]).
  bool get placesNotAvailable => parts.any((p) => p.kind == RegionPartKind.places && p.state == PartState.notAvailable);

  /// The parts not published for this region's area yet, each as its row says it: "Places not available yet", and the same for
  /// directions when the published roads do not reach the area. Empty when every part it has is published.
  List<String> get notAvailableNotes => [for (final p in parts) if (p.state == PartState.notAvailable) '${p.name} ${p.words}'];

  /// The parts that are not ready yet and where each stands, in one short line: "Places 40% · Off-road waiting", or "Places not
  /// available yet". A part is used the moment its tiles are saved, so the parts that are ready are not named. Empty when every
  /// part is ready.
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
    this.focus,
    this.spaceOf,
    this.syncedWithOtherDevice,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _opener = opener ?? openRealRegions,
       _packDownloader = packDownloader ?? ZimDownloader();

  final DataPolicy policy;
  final DateTime Function() _clock;

  /// Whether a region deleted here is deleted on other devices too: the Maps share is on and at least one device is linked. It
  /// decides whether the delete asks with the line "Deleting this will delete this from all synced devices." (null: not synced).
  final bool Function()? syncedWithOtherDevice;

  /// While Ask answers, the core starts no new region tile (set_policy hold); the tile in flight finishes and the downloads go on
  /// when the answer is done. Not the person's pause ([held]): that one stays as it is. Null: not observed.
  final AskFocus? focus;
  final Future<Directory> Function() supportDir;
  final RegionCatalogue catalogue;
  final MapsState maps;
  final RegionsOpener _opener;
  final String baseUrl;
  final String placesBaseUrl;

  /// The published off-road packs; null: regions have no off-road part.
  final OffroadCatalogue? offroadCatalogue;

  /// The storage a region is checked against before any of its parts starts ([download]); null: the one the download pop-up
  /// reads, so the two agree.
  final Space Function(String dir)? spaceOf;

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

  /// The connection probe has answered and the engine has its network rule (the first [_applyPolicy] after launch is done). Until
  /// then a download the engine reports as paused for the network is only "Paused": the engine's default (no network) is not the
  /// phone's connection, and "Stopped: no connection" would be a guess.
  bool _connectionKnown = false;
  bool get connectionKnown => _connectionKnown;

  @visibleForTesting
  set connectionKnown(bool v) {
    _connectionKnown = v;
    notifyListeners();
  }
  ConnectionKind _kind = ConnectionKind.wifi;
  final Map<String, _Kept> _kept = {};
  String? _routingKey;

  /// This device's share of its regions with linked devices (regions_share.dart), once the region engine has opened and named it.
  RegionsShare? _share;

  /// The regions linked devices share and nobody has deleted since (a delete shared by any device, this one's too, ends one added before it).
  List<PeerRegion> _peers = const [];
  bool _applying = false;

  /// Each downloading part's speed and time left.
  final TransferMeter _meter = TransferMeter();

  /// Regions the core was asked to add in this run that it has not listed yet (their parts are waiting, not stopped).
  final Set<String> _asked = {};

  /// Every core `add` goes through here, so the parts it asks for wait for the core instead of reading as stopped.
  Future<Map<String, dynamic>> _coreAdd(RegionsCoreLike core, Map<String, dynamic> args) async {
    final id = '${args['id']}';
    _asked.add(id);
    try {
      return await core.call('add', args);
    } catch (_) {
      _asked.remove(id);
      rethrow;
    }
  }

  bool get routingAvailable => _core != null;

  Future<File> _appFile() async => File('${(await supportDir()).path}/$kRegionsAppFile');

  /// In a browser the app's folders are on Cache Server, reached through the folder seam (the same file there).
  late final AppFs _webFs = createAppFs();

  /// The text of regions-app.json; null when it is not there.
  Future<String?> _readAppFile() async {
    if (plat.isWeb) return _webFs.readString(AppRoot.support, kRegionsAppFile);
    final f = await _appFile();
    return await f.exists() ? f.readAsString() : null;
  }

  /// Reads what the regions hold and starts the core's region engine.
  Future<void> init() async {
    if (_started) return;
    _started = true;
    maps.addListener(_onMaps);
    try {
      final text = await _readAppFile();
      if (text != null) {
        final j = (jsonDecode(text) as Map).cast<String, dynamic>();
        for (final e in ((j['regions'] as Map?) ?? const {}).entries) {
          _kept[e.key as String] = _Kept.fromJson(e.key as String, (e.value as Map).cast<String, dynamic>());
        }
        final r = j['routing'];
        if (r is Map) _routingKey = r['key'] as String?;
        held = j['held'] == true;
      }
    } catch (_) {}
    try {
      if (!plat.isWeb) _offroadPath = (await offroadDir()).path;
    } catch (_) {}
    try {
      // A browser's engine is the server's, which opens it on its own folders: the config is not used there.
      _core = await _opener(plat.isWeb ? const {} : regionsConfig(await supportDir(), routingBaseUrl: baseUrl, placesBaseUrl: placesBaseUrl));
    } catch (e) {
      routingUnavailable = e is CacheSearchException ? e.message : 'Road routing downloads are not available: $e';
      notifyListeners();
      return;
    }
    if (!plat.isWeb) _share = RegionsShare(Directory('${(await supportDir()).path}/regions'));
    await _applyPolicy();
    unawaited(migrateOldDownloads().catchError((_) {}));
    _net = policy.probe.changes.listen((_) => _applyPolicy().catchError((_) {}));
    // Switching mobile data for downloads on or off applies at once, mid-download too.
    policy.settings.addListener(_onSettings);
    focus?.addListener(_onAskFocus);
    await refresh();
    unawaited(recheckPublished().catchError((_) {}));
    unawaited(backfillOutlines().catchError((_) {}));
  }

  void _onMaps() {
    if (!_migrated && maps.engine.ready && _started) unawaited(migrateOldDownloads().catchError((_) {}));
    notifyListeners();
  }

  bool? _lastMobile;

  bool? _lastFocused;

  /// Ask starts or stops answering: the core is told to hold the next tile, or to go on.
  void _onAskFocus() {
    final on = focus?.focused ?? false;
    if (_lastFocused == on) return;
    _lastFocused = on;
    _askRenew?.cancel();
    _askRenew = null;
    if (on) {
      // Ask's hold is a lease on the server, renewed while Ask answers: a closed or dead tab cannot leave the downloads held.
      _askRenew = Timer.periodic(kAskLeaseRenew, (_) => _core?.call('set_policy', {'ask': true}).catchError((_) => <String, dynamic>{}));
    } else {
      unawaited(_core?.call('set_policy', {'ask': false}).catchError((_) => <String, dynamic>{}));
    }
    _applyPolicy().catchError((_) {});
  }

  Timer? _askRenew;

  /// Ask is answering and has the downloads held (this tab's Ask, or one on another tab: the server says so).
  bool get askHolds => (focus?.focused ?? false) || status['ask_hold'] == true;

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
    // The person's Pause and Ask's lease go apart (the server joins them); `ask` is only sent while Ask answers here, so another
    // tab's lease is not ended by this one.
    await _core?.call('set_policy', {'network': ok, 'hold': held, if (focus?.focused ?? false) 'ask': true});
    if (!_connectionKnown) {
      _connectionKnown = true;
      notifyListeners();
    }
    if (ok && !held) unawaited(_resumePacks());
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
        // Its space was checked when the person chose it (the pop-up), and there is nowhere to say a refusal now: it starts as it
        // always has, with each part's own check.
        await _download(w.$1, routing: w.$2, map: w.$3, places: w.$4, offroad: w.$5, anyway: false, checkSpace: false);
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
    _asked.removeWhere((id) => _statusOf(id) != null);
    await _syncShare();
    if (plat.isWeb) await _syncServerPacks(c);
    _schedulePoll();
    await _routingCheck();
    _placesCheck();
    notifyListeners();
  }

  /// At start, each region's parts are checked against what is published now: a region whose places were not published when it
  /// was downloaded gets them as soon as they are (they were asked for then). Nothing is downloaded that was not asked for, and
  /// the mobile data rule applies as to any download.
  Future<void> recheckPublished() async {
    // A region without places (downloaded before they were published for its area): ask the server whether they are now.
    if (!placesPublished && local.any((l) => !l.isArea && (!l.hasPlaces || l.placesNotAvailable))) {
      try {
        await checkUpdates();
      } catch (_) {}
    }
    if (!placesPublished) return;
    for (final l in local) {
      if (l.isArea || !l.placesNotAvailable) continue;
      try {
        await policy.checkDownload();
        await _addPlaces(l);
      } catch (_) {
        // Not now (no connection, mobile data, the catalogue not reachable): Update adds them later.
      }
    }
    await refresh();
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
        placesUpdate?['downloading'] == true ||
        (plat.isWeb && _packRuns.values.any((r) => r.running));
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

  /// The downloads wait for Wi-Fi: the phone is on mobile data and downloads may not use it.
  bool get waitingForWifi => _core != null && !_networkOk && _kind == ConnectionKind.mobile;

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
  List<DownloadedArea> _areasOf(_Kept k) => _areasOfIds(k.areas);

  List<DownloadedArea> _areasOfIds(Iterable<String> ids) {
    final want = ids.toSet();
    return [for (final a in maps.engine.allAreas) if (want.contains(a.id)) a];
  }

  /// The ids of the regions this device holds itself (the app's list, and the core's).
  Set<String> get _ownIds => {..._kept.keys, for (final r in _routingRegions) r['id'] as String};

  /// What a linked device shares of region [id], when nobody has deleted it since (the first device's).
  PeerRegion? _peerFor(String id) => _peers.where((p) => p.id == id).firstOrNull;

  /// Every region on this phone, largest first: its own, then the ones only a linked device shares.
  List<LocalRegion> get local {
    final ids = <String>{..._ownIds, for (final p in _peers) p.id};
    final out = [for (final id in ids) regionOf(id)!];
    out.sort((a, b) => b.bytes.compareTo(a.bytes));
    return out;
  }

  /// The region [id] as it is on this phone (or, for one only a linked device shares, as that device holds it), or null when nothing
  /// of it is here.
  LocalRegion? regionOf(String id) {
    final k = _kept[id];
    final r = _statusOf(id);
    final peer = _peerFor(id);
    if (k == null && r == null && peer == null) return null;
    final packs = <String, _KeptPack>{
      for (final p in peer?.offroad ?? const <Map<String, dynamic>>[]) (p['path'] as String? ?? ''): _KeptPack.fromJson(p),
      for (final p in k?.offroad ?? const <_KeptPack>[]) p.path: p,
    };
    return LocalRegion(
      id: id,
      name: k?.name ?? r?['name'] as String? ?? peer?.name ?? id,
      kind: k?.kind ?? peer?.kind ?? (id.startsWith('drawn-') ? kDrawnRegionKind : null),
      bbox: k?.bbox ?? peer?.bbox,
      routing: _routingOf(r) ?? (k?.routing == true ? null : peer?.routingPart),
      places: _placesOf(r) ?? (k?.places == true ? null : peer?.placesPart),
      areas: _areasOfIds([...?k?.areas, ...?peer?.areas]),
      // A part asked for is waited for until the core lists the region; once it does, a part it does not have was never added
      // (1.0.27 waited for places the core had left out, "Places waiting" for ever).
      wantsRouting: (k?.routing ?? false) && (r == null || _routingOf(r) != null),
      wantsPlaces: (k?.places ?? false) && (r == null || _placesOf(r) != null),
      asked: _asked.contains(id),
      meter: _meter,
      offroad: [for (final p in packs.values) _packState(p)],
      terrain: [for (final a in maps.engine.areasOf(kOffroadElevationLayer)) if ({...?k?.terrain, ...?peer?.terrain}.contains(a.id)) a],
    );
  }

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

  /// The off-road packs on the phone or on their way, each with its size and the regions that use it, by name ([usedBy]) and by id
  /// ([usedByIds], in the same order) (Storage > Regions lists them: a pack stays while one of them is on the phone).
  List<({String name, int bytes, bool done, List<String> usedBy, List<String> usedByIds})> get offroadPacks {
    final byPath = <String, ({String name, int bytes, bool done, List<String> usedBy, List<String> usedByIds})>{};
    for (final k in _kept.values) {
      for (final p in k.offroad) {
        final st = _packState(p);
        final had = byPath[p.path];
        byPath[p.path] = (name: p.name, bytes: st.done ? p.bytes : st.doneBytes, done: st.done, usedBy: [...?had?.usedBy, k.name], usedByIds: [...?had?.usedByIds, k.id]);
      }
    }
    return byPath.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  /// The packs the server says it has (a browser asks it: the files are not here).
  final Set<String> _webOnDisk = {};

  bool _packOnPhone(String path) {
    if (plat.isWeb) return _webOnDisk.contains(path);
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
    final sharing = <({LayerDef def, String ownerId})>[];
    RegionPlan done({List<MapLayerPlan> map = const [], String? mapProblem}) => RegionPlan(
      sharing: sharing,
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
    // The size is of what the download fetches: the outline's tiles, not the whole box.
    final outline = await _mapOutline(r);
    // One estimate per store the tiles are kept in: hillshade and contour lines both read the elevation layer's tiles, so with both on
    // their tiles are counted once (as the download fetches them once, and costOf counts them).
    final stores = <String, String>{};
    for (final card in layers) {
      final def = maps.downloadDefFor(card, bounds);
      final store = maps.engine.downloadLayerOf(def.id);
      final owner = stores[store];
      if (owner != null) {
        sharing.add((def: def, ownerId: owner));
        logInfo('Region plan ${r.id}: layer ${def.id} shares the tiles of $store, counted once');
        continue;
      }
      stores[store] = def.id;
      try {
        final e = await maps.engine.estimate(def.id, bounds, outline: outline);
        map.add(MapLayerPlan(def, e));
        logInfo('Region plan ${r.id}: layer ${def.id} (tiles kept in $store): ${e.allowed ? 'allowed' : 'left out'}, max zoom ${e.maxZoom} of ${def.maxZoom}, '
            '${e.tiles} tiles, ${e.bytes} B${e.tilesAlready > 0 ? ', ${e.bytesAlready} B already here' : ''}');
      } catch (_) {
        mapProblem = 'Could not work out the size of the map.';
        logInfo('Region plan ${r.id}: layer ${def.id} (tiles kept in $store): its size could not be worked out');
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
    final packs = packsCovering(all, bounds, states: await statesOf(r));
    if (packs.isEmpty) return (null, null);
    if (!plat.isWeb) _offroadPath ??= (await offroadDir()).path;
    if (maps.engine.layer(kOffroadElevationLayer) == null) return (null, 'Off-road needs the Elevation map layer, which is not installed.');
    final out = <OffroadPackPlan>[];
    for (final p in packs) {
      AreaEstimate e;
      try {
        e = await maps.engine.estimate(kOffroadElevationLayer, terrainBox(bounds, p.bounds), zoom: kOffroadElevationZoom);
      } catch (err) {
        logError('Off-road terrain size for ${r.id}', error: err);
        e = const AreaEstimate(tiles: 0, bytes: 0, maxZoom: kOffroadElevationZoom, allowed: false, problem: 'Could not work out the size of the terrain heights.');
      }
      out.add(OffroadPackPlan(p, onPhone: _packOnPhone(p.relativePath()) || _packKept(p.relativePath()), elevation: e));
    }
    return (OffroadPlan(out), null);
  }

  final Map<String, bool> _offroadCover = {};
  final Set<String> _offroadCoverAsked = {};

  /// Whether the loaded off-road catalogue has a pack over region [id] (the check the plan makes): null until it has been read,
  /// which this starts (listeners hear when it is known). The region page greys Add off-road where it is false.
  bool? offroadCovered(String id) {
    final known = _offroadCover[id];
    if (known != null) return known;
    if (_offroadCoverAsked.add(id)) unawaited(_readOffroadCover(id));
    return null;
  }

  /// [offroadCovered], waiting for the answer when it is not known yet (null: it cannot be read now).
  Future<bool?> offroadCoveredNow(String id) async {
    if (!_offroadCover.containsKey(id)) {
      _offroadCoverAsked.add(id);
      await _readOffroadCover(id);
    }
    return _offroadCover[id];
  }

  /// A region on the phone whose only missing part is off-road, with no pack over it: its Add off-road is greyed everywhere (the
  /// region page, the Regions sheet, the menu, the Downloads tab's rows) and opens nothing.
  bool offroadMissingNoPack(String id) {
    final l = regionOf(id);
    if (l == null || l.hasOffroad || l.isArea || offroadCatalogue == null || placesNowAvailable(l)) return false;
    return offroadCovered(id) == false;
  }

  Future<void> _readOffroadCover(String id) async {
    try {
      final rec = await recordOf(id);
      final cat = offroadCatalogue;
      final bounds = rec?.bounds;
      if (rec == null || cat == null || bounds == null) {
        _offroadCoverAsked.remove(id);
        return;
      }
      final all = await cat.packs();
      _offroadCover[id] = packsCovering(all, bounds, states: await statesOf(rec)).isNotEmpty;
      notifyListeners();
    } catch (_) {
      // No catalogue to read now (offline): the offer stays as it was, and is asked again next time.
      _offroadCoverAsked.remove(id);
    }
  }

  /// The states or provinces the region list says [r] is in ([statesIn]): a county's or a city's state. Its off-road data is
  /// theirs. Empty when the list does not say: an area drawn on the map, a region larger than a state, or the region's country
  /// file is not on the phone and cannot be read now (the packs are then chosen by their boxes).
  Future<List<RegionRecord>> statesOf(RegionRecord r) async {
    if (r.isDrawn || r.kind == kAreaRegionKind) return const [];
    final loaded = catalogue.loadedShards.where((s) => s[r.id] != null).firstOrNull;
    if (loaded != null) return statesIn(loaded.records, r.id);
    try {
      return statesIn((await catalogue.shard(r.id.split('-').first)).records, r.id);
    } catch (_) {
      return const [];
    }
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
  /// mobile data and downloads may not use it, unless [anyway]. Throws the core's `no_space`, also before anything starts, when
  /// what is known of the picked parts does not fit the phone ([_checkSpace]).
  Future<void> download(RegionRecord r, {required bool routing, required bool map, bool places = false, bool offroad = false, bool anyway = false}) =>
      _download(r, routing: routing, map: map, places: places, offroad: offroad, anyway: anyway, checkSpace: true);

  /// What the picked parts of [r] would download, from the sizes the app already has: the region catalogue's, as [costOf] reads
  /// them (for off-road, the terrain heights and only the packs not on the phone). A part with no size there counts as nothing:
  /// an area drawn on the map has none, and neither has a map layer the catalogue does not size.
  int knownDownloadBytes(RegionRecord r, {required bool routing, required bool map, bool places = false, bool offroad = false}) {
    final c = costOf(r);
    return (map ? (c.map ?? 0) : 0) + (routing ? (c.routing ?? 0) : 0) + (places ? (c.places ?? 0) : 0) + (offroad ? (c.offroad ?? 0) : 0);
  }

  /// One check of the free space for the whole region, before any part of it starts. Each part checks only itself when it starts
  /// (every map layer downloads as a job of its own, and so do the off-road terrain heights and each pack; none of them counts
  /// the others or what Cache keeps free), so the parts of a region that did not fit could each pass and fill the phone together.
  /// What is known of the region ([knownDownloadBytes]) must fit what a download may use ([Space.usable]), the rule and the
  /// figures of the download pop-up; when it does not, the core's `no_space` is thrown and nothing has started. A part whose size
  /// is not known is not counted: its own check when it starts still stands.
  Future<void> _checkSpace(RegionRecord r, {required bool routing, required bool map, required bool places, required bool offroad}) async {
    final bytes = knownDownloadBytes(r, routing: routing, map: map, places: places, offroad: offroad);
    if (bytes <= 0) return;
    Space? space;
    try {
      space = (spaceOf ?? downloadSpace)((await supportDir()).path);
    } catch (_) {
      // The storage cannot be read: each part's own check is what there is.
    }
    if (space != null && space.shortBy(bytes) > 0) throw const CacheSearchException('no_space', 'There is not enough free space on this device.');
  }

  Future<void> _download(
    RegionRecord r, {
    required bool routing,
    required bool map,
    required bool places,
    required bool offroad,
    required bool anyway,
    required bool checkSpace,
  }) async {
    await policy.checkDownload(anyway: anyway);
    places = places && placesAvailable;
    if (checkSpace) await _checkSpace(r, routing: routing, map: map, places: places, offroad: offroad);
    final k = _kept[r.id] ??= _Kept(id: r.id, name: r.name);
    k.bbox ??= r.bbox;
    if (r.isDrawn || r.kind == kAreaRegionKind) k.kind ??= r.kind;
    // Every part comes from the phone (or the region's centre) outwards, and each tile is used as soon as it is saved.
    final near = nearFor(r);
    // The outlines of the region's counties, towns and state are kept with it, so a tap on the map can name them offline. Quietly:
    // a failure leaves the download as it is.
    if (!r.isDrawn && r.kind != kAreaRegionKind) unawaited(catalogue.storeAreaPolygons(r).then((_) {}, onError: (_) {}));
    if (routing || places) {
      final core = _core ?? (throw CacheSearchException('unsupported', routingUnavailable ?? 'Road routing downloads are not available.'));
      final geometry = await catalogue.geometry(r);
      await _coreAdd(core, {
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
      // Each layer is sized for the region's box (the zoom is the box's, as the catalogue's sizes are) and downloads only the
      // tiles of its outline, where the catalogue has one; else the box.
      final bounds = r.bounds;
      if (bounds != null) {
        final outline = await _mapOutline(r);
        // One download per layer the tiles are kept in: hillshade and contour lines both read the elevation layer's tiles, and
        // 1.0.27 downloaded them twice (two areas, listed four times).
        final asked = <String>{for (final a in _areasOf(k)) maps.engine.downloadLayerOf(a.layerId)};
        for (final card in mapLayers) {
          final def = maps.downloadDefFor(card, bounds);
          if (!asked.add(maps.engine.downloadLayerOf(def.id))) continue;
          final est = await maps.engine.estimate(def.id, bounds, outline: outline);
          if (!est.allowed) continue;
          final a = await maps.engine.download(def.id, bounds, label: r.name, anyway: anyway, near: near, outline: outline);
          k.areas.add(a.id);
          // The person's Pause is on: a layer started now stops at once (the engine does not know of the hold), so no part of the
          // region runs while the rows say "all downloads paused". Resume carries it on.
          if (held) await maps.engine.pause(a.id);
        }
      }
    }
    // The off-road part never fails silently: what stopped it is kept and said after the other parts are saved (they have started).
    String? offroadProblem;
    if (offroad) offroadProblem = await _addOffroad(k, r, anyway: anyway, only: !routing && !map && !places);
    if (!k.routing && !k.places && k.areas.isEmpty && k.offroad.isEmpty) _kept.remove(r.id);
    await _save();
    await refresh();
    notifyListeners();
    // WORDING (for cache-pm): the sentences below reach the person as "Couldn't add off-road to <region>: <sentence>".
    if (offroadProblem != null) {
      // A region download asked for while paused (not the Add off-road request, which keeps its own words): Resume starts it.
      if (offroadProblem == _heldOffroad && (routing || map || places)) throw DownloadsPaused(r);
      throw StateError(offroadProblem);
    }
  }

  /// The outline [r]'s map part is downloaded for ([mapOutline]); null (the box) for an area drawn on the map, one kept from before
  /// regions, and when the outline cannot be read now.
  Future<List<List<List<double>>>?> _mapOutline(RegionRecord r) async {
    if (r.isDrawn || r.kind == kAreaRegionKind) return null;
    try {
      return mapOutline(r, await catalogue.geometry(r));
    } catch (_) {
      return null;
    }
  }

  /// The off-road packs that cover [r], each checked against its published SHA-256 (a pack already on the phone is not downloaded
  /// again), and the terrain heights over the region (z12 elevation over the part of the region the pack covers).
  ///
  /// Returns why nothing was started (plain words, for the person), or null when it started. [only]: off-road is all that was asked
  /// for (Add off-road), so a region with no pack over it is said, not passed over.
  Future<String?> _addOffroad(_Kept k, RegionRecord r, {required bool anyway, bool only = false}) async {
    // WORDING (cache-pm): these four sentences.
    if (held) return _heldOffroad;
    final (plan, problem) = await _offroadPlan(r);
    if (plan == null) {
      if (problem != null) {
        logError('Off-road data: no plan for ${r.id}', detail: problem);
        return problem[0].toLowerCase() + problem.substring(1);
      }
      return only ? 'no off-road data is published for this area.' : null;
    }
    if (!plan.allowed) {
      final why = plan.problem;
      logError('Off-road data: plan not allowed for ${r.id}', detail: why);
      return why == null
          ? "the terrain heights for this area can't be worked out."
          : "the terrain heights for this area can't be downloaded (${why[0].toLowerCase()}${why.substring(1).replaceFirst(RegExp(r'\.$'), '')}).";
    }
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
      final String area;
      try {
        area = have ?? (await maps.engine.download(kOffroadElevationLayer, box, label: label, anyway: anyway, zoom: kOffroadElevationZoom, near: nearFor(r))).id;
      } on MobileDataBlocked {
        rethrow;
      } catch (e, st) {
        logError('Off-road terrain heights for ${r.id}', error: e, stack: st);
        return "the terrain heights could not be downloaded. Try again.";
      }
      if (!k.terrain.contains(area)) k.terrain.add(area);
      unawaited(_fetchPack(k.offroad.firstWhere((x) => x.path == path)));
    }
    return null;
  }

  /// Downloads one pack into the off-road folder: under a hidden name, checked against its SHA-256 (a file that does not match is
  /// thrown away), then renamed into place, so the router only ever sees whole packs.
  Future<void> _fetchPack(_KeptPack p) async {
    if (plat.isWeb) return _fetchPackOnServer(p);
    final dir = (await offroadDir()).path;
    _offroadPath = dir;
    final dest = File('$dir/${p.path}');
    if (_packRuns[p.path]?.running ?? false) return;
    if (await dest.exists()) {
      _packRuns.remove(p.path);
      return;
    }
    if (held) return;
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

  /// [_fetchPack] in a browser: Cache Server downloads the pack into its own off-road folder, with no tab needed, and [refresh]
  /// reads how far it is (the phone's pack downloader and the server's are the same steps).
  Future<void> _fetchPackOnServer(_KeptPack p) async {
    final core = _core;
    if (_packRuns[p.path]?.running ?? false) return;
    if (core == null || held) {
      // Not silent: the pack's row says why it is not coming (paused reads as Paused, a missing engine as a problem).
      if (core == null) {
        logError('Off-road pack ${p.path}: no region engine on the server');
        (_packRuns[p.path] = _PackRun())
          ..running = false
          ..error = "Off-road data couldn't be downloaded: the server has no region engine.";
        notifyListeners();
      }
      return;
    }
    final run = _packRuns[p.path] = _PackRun();
    notifyListeners();
    try {
      final r = await core.call('offroad_fetch', {'path': p.path, 'url': p.url, 'bytes': p.bytes, 'sha256': p.sha256});
      if (r['state'] == 'ready') {
        _packRuns.remove(p.path);
        _webOnDisk.add(p.path);
      } else if (r['state'] == 'held') {
        _packRuns.remove(p.path);
      }
    } catch (e) {
      run
        ..running = false
        ..error = e is CacheSearchException && e.message.isNotEmpty ? e.message : "Off-road data couldn't be downloaded. Try again later.";
    }
    notifyListeners();
    _schedulePoll();
  }

  /// A browser reads from the server which packs are on its disk and how far the ones downloading are.
  Future<void> _syncServerPacks(RegionsCoreLike core) async {
    final paths = {for (final k in _kept.values) for (final p in k.offroad) p.path}.toList();
    if (paths.isEmpty) {
      _webOnDisk.clear();
      return;
    }
    final Map<String, dynamic> packs;
    try {
      packs = ((await core.call('offroad_status', {'paths': paths}))['packs'] as Map?)?.cast<String, dynamic>() ?? const {};
    } catch (_) {
      return;
    }
    _webOnDisk.clear();
    for (final e in packs.entries) {
      final v = (e.value as Map).cast<String, dynamic>();
      if (v['on_disk'] == true) {
        _webOnDisk.add(e.key);
        _packRuns.remove(e.key);
      } else if (v['running'] == true) {
        _packRuns.putIfAbsent(e.key, _PackRun.new)
          ..running = true
          ..error = null
          ..done = (v['done'] as num?)?.toInt() ?? 0;
      } else if (v['error'] is String) {
        _packRuns.putIfAbsent(e.key, _PackRun.new)
          ..running = false
          ..error = v['error'] as String;
      } else {
        _packRuns.remove(e.key);
      }
    }
  }

  /// The person paused the region downloads (Pause on a region): the core fetches no tiles, the off-road packs and the map areas
  /// stop and keep what they have. Kept across restarts; [resumeAll] carries on in order.
  bool held = false;

  /// Pause was tapped and the downloads are still stopping (the row says "Pausing…").
  bool pausing = false;

  /// Resume was tapped and nothing has moved yet (the row says "Starting…").
  bool resuming = false;

  /// Pauses every region download: the running part stops and the others wait.
  Future<void> pauseAll() async {
    if (held) return;
    held = true;
    pausing = true;
    notifyListeners();
    try {
      await _core?.call('set_policy', {'hold': true});
      for (final r in List.of(_packRuns.values)) {
        r.cancel.cancel();
      }
      for (final l in local) {
        for (final a in [...l.areas, ...l.terrain]) {
          if (a.phase == AreaPhase.running) await maps.engine.pause(a.id);
        }
      }
      await _save();
      await refresh();
    } finally {
      pausing = false;
      notifyListeners();
    }
  }

  /// Resume on a download that was asked for while paused: carries on everything paused, then starts the off-road part that waited.
  Future<void> resumeAndStart(RegionRecord r) async {
    await resumeAll(anyway: true);
    final here = regionOf(r.id);
    if (here != null && !here.hasOffroad) await download(r, routing: false, map: false, offroad: true, anyway: true);
  }

  /// Carries on every paused region download, in the order they were added.
  Future<void> resumeAll({bool anyway = false}) async {
    if (!held) return;
    await policy.checkDownload(anyway: anyway);
    held = false;
    resuming = true;
    notifyListeners();
    try {
      await _core?.call('set_policy', {'hold': false});
      for (final l in local) {
        for (final a in [...l.areas, ...l.terrain]) {
          if (a.phase == AreaPhase.failed) await maps.engine.update(a.id, anyway: anyway);
        }
      }
      if (_networkOk) unawaited(_resumePacks());
      await _save();
      await refresh();
    } finally {
      resuming = false;
      notifyListeners();
    }
  }

  /// The packs kept regions want that are not on the phone and not downloading: started again (on a connection downloads may use).
  Future<void> _resumePacks() async {
    if (held) return;
    if (!plat.isWeb) _offroadPath ??= (await offroadDir()).path;
    for (final k in _kept.values) {
      for (final p in k.offroad) {
        if (!_packOnPhone(p.path) && !(_packRuns[p.path]?.running ?? false)) unawaited(_fetchPack(p));
      }
    }
  }

  /// Removes the region. Tiles another region still needs stay (the core and the layer engine keep shared tiles once).
  ///
  /// A delete is a delete on every linked device that shares Maps: it is noted in this device's shared folder, each device removes the
  /// region from its own copy, and a region downloaded after it stays (regions_share.dart). [everywhere] false is for the repair that
  /// deletes and downloads again ("Delete and start again"), which is not meant to take other devices' copies away.
  Future<void> remove(String id, {bool everywhere = true}) async {
    final peer = _peerFor(id);
    final k = _kept.remove(id);
    final mine = _kept.values;
    if ((k?.routing ?? false) || (k?.places ?? false) || _statusOf(id) != null) await _core?.call('remove', {'id': id});
    for (final a in {...?k?.areas, ...?peer?.areas}) {
      await maps.engine.delete(a);
    }
    // off-road packs and their terrain heights stay while another region uses them
    for (final a in {...?k?.terrain, ...?peer?.terrain}) {
      if (!mine.any((o) => o.terrain.contains(a))) await maps.engine.delete(a);
    }
    final packs = <String, _KeptPack>{
      for (final p in peer?.offroad ?? const <Map<String, dynamic>>[]) (p['path'] as String? ?? ''): _KeptPack.fromJson(p),
      for (final p in k?.offroad ?? const <_KeptPack>[]) p.path: p,
    };
    for (final p in packs.values) {
      if (mine.any((o) => o.offroad.any((x) => x.path == p.path))) continue;
      _packRuns.remove(p.path)?.cancel.cancel();
      if (plat.isWeb) {
        // the server deletes the pack and its part
        _webOnDisk.remove(p.path);
        try {
          await _core?.call('offroad_remove', {'path': p.path});
        } catch (_) {}
        continue;
      }
      final dir = (await offroadDir()).path;
      for (final f in [File('$dir/${p.path}'), File('${File('$dir/${p.path}').parent.path}/.offroad.sqlite.part')]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    if (everywhere) {
      try {
        _share?.recordDelete(id);
      } catch (_) {}
    }
    _peers = [for (final p in _peers) if (p.id != id) p];
    await _save();
    await refresh();
    notifyListeners();
  }

  /// Whether deleting a region here also deletes it on other devices (the Maps share is on and a device is linked): the delete's
  /// confirmation then says so.
  bool get deleteReachesOtherDevices => syncedWithOtherDevice?.call() ?? false;

  /// The region [id] as a record to download or carry on: its own box for an area drawn on the map or kept from before regions, else
  /// the catalogue's record (read from the copy on the phone when there is one), else a record made from the box it was downloaded
  /// for. Null when none of these is known.
  Future<RegionRecord?> recordOf(String id) async {
    final k = _kept[id];
    final box = k?.bbox ?? _peerFor(id)?.bbox ?? _boxOfAreas(k);
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
  final Map<String, int> _tries = {};

  /// How many times Try again was tapped for region [id] in this run of the app: after two, its page also offers Delete and start
  /// again.
  int triesOf(String id) => _tries[id] ?? 0;

  /// Try again was tapped for region [id].
  void noteTry(String id) {
    _tries[id] = triesOf(id) + 1;
    notifyListeners();
  }

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
      if ((l.places?['state'] == 'failed' && !l.placesNotAvailable) || (k?.places == true && l.places == null && _statusOf(id) == null)) 'places',
      if (_routingOf(_statusOf(id))?['state'] == 'failed' || (k?.routing == true && _statusOf(id) == null)) 'routing',
    ];
    if (core != null && again.isNotEmpty) {
      final rec = await recordOf(id);
      if (rec == null) throw const CacheSearchException('not_found', 'This region could not be read. Connect and try again.');
      final near = nearFor(rec);
      await _coreAdd(core, {
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

  /// The box region [id] covers, for showing it on the map: the box it was downloaded for, else the box around its map areas, else
  /// the catalogue's (when its country's file is read already). Null when none is known.
  GeoBounds? boundsOf(String id) {
    final k = _kept[id];
    final b = k?.bbox ?? _boxOfAreas(k) ?? loadedRecord(id)?.bbox;
    return b == null ? null : RegionRecord(id: id, name: id, kind: 'region', bbox: b).bounds;
  }

  /// A region on this phone whose box ([boundsOf]) holds the point: one with directions ([routing]), or one with no off-road yet
  /// that can have it ([withoutOffroad]: not an area kept from before regions). The smallest when several do; null when none.
  LocalRegion? regionHolding(double lat, double lon, {bool routing = false, bool withoutOffroad = false}) {
    LocalRegion? best;
    var bestSize = double.infinity;
    for (final l in local) {
      if (routing && !l.hasRouting) continue;
      if (withoutOffroad && (l.hasOffroad || l.isArea)) continue;
      final b = boundsOf(l.id);
      if (b == null || !b.contains(lat, lon)) continue;
      final size = (b.east - b.west) * (b.north - b.south);
      if (size < bestSize) {
        best = l;
        bestSize = size;
      }
    }
    return best;
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
        // The core's own total is what the part takes on the device, in the unit the bytes done are counted in; the catalogue's
        // figure is the gzip transfer (about half), so it is only the answer before the core knows the part.
        RegionPartKind.directions => (p.totalBytes ?? 0) > 0 ? p.totalBytes : sz.routing,
        RegionPartKind.places => (p.totalBytes ?? 0) > 0 ? p.totalBytes : sz.places,
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
        for (final p in here.parts.where((p) => !p.complete)) {
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

  /// The migration running now: a call meanwhile waits for it (and returns when it is done), instead of returning at once.
  Future<void>? _migration;

  /// Said once after old map downloads were tidied up ("Removed 2 duplicate map downloads..."); the screen that shows it clears it.
  String? tidyNote;

  /// Map downloads made before regions (1.0.0 builds downloaded each layer for an area on its own) and duplicates of the same layer
  /// over the same box. Each old download inside a region on the phone (downloaded or partly downloaded) joins that region; the rest
  /// are grouped by their box, one area each, listed with the regions. Nothing is deleted except an exact duplicate (the same layer,
  /// box and zooms as another download the region keeps), whose tiles stay because the other one covers them. Runs once the map
  /// layers are read, and only once.
  @visibleForTesting
  Future<void> migrateOldDownloads() {
    if (_migrated || !maps.engine.ready) return Future<void>.value();
    return _migration ??= _migrateOldDownloads().whenComplete(() => _migration = null);
  }

  Future<void> _migrateOldDownloads() async {
    final engine = maps.engine;
    // a region a linked device shares holds its areas too (they are listed with it, not adopted as regions of this device)
    await _syncShare();
    final held = <String>{for (final k in _kept.values) ...[...k.areas, ...k.terrain], for (final p in _peers) ...[...p.areas, ...p.terrain]};
    // (an area only a linked device's shared copy holds is that device's, listed with its region; never adopted as this device's own)
    final loose = [for (final a in engine.allAreas) if (!held.contains(a.id) && a.phase != AreaPhase.running && a.sharedFrom == null) a];
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
  }

  /// Asks the core whether a newer road routing or places build is out.
  Future<void> checkUpdates() async {
    final r = await _core?.call('check_update');
    // The places server's build, read even when no region has places yet (the core's status names a build only once one does):
    // a region downloaded before places were published can then add them.
    final pb = (r?['places'] as Map?)?['build'];
    if (pb is String && pb.isNotEmpty) _placesServerBuild = pb;
    await refresh();
  }

  /// The places build the server published, as the last check_update read it (null: not read yet).
  String? _placesServerBuild;

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
    if (l != null && (missesPlaces(l) || (l.placesNotAvailable && placesPublished))) await _addPlaces(l);
    for (final p in k?.offroad ?? const <_KeptPack>[]) {
      if (_packRuns[p.path]?.running != true) unawaited(_fetchPack(p));
    }
    for (final a in k?.areas ?? const <String>[]) {
      await maps.engine.update(a, anyway: anyway);
    }
    // The region's outlines are brought up to date too (a person asked for it, so the quiet hours do not apply).
    await backfillOutlines(only: id, anyway: anyway, automatic: false);
    await refresh();
  }

  bool _backfilling = false;

  /// The town, county and state outlines of every kept region that has not had them all kept once (no marker): fetched, only the ones
  /// that are missing, and a marker is left when none failed. Outlines only. Runs by itself after the regions load, and for one region
  /// inside [updateRegion] ([only]). An automatic run does nothing from 1 to 8 AM (the phone's local time) and follows the mobile data
  /// setting for downloads (DataPolicy.blocksDownload, settings/data_policy.dart); [anyway] is the person's "Update now".
  Future<void> backfillOutlines({String? only, bool anyway = false, bool automatic = true}) async {
    if (plat.isWeb || _backfilling) return;
    if (automatic) {
      final h = _clock().hour;
      if (h >= 1 && h < 8) return;
    }
    if (!anyway && await policy.blocksDownload()) return;
    _backfilling = true;
    try {
      for (final l in local) {
        if (only != null && l.id != only) continue;
        if (l.kind == kDrawnRegionKind || l.kind == kAreaRegionKind) continue;
        RegionRecord? rec;
        try {
          rec = await catalogue.record(l.id);
        } catch (_) {}
        if (rec == null || rec.isDrawn || rec.kind == kAreaRegionKind) continue;
        // The marker is checked against the files (a stat of each): a region whose files were lost is filled again.
        if (await catalogue.outlinesComplete(rec)) continue;
        final r = await catalogue.storeAreaPolygons(rec);
        appLog.add(LogLevel.standard, 'INFO', 'outlines backfill region=${l.id} wanted=${r.wanted} present=${r.present} fetched=${r.fetched} failed=${r.failed}');
      }
    } catch (_) {
    } finally {
      _backfilling = false;
    }
  }

  /// A region on the phone that has no places part while places can be downloaded (one downloaded before they were part of
  /// regions). Update adds it; it is never downloaded without being asked.
  bool missesPlaces(LocalRegion l) => placesPublished && !l.isArea && !l.hasPlaces && (l.hasRouting || l.hasMap);

  /// The places server has a build (the core read its current.json). Until places are published, no region is offered them: a
  /// part asked for then could only fail.
  bool get placesPublished => placesAvailable && ((status['places'] as Map?)?['build'] != null || _placesServerBuild != null);

  /// Places were published after region [l] was downloaded (it has none): its page offers them ("Now available", Add).
  bool placesNowAvailable(LocalRegion l) => placesPublished && !l.isArea && !l.hasPlaces;

  Future<void> _addPlaces(LocalRegion l) async {
    final core = _core;
    if (core == null) return;
    RegionRecord? rec;
    try {
      rec = await catalogue.record(l.id);
    } catch (_) {}
    if (rec == null) throw const CacheSearchException('not_found', 'This region could not be read. Connect and try again.');
    await _coreAdd(core, {'id': rec.id, 'name': rec.name, 'geometry': await catalogue.geometry(rec), 'parts': ['places']});
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

  /// Reads what linked devices share of their regions and the deletes shared, ends this device's own regions that another device
  /// deleted since they were added here, and shares this device's regions.
  Future<void> _syncShare() async {
    final sh = _share;
    if (sh == null || _applying) return;
    try {
      final peers = sh.readPeers();
      final deletes = sh.readDeletes();
      _peers = [for (final p in peers) if (!deletes.any((d) => d.id == p.id && d.ends(p.added))) p];
      // A region of kind "area" that an earlier version adopted from a store this device did not download (the other device's file
      // landed in its live store) is the other device's: it is listed once, with the region that device shares; and one whose areas
      // are gone everywhere (a delete took them) is not left behind as "0 B".
      final shared = <String>{for (final p in _peers) ...[...p.areas, ...p.terrain]};
      final known = maps.engine.ready ? {for (final a in maps.engine.allAreas) a.id} : null;
      final adopted = [
        for (final k in _kept.values)
          if (k.kind == kAreaRegionKind && k.areas.isNotEmpty && (k.areas.every(shared.contains) || (known != null && k.areas.every((a) => !known.contains(a)))))
            k.id,
      ];
      if (adopted.isNotEmpty) {
        adopted.forEach(_kept.remove);
        unawaited(_save());
      }
      final ended = [for (final id in _ownIds) if (deletes.any((d) => d.id == id && d.ends(_kept[id]?.added ?? 0))) id];
      if (ended.isNotEmpty) {
        _applying = true;
        try {
          for (final id in ended) {
            await remove(id, everywhere: false);
          }
        } finally {
          _applying = false;
        }
      }
      sh.writeOwn(_shareOut());
    } catch (_) {}
  }

  /// This device's own regions as it shares them: what each holds, and (for the parts the core reports) how each stands.
  Map<String, Map<String, dynamic>> _shareOut() {
    Map<String, dynamic>? part(Map<String, dynamic>? p) {
      final state = p?['state'] as String?;
      if (state == null) return null;
      return {'state': state, if (state == 'ready' && p?['bytes'] is num) 'bytes': p!['bytes']};
    }

    final out = <String, Map<String, dynamic>>{};
    for (final id in _ownIds) {
      final k = _kept[id];
      final r = _statusOf(id);
      final routing = part(_routingOf(r));
      final places = part(_placesOf(r));
      out[id] = {
        if (k != null) ...k.toJson(),
        if (k == null) ...{'name': r?['name'] ?? id, 'added': 0, 'routing': routing != null, 'places': places != null},
        'routingPart': ?routing,
        'placesPart': ?places,
      };
    }
    return out;
  }

  Future<void> _save() async {
    try {
      final ready = [for (final r in _routingRegions) if (_routingOf(r)?['state'] == 'ready') r['name'] as String? ?? r['id'] as String];
      final text = jsonEncode({
        'regions': {for (final k in _kept.values) k.id: k.toJson()},
        if (held) 'held': true,
        'routing': {
          'key': _routingKey,
          if (status['tile_dir'] is String && ready.isNotEmpty) 'tile_dir': status['tile_dir'],
          'regions': ready,
        },
      });
      if (plat.isWeb) {
        await _webFs.writeStringAtomic(AppRoot.support, kRegionsAppFile, text);
        return;
      }
      final f = await _appFile();
      await f.parent.create(recursive: true);
      await writeStringAtomic(f, text);
    } catch (_) {}
  }

  /// Set by [dispose]: work that was still under way (a refresh, a download step) finishes quietly, with no notice to listeners.
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _askRenew?.cancel();
    _net?.cancel();
    maps.removeListener(_onMaps);
    if (_core != null) policy.settings.removeListener(_onSettings);
    focus?.removeListener(_onAskFocus);
    _core?.close();
    super.dispose();
  }
}

/// What the app remembers of one region: its name and the parts it asked for.
class _Kept {
  _Kept({required this.id, required this.name, this.routing = false, this.places = false, List<String>? areas, List<_KeptPack>? offroad, List<String>? terrain, this.kind, this.bbox, int? added})
    : added = added ?? DateTime.now().millisecondsSinceEpoch,
      areas = areas ?? [],
      offroad = offroad ?? [],
      terrain = terrain ?? [];

  final String id;
  final String name;

  /// When this device added the region (milliseconds; 0 for one kept by a version before this was recorded): a delete shared by a
  /// linked device ends the region only when it was made after this (regions_share.dart).
  final int added;

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
    'added': added,
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
    added: (j['added'] as num?)?.toInt() ?? 0,
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
