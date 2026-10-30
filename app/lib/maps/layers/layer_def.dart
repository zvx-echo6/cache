import 'dart:convert';

import '../geo.dart';

/// How the app draws a layer. The layer definition says which; the style generator holds the drawing.
enum LayerKind {
  /// The base map: vector tiles in the OpenMapTiles layout.
  basemap,

  /// Elevation tiles (Terrarium-encoded), drawn as hillshade on the phone.
  hillshade,

  /// Contour lines as vector tiles (source layer "contours", fields `ele` in metres and `level`), labelled in feet.
  contours,

  /// Elevation tiles (Terrarium) that hillshade and contours are made from: never drawn, never listed.
  elevation,

  /// Picture tiles drawn as they are (land cover, satellite).
  raster,

  /// Any other vector tiles: lines or polygons coloured by [LayerDef.styleRole].
  vector,
}

/// The colour families a vector layer can name in `style_hints.role`: the one list the publisher (cache-packs) writes and the style
/// generator draws.
const List<String> kStyleRoles = ['public_lands', 'mvum', 'blm_routes', 'trails'];

/// One entry of the layer catalogue: a definition (data, never code). The engine owns the catalogue; this
/// is the app's view of it. It reads the catalogue's own schema (format 1: `license`, `coverage.bbox`,
/// `source {type, url, minzoom, maxzoom, tile_format}`, `offline.allowed`, `style_hints.layers[].name`,
/// optional `layout`, `enabled_by_default`) and the shorter field names of earlier hand-written definitions.
/// The original JSON is kept in [raw], so editing a definition by hand (Advanced) never drops a field.
class LayerDef {
  LayerDef({
    required this.id,
    required this.title,
    required this.description,
    required this.licence,
    required this.attribution,
    required this.coverage,
    required this.kind,
    this.styleRole = '',
    this.sourceLayers = const [],
    this.plural = false,
    this.minZoom = 0,
    this.maxZoom = 14,
    this.tileSize = 256,
    this.encoding = '',
    this.onlineOnly = false,
    this.defaultOn = false,
    this.enabledByDefault = true,
    this.sourceUrl = '',
    this.sourceType = '',
    Map<String, dynamic>? raw,
  }) : raw = raw ?? {};

  final String id;
  final String title;
  final String description;
  final String licence;

  /// The credit line shown on the map while the layer is visible.
  final String attribution;

  /// Where the layer has data, in words.
  final String coverage;
  final LayerKind kind;

  /// For [LayerKind.vector]: which palette colour family, one of [kStyleRoles] (anything else draws as public lands).
  final String styleRole;

  /// The vector tile layers to draw (from the definition's style hints).
  final List<String> sourceLayers;

  /// True when the title is plural, so the notice reads "Contours need" and not "Contours needs".
  final bool plural;
  final int minZoom;
  final int maxZoom;
  final int tileSize;

  /// The elevation encoding of the tiles ("terrarium"), when the layer is elevation.
  final String encoding;

  /// A live service whose terms do not allow keeping it offline.
  final bool onlineOnly;

  /// Drawn the first time the map opens.
  final bool defaultOn;

  /// False for a definition that stays in the catalogue but is off until the user switches it on (Advanced).
  final bool enabledByDefault;

  /// The layer's original public source (address), for the Advanced editor.
  final String sourceUrl;

  /// "pmtiles", "tilejson", "xyz" and so on.
  final String sourceType;
  final Map<String, dynamic> raw;

  bool get isBase => kind == LayerKind.basemap;

  /// The tile layout of a base map: "openmaptiles" (the OpenFreeMap style) or "protomaps-v4".
  String get layout => (raw['layout'] as String?) ?? 'openmaptiles';

  /// Where the layer has data, as one box (`coverage.bbox` as west, south, east, north), or null for everywhere.
  GeoBounds? get coverageBox {
    final c = raw['coverage'];
    final b = c is Map ? c['bbox'] : null;
    if (b is! List || b.length != 4) return null;
    final v = [for (final e in b) (e as num).toDouble()];
    return GeoBounds(south: v[1], west: v[0], north: v[3], east: v[2]);
  }

  /// True when [area] lies wholly inside the layer's coverage box (any area, if it has none).
  bool covers(GeoBounds area) {
    final b = coverageBox;
    if (b == null) return true;
    return area.south >= b.south && area.north <= b.north && area.west >= b.west && area.east <= b.east;
  }

  /// A rough size of the coverage box in square degrees (smaller means more specific).
  double get coverageSize {
    final b = coverageBox;
    return b == null ? double.infinity : (b.north - b.south) * (b.east - b.west);
  }

