import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../files.dart';
import '../maps/geo.dart';
import '../search/core_config.dart' show kDataBaseUrl;
import '../weather/catalogue_store.dart' show FetchBytes, NetworkProblem, fetchBytes;

/// Where the public region catalogue is published (cache-packs' regions recipe): index.json, one shard per country
/// (`<iso>.json` and `<iso>.search.json`), `search-global.json` and `polygons/<id>.geojson`.
const String kRegionCatalogueBase = '$kDataBaseUrl/regions/';

/// The kind of a region drawn on the map rather than taken from the catalogue.
const String kDrawnRegionKind = 'drawn';

/// The kind of map downloads kept from before regions (per-layer area downloads of 1.0.0 builds) that no region on the phone holds:
/// they list as one area, map only.
const String kAreaRegionKind = 'area';

/// What each part of a catalogue region weighs, worked out when the catalogue is built (cache-packs, regions/region_sizes.py) from
/// the published routing and places indexes, the map layers' tile directories and the off-road catalogue: nothing is worked out on
/// the phone. A part the catalogue cannot size is left out (null, or missing from [map]).
class RegionSizes {
  const RegionSizes({this.routing, this.places, this.map = const {}, this.offroadPacks = const {}, this.offroadTerrain});

  /// Road routing: the gzipped tiles of the region's outline.
  final int? routing;

  /// Places and addresses; null while places are not published.
  final int? places;

  /// Each map layer (by the id it downloads as: hillshade and contour lines download as "elevation"): its bytes at the most detail
  /// that fits one download.
  final Map<String, int> map;

  /// The off-road packs that cover the region, by pack id, and the terrain heights over the region (z12).
  final Map<String, int> offroadPacks;
  final int? offroadTerrain;

  bool get hasOffroad => offroadPacks.isNotEmpty;

  static RegionSizes? fromJson(Object? v) {
    if (v is! Map) return null;
    int? n(Object? x) => x is num ? x.toInt() : null;
    final map = <String, int>{};
    for (final e in ((v['map'] as Map?) ?? const {}).entries) {
      final b = e.value is List && (e.value as List).isNotEmpty ? n((e.value as List).first) : n(e.value);
      if (b != null) map[e.key as String] = b;
    }
    final off = v['offroad'];
    final packs = <String, int>{};
    if (off is Map) {
      for (final e in ((off['packs'] as Map?) ?? const {}).entries) {
        final b = n(e.value);
        if (b != null) packs[e.key as String] = b;
      }
    }
    return RegionSizes(routing: n(v['routing']), places: n(v['places']), map: map, offroadPacks: packs, offroadTerrain: off is Map ? n(off['terrain']) : null);
  }
}

/// When the catalogue first carried sizes: a country's file kept on the phone from before is read again once.
final DateTime kRegionSizesSince = DateTime.utc(2026, 10, 31);

/// One region of the catalogue, at any scale: a country, a state, several states, part of a state, a valley, a metro area, a
/// county or a city. Regions overlap freely; [parents] are every region it sits in.
class RegionRecord {
  const RegionRecord({
    required this.id,
    required this.name,
    required this.kind,
    this.parents = const [],
    this.bbox,
    this.areaKm2,
    this.population,
    this.description,
    this.polygon,
    this.country,
    this.sizes,
  });

  final String id;
  final String name;

  /// The catalogue's kind: country, dependency, region, multi_state, multi_country, sub_state, valley, metro, metro_alias,
  /// county or locality.
  final String kind;
  final List<String> parents;

  /// [west, south, east, north] in degrees. West is greater than east when the region crosses the antimeridian (the United
  /// States, for the Aleutians).
  final List<double>? bbox;
  final double? areaKm2;
  final int? population;
  final String? description;

  /// The polygon's path relative to the catalogue (`polygons/<id>.geojson`).
  final String? polygon;

  /// The ISO 3166-1 code of the country it is in ("US").
  final String? country;

