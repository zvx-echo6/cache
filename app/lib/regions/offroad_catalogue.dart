import 'dart:convert';
import 'dart:io';

import '../files.dart';
import '../maps/geo.dart';
import '../search/core_config.dart' show kDataBaseUrl;
import '../weather/catalogue_store.dart' show FetchBytes, NetworkProblem, fetchBytes;

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
  if (j is! Map || j['component'] != 'offroad') throw const FormatException('not an off-road catalogue');
  return [
    for (final r in (j['regions'] as List? ?? const []))
      if (r is Map) ?OffroadPack.fromJson(r.cast<String, dynamic>()),
  ];
}

/// The packs a region with box [b] needs: the smallest pack whose box holds all of it; when none does (a region across a border),
/// every pack whose box meets it. Empty when no pack is near: the region has no off-road part.
List<OffroadPack> packsCovering(List<OffroadPack> packs, GeoBounds b) {
  bool holds(OffroadPack p) => p.bbox[0] <= b.west && p.bbox[1] <= b.south && p.bbox[2] >= b.east && p.bbox[3] >= b.north;
  bool meets(OffroadPack p) => p.bbox[0] < b.east && p.bbox[2] > b.west && p.bbox[1] < b.north && p.bbox[3] > b.south;
  double area(OffroadPack p) => (p.bbox[2] - p.bbox[0]) * (p.bbox[3] - p.bbox[1]);
  final whole = [for (final p in packs) if (holds(p)) p]..sort((a, c) => area(a).compareTo(area(c)));
  if (whole.isNotEmpty) return [whole.first];
  return [for (final p in packs) if (meets(p)) p];
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

  List<OffroadPack> _keep(List<OffroadPack> list) {
    _readAt = _now();
    return _packs = list;
  }
}
