import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../layers/layer_def.dart';
import '../palette/map_palette.dart';

/// The map style generator. One generator and four palettes make every style the map shows:
///
///  * the base map is the OpenMapTiles-layout template (assets/map/omt_template.json, derived from
///    OpenFreeMap's Liberty style by tool/make_omt_template.py) whose colours are "@role" and are filled
///    from the palette;
///  * overlays (hillshade, contours with labels in feet, rasters, public lands, trails, MVUM) are built here
///    from their layer definition, with their colours from the same palette;
///  * the phone's position (accuracy circle, dot, heading marker) is a GeoJSON source the screen updates.
///
/// The Protomaps-layout generator that comes later (for servers that use that layout) plugs in beside
/// [_baseLayers]: it takes the same palette roles and returns that layout's layers.

/// The source id the screen updates with the phone's position.
const String kPositionSource = 'cache-position';
const String kPositionAccuracyFill = 'position-accuracy-fill';
const String kPositionAccuracyLine = 'position-accuracy-line';
const String kPositionDot = 'position-dot';
const String kPositionHeading = 'position-heading';

/// The name of the heading marker image the screen adds to the style.
const String kHeadingImage = 'position-heading';

/// A visible layer and how opaque it is drawn.
class StyleLayerUse {
  const StyleLayerUse(this.def, [this.opacity = 1]);
  final LayerDef def;
  final double opacity;
}

/// The base-map template, from the app's assets.
Future<Map<String, dynamic>> loadOmtTemplate() async =>
    jsonDecode(await rootBundle.loadString('assets/map/omt_template.json')) as Map<String, dynamic>;

/// The layer ids an overlay adds to the style, in drawing order.
List<String> overlayLayerIds(LayerDef d) {
  switch (d.kind) {
    case LayerKind.basemap:
      return const [];
    case LayerKind.hillshade:
    case LayerKind.raster:
      return [d.id];
    case LayerKind.contours:
      return ['${d.id}-minor', '${d.id}-index', '${d.id}-label'];
    case LayerKind.vector:
      return d.geometry == 'polygon' ? ['${d.id}-fill', '${d.id}-outline'] : ['${d.id}-casing', '${d.id}-line'];
  }
}

String sourceIdOf(LayerDef d) => 'src-${d.id}';

/// Builds the MapLibre style JSON for [palette] with the given visible [layers] (bottom first).
///
/// [tilesUrl] gives each layer's tile address (the local tile server's), [glyphsUrl] the folder of map
/// fonts shipped with the app (`.../{fontstack}/{range}.pbf`).
Map<String, dynamic> buildMapStyle({
  required MapPalette palette,
  required Map<String, dynamic> omtTemplate,
  required List<StyleLayerUse> layers,
  required String Function(LayerDef) tilesUrl,
  required String glyphsUrl,
}) {
  final sources = <String, dynamic>{};
  final basemap = layers.where((u) => u.def.kind == LayerKind.basemap).firstOrNull;
  final overlays = [for (final u in layers) if (u.def.kind != LayerKind.basemap) u];

  List<Map<String, dynamic>> base;
  if (basemap != null) {
    final src = sourceIdOf(basemap.def);
    sources[src] = _source(basemap.def, 'vector', tilesUrl(basemap.def), tileSize: null);
    base = _baseLayers(palette, omtTemplate, src);
  } else {
    base = [
      {
        'id': 'background',
        'type': 'background',
        'paint': {'background-color': palette.css('land')},
      }
    ];
  }

  final ground = <Map<String, dynamic>>[]; // under roads
  final above = <Map<String, dynamic>>[]; // over roads, under labels
  final top = <Map<String, dynamic>>[]; // over everything (contour labels)

  // Polygons first, then lines, so a trail is never hidden by a land fill.
  final ordered = [
    ...overlays.where((u) => u.def.kind == LayerKind.vector && u.def.geometry == 'polygon'),
    ...overlays.where((u) => !(u.def.kind == LayerKind.vector && u.def.geometry == 'polygon')),
  ];
  for (final u in ordered) {
    final d = u.def;
    final src = sourceIdOf(d);
    switch (d.kind) {
      case LayerKind.basemap:
        break;
      case LayerKind.hillshade:
        sources[src] = _source(d, 'raster-dem', tilesUrl(d), tileSize: d.tileSize, encoding: d.raw['encoding'] as String? ?? 'terrarium');
        ground.add(_hillshade(palette, d, src, u.opacity));
      case LayerKind.raster:
        sources[src] = _source(d, 'raster', tilesUrl(d), tileSize: d.tileSize);
        ground.add({
          'id': d.id,
          'type': 'raster',
          'source': src,
          'paint': {'raster-opacity': u.opacity},
        });
      case LayerKind.contours:
        sources[src] = _source(d, 'vector', tilesUrl(d), tileSize: null);
        final c = _contours(palette, d, src, u.opacity);
        above.addAll(c.take(2));
        top.add(c.last);
      case LayerKind.vector:
        sources[src] = _source(d, 'vector', tilesUrl(d), tileSize: null);
        above.addAll(_vectorOverlay(palette, d, src, u.opacity));
    }
  }

  final groundAt = base.indexWhere((l) => (l['id'] as String).startsWith('tunnel_'));
  final labelAt = base.indexWhere((l) => l['id'] == 'waterway_line_label');
  final List<Map<String, dynamic>> all;
  if (basemap == null) {
    all = [...base, ...ground, ...above, ...top];
  } else {
    final g = groundAt < 0 ? base.length : groundAt;
    final l = labelAt < 0 ? base.length : labelAt;
    all = [...base.sublist(0, g), ...ground, ...base.sublist(g, l), ...above, ...base.sublist(l), ...top];
  }

  sources[kPositionSource] = {
    'type': 'geojson',
    'data': {'type': 'FeatureCollection', 'features': <Object>[]},
  };
  all.addAll(_positionLayers(palette));

  return {
    'version': 8,
    'name': 'Cache ${palette.id.name}',
    'glyphs': glyphsUrl,
    'sources': sources,
    'layers': all,
  };
}