  /// What each part weighs, from the catalogue; null for a region it has no sizes for (and a drawn area).
  final RegionSizes? sizes;

  /// An area drawn on the map ("Draw your own area instead"): a rectangle, downloaded like any region.
  factory RegionRecord.drawn(GeoBounds b, {DateTime? at}) => RegionRecord(
    id: 'drawn-${(at ?? DateTime.now()).millisecondsSinceEpoch}',
    name: 'Drawn area',
    kind: kDrawnRegionKind,
    bbox: [b.west, b.south, b.east, b.north],
  );

  bool get isDrawn => kind == kDrawnRegionKind;

  factory RegionRecord.fromJson(Map<String, dynamic> j) => RegionRecord(
    id: j['id'] as String,
    name: j['name'] as String,
    kind: (j['kind'] as String?) ?? 'region',
    parents: [for (final p in (j['parents'] as List? ?? const [])) p as String],
    bbox: j['bbox'] is List && (j['bbox'] as List).length == 4 ? [for (final v in j['bbox'] as List) (v as num).toDouble()] : null,
    areaKm2: (j['area_km2'] as num?)?.toDouble(),
    population: (j['population'] as num?)?.toInt(),
    description: j['description'] as String?,
    polygon: j['polygon'] as String?,
    country: j['country'] as String?,
    sizes: RegionSizes.fromJson(j['sizes']),
  );

  /// The box the map layers are downloaded for. The layer engine takes a box, never a polygon, so the map part of a region
  /// covers its whole bounding box. A box across the antimeridian is cut to its larger side (the map does not wrap).
  GeoBounds? get bounds {
    final b = bbox;
    if (b == null) return null;
    var west = b[0], east = b[2];
    if (west > east) {
      final eastSide = 180 - west;
      final westSide = east + 180;
      if (westSide >= eastSide) {
        west = -180;
      } else {
        east = 180;
      }
    }
    return GeoBounds(south: b[1], west: west, north: b[3], east: east);
  }
}

/// A place in the browse tree. The same region can sit under more than one parent (Idaho is in the Pacific Northwest and in the
/// Intermountain West).
class RegionNode {
  const RegionNode({required this.id, required this.name, required this.kind, this.children = const []});

  final String id;
  final String name;
  final String kind;
  final List<RegionNode> children;

  factory RegionNode.fromJson(Map<String, dynamic> j) => RegionNode(
    id: j['id'] as String,
    name: j['name'] as String,
    kind: (j['kind'] as String?) ?? 'region',
    children: [for (final c in (j['children'] as List? ?? const [])) RegionNode.fromJson((c as Map).cast<String, dynamic>())],
  );
}

/// One country's part of the catalogue: its records by id and its browse tree.
class RegionShard {
  RegionShard({required this.id, required this.release, required this.records, required this.tree});

  final String id;
  final String release;
  final Map<String, RegionRecord> records;
  final List<RegionNode> tree;

  RegionRecord? operator [](String id) => records[id];

  static RegionShard parse(String id, String text) {
    final j = (jsonDecode(text) as Map).cast<String, dynamic>();
    return RegionShard(
      id: (j['shard'] as String?) ?? id,
      release: (j['release'] as String?) ?? '',
      records: {
        for (final r in (j['regions'] as List? ?? const []).cast<Map>())
          r['id'] as String: RegionRecord.fromJson(r.cast<String, dynamic>()),
      },
      tree: [for (final n in (j['tree'] as List? ?? const [])) RegionNode.fromJson((n as Map).cast<String, dynamic>())],
    );
  }
}

/// One line of a search list: enough to show the hit and find its record.
class RegionHit {
  const RegionHit({required this.id, required this.name, required this.kind, this.alt = const [], this.inside = '', this.population, this.shard});

  final String id;
  final String name;
  final String kind;
  final List<String> alt;

  /// What it is in, as the catalogue words it ("Ada County, Idaho").
  final String inside;
  final int? population;