  /// Definitions that are the same layer cut for different regions share a title and kind; the catalogue shows
  /// them as one card and a download uses the most specific one that covers the area.
  String get groupKey => '${kind.name}|$title';

  /// "Contours need a connection or a download here".
  String get missingNotice {
    final verb = plural ? 'need' : 'needs';
    return onlineOnly ? '$title $verb a connection here' : '$title $verb a connection or a download here';
  }

  static LayerKind _kind(Map<String, dynamic> j) {
    switch (j['transform']) {
      case 'hillshade' || 'elevation_to_hillshade':
        return LayerKind.hillshade;
      case 'contours' || 'elevation_to_contours':
        return LayerKind.contours;
    }
    if (j['kind'] == 'elevation') return LayerKind.elevation;
    if (j['kind'] == 'online-raster') return LayerKind.raster;
    // The published catalogue calls the base map "vector" like any other vector tiles; what makes it the base
    // map is its tile layout, or its style hint.
    final hints = j['style_hints'];
    if (j['layout'] is String || (hints is Map && hints['role'] == 'basemap')) return LayerKind.basemap;
    return LayerKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => LayerKind.vector);
  }

  static String _words(Map<String, dynamic> j) {
    final c = j['coverage'];
    if (c is String) return c;
    if (c is Map && c['name'] is String) return c['name'] as String;
    if (c is Map && c['bbox'] is List && (c['bbox'] as List).length == 4) {
      final b = [for (final e in c['bbox'] as List) (e as num).toDouble()];
      String d(double v, String pos, String neg) => '${v.abs().toStringAsFixed(v.abs() % 1 == 0 ? 0 : 1)}° ${v < 0 ? neg : pos}';
      return '${d(b[1], 'N', 'S')} to ${d(b[3], 'N', 'S')}, ${d(b[0], 'E', 'W')} to ${d(b[2], 'E', 'W')}';
    }
    return 'Worldwide';
  }

  /// The colour family of a vector layer, as the definition states it (`style_hints.role`, one of [kStyleRoles]); empty for none.
  static String _role(Map<String, dynamic> j) {
    final hints = j['style_hints'];
    final stated = (j['style_role'] as String?) ?? (hints is Map ? hints['role'] as String? : null);
    return stated ?? '';
  }

  factory LayerDef.fromJson(Map<String, dynamic> j) {
    String s(String k, [String d = '']) => (j[k] as String?) ?? d;
    final id = s('id');
    if (id.isEmpty || !RegExp(r'^[a-z0-9_-]+$').hasMatch(id)) {
      throw const FormatException('A layer needs an id of lower-case letters, digits, - and _');
    }
    if (s('title').isEmpty) throw const FormatException('A layer needs a title');
    final src = j['source'] is Map ? Map<String, dynamic>.from(j['source'] as Map) : <String, dynamic>{};
    int zoom(String longKey, String shortKey, int d) => ((src[longKey] ?? j[shortKey]) as num?)?.toInt() ?? d;
    final hints = j['style_hints'];
    final hinted = <String>[
      if (hints is Map && hints['layers'] is List)
        for (final l in hints['layers'] as List)
          if (l is Map && l['name'] is String) l['name'] as String,
    ];
    final single = s('source_layer');
    final kind = _kind(j);
    final offline = j['offline'];
    return LayerDef(
      id: id,
      title: s('title'),
      description: s('description'),
      licence: s('license', s('licence')),
      attribution: s('attribution'),
      coverage: _words(j),
      kind: kind,
      styleRole: kind == LayerKind.vector ? _role(j) : '',
      sourceLayers: hinted.isNotEmpty ? hinted : (single.isEmpty ? const [] : [single]),
      plural: j['plural'] == true,
      minZoom: zoom('minzoom', 'min_zoom', 0),
      maxZoom: zoom('maxzoom', 'max_zoom', 14),
      tileSize: ((src['tile_size'] ?? j['tile_size']) as num?)?.toInt() ?? 256,
      encoding: (src['encoding'] as String?) ?? '',
      onlineOnly: j['online_only'] == true || (offline is Map && offline['allowed'] == false),
      defaultOn: j['default_on'] == true || (kind == LayerKind.basemap && j['enabled_by_default'] != false),
      enabledByDefault: j['enabled_by_default'] != false,
      sourceUrl: (src['url'] as String?) ?? '',
      sourceType: (src['type'] as String?) ?? (src['format'] as String?) ?? '',
      raw: Map<String, dynamic>.from(j),
    );
  }

  factory LayerDef.parse(String json) {
    final j = jsonDecode(json);
    if (j is! Map) throw const FormatException('A layer definition is a JSON object');
    return LayerDef.fromJson(Map<String, dynamic>.from(j));
  }

  /// What the map style depends on, so a style is built again only when it changes (not whenever the catalogue is read
  /// again).
  String get styleSignature => '$id|${kind.name}|$minZoom-$maxZoom|$tileSize|$encoding|$sourceUrl|$attribution';

  /// A layer made from another (hillshade and contours from elevation) has no source of its own: this copy takes its
  /// zooms, tile size and encoding from [from], with [minZoom] and [maxZoom] where the engine serves other zooms. The
  /// definition as written ([raw]) does not change.
  LayerDef derivedFrom(LayerDef? from, {int? minZoom, int? maxZoom}) => LayerDef(
        id: id,
        title: title,
        description: description,
        licence: licence,
        attribution: attribution,
        coverage: coverage,
        kind: kind,
        styleRole: styleRole,
        sourceLayers: sourceLayers,
        plural: plural,
        minZoom: minZoom ?? from?.minZoom ?? this.minZoom,
        maxZoom: maxZoom ?? from?.maxZoom ?? this.maxZoom,
        tileSize: from?.tileSize ?? tileSize,
        encoding: from?.encoding.isNotEmpty == true ? from!.encoding : encoding,
        onlineOnly: onlineOnly,
        defaultOn: defaultOn,
        enabledByDefault: enabledByDefault,
        sourceUrl: sourceUrl,
        sourceType: sourceType,
        raw: raw,
      );

  /// The definition as written (what the Advanced editor shows and saves).
  Map<String, dynamic> toJson() => Map<String, dynamic>.from(raw);

  String prettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}