Map<String, dynamic> _source(LayerDef d, String type, String tiles, {int? tileSize, String? encoding}) => {
      'type': type,
      'tiles': [tiles],
      'minzoom': d.minZoom,
      'maxzoom': d.maxZoom,
      'tileSize': ?tileSize,
      'encoding': ?encoding,
      if (d.attribution.isNotEmpty) 'attribution': d.attribution,
    };

/// The template with every "@role" replaced by the palette's colour and its source set to [src].
List<Map<String, dynamic>> _baseLayers(MapPalette p, Map<String, dynamic> template, String src) {
  Object? fill(Object? v) {
    if (v is String && v.startsWith('@')) return p.css(v.substring(1));
    if (v is List) return [for (final e in v) fill(e)];
    if (v is Map) return <String, dynamic>{for (final e in v.entries) e.key as String: fill(e.value)};
    return v;
  }

  return [
    for (final l in template['layers'] as List)
      () {
        final m = fill(l) as Map<String, dynamic>;
        if (m.containsKey('source')) m['source'] = src;
        return m;
      }()
  ];
}

Map<String, dynamic> _hillshade(MapPalette p, LayerDef d, String src, double o) => {
      'id': d.id,
      'type': 'hillshade',
      'source': src,
      'paint': {
        'hillshade-shadow-color': p.css('hillshadeShadow', opacity: o),
        'hillshade-highlight-color': p.css('hillshadeHighlight', opacity: o),
        'hillshade-accent-color': p.css('hillshadeAccent', opacity: o),
        'hillshade-exaggeration': 0.5,
        'hillshade-illumination-direction': 335,
      },
    };

/// Minor lines, index lines, and the index lines' labels in feet. Returns [minor, index, label].
List<Map<String, dynamic>> _contours(MapPalette p, LayerDef d, String src, double o) {
  final sl = d.sourceLayer.isEmpty ? 'contours' : d.sourceLayer;
  return [
    {
      'id': '${d.id}-minor',
      'type': 'line',
      'source': src,
      'source-layer': sl,
      'minzoom': 11,
      'filter': ['<', ['to-number', ['get', 'level'], 0], 1],
      'layout': {'line-join': 'round'},
      'paint': {
        'line-color': p.css('contour'),
        'line-opacity': o,
        'line-width': ['interpolate', ['linear'], ['zoom'], 11, 0.4, 16, 1.0],
      },
    },
    {
      'id': '${d.id}-index',
      'type': 'line',
      'source': src,
      'source-layer': sl,
      'minzoom': 9,
      'filter': ['>=', ['to-number', ['get', 'level'], 0], 1],
      'layout': {'line-join': 'round'},
      'paint': {
        'line-color': p.css('contourIndex'),
        'line-opacity': o,
        'line-width': ['interpolate', ['linear'], ['zoom'], 9, 0.5, 16, 1.8],
      },
    },
    {
      'id': '${d.id}-label',
      'type': 'symbol',
      'source': src,
      'source-layer': sl,
      'minzoom': 12,
      'filter': ['>=', ['to-number', ['get', 'level'], 0], 1],
      'layout': {
        'symbol-placement': 'line',
        'symbol-spacing': 320,
        // Elevations are metres in the tiles; the map says feet.
        'text-field': [
          'concat',
          ['to-string', ['round', ['*', ['to-number', ['get', 'ele'], 0], 3.28084]]],
          ' ft'
        ],
        'text-font': ['NotoSans-Regular'],
        'text-size': 11,
        'text-max-angle': 30,
      },
      'paint': {
        'text-color': p.css('contourLabel'),
        'text-halo-color': p.css('labelHalo'),
        'text-halo-width': 1.5,
        'text-opacity': o,
      },
    },
  ];
}

