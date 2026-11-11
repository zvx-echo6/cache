import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../app_fs.dart';
import '../files.dart';
import '../maps/geo.dart';
import '../platform.dart' as plat;
import '../search/core_config.dart' show kDataBaseUrl;
import '../weather/catalogue_store.dart' show FetchBytes, NetworkProblem, fetchBytes;
import 'region_catalogue.dart' show RegionRecord, kRegionCatalogueDir;

/// Where the off-road packs are published (cache-packs' recipes/offroad-regions.md): `current.json`, then one folder per build.
const String kOffroadBaseUrl = '$kDataBaseUrl/offroad/';

/// The map layer whose z12 tiles the off-road router reads its elevation from (the starter `elevation` layer: Mapterhorn's tiles).
const String kOffroadElevationLayer = 'elevation';

/// The only zoom of elevation the off-road router reads.
const int kOffroadElevationZoom = 12;

/// One published off-road pack: a state or province (plus about 50 km), one file.
class OffroadPack {
  const OffroadPack({
    required this.id,
    required this.name,
    required this.bbox,
    required this.build,
    required this.url,
    required this.bytes,
    required this.sha256,
    this.country,
    this.landAccess,
  });

  final String id;
  final String name;

  /// [west, south, east, north]: the area the pack covers.
  final List<double> bbox;
  final String build;

  /// `offroad.sqlite`: its address, size and SHA-256 as served.
  final String url;
  final int bytes;
  final String sha256;
  final String? country;

  /// "us" (US land-access data used) or "none".
  final String? landAccess;

  GeoBounds get bounds => GeoBounds(south: bbox[1], west: bbox[0], north: bbox[3], east: bbox[2]);

  /// Where the pack lives under the off-road folder: `<build>/<id>/offroad.sqlite`, the layout the router reads.
  String relativePath() => '$build/$id/offroad.sqlite';

  static OffroadPack? fromJson(Map<String, dynamic> j) {
    final file = ((j['files'] as Map?)?['offroad.sqlite'] as Map?)?.cast<String, dynamic>();
    final bbox = j['bbox'];
    if (file == null || bbox is! List || bbox.length != 4) return null;
    final url = file['url'], sha = file['sha256'], bytes = file['bytes'];
    final id = j['id'], build = j['build'];
    if (url is! String || sha is! String || bytes is! num || id is! String || build is! String) return null;
    // the id and build are folder names on the phone
    if (!_safe.hasMatch(id) || !_safe.hasMatch(build)) return null;
    return OffroadPack(
      id: id,
      name: (j['name'] as String?) ?? id,
      bbox: [for (final v in bbox) (v as num).toDouble()],
      build: build,
      url: url,
      bytes: bytes.toInt(),
      sha256: sha.toLowerCase(),
      country: j['country'] as String?,
      landAccess: j['land_access'] as String?,
    );
  }

  static final RegExp _safe = RegExp(r'^[a-z0-9][a-z0-9._-]*$');
}

/// The packs listed in `current.json` (entries that cannot be read are left out).
List<OffroadPack> parseOffroadCatalogue(String text) {
  final j = jsonDecode(text);
  if (j is! Map || j['component'] != 'offroad') throw const FormatException('not an off-road catalog');
  return [
    for (final r in (j['regions'] as List? ?? const []))
      if (r is Map) ?OffroadPack.fromJson(r.cast<String, dynamic>()),
  ];
}

/// The packs a region with box [b] needs. Empty when no pack is near: the region has no off-road part.
///
/// A pack's box is its state or province plus about 50 km, so near a state line two or three boxes hold the same ground. The
/// smallest box that held the region used to win, which gave a county on a state line the neighbouring state's pack whenever
/// that state's box was the smaller one: its off-road routes then ran off the edge of the data a little way into its own state.
///
/// - [states] given (the states or provinces the region list ties the region to, see `statesIn`): their packs, and no
///   neighbour's. A region in one state gets that state's pack; a region of several states, or a metro area across a state line,
///   gets one pack for each of its states that has one.
/// - Otherwise (an area drawn on the map, or a state with no pack of its own): by overlap. The pack that covers most of the box,
///   then, while part of the box is still uncovered, the pack that covers most of what is left. A pack that would only repeat
///   ground the chosen ones cover is left out. When packs cover the same share (two boxes both hold all of a small area), the
///   one the area lies deepest inside wins, which is the state it is in rather than the neighbour whose margin reaches it.
List<OffroadPack> packsCovering(List<OffroadPack> packs, GeoBounds b, {Iterable<RegionRecord> states = const []}) {
  bool meets(OffroadPack p) => p.bbox[0] < b.east && p.bbox[2] > b.west && p.bbox[1] < b.north && p.bbox[3] > b.south;
  final near = [for (final p in packs) if (meets(p)) p];
  final own = [for (final p in near) if (states.any((s) => _isPackOf(p, s))) p];
  return own.isNotEmpty ? own : _byOverlap(near, b);
}

/// [p] is the pack of the state or province [s]. The off-road list names a pack by the state's name and country ("Idaho", id
/// "idaho", "US"), not by the region list's id for it ("us-id"), so the two are matched by name within the country.
bool _isPackOf(OffroadPack p, RegionRecord s) {
  final pc = p.country, sc = s.country;
  if (pc != null && sc != null && pc.toUpperCase() != sc.toUpperCase()) return false;
  final name = _slug(s.name);
  return name.isNotEmpty && (name == p.id || name == _slug(p.name));
}