/// What a download of [area] would cost, shown before anything is downloaded.
class AreaEstimate {
  const AreaEstimate({
    required this.tiles,
    required this.bytes,
    required this.maxZoom,
    required this.allowed,
    this.problem,
    this.tilesAlready = 0,
    this.bytesAlready = 0,
  });

  /// The tiles this download fetches (those not on the phone yet).
  final int tiles;
  final int bytes;

  /// What an earlier download already put on the phone for this area, which is not fetched again.
  final int tilesAlready;
  final int bytesAlready;

  /// The most detailed zoom the download will include.
  final int maxZoom;

  /// False when the area is too big for this layer's source (the reason is in [problem]).
  final bool allowed;
  final String? problem;
}

enum AreaPhase { running, done, failed }

/// An area of one layer that is downloaded (or being downloaded) to the phone.
class DownloadedArea {
  DownloadedArea({
    required this.id,
    required this.layerId,
    required this.bounds,
    required this.label,
    required this.minZoom,
    required this.maxZoom,
    required this.totalTiles,
    this.doneTiles = 0,
    this.bytes = 0,
    this.phase = AreaPhase.running,
    this.error,
    this.fetchedAt,
  });

  final String id;
  final String layerId;
  final GeoBounds bounds;
  final String label;
  final int minZoom;
  final int maxZoom;
  int totalTiles;
  int doneTiles;
  int bytes;
  AreaPhase phase;
  String? error;

  /// Stopped part way with nothing wrong (Cache was closed while it ran, or an older build left it): it carries on, it did not
  /// fail.
  bool interrupted = false;

  /// When the tiles were fetched (updates restart it).
  DateTime? fetchedAt;

  double get fraction => totalTiles == 0 ? 1 : doneTiles / totalTiles;

  Map<String, dynamic> toJson() => {
        'id': id,
        'layer': layerId,
        'bounds': bounds.toJson(),
        'label': label,
        'min_zoom': minZoom,
        'max_zoom': maxZoom,
        'total_tiles': totalTiles,
        'done_tiles': doneTiles,
        'bytes': bytes,
        'phase': phase.name,
        if (error != null) 'error': error,
        if (fetchedAt != null) 'fetched_at': fetchedAt!.toIso8601String(),
      };

  factory DownloadedArea.fromJson(Map<String, dynamic> j) => DownloadedArea(
        id: j['id'] as String,
        layerId: j['layer'] as String,
        bounds: GeoBounds.fromJson(Map<String, dynamic>.from(j['bounds'] as Map)),
        label: j['label'] as String,
        minZoom: j['min_zoom'] as int,
        maxZoom: j['max_zoom'] as int,
        totalTiles: j['total_tiles'] as int,
        doneTiles: (j['done_tiles'] as int?) ?? 0,
        bytes: (j['bytes'] as int?) ?? 0,
        phase: AreaPhase.values.firstWhere((p) => p.name == j['phase'], orElse: () => AreaPhase.failed),
        error: j['error'] as String?,
        fetchedAt: j['fetched_at'] == null ? null : DateTime.parse(j['fetched_at'] as String),
      );
}
