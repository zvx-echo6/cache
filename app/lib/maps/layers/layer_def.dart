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

  /// Picture tiles drawn as they are (land cover, satellite).
  raster,

  /// Any other vector tiles: lines or polygons coloured by [LayerDef.styleRole].
  vector,
}

/// One entry of the layer catalogue: a definition (data, never code). The engine owns the catalogue; this
/// is the app's view of it. Fields the app does not know are kept in [raw] so editing a definition by hand
/// (Advanced) never drops them.
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
    this.sourceLayer = '',
    this.geometry = 'line',
    this.plural = false,
    this.minZoom = 0,
    this.maxZoom = 14,
    this.tileSize = 256,
    this.onlineOnly = false,
    this.defaultOn = false,
    this.sourceUrl = '',
    Map<String, dynamic>? raw,
  }) : raw = raw ?? {};

  final String id;
  final String title;
  final String description;
  final String licence;

  /// The credit line shown on the map while the layer is visible.
  final String attribution;

  /// Where the layer has data, in words ("Worldwide", "United States").
  final String coverage;
  final LayerKind kind;

  /// For [LayerKind.vector]: which palette colour family ("public_lands", "trail", "mvum", "blm").
  final String styleRole;
  final String sourceLayer;

  /// For [LayerKind.vector]: "line" or "polygon".
  final String geometry;

  /// True when the title is plural, so the notice reads "Contours need" and not "Contours needs".
  final bool plural;
  final int minZoom;
  final int maxZoom;
  final int tileSize;

  /// A live service whose terms do not allow keeping it offline.
  final bool onlineOnly;
  final bool defaultOn;

  /// The layer's original public source (address), for the Advanced editor.
  final String sourceUrl;
  final Map<String, dynamic> raw;

  bool get isBase => kind == LayerKind.basemap;

  /// "Contours need a connection or a download here".
  String get missingNotice {
    final verb = plural ? 'need' : 'needs';
    return onlineOnly ? '$title $verb a connection here' : '$title $verb a connection or a download here';
  }

  static LayerKind _kind(String? s) =>
      LayerKind.values.firstWhere((k) => k.name == s, orElse: () => LayerKind.vector);

  factory LayerDef.fromJson(Map<String, dynamic> j) {
    String s(String k, [String d = '']) => (j[k] as String?) ?? d;
    int i(String k, int d) => (j[k] as num?)?.toInt() ?? d;
    final id = s('id');
    if (id.isEmpty || !RegExp(r'^[a-z0-9_-]+$').hasMatch(id)) {
      throw const FormatException('A layer needs an id of lower-case letters, digits, - and _');
    }
    if (s('title').isEmpty) throw const FormatException('A layer needs a title');
    return LayerDef(
      id: id,
      title: s('title'),
      description: s('description'),
      licence: s('licence'),
      attribution: s('attribution'),
      coverage: s('coverage', 'Worldwide'),
      kind: _kind(j['kind'] as String?),
      styleRole: s('style_role'),
      sourceLayer: s('source_layer'),
      geometry: s('geometry', 'line'),
      plural: j['plural'] == true,
      minZoom: i('min_zoom', 0),
      maxZoom: i('max_zoom', 14),
      tileSize: i('tile_size', 256),
      onlineOnly: j['online_only'] == true,
      defaultOn: j['default_on'] == true,
      sourceUrl: ((j['source'] as Map?)?['url'] as String?) ?? '',
      raw: Map<String, dynamic>.from(j),
    );
  }

  factory LayerDef.parse(String json) {
    final j = jsonDecode(json);
    if (j is! Map) throw const FormatException('A layer definition is a JSON object');
    return LayerDef.fromJson(Map<String, dynamic>.from(j));
  }

  Map<String, dynamic> toJson() => {
        ...raw,
        'id': id,
        'title': title,
        'description': description,
        'licence': licence,
        'attribution': attribution,
        'coverage': coverage,
        'kind': kind.name,
        if (styleRole.isNotEmpty) 'style_role': styleRole,
        if (sourceLayer.isNotEmpty) 'source_layer': sourceLayer,
        'geometry': geometry,
        'plural': plural,
        'min_zoom': minZoom,
        'max_zoom': maxZoom,
        'tile_size': tileSize,
        'online_only': onlineOnly,
        'default_on': defaultOn,
      };

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
  });

  final int tiles;
  final int bytes;

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
  final int totalTiles;
  int doneTiles;
  int bytes;
  AreaPhase phase;
  String? error;

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
