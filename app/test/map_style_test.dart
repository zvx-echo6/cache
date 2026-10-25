import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/layers/fake_catalogue.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/maps/style/style_generator.dart';
import 'package:cache/theme.dart';
import 'package:flutter_test/flutter_test.dart';

final _colour = RegExp(r'^(#[0-9a-f]{6}|rgba\(\d{1,3},\d{1,3},\d{1,3},(0|1|0?\.\d+)\))$');

void main() {
  final template = jsonDecode(File('assets/map/omt_template.json').readAsStringSync()) as Map<String, dynamic>;
  final defs = [for (final j in fakeCatalogue) LayerDef.fromJson(Map<String, dynamic>.from(j))];
  // Every kind of layer on at once, at 70 % for the overlays.
  final all = [for (final d in defs) StyleLayerUse(d, d.isBase ? 1 : 0.7)];

  Map<String, dynamic> build(CacheThemeId id, List<StyleLayerUse> uses) => buildMapStyle(
        palette: mapPaletteFor(id),
        omtTemplate: template,
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
        for (final must in ['background', 'water', 'road_motorway', 'building', 'label_city', 'hillshade', 'contours-label', 'public_lands-fill', 'fs_trails-line', 'mvum-line', 'blm-line', 'landcover', 'satellite', kPositionDot, kPositionAccuracyFill, kPositionHeading]) {
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
        expect(layers.firstWhere((l) => l['id'] == 'mvum-line')['paint']['line-color'], p.css('mvum'));
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

  test('without a base map there is still a background and the position layers', () {
    final style = build(CacheThemeId.dark, [StyleLayerUse(defs.firstWhere((d) => d.id == 'hillshade'))]);
    final ids = [for (final l in style['layers'] as List) (l as Map)['id']];
    expect(ids, ['background', 'hillshade', kPositionAccuracyFill, kPositionAccuracyLine, kPositionDot, kPositionHeading]);
  });

  test('overlays are drawn between the base map\'s roads and labels, contour labels on top', () {
    final style = build(CacheThemeId.light, all);
    final ids = [for (final l in style['layers'] as List) (l as Map)['id'] as String];
    expect(ids.indexOf('hillshade'), lessThan(ids.indexOf('road_motorway')));
    expect(ids.indexOf('fs_trails-line'), greaterThan(ids.indexOf('road_motorway')));
    expect(ids.indexOf('fs_trails-line'), lessThan(ids.indexOf('label_city')));
    expect(ids.indexOf('contours-label'), greaterThan(ids.indexOf('label_city')));
    // Land fills of public lands sit under trails.
    expect(ids.indexOf('public_lands-fill'), lessThan(ids.indexOf('fs_trails-line')));
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
    expect(layers.firstWhere((l) => l['id'] == 'satellite')['paint']['raster-opacity'], 0.4);
    expect(layers.firstWhere((l) => l['id'] == 'hillshade')['paint']['hillshade-shadow-color'], startsWith('rgba('));
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
}
