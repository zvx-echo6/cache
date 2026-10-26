import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/fake_catalogue.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/maps/style/protomaps_layout.dart';
import 'package:cache/maps/style/style_generator.dart';
import 'package:cache/theme.dart';
import 'package:flutter_test/flutter_test.dart';

final _colour = RegExp(r'^(#[0-9a-f]{6}|rgba\(\d{1,3},\d{1,3},\d{1,3},(0|1|0?\.\d+)\))$');

void main() {
  final template = jsonDecode(File('assets/map/omt_template.json').readAsStringSync()) as Map<String, dynamic>;
  final pmTemplate = jsonDecode(File('assets/map/protomaps_v4_template.json').readAsStringSync()) as Map<String, dynamic>;
  // The app's bundled definitions plus a copy of the published catalogue (test/fixtures/catalogue.json), which is
  // what the engine merges at run time. Every kind of layer is in there.
  final published = (jsonDecode(File('test/fixtures/catalogue.json').readAsStringSync()) as Map)['layers'] as List;
  final defs = [
    for (final j in [...fakeCatalogue, ...published]) LayerDef.fromJson(Map<String, dynamic>.from(j as Map)),
  ];
  final openFreeMap = defs.firstWhere((d) => d.id == 'openfreemap');
  final protomaps = defs.firstWhere((d) => d.id == 'basemap');
  List<StyleLayerUse> withBase(LayerDef base) => [
        StyleLayerUse(base),
        for (final d in defs) if (!d.isBase) StyleLayerUse(d, 0.7),
      ];
  // Every kind of layer on at once, at 70 % for the overlays, on the OpenMapTiles-layout base map.
  final all = withBase(openFreeMap);

  Map<String, dynamic> build(CacheThemeId id, List<StyleLayerUse> uses) => buildMapStyle(
        palette: mapPaletteFor(id),
        omtTemplate: template,
        protomapsTemplate: pmTemplate,
        layers: uses,
        tilesUrl: (d) => 'http://127.0.0.1:9/layers/${d.id}/{z}/{x}/{y}',
        glyphsUrl: 'file:///fonts/{fontstack}/{range}.pbf',
      );

  Iterable<String> colours(Object? v) sync* {
    // Strings that are colours in paint properties of the style.
    if (v is Map) {
      for (final e in v.entries) {
        if ((e.key as String).endsWith('-color') && e.value is String) yield e.value as String;
        yield* colours(e.value);
      }
    } else if (v is List) {
      for (final e in v) {
        yield* colours(e);
      }
    }
  }

  test('every palette defines every role', () {
    for (final id in CacheThemeId.values) {
      final p = mapPaletteFor(id);
      for (final r in MapPalette.roleNames) {
        expect(p.has(r), isTrue, reason: '${id.name} lacks $r');
      }
    }
  });

  test('the template uses only roles the palettes define', () {
    final used = RegExp(r'"@(\w+)"').allMatches(jsonEncode(template)).map((m) => m.group(1)!).toSet();
    expect(used, isNotEmpty);
    expect(MapPalette.roleNames.toSet().containsAll(used), isTrue, reason: 'unknown: ${used.difference(MapPalette.roleNames.toSet())}');
  });

  for (final id in CacheThemeId.values) {
    group('style for ${id.name}', () {
      test('is a valid style with every expected layer id', () {
        final style = build(id, all);
        expect(style['version'], 8);
        expect(style['glyphs'], contains('{fontstack}'));
        final layers = (style['layers'] as List).cast<Map<String, dynamic>>();
        final ids = [for (final l in layers) l['id'] as String];
        expect(ids.toSet().length, ids.length, reason: 'layer ids must be unique');
        expect(ids, unorderedEquals(expectedLayerIds(template, all)));
        // The base map's own layers, the overlays and the phone's position.
        for (final must in ['background', 'water', 'road_motorway', 'building', 'label_city', 'hillshade-shade', 'contours-label', 'public-lands-idaho-fill', 'usfs-trails-roads-trails-line', 'mvum-mvum_roads-line', 'blm-routes-line', 'landcover-raster', 'satellite-raster', kPositionDot, kPositionAccuracyFill, kPositionHeading]) {
          expect(ids, contains(must));
        }
        final sources = style['sources'] as Map<String, dynamic>;
        for (final l in layers) {
          if (l.containsKey('source')) expect(sources, contains(l['source']), reason: l['id'] as String);
        }
      });

      test('has no unfilled roles and only valid colours', () {
        final style = build(id, all);
        expect(jsonEncode(style), isNot(contains('"@')));
        final found = colours(style['layers']).toList();
        expect(found, isNotEmpty);
        for (final c in found) {
          expect(c, matches(_colour), reason: c);
        }
      });

      test('takes its colours from its own palette', () {
        final style = build(id, all);
        final p = mapPaletteFor(id);
        final layers = (style['layers'] as List).cast<Map<String, dynamic>>();
        expect(layers.firstWhere((l) => l['id'] == 'background')['paint']['background-color'], p.css('land'));
        expect(layers.firstWhere((l) => l['id'] == 'water')['paint']['fill-color'], p.css('water'));
        expect(layers.firstWhere((l) => l['id'] == 'mvum-mvum_roads-line')['paint']['line-color'], p.css('mvum'));
        expect(layers.firstWhere((l) => l['id'] == 'contours-label')['paint']['text-color'], p.css('contourLabel'));
      });
    });
  }

  test('the four palettes give four different styles from the same layout', () {
    final styles = {for (final id in CacheThemeId.values) id: jsonEncode(build(id, all))};
    expect(styles.values.toSet().length, 4);
    final idsOf = {
      for (final e in styles.entries) e.key: [for (final l in (jsonDecode(e.value)['layers'] as List)) l['id']]
    };
    expect(idsOf.values.map((v) => v.join(',')).toSet().length, 1);
  });

  test('without a base map there is still a background, the route and pin layers and the position layers', () {
    final style = build(CacheThemeId.dark, [StyleLayerUse(defs.firstWhere((d) => d.id == 'hillshade'))]);
    final ids = [for (final l in style['layers'] as List) (l as Map)['id']];
    expect(ids, ['background', 'hillshade-shade', kRouteAlt, kRouteCasing, kRouteRoad, kRouteFollow, kRouteOffroad, kPinResults, kPinSelected, kPositionAccuracyFill, kPositionAccuracyLine, kPositionDot, kPositionHeading]);
  });

  test('overlays are drawn between the base map\'s roads and labels, contour labels on top', () {
    final style = build(CacheThemeId.light, all);
    final ids = [for (final l in style['layers'] as List) (l as Map)['id'] as String];
    expect(ids.indexOf('hillshade-shade'), lessThan(ids.indexOf('road_motorway')));
    expect(ids.indexOf('usfs-trails-roads-trails-line'), greaterThan(ids.indexOf('road_motorway')));
    expect(ids.indexOf('usfs-trails-roads-trails-line'), lessThan(ids.indexOf('label_city')));
    expect(ids.indexOf('contours-label'), greaterThan(ids.indexOf('label_city')));
    // Land fills of public lands sit under trails.
    expect(ids.indexOf('public-lands-idaho-fill'), lessThan(ids.indexOf('usfs-trails-roads-trails-line')));
  });

  test('contour labels read in feet', () {
    final style = build(CacheThemeId.light, all);
    final label = (style['layers'] as List).cast<Map>().firstWhere((l) => l['id'] == 'contours-label');
    final field = jsonEncode(label['layout']['text-field']);
    expect(field, contains('3.28084'));
    expect(field, contains('ft'));
  });

  test('opacity multiplies colour alpha for hillshade and sets raster opacity', () {
    final style = build(CacheThemeId.light, [
      StyleLayerUse(defs.firstWhere((d) => d.id == 'hillshade'), 0.5),
      StyleLayerUse(defs.firstWhere((d) => d.id == 'satellite'), 0.4),
    ]);
    final layers = (style['layers'] as List).cast<Map>();
    expect(layers.firstWhere((l) => l['id'] == 'satellite-raster')['paint']['raster-opacity'], 0.4);
    expect(layers.firstWhere((l) => l['id'] == 'hillshade-shade')['paint']['hillshade-shadow-color'], startsWith('rgba('));
  });

  test('sources carry their attribution, the base map\'s first', () {
    final style = build(CacheThemeId.light, all);
    final sources = style['sources'] as Map<String, dynamic>;
    expect(sources['src-openfreemap']['attribution'], contains('OpenFreeMap'));
    expect(sources['src-openfreemap']['attribution'], contains('OpenStreetMap'));
    expect(sources['src-hillshade']['attribution'], contains('Mapterhorn'));
    expect(sources['src-hillshade']['encoding'], 'terrarium');
  });

  test('a layer definition survives an edit round trip, keeping fields the app does not know', () {
    final d = LayerDef.fromJson({...fakeCatalogue.first, 'future_field': {'a': 1}});
    final back = LayerDef.parse(d.prettyJson());
    expect(back.raw['future_field'], {'a': 1});
    expect(back.id, d.id);
    expect(() => LayerDef.parse('{"id":"Bad Id","title":"x"}'), throwsFormatException);
  });

  group('the Protomaps v4 layout', () {
    test('a definition picks its layout from its layout field', () {
      expect(MapLayout.parse(protomaps.raw['layout']), MapLayout.protomapsV4);
      expect(MapLayout.parse(openFreeMap.raw['layout']), MapLayout.openMapTiles);
      expect(MapLayout.parse(null), MapLayout.openMapTiles);
      expect(protomaps.layout, 'protomaps-v4');
      expect(openFreeMap.layout, 'openmaptiles');
    });

    test('the template comes from the package and every placeholder in it has a palette colour', () {
      final used = RegExp(r'"@([\w.]+)"').allMatches(jsonEncode(pmTemplate)).map((m) => m.group(1)!).toSet();
      expect(used.length, greaterThan(60));
      for (final id in CacheThemeId.values) {
        final flavor = protomapsFlavor(mapPaletteFor(id));
        expect(flavor.keys.toSet().containsAll(used), isTrue, reason: '${id.name}: ${used.difference(flavor.keys.toSet())}');
      }
      // The layers that need the sprite sheet are not in the template.
      final ids = [for (final l in pmTemplate['layers'] as List) (l as Map)['id']];
      expect(ids, isNot(contains('pois')));
      expect(ids, isNot(contains('roads_shields')));
      expect(jsonEncode(pmTemplate), isNot(contains('icon-image')));
    });

    for (final id in CacheThemeId.values) {
      group('style for ${id.name}', () {
        late Map<String, dynamic> style;
        setUp(() => style = build(id, withBase(protomaps)));

        test('is a valid style with every expected layer id', () {
          expect(style['version'], 8);
          final layers = (style['layers'] as List).cast<Map<String, dynamic>>();
          final ids = [for (final l in layers) l['id'] as String];
          expect(ids.toSet().length, ids.length, reason: 'layer ids must be unique');
          expect(ids, unorderedEquals(expectedLayerIds(template, withBase(protomaps), protomapsTemplate: pmTemplate)));
          for (final must in ['background', 'earth', 'water', 'roads_highway', 'buildings', 'places_locality', 'hillshade-shade', 'contours-label', kPositionDot]) {
            expect(ids, contains(must));
          }
          final sources = style['sources'] as Map<String, dynamic>;
          expect(sources, contains('src-basemap'));
          expect(sources, isNot(contains('src-openfreemap')));
          expect(sources['src-basemap']['attribution'], contains('Protomaps'));
          for (final l in layers) {
            if (l.containsKey('source')) expect(sources, contains(l['source']), reason: l['id'] as String);
          }
        });

        test('has no unfilled placeholders and only valid colours', () {
          expect(jsonEncode(style), isNot(contains('"@')));
          final found = colours(style['layers']).toList();
          expect(found, isNotEmpty);
          for (final c in found) {
            expect(c, matches(_colour), reason: c);
          }
        });

        test('takes its colours from its own palette', () {
          final p = mapPaletteFor(id);
          final layers = (style['layers'] as List).cast<Map<String, dynamic>>();
          expect(layers.firstWhere((l) => l['id'] == 'background')['paint']['background-color'], p.css('land'));
          expect(layers.firstWhere((l) => l['id'] == 'water')['paint']['fill-color'], p.css('water'));
          expect(layers.firstWhere((l) => l['id'] == 'mvum-mvum_roads-line')['paint']['line-color'], p.css('mvum'));
        });

        test('uses the fonts that ship with the app and no sprite', () {
          final text = jsonEncode(style['layers']);
          expect(text, contains('NotoSans-Regular'));
          expect(text, isNot(contains('"Noto Sans Regular"')));
          expect(style.containsKey('sprite'), isFalse);
        });

        test('overlays sit between the roads and the labels, contour labels on top', () {
          final ids = [for (final l in style['layers'] as List) (l as Map)['id'] as String];
          expect(ids.indexOf('hillshade-shade'), lessThan(ids.indexOf('roads_tunnels_other_casing')));
          expect(ids.indexOf('usfs-trails-roads-trails-line'), greaterThan(ids.indexOf('roads_highway')));
          expect(ids.indexOf('usfs-trails-roads-trails-line'), lessThan(ids.indexOf('address_label')));
          expect(ids.indexOf('contours-label'), greaterThan(ids.indexOf('places_country')));
        });
      });
    }

    test('both layouts are drawn from the same palette: same water and land colours', () {
      for (final id in CacheThemeId.values) {
        final a = build(id, withBase(openFreeMap));
        final b = build(id, withBase(protomaps));
        Object? paint(Map<String, dynamic> st, String layer, String prop) =>
            ((st['layers'] as List).cast<Map>().firstWhere((l) => l['id'] == layer)['paint'] as Map)[prop];
        expect(paint(b, 'water', 'fill-color'), paint(a, 'water', 'fill-color'), reason: id.name);
        expect(paint(b, 'background', 'background-color'), paint(a, 'background', 'background-color'), reason: id.name);
      }
    });

    test('a Protomaps base map without its template is refused, not drawn wrong', () {
      expect(
        () => buildMapStyle(
          palette: mapPaletteFor(CacheThemeId.dark),
          omtTemplate: template,
          layers: [StyleLayerUse(protomaps)],
          tilesUrl: (d) => 'x',
          glyphsUrl: 'g',
        ),
        throwsArgumentError,
      );
    });
  });

  group('the published catalogue\'s own schema', () {
    LayerDef def(String id) => defs.firstWhere((d) => d.id == id);

    test('a published definition is read: licence, coverage box, zoom range, source layers, colour family', () {
      final b = def('blm-routes');
      expect(b.kind, LayerKind.vector);
      expect(b.licence, contains('as is'));
      expect(b.minZoom, 6);
      expect(b.maxZoom, 14);
      expect(b.sourceUrl, endsWith('.pmtiles'));
      expect(b.sourceType, 'pmtiles');
      expect(b.sourceLayers, ['blm_routes']);
      expect(b.styleRole, 'blm');
      expect(b.onlineOnly, isFalse);
      expect(def('mvum').sourceLayers, ['mvum_roads', 'mvum_trails']);
      expect(def('mvum').styleRole, 'mvum');
      expect(def('usfs-trails-roads').styleRole, 'trail');
      expect(def('public-lands-idaho').styleRole, 'public_lands');
      expect(def('blm-routes-idaho').coverage, contains('N'));
      expect(def('blm-routes-idaho').coverageBox!.west, -118.0);
      expect(def('blm-routes').coverageSize, greaterThan(def('blm-routes-idaho').coverageSize));
    });

    test('cuts of one layer for regions share a group; a layer with no box covers everywhere', () {
      expect(def('blm-routes').groupKey, def('blm-routes-idaho').groupKey);
      expect(def('mvum').groupKey, isNot(def('blm-routes').groupKey));
      expect(def('hillshade').covers(const GeoBounds(south: -80, west: -170, north: 80, east: 170)), isTrue);
      expect(def('blm-routes-idaho').covers(const GeoBounds(south: 42.5, west: -113.8, north: 42.6, east: -113.6)), isTrue);
      expect(def('blm-routes-idaho').covers(const GeoBounds(south: 39, west: -105, north: 39.1, east: -104.9)), isFalse);
    });

    test('a definition says whether it is on by default', () {
      expect(def('basemap').enabledByDefault, isTrue);
      expect(def('basemap').defaultOn, isTrue);
      expect(def('openfreemap').enabledByDefault, isFalse);
      expect(def('basemap').layout, 'protomaps-v4');
      expect(def('openfreemap').layout, 'openmaptiles');
    });

    test('a definition with several tile layers draws each, with ids that cannot collide', () {
      final style = build(CacheThemeId.light, withBase(openFreeMap));
      final ids = [for (final l in style['layers'] as List) (l as Map)['id'] as String];
      expect(ids, containsAll(['mvum-mvum_roads-line', 'mvum-mvum_trails-line', 'mvum-idaho-mvum_roads-fill', 'blm-routes-idaho-line']));
      expect(ids.toSet().length, ids.length);
      // Areas are told from routes by the geometry of each feature, so the definition needs no geometry field.
      final fill = (style['layers'] as List).cast<Map>().firstWhere((l) => l['id'] == 'public-lands-idaho-fill');
      expect(fill['filter'], ['==', ['geometry-type'], 'Polygon']);
    });
  });

  test('every map asset the app loads is declared in pubspec.yaml (tests read the files directly and would not notice)', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final f in ['assets/map/omt_template.json', 'assets/map/protomaps_v4_template.json', 'assets/map/fonts/NotoSans-Regular/', 'assets/map/fonts/NotoSans-Bold/', 'assets/map/fonts/NotoSans-Italic/']) {
      expect(pubspec, contains('- $f'), reason: f);
    }
  });

  test('the published base map entry draws in the Protomaps layout in all four themes', () {
    final entry = (jsonDecode(File('test/fixtures/catalogue_basemap.json').readAsStringSync()) as Map)['layers'][0] as Map;
    final base = LayerDef.fromJson(Map<String, dynamic>.from(entry));
    for (final id in CacheThemeId.values) {
      final style = build(id, [StyleLayerUse(base)]);
      final ids = [for (final l in style['layers'] as List) (l as Map)['id'] as String];
      expect(ids, containsAll(['earth', 'water', 'roads_highway', 'buildings', 'places_locality']), reason: id.name);
      expect((style['sources'] as Map)['src-basemap']['maxzoom'], 15);
      expect((style['sources'] as Map)['src-basemap']['tiles'][0], contains('/layers/basemap/'));
    }
  });
}
