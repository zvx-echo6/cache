import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../layers/layer_def.dart';
import '../palette/map_palette.dart';
import 'protomaps_layout.dart';

/// The map style generator. One generator and four palettes make every style the map shows:
///
///  * the base map is the OpenMapTiles-layout template (assets/map/omt_template.json, derived from
///    OpenFreeMap's Liberty style by tool/make_omt_template.py) whose colours are "@role" and are filled
///    from the palette;
///  * overlays (hillshade, contours with labels in feet, rasters, public lands, trails, MVUM) are built here
///    from their layer definition, with their colours from the same palette;
///  * the phone's position (accuracy circle, dot, heading marker) is a GeoJSON source the screen updates.
///
/// A base-map definition says which layout its tiles use (`layout`): OpenMapTiles (OpenFreeMap, the default)
/// or Protomaps v4 (protomaps_layout.dart). Both are filled from the same palette roles.

/// The source id the screen updates with the phone's position.
const String kPositionSource = 'cache-position';
const String kPositionAccuracyFill = 'position-accuracy-fill';
const String kPositionAccuracyLine = 'position-accuracy-line';
const String kPositionDot = 'position-dot';
const String kPositionHeading = 'position-heading';

/// The sources the screen updates with the route being looked at or followed, and with the chosen place and the search results.
const String kRouteSource = 'cache-route';
const String kPinSource = 'cache-pin';
const String kRouteAlt = 'route-alt';
const String kRouteCasing = 'route-casing';
const String kRouteRoad = 'route-road';
const String kRouteFollow = 'route-follow';
const String kRouteOffroad = 'route-offroad';
const String kPinResults = 'pin-results';
const String kPinSelected = 'pin-selected';

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
    case LayerKind.basemap || LayerKind.elevation:
      return const [];
    // Ids carry a suffix so an overlay can never collide with a layer of the base map ("landcover").
    case LayerKind.hillshade:
      return ['${d.id}-shade'];
    case LayerKind.raster:
      return ['${d.id}-raster'];
    case LayerKind.contours:
      return ['${d.id}-minor', '${d.id}-index', '${d.id}-label'];
    case LayerKind.vector:
      return [
        for (final t in _vectorTags(d)) ...['$t-fill', '$t-casing', '$t-line'],
      ];
  }
}

/// One id prefix per vector tile layer of a definition (the definition's own id when it has just one).
List<String> _vectorTags(LayerDef d) {
  final sls = d.sourceLayers;
  if (sls.length <= 1) return [d.id];
  return [for (final sl in sls) '${d.id}-$sl'];
}

String sourceIdOf(LayerDef d) => 'src-${d.id}';

