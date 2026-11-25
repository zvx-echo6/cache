import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../app_fs.dart';
import '../files.dart';
import '../maps/geo.dart';
import '../platform.dart' as plat;
import '../search/core_config.dart' show kDataBaseUrl;
import '../weather/catalogue_store.dart' show FetchBytes, NetworkProblem, fetchBytes;
import 'area_lookup.dart';

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

/// When the catalogue's sizes last gained a part (places, republished 2026-11-01 00:20:41 UTC): a country's file kept on the phone
/// from before is read again once, so places are offered straight away.
final DateTime kRegionSizesSince = DateTime.utc(2026, 11, 1, 0, 21);

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
    this.regionCode,
    this.placeClass,
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

  /// The ISO 3166-2 code of the state it is in ("US-ID"), where the catalogue says.
  final String? regionCode;

  /// What a city or town is called by the catalogue: city, town, village, hamlet.
  final String? placeClass;

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
    regionCode: j['region_code'] as String?,
    placeClass: j['class'] as String?,
    sizes: RegionSizes.fromJson(j['sizes']),
  );

  /// The box the map layers are sized for and downloaded within ([mapOutline] is the shape downloaded inside it). A box across
  /// the antimeridian is cut to its larger side (the map does not wrap).
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

/// The outline the map part of [r] is downloaded for, from its [geometry] (a GeoJSON Polygon or MultiPolygon): every ring of every
/// part as [lon, lat] pairs, which the layer engine reads even-odd, so the parts make their union and a hole stays out. When the
/// region's box crosses the antimeridian only the parts inside [RegionRecord.bounds] (the side the box was cut to) are kept. Null
/// when there is no usable outline (a drawn area, another geometry, coordinates that are not numbers): the map then covers the box.
///
/// The catalogue's map sizes are worked out for the box, so an outline downloads less than the size shown.
List<List<List<double>>>? mapOutline(RegionRecord r, Map<String, dynamic> geometry) {
  final b = r.bounds, box = r.bbox;
  if (r.isDrawn || b == null || box == null) return null;
  final type = geometry['type'], coords = geometry['coordinates'];
  if (coords is! List) return null;
  final List<Object?> parts = switch (type) {
    'Polygon' => [coords],
    'MultiPolygon' => coords,
    _ => const [],
  };
  final crosses = box[0] > box[2];
  final rings = <List<List<double>>>[];
  for (final part in parts) {
    if (part is! List) return null;
    final own = <List<List<double>>>[];
    for (final ring in part) {
      if (ring is! List) return null;
      final pts = <List<double>>[];
      for (final p in ring) {
        if (p is! List || p.length < 2 || p[0] is! num || p[1] is! num) return null;
        pts.add([(p[0] as num).toDouble(), (p[1] as num).toDouble()]);
      }
      if (pts.length >= 3) own.add(pts);
    }
    if (own.isEmpty) continue;
    if (crosses && !own.first.every((p) => p[0] >= b.west && p[0] <= b.east)) continue;
    rings.addAll(own);
  }
  return rings.isEmpty ? null : rings;
}