  /// The shard holding its record (the global list says; a country's own list leaves it out).
  final String? shard;

  /// The shard of a hit: given, or the id up to its first dash (country ids are the ISO code).
  String get shardId => shard ?? id.split('-').first;

  factory RegionHit.fromJson(Map<String, dynamic> j, {String? shard}) => RegionHit(
    id: j['id'] as String,
    name: j['name'] as String,
    kind: (j['kind'] as String?) ?? 'region',
    alt: [for (final a in (j['alt'] as List? ?? const [])) a as String],
    inside: (j['in'] as String?) ?? '',
    population: (j['pop'] as num?)?.toInt(),
    shard: (j['shard'] as String?) ?? shard,
  );

  static List<RegionHit> parseList(String text, {String? shard}) => [
    for (final r in jsonDecode(text) as List) RegionHit.fromJson((r as Map).cast<String, dynamic>(), shard: shard),
  ];
}

/// A country in the index: its shard and how many regions it holds.
class RegionCountry {
  const RegionCountry({required this.record, required this.shard, required this.count});

  final RegionRecord record;
  final String shard;
  final int count;
}

/// The catalogue's front page: every country and where its shard and polygons are.
class RegionIndex {
  RegionIndex({required this.generated, required this.polygonBase, required this.countries, required this.searchFiles});

  final String generated;
  final String polygonBase;
  final List<RegionCountry> countries;

  /// Shard id to its search list's file name.
  final Map<String, String> searchFiles;

  static RegionIndex parse(String text) {
    final j = (jsonDecode(text) as Map).cast<String, dynamic>();
    final shards = (j['shards'] as Map? ?? const {}).cast<String, dynamic>();
    final countries = [
      for (final c in (j['countries'] as List? ?? const []).cast<Map>())
        RegionCountry(
          record: RegionRecord.fromJson(c.cast<String, dynamic>()),
          shard: (c['shard'] as String?) ?? c['id'] as String,
          count: (c['count'] as num?)?.toInt() ?? 0,
        ),
    ]..sort((a, b) => a.record.name.compareTo(b.record.name));
    return RegionIndex(
      generated: (j['generated'] as String?) ?? '',
      polygonBase: (j['polygon_base'] as String?) ?? '${kRegionCatalogueBase}polygons/',
      countries: countries,
      searchFiles: {for (final e in shards.entries) e.key: ((e.value as Map)['search'] as String?) ?? '${e.key}.search.json'},
    );
  }
}

/// The region catalogue, read from the public host and kept in [dir] so it works offline once seen. A file is fetched again
/// when it is older than [maxAge] (a month: the catalogue follows the monthly map releases); when that fails, the copy on
/// the phone is used.
class RegionCatalogue {
  RegionCatalogue({required this.dir, FetchBytes? fetch, DateTime Function()? now, this.base = kRegionCatalogueBase, this.maxAge = const Duration(days: 30)})
    : _fetch = fetch ?? ((u) => fetchBytes(u, maxBytes: 64 * 1024 * 1024)),
      _now = now ?? DateTime.now;

  final Future<Directory> Function() dir;
  final String base;
  final Duration maxAge;
  final FetchBytes _fetch;
  final DateTime Function() _now;

  RegionIndex? _index;
  final Map<String, RegionShard> _shards = {};
  final Map<String, List<RegionHit>> _search = {};
  List<RegionHit>? _global;
  final Map<String, Map<String, dynamic>> _geometry = {};

  /// The shards read so far (the browse screen and search use them).
  Iterable<RegionShard> get loadedShards => _shards.values;

  Future<RegionIndex> index() async => _index ??= RegionIndex.parse(await _text('index.json'));

  Future<RegionShard> shard(String id) async {
    final known = _shards[id];
    if (known != null) return known;
    // A country's file from before the catalogue had sizes is read again (once): the sizes come with it.
    final text = await _text('$id.json', freshAfter: kRegionSizesSince);
    // A large country's shard is several megabytes of JSON: read off the screen's thread.
    final s = await Isolate.run(() => RegionShard.parse(id, text));
    return _shards[id] = s;
  }