/// Builds the MapLibre style JSON for [palette] with the given visible [layers] (bottom first).
///
/// [tilesUrl] gives each layer's tile address (the local tile server's), [glyphsUrl] the folder of map
/// fonts shipped with the app (`.../{fontstack}/{range}.pbf`).
Map<String, dynamic> buildMapStyle({
  required MapPalette palette,
  required Map<String, dynamic> omtTemplate,
  Map<String, dynamic>? protomapsTemplate,
  required List<StyleLayerUse> layers,
  required String Function(LayerDef) tilesUrl,
  required String glyphsUrl,
}) {
  final sources = <String, dynamic>{};
  final basemap = layers.where((u) => u.def.kind == LayerKind.basemap).firstOrNull;
  final overlays = [for (final u in layers) if (u.def.kind != LayerKind.basemap) u];

  List<Map<String, dynamic>> base;
  var groundPrefix = 'tunnel_';
  var labelsId = 'waterway_line_label';
  if (basemap != null) {
    final src = sourceIdOf(basemap.def);
    sources[src] = _source(basemap.def, 'vector', tilesUrl(basemap.def), tileSize: null);
    if (MapLayout.parse(basemap.def.raw['layout']) == MapLayout.protomapsV4) {
      if (protomapsTemplate == null) throw ArgumentError('A Protomaps base map needs the Protomaps template');
      base = protomapsLayers(palette, protomapsTemplate, src);
      groundPrefix = protomapsGroundAt;
      labelsId = protomapsLabelsAt;
    } else {
      base = _baseLayers(palette, omtTemplate, src);
    }
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

  // Land areas first, then lines, so a trail is never hidden by a land fill.
  bool isArea(StyleLayerUse u) => u.def.kind == LayerKind.vector && u.def.styleRole == 'public_lands';
  final ordered = [...overlays.where(isArea), ...overlays.where((u) => !isArea(u))];
  for (final u in ordered) {
    final d = u.def;
    final src = sourceIdOf(d);
    switch (d.kind) {
      case LayerKind.basemap || LayerKind.elevation:
        break;
      case LayerKind.hillshade:
        sources[src] = _source(d, 'raster-dem', tilesUrl(d),
            tileSize: d.tileSize, encoding: d.encoding.isNotEmpty ? d.encoding : (d.raw['encoding'] as String? ?? 'terrarium'));
        ground.add(_hillshade(palette, d, src, u.opacity));
      case LayerKind.raster:
        sources[src] = _source(d, 'raster', tilesUrl(d), tileSize: d.tileSize);
        ground.add({
          'id': '${d.id}-raster',
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

  final groundAt = base.indexWhere((l) => (l['id'] as String).startsWith(groundPrefix));
  final labelAt = base.indexWhere((l) => l['id'] == labelsId);
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
  sources[kRouteSource] = {
    'type': 'geojson',
    'data': {'type': 'FeatureCollection', 'features': <Object>[]},
  };
  sources[kPinSource] = {
    'type': 'geojson',
    'data': {'type': 'FeatureCollection', 'features': <Object>[]},
  };
  all.addAll(_routeLayers(palette));
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
      'id': '${d.id}-shade',
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
  final sl = d.sourceLayers.isEmpty ? 'contours' : d.sourceLayers.first;
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
        // The core's contour tiles carry `ele` in feet already.
        'text-field': [
          'concat',
          ['to-string', ['round', ['to-number', ['get', 'ele'], 0]]],
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

/// Which palette roles a vector layer uses, by its style role (see kStyleRoles).
({String fill, String line}) _roleColors(String styleRole) => switch (styleRole) {
      'mvum' => (fill: 'publicLandsFill', line: 'mvum'),
      'blm_routes' => (fill: 'publicLandsFill', line: 'blm'),
      'trails' => (fill: 'publicLandsFill', line: 'trail'),
      _ => (fill: 'publicLandsFill', line: 'publicLandsLine'),
    };

List<Map<String, dynamic>> _vectorOverlay(MapPalette p, LayerDef d, String src, double o) {
  final colors = _roleColors(d.styleRole);
  final dash = switch (d.styleRole) {
    'trails' => [2.0, 1.2],
    'blm_routes' => [4.0, 2.0],
    _ => null,
  };
  final sls = d.sourceLayers.isEmpty ? [''] : d.sourceLayers;
  final tags = _vectorTags(d);
  const polygon = ['==', ['geometry-type'], 'Polygon'];
  const line = ['==', ['geometry-type'], 'LineString'];
  return [
    for (var i = 0; i < sls.length; i++) ...[
      () {
        final base = {'source': src, if (sls[i].isNotEmpty) 'source-layer': sls[i]};
        return <Map<String, dynamic>>[
          // Areas (public lands): a tint and an outline.
          {
            'id': '${tags[i]}-fill',
            'type': 'fill',
            ...base,
            'filter': polygon,
            'paint': {'fill-color': p.css(colors.fill), 'fill-opacity': o},
          },
          // Routes: a pale casing under the line so it reads on any ground.
          {
            'id': '${tags[i]}-casing',
            'type': 'line',
            ...base,
            'minzoom': 8,
            'filter': line,
            'layout': {'line-cap': 'round', 'line-join': 'round'},
            'paint': {
              'line-color': p.css('labelHalo'),
              'line-opacity': o,
              'line-width': ['interpolate', ['linear'], ['zoom'], 8, 1.2, 16, 4.5],
            },
          },
          // The line itself (and the outline of an area).
          {
            'id': '${tags[i]}-line',
            'type': 'line',
            ...base,
            'layout': {'line-cap': dash == null ? 'round' : 'butt', 'line-join': 'round'},
            'paint': {
              'line-color': p.css(colors.line),
              'line-opacity': o,
              'line-width': ['interpolate', ['linear'], ['zoom'], 4, 0.4, 8, 0.8, 16, 2.6],
              'line-dasharray': ?dash,
            },
          },
        ];
      }()
    ].expand((l) => l),
  ];
}

/// The route: the other routes in grey, then the chosen one with an outline, drawn solid on roads, dashed over open ground
/// and dotted along a trail; and the pins (search results small, the chosen place large).
List<Map<String, dynamic>> _routeLayers(MapPalette p) => [
      {
        'id': kRouteAlt,
        'type': 'line',
        'source': kRouteSource,
        'filter': ['==', ['get', 'alt'], true],
        'layout': {'line-cap': 'round', 'line-join': 'round'},
        'paint': {'line-color': p.css('routeAlternate'), 'line-width': 6, 'line-opacity': 0.85},
      },
      {
        'id': kRouteCasing,
        'type': 'line',
        'source': kRouteSource,
        'filter': ['==', ['get', 'alt'], false],
        'layout': {'line-cap': 'round', 'line-join': 'round'},
        'paint': {'line-color': p.css('routeCasing'), 'line-width': 10},
      },
      {
        'id': kRouteRoad,
        'type': 'line',
        'source': kRouteSource,
        'filter': ['all', ['==', ['get', 'alt'], false], ['==', ['get', 'kind'], 'road']],
        'layout': {'line-cap': 'round', 'line-join': 'round'},
        'paint': {'line-color': p.css('route'), 'line-width': 6},
      },
      {
        'id': kRouteFollow,
        'type': 'line',
        'source': kRouteSource,
        'filter': ['all', ['==', ['get', 'alt'], false], ['==', ['get', 'kind'], 'follow']],
        'layout': {'line-cap': 'butt', 'line-join': 'round'},
        'paint': {'line-color': p.css('routeOffroad'), 'line-width': 6, 'line-dasharray': [1, 1]},
      },
      {
        'id': kRouteOffroad,
        'type': 'line',
        'source': kRouteSource,
        'filter': ['all', ['==', ['get', 'alt'], false], ['==', ['get', 'kind'], 'offroad']],
        'layout': {'line-cap': 'butt', 'line-join': 'round'},
        'paint': {'line-color': p.css('routeOffroad'), 'line-width': 6, 'line-dasharray': [2, 1.2]},
      },
      {
        'id': kPinResults,
        'type': 'circle',
        'source': kPinSource,
        'filter': ['==', ['get', 'role'], 'result'],
        'paint': {
          'circle-radius': 7,
          'circle-color': p.css('pin'),
          'circle-stroke-width': 2,
          'circle-stroke-color': p.css('routeCasing'),
        },
      },
      {
        'id': kPinSelected,
        'type': 'circle',
        'source': kPinSource,
        'filter': ['==', ['get', 'role'], 'selected'],
        'paint': {
          'circle-radius': 11,
          'circle-color': p.css('pin'),
          'circle-stroke-width': 4,
          'circle-stroke-color': p.css('routeCasing'),
        },
      },
    ];

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
List<String> expectedLayerIds(Map<String, dynamic> omtTemplate, List<StyleLayerUse> layers,
    {Map<String, dynamic>? protomapsTemplate}) {
  final base = layers.where((u) => u.def.kind == LayerKind.basemap).firstOrNull;
  final template =
      base != null && MapLayout.parse(base.def.raw['layout']) == MapLayout.protomapsV4 ? protomapsTemplate! : omtTemplate;
  return [
    if (base != null) for (final l in template['layers'] as List) (l as Map)['id'] as String else 'background',
    for (final u in layers) ...overlayLayerIds(u.def),
    kRouteAlt,
    kRouteCasing,
    kRouteRoad,
    kRouteFollow,
    kRouteOffroad,
    kPinResults,
    kPinSelected,
    kPositionAccuracyFill,
    kPositionAccuracyLine,
    kPositionDot,
    kPositionHeading,
  ];
}
