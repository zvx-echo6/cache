import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/maps/style/protomaps_layout.dart';
import 'package:cache/maps/style/style_generator.dart';
import 'package:cache/notebook/pin_image.dart' show PinStyle, pinIconSize;
import 'package:cache/roads/road_map_layers.dart';
import 'package:cache/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layer_fixtures.dart';

final _colour = RegExp(r'^(#[0-9a-f]{6}|rgba\(\d{1,3},\d{1,3},\d{1,3},(0|1|0?\.\d+)\))$');

void main() {
  final template = jsonDecode(File('assets/map/omt_template.json').readAsStringSync()) as Map<String, dynamic>;
  final pmTemplate = jsonDecode(File('assets/map/protomaps_v4_template.json').readAsStringSync()) as Map<String, dynamic>;
  // The app's bundled definitions plus a copy of the published catalogue (test/fixtures/catalogue.json), which is
  // what the engine merges at run time. Every kind of layer is in there.
  final published = (jsonDecode(File('test/fixtures/catalogue.json').readAsStringSync()) as Map)['layers'] as List;
  final defs = [
    for (final j in [...testCatalogue, ...published]) LayerDef.fromJson(Map<String, dynamic>.from(j as Map)),
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

  group('icons and town names: the icons take part in collision and the names win', () {
    bool on(Object? v) => v == true;
    Map<String, dynamic> layer(Map<String, dynamic> style, String id) => ((style['layers'] as List).cast<Map<String, dynamic>>()).firstWhere((l) => l['id'] == id);
    int at(Map<String, dynamic> style, String id) => (style['layers'] as List).indexWhere((l) => (l as Map)['id'] == id);

    for (final (name, base, firstName) in [('Protomaps', protomaps, 'places_subplace'), ('OpenMapTiles', openFreeMap, 'label_other')]) {
      for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
        test('$name, ${theme.name}: road-event icons and repeater icons collide, with padding, and sit under the place names', () {
          final style = buildMapStyle(
            palette: mapPaletteFor(theme),
            omtTemplate: template,
            protomapsTemplate: pmTemplate,
            layers: withBase(base),
            tilesUrl: (d) => 'http://127.0.0.1:9/layers/${d.id}/{z}/{x}/{y}',
            glyphsUrl: 'file:///fonts/{fontstack}/{range}.pbf',
            pinStyle: PinStyle.icon,
          );
          for (final id in [kRoadEventChips, kUserRepeaters]) {
            final l = layer(style, id)['layout'] as Map<String, dynamic>;
            expect(on(l['icon-allow-overlap']), isFalse, reason: '$id takes part in collision');
            expect(on(l['icon-ignore-placement']), isFalse, reason: '$id is placed, so others make way for it');
            expect(l['icon-padding'], 2, reason: '$id: near-touching icons separate');
            expect(at(style, id), lessThan(at(style, firstName)), reason: '$id is under the place names, so a town name wins the collision');
          }
          // Priority, first placed first: the place names, then the repeaters, then the road events, then the public places' chips.
          if (name == 'Protomaps') {
            expect(at(style, kUserRepeaters), greaterThan(at(style, kRoadEventChips)));
            expect(at(style, kRoadEventChips), greaterThan(at(style, 'pois')));
          }
          // The markers of grouped icons: always drawn, never smaller than 0.75, right above the repeaters.
          final m = layer(style, kStackMarkers)['layout'] as Map<String, dynamic>;
          expect(on(m['icon-allow-overlap']), isTrue);
          expect(on(m['icon-ignore-placement']), isTrue);
          expect(at(style, kStackMarkers), at(style, kUserRepeaters) + 1);
          final size = (m['icon-size'] as List).skip(3).toList();
          for (var i = 1; i < size.length; i += 2) {
            expect((size[i] as num) * (1 / pinIconSize()), greaterThanOrEqualTo(0.75 - 1e-9), reason: 'a marker is never smaller than 0.75');
          }
          expect((style['sources'] as Map).containsKey(kStackSource), isTrue);
          // The person's own pins and the route, destination and position markers are always drawn.
          for (final id in [kNotebookPins, kPinSelectedIcon, kPinResultsIcon, kRouteTime, kPositionHeading]) {
            final l = layer(style, id)['layout'] as Map<String, dynamic>;
            expect(on(l['icon-allow-overlap']), isTrue, reason: '$id stays visible');
            expect(on(l['icon-ignore-placement']), isTrue, reason: '$id hides nothing');
          }
        });
      }
    }
  });

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
        // The roles the publisher writes (blm_routes, trails) draw in their own colours and dashes, not the default line.
        final blm = layers.firstWhere((l) => l['id'] == 'blm-routes-line');
        expect(blm['paint']['line-color'], p.css('blm'));
        expect(blm['paint']['line-dasharray'], [4.0, 2.0]);
        expect(layers.firstWhere((l) => l['id'] == 'usfs-trails-roads-trails-line')['paint']['line-color'], p.css('trail'));
        expect(layers.firstWhere((l) => l['id'] == 'contours-label')['paint']['text-color'], p.css('contourLabel'));
      });
    });
  }

  test('the other routes are the route colour at 40% opacity and thinner than the chosen route, under it; each route has a time label layer', () {
    for (final id in CacheThemeId.values) {
      final palette = mapPaletteFor(id);
      final layers = {for (final l in build(id, all)['layers'] as List) (l as Map)['id'] as String: l};
      final alt = layers[kRouteAlt]!['paint'] as Map;
      expect(alt['line-color'], palette.css('route'), reason: '$id: the route colour, not the grey of routeAlternate');
      expect(alt['line-color'], isNot(palette.css('routeAlternate')));
      expect(alt['line-opacity'], 0.4);
      final road = layers[kRouteRoad]!['paint'] as Map;
      expect(alt['line-width'] as num, lessThan(road['line-width'] as num), reason: 'thinner than the chosen route');
      final order = (build(id, all)['layers'] as List).map((l) => (l as Map)['id']).toList();
      expect(order.indexOf(kRouteAlt), lessThan(order.indexOf(kRouteCasing)), reason: 'under the chosen route\'s casing');
      final time = layers[kRouteTime]!;
      expect(time['type'], 'symbol');
      expect((time['layout'] as Map)['icon-image'], ['get', 'img']);
      expect((time['layout'] as Map)['symbol-sort-key'], isNotNull, reason: 'the chosen route\'s label is drawn on top');
      expect(order.indexOf(kRouteTime), greaterThan(order.indexOf(kRouteOffroad)));
    }
  });

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
    expect(ids, ['background', 'hillshade-shade', kAreaFill, kAreaCasing, kAreaLine, kRoadEventCasing, kRoadEventClosure, kRoadEventWork, kRoadEventDetour, kRoadEventSelected, kRoadEventChips, kRouteAlt, kRouteCasing, kRouteRoad, kRouteFollow, kRouteOffroad, kRouteTime, kUserAreas, kUserLines, kUserRepeaters, kNotebookPins, kMeasureLine, kMeasurePoints, kPinResults, kPinSelected, kPositionAccuracyFill, kPositionAccuracyLine, kPositionDot, kPositionHeading]);
  });

  test('a tapped area\'s outline is above the roads and buildings and under the labels (Protomaps layout)', () {
    final ids = [for (final l in build(CacheThemeId.light, withBase(protomaps))['layers'] as List) (l as Map)['id'] as String];
    expect(ids.indexOf(kAreaFill), lessThan(ids.indexOf(kAreaCasing)));
    expect(ids.indexOf(kAreaCasing), lessThan(ids.indexOf(kAreaLine)));
    expect(ids.indexOf(kAreaFill), greaterThan(ids.indexOf('roads_major')));
    expect(ids.indexOf(kAreaLine), lessThan(ids.indexOf('address_label')));
    expect(ids.indexOf(kAreaLine), lessThan(ids.indexOf('places_locality')), reason: '"Twin Falls" stays readable');
    final layers = {for (final l in build(CacheThemeId.tactical, withBase(protomaps))['layers'] as List) (l as Map)['id']: l};
    final p = mapPaletteFor(CacheThemeId.tactical);
    expect((layers[kAreaLine] as Map)['paint']['line-color'], p.css('pin'));
    expect((layers[kAreaCasing] as Map)['paint']['line-color'], p.css('routeCasing'));
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

  test('contour labels read in feet, as the core\'s contour tiles already give them', () {
    final style = build(CacheThemeId.light, all);
    final label = (style['layers'] as List).cast<Map>().firstWhere((l) => l['id'] == 'contours-label');
    final field = jsonEncode(label['layout']['text-field']);
    expect(field, isNot(contains('3.28084')), reason: 'ele is feet in the tiles; nothing converts it');
    expect(field, contains('"ele"'));
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
    final d = LayerDef.fromJson({...testCatalogue.first, 'future_field': {'a': 1}});
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
      expect(b.styleRole, 'blm_routes');
      expect(b.onlineOnly, isFalse);
      expect(def('mvum').sourceLayers, ['mvum_roads', 'mvum_trails']);
      expect(def('mvum').styleRole, 'mvum');
      expect(def('usfs-trails-roads').styleRole, 'trails');
      expect(def('public-lands-idaho').styleRole, 'public_lands');
      // One vocabulary: every role the published catalogue states is one the style generator draws.
      for (final d in defs) {
        if (d.kind == LayerKind.vector && d.styleRole.isNotEmpty) expect(kStyleRoles, contains(d.styleRole), reason: d.id);
      }
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