  /// The record of [id], from the shard of [shardId] (read if needed); null when the catalogue has no such region.
  Future<RegionRecord?> record(String id, {String? shardId}) async => (await shard(shardId ?? id.split('-').first))[id];

  /// The worldwide search list: countries, states and the larger places of every country.
  Future<List<RegionHit>> globalSearch() async {
    final known = _global;
    if (known != null) return known;
    final text = await _text('search-global.json');
    final list = await Isolate.run(() => RegionHit.parseList(text));
    _global = list;
    return list;
  }

  /// One country's full search list (every region it holds).
  Future<List<RegionHit>> shardSearch(String id) async {
    final known = _search[id];
    if (known != null) return known;
    final name = (await index()).searchFiles[id] ?? '$id.search.json';
    final text = await _text(name);
    return _search[id] = await Isolate.run(() => RegionHit.parseList(text, shard: id));
  }

  /// The region's outline as a GeoJSON geometry (a Polygon or MultiPolygon). A drawn area's is its rectangle.
  Future<Map<String, dynamic>> geometry(RegionRecord r) async {
    final b = r.bbox;
    if (r.isDrawn && b != null) {
      return {
        'type': 'Polygon',
        'coordinates': [
          [[b[0], b[1]], [b[2], b[1]], [b[2], b[3]], [b[0], b[3]], [b[0], b[1]]],
        ],
      };
    }
    final known = _geometry[r.id];
    if (known != null) return known;
    return _geometry[r.id] = await _readGeometry(r);
  }

  Future<Map<String, dynamic>> _readGeometry(RegionRecord r) async {
    final ix = await index();
    final at = ix.polygonBase.endsWith('/') ? ix.polygonBase : '${ix.polygonBase}/';
    final j = (jsonDecode(await _text('polygons/${r.id}.geojson', url: '$at${r.id}.geojson')) as Map).cast<String, dynamic>();
    final type = j['type'];
    if (type == 'FeatureCollection') {
      final f = (j['features'] as List).first as Map;
      return (f['geometry'] as Map).cast<String, dynamic>();
    }
    if (type == 'Feature') return (j['geometry'] as Map).cast<String, dynamic>();
    return j;
  }

  /// The smallest state-sized or smaller region of the read shards whose box holds the point: what a quiet
  /// "Download `<region>`?" on the map would offer. Not shown anywhere yet.
  RegionRecord? regionAt(double lat, double lon, {Set<String> kinds = const {'region', 'sub_state', 'valley', 'county'}}) {
    RegionRecord? best;
    for (final s in _shards.values) {
      for (final r in s.records.values) {
        final b = r.bounds;
        if (!kinds.contains(r.kind) || b == null || !b.contains(lat, lon)) continue;
        if (best == null || (r.areaKm2 ?? double.infinity) < (best.areaKm2 ?? double.infinity)) best = r;
      }
    }
    return best;
  }

  /// The regions of the read shards whose box holds the point, smallest first (at most [limit]): what the Regions sheet lists for
  /// the place on the map.
  List<RegionRecord> regionsAt(double lat, double lon, {Set<String> kinds = const {'region', 'sub_state', 'valley', 'metro', 'county'}, int limit = 8}) {
    final out = [
      for (final s in _shards.values)
        for (final r in s.records.values)
          if (kinds.contains(r.kind) && (r.bounds?.contains(lat, lon) ?? false)) r,
    ]..sort((a, b) => (a.areaKm2 ?? double.infinity).compareTo(b.areaKm2 ?? double.infinity));
    return out.take(limit).toList();
  }