/// Which palette roles a vector layer uses, by its `style_role`.
({String fill, String line}) _roleColors(String styleRole) => switch (styleRole) {
      'mvum' => (fill: 'publicLandsFill', line: 'mvum'),
      'blm' => (fill: 'publicLandsFill', line: 'blm'),
      'trail' => (fill: 'publicLandsFill', line: 'trail'),
      _ => (fill: 'publicLandsFill', line: 'publicLandsLine'),
    };

List<Map<String, dynamic>> _vectorOverlay(MapPalette p, LayerDef d, String src, double o) {
  final colors = _roleColors(d.styleRole);
  final base = {'source': src, if (d.sourceLayer.isNotEmpty) 'source-layer': d.sourceLayer};
  if (d.geometry == 'polygon') {
    return [
      {
        'id': '${d.id}-fill',
        'type': 'fill',
        ...base,
        'paint': {'fill-color': p.css(colors.fill), 'fill-opacity': o},
      },
      {
        'id': '${d.id}-outline',
        'type': 'line',
        ...base,
        'paint': {
          'line-color': p.css('publicLandsLine'),
          'line-opacity': o,
          'line-width': ['interpolate', ['linear'], ['zoom'], 4, 0.4, 12, 1.4],
        },
      },
    ];
  }
  final dash = switch (d.styleRole) {
    'trail' => [2.0, 1.2],
    'blm' => [4.0, 2.0],
    _ => null,
  };
  return [
    {
      'id': '${d.id}-casing',
      'type': 'line',
      ...base,
      'minzoom': 8,
      'layout': {'line-cap': 'round', 'line-join': 'round'},
      'paint': {
        'line-color': p.css('labelHalo'),
        'line-opacity': o,
        'line-width': ['interpolate', ['linear'], ['zoom'], 8, 1.2, 16, 4.5],
      },
    },
    {
      'id': '${d.id}-line',
      'type': 'line',
      ...base,
      'minzoom': 8,
      'layout': {'line-cap': dash == null ? 'round' : 'butt', 'line-join': 'round'},
      'paint': {
        'line-color': p.css(colors.line),
        'line-opacity': o,
        'line-width': ['interpolate', ['linear'], ['zoom'], 8, 0.6, 16, 2.4],
        'line-dasharray': ?dash,
      },
    },
  ];
}

List<Map<String, dynamic>> _positionLayers(MapPalette p) => [
      {
        'id': kPositionAccuracyFill,
        'type': 'fill',
        'source': kPositionSource,
        'filter': ['==', ['geometry-type'], 'Polygon'],
        'paint': {'fill-color': p.css('positionAccuracy')},
      },
      {
        'id': kPositionAccuracyLine,
        'type': 'line',
        'source': kPositionSource,
        'filter': ['==', ['geometry-type'], 'Polygon'],
        'paint': {'line-color': p.css('position'), 'line-opacity': 0.5, 'line-width': 1},
      },
      {
        'id': kPositionDot,
        'type': 'circle',
        'source': kPositionSource,
        'filter': ['==', ['geometry-type'], 'Point'],
        'paint': {
          'circle-radius': 8,
          'circle-color': p.css('position'),
          'circle-stroke-width': 3,
          'circle-stroke-color': p.css('positionRing'),
          'circle-pitch-alignment': 'map',
        },
      },
      {
        'id': kPositionHeading,
        'type': 'symbol',
        'source': kPositionSource,
        'filter': ['all', ['==', ['geometry-type'], 'Point'], ['has', 'heading']],
        'layout': {
          'icon-image': kHeadingImage,
          'icon-rotate': ['get', 'heading'],
          'icon-rotation-alignment': 'map',
          'icon-allow-overlap': true,
          'icon-ignore-placement': true,
        },
      },
    ];

/// All layer ids [buildMapStyle] produces for these inputs (for tests and for the screen's opacity changes).
List<String> expectedLayerIds(Map<String, dynamic> omtTemplate, List<StyleLayerUse> layers) {
  final hasBase = layers.any((u) => u.def.kind == LayerKind.basemap);
  return [
    if (hasBase) for (final l in omtTemplate['layers'] as List) (l as Map)['id'] as String else 'background',
    for (final u in layers) ...overlayLayerIds(u.def),
    kPositionAccuracyFill,
    kPositionAccuracyLine,
    kPositionDot,
    kPositionHeading,
  ];
}
