import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/layers/layer_def.dart';
import 'package:flutter_test/flutter_test.dart';

/// The starter definitions the core ships (packages/cache_search/layers) read by the app, in the core's format 1.
void main() {
  final dir = Directory('../packages/cache_search/layers');
  final defs = {
    for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')))
      (jsonDecode(f.readAsStringSync()) as Map)['id'] as String: LayerDef.fromJson(Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map)),
  };

  test('every starter definition is read, and the kinds come from kind and transform', () {
    expect(defs.keys, containsAll(['elevation', 'hillshade', 'contours', 'openfreemap', 'landcover', 'usgs-imagery', 'esri-world-imagery']));
    expect(defs['elevation']!.kind, LayerKind.elevation);
    expect(defs['hillshade']!.kind, LayerKind.hillshade);
    expect(defs['contours']!.kind, LayerKind.contours);
    expect(defs['openfreemap']!.kind, LayerKind.basemap);
    expect(defs['landcover']!.kind, LayerKind.raster);
    expect(defs['usgs-imagery']!.kind, LayerKind.raster);
    expect(defs['esri-world-imagery']!.kind, LayerKind.raster);
  });

  test('OpenFreeMap is off by default and is not on the first time the map opens; online-only imagery cannot be offline', () {
    expect(defs['openfreemap']!.enabledByDefault, isFalse);
    expect(defs['openfreemap']!.defaultOn, isFalse);
    expect(defs['esri-world-imagery']!.onlineOnly, isTrue);
    expect(defs['usgs-imagery']!.onlineOnly, isFalse);
  });

  test('hillshade and contours take their zooms and tile size from the elevation layer they are made from', () {
    final elevation = defs['elevation']!;
    expect(elevation.maxZoom, 12);
    expect(elevation.tileSize, 512);
    expect(elevation.encoding, 'terrarium');
    final shade = defs['hillshade']!.derivedFrom(elevation);
    expect(shade.maxZoom, 12);
    expect(shade.tileSize, 512);
    expect(shade.encoding, 'terrarium');
    final contours = defs['contours']!.derivedFrom(elevation, minZoom: 3, maxZoom: 15);
    expect(contours.minZoom, 3);
    expect(contours.maxZoom, 15);
    // The definition as written is untouched, so the Advanced editor shows and saves what the core holds.
    expect(shade.raw.containsKey('source'), isFalse);
    expect(shade.raw['derived_from'], 'elevation');
  });

  test('the published base map is on by default; the contour source layer is the one the core makes', () {
    final basemap = LayerDef.fromJson({
      'format': 1,
      'id': 'basemap',
      'title': 'Base map',
      'kind': 'vector',
      'layout': 'protomaps-v4',
      'source': {'type': 'pmtiles', 'url': 'https://example.test/p.pmtiles'},
    });
    expect(basemap.isBase, isTrue);
    expect(basemap.defaultOn, isTrue);
    expect(defs['contours']!.raw['style_hints']['source_layer'], 'contours');
  });
}