/// The states or provinces (kind `region`) the region list says region [id] is in, from one country's [records]:
/// - itself, when it is a state;
/// - else the states it sits in, through its parents at any distance (a county's state; a city's, through its county; both
///   states of a metro area that crosses a state line);
/// - else the state its id starts with (ids are `<state>-<name>`, "us-id-..." in Idaho), when its parents name none.
/// Empty when [records] does not hold [id], and for a region larger than a state (several states, a country): the list does
/// not put those in one.
List<RegionRecord> statesIn(Map<String, RegionRecord> records, String id) {
  final r = records[id];
  if (r == null) return const [];
  bool isState(RegionRecord? x) => x != null && x.kind == 'region';
  if (isState(r)) return [r];
  // every region it sits in, nearest first
  final above = <String>{};
  final todo = [id];
  while (todo.isNotEmpty) {
    for (final p in records[todo.removeAt(0)]?.parents ?? const <String>[]) {
      if (above.add(p)) todo.add(p);
    }
  }
  final up = [for (final p in above) if (isState(records[p])) records[p]!];
  if (up.isNotEmpty) return up;
  final byId = records[id.split('-').take(2).join('-')];
  return isState(byId) ? [byId!] : const [];
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
class RegionCatalogue implements AreaSource, AreaFetcher {
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
    final s = await _off(() => RegionShard.parse(id, text));
    return _shards[id] = s;
  }

  /// The record of [id], from the shard of [shardId] (read if needed); null when the catalogue has no such region.
  Future<RegionRecord?> record(String id, {String? shardId}) async => (await shard(shardId ?? id.split('-').first))[id];

  /// The worldwide search list: countries, states and the larger places of every country.
  Future<List<RegionHit>> globalSearch() async {
    final known = _global;
    if (known != null) return known;
    final text = await _text('search-global.json');
    final list = await _off(() => RegionHit.parseList(text));
    _global = list;
    return list;
  }

  /// Every region the search looks through: the global list (countries, states, the larger places) and the full list of each country
  /// whose shard is loaded and of each of [countries] (country ids, "us"): the towns and counties are only in those. A list that
  /// cannot be read is left out.
  Future<List<RegionHit>> searchRows({Iterable<String> countries = const []}) async {
    final rows = <RegionHit>[...await globalSearch()];
    final ids = <String>{for (final s in loadedShards) s.id, ...countries};
    for (final id in ids) {
      try {
        rows.addAll(await shardSearch(id));
      } catch (_) {}
    }
    return rows;
  }

  /// The rows the setup wizard's place search looks through for [query]: the global list, the lists already read, and a few more read
  /// now, at most [maxLists] (each is opened once and kept): the country at [position]; the country or state of the global list that a
  /// word of the query names ("Hilo Hawaii": Hawaii, in the US list); and, when neither gives one, the country of the device's
  /// [localeCountry] ("US"). A list that cannot be read is left out.
  Future<List<RegionHit>> searchRowsFor(String query, {({double lat, double lon})? position, String? localeCountry, int maxLists = 3}) async {
    final global = await globalSearch();
    final rows = <RegionHit>[...global];
    final ids = <String>{for (final s in loadedShards) s.id};
    final fresh = <String>[];
    if (position != null) {
      try {
        await readShardAt(position.lat, position.lon);
      } catch (_) {}
      ids.addAll([for (final s in loadedShards) s.id]);
    }
    final named = global.where((h) => const {'country', 'dependency', 'region', 'sub_state', 'multi_state'}.contains(h.kind)).toList();
    for (final w in _words(query)) {
      if (w.length < 3) continue;
      for (final h in searchRegions(w, named, limit: 2)) {
        if (!ids.contains(h.shardId) && !fresh.contains(h.shardId)) fresh.add(h.shardId);
      }
    }
    if (fresh.isEmpty && position == null && localeCountry != null && localeCountry.isNotEmpty) fresh.add(localeCountry.toLowerCase());
    for (final id in fresh.take(maxLists)) {
      ids.add(id);
    }
    for (final id in ids) {
      try {
        rows.addAll(await shardSearch(id));
      } catch (_) {}
    }
    return rows;
  }

  /// One country's full search list (every region it holds).
  Future<List<RegionHit>> shardSearch(String id) async {
    final known = _search[id];
    if (known != null) return known;
    final name = (await index()).searchFiles[id] ?? '$id.search.json';
    final text = await _text(name);
    return _search[id] = await _off(() => RegionHit.parseList(text, shard: id));
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

  /// The outline of [r], fetched when it is not on the phone and kept (the same fetch-and-keep as [geometry]); null when it cannot be had.
  @override
  Future<Map<String, dynamic>?> fetchGeometry(RegionRecord r) async {
    try {
      return await geometry(r);
    } catch (_) {
      return null;
    }
  }

  /// The outline of [r] as it is kept on the phone, never fetched: null when it is not there or cannot be read (a part-written or
  /// corrupt file is skipped, not an error). What a lookup of the town and county of a point reads.
  @override
  Future<Map<String, dynamic>?> storedGeometry(RegionRecord r) async {
    try {
      final String? text;
      if (plat.isWeb) {
        text = await (_webFs ??= createAppFs()).readString(AppRoot.support, '$kRegionCatalogueDir/polygons/${r.id}.geojson');
      } else {
        final f = File('${(await dir()).path}/polygons/${r.id}.geojson');
        text = await f.exists() ? await f.readAsString() : null;
      }
      if (text == null) return null;
      return _geometryOf((jsonDecode(text) as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _geometryOf(Map<String, dynamic> j) {
    final type = j['type'];
    if (type == 'FeatureCollection') return ((j['features'] as List).first as Map)['geometry'].cast<String, dynamic>();
    if (type == 'Feature') return (j['geometry'] as Map).cast<String, dynamic>();
    return j;
  }

  @override
  List<RegionRecord> townsIn(RegionRecord county, {int limit = 3}) {
    final s = _shards[county.id.split('-').first];
    if (s == null) return const [];
    final towns = [for (final r in s.records.values) if (r.kind == 'locality' && r.parents.contains(county.id) && (r.population ?? 0) > 0) r]
      ..sort((a, b) => (b.population ?? 0).compareTo(a.population ?? 0));
    return towns.take(limit).toList();
  }

  /// The regions a region's download keeps outlines for: its counties and its cities and towns (every level below it, found through
  /// the parents of the records of its shard), and the county and state it is in. A country or a group of states has none: it is too big
  /// to keep every outline for. Needs the region's shard read ([shard]).
  List<RegionRecord> areaRecordsOf(RegionRecord r) {
    if (r.isDrawn || r.kind == 'country' || r.kind == 'dependency' || r.kind == 'multi_state' || r.kind == 'multi_country') return const [];
    final s = _shards[r.id.split('-').first];
    if (s == null) return const [];
    final children = <String, List<RegionRecord>>{};
    for (final x in s.records.values) {
      for (final p in x.parents) {
        (children[p] ??= []).add(x);
      }
    }
    final out = <String, RegionRecord>{};
    final queue = [r.id];
    final seen = {r.id};
    while (queue.isNotEmpty) {
      for (final c in children[queue.removeLast()] ?? const <RegionRecord>[]) {
        if (!seen.add(c.id)) continue;
        queue.add(c.id);
        if (c.kind == 'county' || c.kind == 'locality') out[c.id] = c;
      }
    }
    if (r.kind == 'county' || r.kind == 'locality') out[r.id] = r;
    // The county and the state above the region (the county a town is in, the state a county is in).
    final up = [...r.parents];
    final done = <String>{};
    while (up.isNotEmpty) {
      final p = s.records[up.removeLast()];
      if (p == null || !done.add(p.id)) continue;
      if (p.kind == 'region' || p.kind == 'county') out[p.id] = p;
      up.addAll(p.parents);
    }
    if (r.kind == 'region') out[r.id] = r;
    // A town of the next state can have a county here among its parents (a valley that crosses the border): it is not this region's.
    final code = r.regionCode;
    return out.values.where((x) => x.polygon != null && (code == null || x.regionCode == null || x.regionCode == code)).toList();
  }

  /// Keeps the outlines of [areaRecordsOf] on the phone beside the region's download, so tapping a place on the map can name its town
  /// and county offline. They are the catalogue's polygon files, kept as the region's own outline is (one file each, found again
  /// by [storedGeometry]); [parallel] at a time. One that cannot be fetched is left out and the rest go on. More than [maxFiles] is
  /// not done at all.
  Future<AreaStoreResult> storeAreaPolygons(RegionRecord r, {int maxFiles = 1500, int parallel = 4}) async {
    try {
      await shard(r.id.split('-').first);
    } catch (_) {
      return const AreaStoreResult(wanted: 0, stored: 0, failed: 0);
    }
    final want = areaRecordsOf(r);
    if (want.length > maxFiles) return AreaStoreResult(wanted: want.length, stored: 0, failed: 0, tooMany: true);
    var stored = 0, failed = 0, next = 0;
    final present = await _presentOutlines(want);
    Future<void> worker() async {
      while (next < want.length) {
        final x = want[next++];
        try {
          await _readGeometry(x); // fetched and kept (a copy younger than the catalogue's age is kept as it is)
          stored++;
        } catch (_) {
          failed++;
        }
      }
    }

    await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
    // Every outline of the region is on the phone: the back-fill need not look at this region again.
    if (failed == 0 && want.isNotEmpty) await _markOutlinesDone(r.id);
    return AreaStoreResult(wanted: want.length, stored: stored, failed: failed, present: present);
  }

  /// The marker that says every outline of region [regionId] was kept: written only when a store ended with none failed and not too
  /// many. Next to the outline files, so removing the files' folder removes it.
  File _doneMarker(Directory d, String regionId) => File('${d.path}/polygons/.done-$regionId');

  /// Whether the outlines of region [regionId] were all kept once (its marker). False in a browser, which keeps no files.
  Future<bool> outlinesDone(String regionId) async {
    if (plat.isWeb) return false;
    try {
      return await _doneMarker(await dir(), regionId).exists();
    } catch (_) {
      return false;
    }
  }

  Future<void> _markOutlinesDone(String regionId) async {
    if (plat.isWeb) return;
    try {
      await _doneMarker(await dir(), regionId).create(recursive: true);
    } catch (_) {}
  }

  /// How many of [records]' outline files are on the phone now.
  Future<int> _presentOutlines(List<RegionRecord> records) async {
    if (plat.isWeb) return 0;
    var n = 0;
    try {
      final d = await dir();
      for (final x in records) {
        if (await File('${d.path}/polygons/${x.id}.geojson').exists()) n++;
      }
    } catch (_) {}
    return n;
  }

  /// The town, county and state of a point from the outlines kept on the phone (never fetched). The shards of the countries around
  /// the point are read first; null when the point is in none of the outlines that are there.
  @override
  Future<AreaHit?> areaAtPoint(double lat, double lon) async {
    await readShardAt(lat, lon);
    return areaAt(lat, lon, [for (final s in _shards.values) ...s.records.values], storedGeometry);
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
    // A browser keeps the copy on Cache Server (the app's support folder there), through the app's folder seam.
    if (plat.isWeb) return _textOnServer(name, url: url, freshAfter: freshAfter);
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

  AppFs? _webFs;

  /// [_text] in a browser: the same rules, the copy in `region-catalogue/` of the server's support folder.
  Future<String> _textOnServer(String name, {String? url, DateTime? freshAfter}) async {
    final fs = _webFs ??= createAppFs();
    final path = '$kRegionCatalogueDir/$name';
    final stat = await fs.stat(AppRoot.support, path);
    final have = stat != null;
    if (stat != null && _now().difference(stat.mtime) < maxAge && (freshAfter == null || stat.mtime.isAfter(freshAfter))) {
      final text = await fs.readString(AppRoot.support, path);
      if (text != null) return text;
    }
    try {
      final bytes = await _fetch(Uri.parse(url ?? '$base$name'));
      final text = utf8.decode(bytes);
      jsonDecode(text); // never keep something that is not JSON
      await fs.writeStringAtomic(AppRoot.support, path, text);
      return text;
    } catch (e) {
      final old = have ? await fs.readString(AppRoot.support, path) : null;
      if (old != null) return old;
      if (e is NetworkProblem) rethrow;
      throw NetworkProblem('The region list could not be read: $e');
    }
  }
}

/// What [RegionCatalogue.storeAreaPolygons] did: outlines asked for, kept, and not fetched; [tooMany] when it did none for lack of room.
class AreaStoreResult {
  const AreaStoreResult({required this.wanted, required this.stored, required this.failed, this.tooMany = false, this.present = 0});

  final int wanted;
  final int stored;
  final int failed;

  /// How many of the outlines were already on the phone when it started (they are not fetched again).
  final int present;

  /// How many were fetched by this run.
  int get fetched => (stored - present).clamp(0, stored);
  final bool tooMany;
}

/// The folder of the support folder the region catalogue and the off-road catalogue are kept in.
const String kRegionCatalogueDir = 'region-catalogue';

/// [Isolate.run] where there are isolates; a browser has none, so the work runs here.
Future<T> _off<T>(T Function() work) => plat.isWeb ? Future<T>.sync(work) : Isolate.run(work);

/// Finds regions by name in [rows]: every word of the query must start a word of the name (or of one of its other names).
/// Exact names first, then names that start with the query, then the rest; larger places first within each.
List<RegionHit> searchRegions(String query, Iterable<RegionHit> rows, {int limit = 40, bool includeInside = false}) {
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
    // [includeInside]: a word may also be one of the place it is in ("Hilo Hawaii": Hilo, in Hawaii County, Hawaii), as long as one
    // word is in the name itself.
    if (best < 0 && includeInside && r.inside.isNotEmpty) {
      final own = {for (final n in [r.name, ...r.alt]) ..._words(n)};
      final all = {...own, ..._words(r.inside)};
      bool starts(Set<String> set, String x) => set.any((y) => y.startsWith(x));
      if (words.every((x) => starts(all, x)) && words.any((x) => starts(own, x))) best = 6;
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