/// "British Columbia" as "british-columbia": a name as the off-road list writes its ids.
String _slug(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

/// How deep box [b] lies inside the box of [p]: the least distance from a side of [b] to the same side of the pack's box, in
/// degrees of latitude (a degree of longitude is counted at its length at the box's latitude). Negative when [b] reaches
/// outside the pack's box.
double _depth(OffroadPack p, GeoBounds b) {
  final k = math.cos((b.south + b.north) / 2 * math.pi / 180);
  return [(b.west - p.bbox[0]) * k, (p.bbox[2] - b.east) * k, b.south - p.bbox[1], p.bbox[3] - b.north].reduce(math.min);
}

/// The packs of [near] that cover box [b], chosen by overlap (see [packsCovering]).
List<OffroadPack> _byOverlap(List<OffroadPack> near, GeoBounds b) {
  if (near.isEmpty) return const [];
  // The box cut along every pack edge inside it: each piece is then wholly inside or wholly outside each pack's box.
  List<double> cuts(double lo, double hi, Iterable<double> edges) => {lo, hi, for (final e in edges) if (e > lo && e < hi) e}.toList()..sort();
  final xs = cuts(b.west, b.east, [for (final p in near) ...[p.bbox[0], p.bbox[2]]]);
  final ys = cuts(b.south, b.north, [for (final p in near) ...[p.bbox[1], p.bbox[3]]]);
  // A box with no width or height: the one pack it lies deepest in.
  if (xs.length < 2 || ys.length < 2) return [near.reduce((a, c) => _depth(c, b) > _depth(a, b) ? c : a)];
  bool holds(OffroadPack p, (int, int) c) => p.bbox[0] <= xs[c.$1] && p.bbox[2] >= xs[c.$1 + 1] && p.bbox[1] <= ys[c.$2] && p.bbox[3] >= ys[c.$2 + 1];
  double area((int, int) c) => (xs[c.$1 + 1] - xs[c.$1]) * (ys[c.$2 + 1] - ys[c.$2]);
  final left = <(int, int)>{
    for (var i = 0; i + 1 < xs.length; i++)
      for (var j = 0; j + 1 < ys.length; j++) (i, j),
  };
  final out = <OffroadPack>[];
  while (left.isNotEmpty) {
    OffroadPack? best;
    var most = 0.0;
    for (final p in near) {
      if (out.contains(p)) continue;
      final gain = left.where((c) => holds(p, c)).fold<double>(0, (s, c) => s + area(c));
      if (gain <= 0) continue;
      if (best == null || gain > most || (gain == most && _depth(p, b) > _depth(best, b))) {
        best = p;
        most = gain;
      }
    }
    if (best == null) break;
    final chosen = best;
    out.add(chosen);
    left.removeWhere((c) => holds(chosen, c));
  }
  return out;
}

/// The off-road catalogue, read from the data host and kept in [dir] so it works offline once seen. It is read again when the copy
/// is older than [maxAge]; when that fails, the copy on the phone is used.
class OffroadCatalogue {
  OffroadCatalogue({required this.dir, FetchBytes? fetch, DateTime Function()? now, this.url = '${kOffroadBaseUrl}current.json', this.maxAge = const Duration(days: 1)})
    : _fetch = fetch ?? ((u) => fetchBytes(u, maxBytes: 4 * 1024 * 1024)),
      _now = now ?? DateTime.now;

  final Future<Directory> Function() dir;
  final String url;
  final Duration maxAge;
  final FetchBytes _fetch;
  final DateTime Function() _now;
  List<OffroadPack>? _packs;
  DateTime? _readAt;

  /// The published packs.
  Future<List<OffroadPack>> packs() async {
    final known = _packs;
    if (known != null && _readAt != null && _now().difference(_readAt!) < maxAge) return known;
    if (plat.isWeb) return _packsOnServer();
    final f = File('${(await dir()).path}/offroad-current.json');
    final have = await f.exists();
    if (have && _now().difference(await f.lastModified()) < maxAge) return _keep(parseOffroadCatalogue(await f.readAsString()));
    try {
      final text = utf8.decode(await _fetch(Uri.parse(url)));
      final list = parseOffroadCatalogue(text); // never keep something that is not the catalogue
      await f.parent.create(recursive: true);
      await writeStringAtomic(f, text);
      return _keep(list);
    } catch (e) {
      if (have) return _keep(parseOffroadCatalogue(await f.readAsString()));
      if (e is NetworkProblem) rethrow;
      throw NetworkProblem('The off-road list could not be read: $e');
    }
  }

  AppFs? _webFs;

  /// [packs] in a browser: the copy is `region-catalogue/offroad-current.json` in the server's support folder.
  Future<List<OffroadPack>> _packsOnServer() async {
    final fs = _webFs ??= createAppFs();
    const path = '$kRegionCatalogueDir/offroad-current.json';
    final stat = await fs.stat(AppRoot.support, path);
    if (stat != null && _now().difference(stat.mtime) < maxAge) {
      final text = await fs.readString(AppRoot.support, path);
      if (text != null) return _keep(parseOffroadCatalogue(text));
    }
    try {
      final text = utf8.decode(await _fetch(Uri.parse(url)));
      final list = parseOffroadCatalogue(text); // never keep something that is not the catalogue
      await fs.writeStringAtomic(AppRoot.support, path, text);
      return _keep(list);
    } catch (e) {
      final old = stat == null ? null : await fs.readString(AppRoot.support, path);
      if (old != null) return _keep(parseOffroadCatalogue(old));
      if (e is NetworkProblem) rethrow;
      throw NetworkProblem('The off-road list could not be read: $e');
    }
  }

  List<OffroadPack> _keep(List<OffroadPack> list) {
    _readAt = _now();
    return _packs = list;
  }
}