  /// Reads the shards of the countries whose box holds the point (so [regionsAt] knows their regions). Boxes overlap near borders:
  /// a shard that cannot be read is left out, the others still count.
  Future<void> readShardAt(double lat, double lon) async {
    for (final c in (await index()).countries) {
      if (!(c.record.bounds?.contains(lat, lon) ?? false) || _shards.containsKey(c.shard)) continue;
      try {
        await shard(c.shard);
      } catch (_) {}
    }
  }

  /// The text of [name]: the copy on the phone while it is younger than [maxAge] (and newer than [freshAfter]), else fetched (and
  /// kept), else the old copy.
  Future<String> _text(String name, {String? url, DateTime? freshAfter}) async {
    final f = File('${(await dir()).path}/$name');
    final have = await f.exists();
    if (have) {
      final at = await f.lastModified();
      if (_now().difference(at) < maxAge && (freshAfter == null || at.isAfter(freshAfter))) return f.readAsString();
    }
    try {
      final bytes = await _fetch(Uri.parse(url ?? '$base$name'));
      final text = utf8.decode(bytes);
      jsonDecode(text); // never keep something that is not JSON
      await f.parent.create(recursive: true);
      await writeStringAtomic(f, text);
      return text;
    } catch (e) {
      if (have) return f.readAsString();
      if (e is NetworkProblem) rethrow;
      throw NetworkProblem('The region list could not be read: $e');
    }
  }
}

/// Finds regions by name in [rows]: every word of the query must start a word of the name (or of one of its other names).
/// Exact names first, then names that start with the query, then the rest; larger places first within each.
List<RegionHit> searchRegions(String query, Iterable<RegionHit> rows, {int limit = 40}) {
  final words = _words(query);
  if (words.isEmpty) return const [];
  final seen = <String>{};
  final scored = <(int, RegionHit)>[];
  final q = words.join(' ');
  for (final r in rows) {
    if (seen.contains(r.id)) continue;
    var best = -1;
    // The region's own name beats one of its other names (the city "Twin Falls" before the metro area also known by it).
    for (final (i, n) in [r.name, ...r.alt].indexed) {
      final w = _words(n);
      if (!words.every((x) => w.any((y) => y.startsWith(x)))) continue;
      final joined = w.join(' ');
      final s = (joined == q ? 0 : (joined.startsWith(q) ? 2 : 4)) + (i == 0 ? 0 : 1);
      if (best < 0 || s < best) best = s;
    }
    if (best < 0) continue;
    seen.add(r.id);
    scored.add((best, r));
  }
  scored.sort((a, b) {
    final c = a.$1.compareTo(b.$1);
    if (c != 0) return c;
    return (b.$2.population ?? 0).compareTo(a.$2.population ?? 0);
  });
  return [for (final s in scored.take(limit)) s.$2];
}

List<String> _words(String s) => [for (final w in s.toLowerCase().split(RegExp(r'[\s,.\-()/]+'))) if (w.isNotEmpty) w];

/// What a kind of region is called on screen.
String regionKindLabel(String kind, {String? country}) => switch (kind) {
  'country' => 'Country',
  'dependency' => 'Territory',
  'region' => country == 'US' ? 'State' : 'Region',
  'multi_state' => 'Several states',
  'multi_country' => 'Several countries',
  'sub_state' => 'Part of a state',
  'valley' => 'Valley',
  'metro' || 'metro_alias' => 'Metro area',
  'county' => 'County',
  'locality' => 'City or town',
  kDrawnRegionKind => 'Drawn on the map',
  _ => 'Region',
};

/// The heading over a group of one kind in the browse tree.
String regionKindHeading(String kind, {String? country}) => switch (kind) {
  'country' => 'Countries',
  'dependency' => 'Territories',
  'region' => country == 'US' ? 'States' : 'Regions',
  'multi_state' => 'Several states',
  'multi_country' => 'Several countries',
  'sub_state' => 'Parts of the state',
  'valley' => 'Valleys',
  'metro' || 'metro_alias' => 'Metro areas',
  'county' => 'Counties',
  'locality' => 'Cities and towns',
  _ => 'Regions',
};
