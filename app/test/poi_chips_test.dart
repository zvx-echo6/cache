import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/maps/poi_chips.dart';
import 'package:cache/maps/style/protomaps_layout.dart';
import 'package:cache/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final pmTemplate = jsonDecode(File('assets/map/protomaps_v4_template.json').readAsStringSync()) as Map<String, dynamic>;

  group('the public-place table', () {
    test('has the 22 icons in 9 groups, each kind once, each icon an image name of its own', () {
      expect(poiIcons.length, 22);
      expect({for (final i in poiIcons) i.group}.length, 9);
      expect({for (final i in poiIcons) i.group}, poiGroupRoles.toSet());
      expect(poiIcons.map((i) => i.id).toSet().length, 22);
      expect(poiKinds.toSet().length, poiKinds.length, reason: 'a kind is drawn by one icon only');
    });

    test('leaves out churches, schools, banks and civic buildings', () {
      for (final k in ['place_of_worship', 'church', 'school', 'bank', 'townhall', 'courthouse', 'post_office', 'library', 'kindergarten']) {
        expect(poiKinds, isNot(contains(k)));
      }
    });

    test('the emergency kinds are the medical and safety groups, and the early kinds are drawn kinds', () {
      for (final k in ['hospital', 'clinic', 'pharmacy', 'police', 'fire_station']) {
        expect(poiPriorityKinds, contains(k));
      }
      expect(poiPriorityKinds, isNot(contains('restaurant')));
      for (final k in poiEarlyKinds) {
        expect(poiKinds, contains(k));
      }
    });
  });

  group('colours', () {
    test('every theme defines the nine group colours', () {
      for (final id in CacheThemeId.values) {
        final p = mapPaletteFor(id);
        for (final r in poiGroupRoles) {
          expect(p.has(r), isTrue, reason: '${id.name} lacks $r');
          expect(MapPalette.roleNames, contains(r));
        }
      }
    });

    test('tactical is one red for every group, so only the glyph tells chips apart; the others differ by group', () {
      final t = mapPaletteFor(CacheThemeId.tactical);
      expect({for (final r in poiGroupRoles) t[r].toARGB32()}.length, 1);
      final looks = [for (final r in poiGroupRoles) poiChipLook(t, r)];
      for (final l in looks) {
        expect(l.fill, const ui.Color(0xFF160505));
        expect(l.ring, l.glyph);
        expect(l.ring.toARGB32(), t[poiFuel].toARGB32());
      }
      for (final id in [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.parchment]) {
        final p = mapPaletteFor(id);
        expect({for (final r in poiGroupRoles) p[r].toARGB32()}.length, 9, reason: id.name);
      }
    });
  });

  group('the style layer', () {
    for (final id in CacheThemeId.values) {
      test('${id.name}: one symbol layer on the pois source layer, a chip per kind, names optional, emergencies first', () {
        final layers = protomapsLayers(mapPaletteFor(id), pmTemplate, 'src');
        final ids = [for (final l in layers) l['id'] as String];
        expect(ids, containsAll(poiLayerIds));
        expect(ids.indexOf('pois'), lessThan(ids.indexOf('places_subplace')), reason: 'a town name wins a collision with a chip');
        expect(ids.indexOf('pois'), greaterThan(ids.indexOf('roads_labels_major')), reason: 'above the road labels');
        final l = layers.firstWhere((l) => l['id'] == 'pois');
        expect(l['source-layer'], 'pois');
        expect(l['type'], 'symbol');
        final layout = l['layout'] as Map;
        expect(layout['text-optional'], isTrue);
        final match = jsonEncode(layout['icon-image']);
        for (final i in poiIcons) {
          for (final k in i.kinds) {
            expect(match, contains('"$k"'));
          }
          expect(match, contains('"${i.image}"'));
        }
        expect(jsonEncode(layout['symbol-sort-key']), contains('"hospital"'));
        // The filter: a drawn kind whose min_zoom (two less for the early kinds) has been reached.
        final filter = jsonEncode(l['filter']);
        expect(filter, contains('"zoom"'));
        expect(filter, contains('"fuel"'));
        expect(jsonEncode(l['paint']), isNot(contains('"@')));
      });
    }

    test('the filter set after the chips is a different filter with the same meaning, so the tiles are laid out again', () {
      expect(jsonEncode(poiFilterAfterChips()), isNot(jsonEncode(poiFilter())));
      expect(jsonEncode(poiFilterAfterChips()), contains(jsonEncode(poiFilter())));
    });

    test('a browser draws the images three times as big, so the layer draws them a third of the size', () {
      final phone = protomapsLayers(mapPaletteFor(CacheThemeId.light), pmTemplate, 's').firstWhere((l) => l['id'] == 'pois');
      final web = protomapsLayers(mapPaletteFor(CacheThemeId.light), pmTemplate, 's', poiIconScale: 1 / 3).firstWhere((l) => l['id'] == 'pois');
      final a = (phone['layout'] as Map)['icon-size'] as List, b = (web['layout'] as Map)['icon-size'] as List;
      expect(a.last, closeTo(1.0, 1e-9));
      expect((b.last as num) * 3, closeTo(1.0, 1e-9));
    });
  });

  group('the chip image', () {
    int width(Uint8List png) => ByteData.sublistView(png).getUint32(16);
    int height(Uint8List png) => ByteData.sublistView(png).getUint32(20);

    testWidgets('is 24 points square at the screen scale, a disc in the centre and clear corners', (tester) async {
      await tester.runAsync(() async {
        for (final ratio in [2.0, 2.625, 3.0]) {
          final png = await renderPoiChipPng(poiIcons.first, mapPaletteFor(CacheThemeId.light), ratio: ratio);
          expect(width(png), (24 * ratio).round());
          expect(height(png), (24 * ratio).round());
        }
        final codec = await ui.instantiateImageCodec(await renderPoiChipPng(poiIcons[3], mapPaletteFor(CacheThemeId.light), ratio: 3));
        final img = (await codec.getNextFrame()).image;
        final bytes = (await img.toByteData())!;
        int a(int x, int y) => bytes.getUint8((y * img.width + x) * 4 + 3);
        expect(a(0, 0), 0, reason: 'the corner is clear: the chip is round');
        expect(a(36, 8), greaterThan(200), reason: 'inside the edge ring at the top of the disc');
      });
    });

    testWidgets('every theme draws every chip, and the themes draw them differently', (tester) async {
      await tester.runAsync(() async {
        final seen = <String, Uint8List>{};
        for (final id in CacheThemeId.values) {
          final names = <String>[];
          await addPoiChips((n, png) async {
            names.add(n);
            expect(png.length, greaterThan(100));
          }, mapPaletteFor(id), ratio: 3);
          expect(names, [for (final i in poiIcons) i.image]);
          seen[id.name] = await renderPoiChipPng(poiIcons[1], mapPaletteFor(id), ratio: 3);
        }
        expect({for (final b in seen.values) base64Encode(b)}.length, 4);
      });
    });

    testWidgets('one chip failing to add does not stop the others', (tester) async {
      await tester.runAsync(() async {
        var n = 0;
        await addPoiChips((name, png) async {
          n++;
          if (n == 2) throw StateError('no');
        }, mapPaletteFor(CacheThemeId.dark), ratio: 3);
        expect(n, 23, reason: 'the failed chip is tried once more, so the others still come');
      });
    });

    testWidgets('a chip that fails twice is logged and its kind gets the plain dot; no kind is left without an image', (tester) async {
      await tester.runAsync(() async {
        final added = <String, Uint8List>{}, log = <String>[];
        var fuelTries = 0;
        await addPoiChips((name, png) async => added[name] = png, mapPaletteFor(CacheThemeId.light), ratio: 3, log: log.add,
            render: (icon, p, {double ratio = 3, bool dot = false}) {
          if (icon.id == 'fuel' && !dot) {
            fuelTries++;
            throw StateError('no glyph');
          }
          return renderPoiChipPng(icon, p, ratio: ratio, dot: dot);
        });
        expect(fuelTries, 2, reason: 'tried, then once more');
        expect(added.keys.toSet(), {for (final i in poiIcons) i.image}, reason: 'every kind has an image');
        final full = await renderPoiChipPng(poiIcons.first, mapPaletteFor(CacheThemeId.light), ratio: 3);
        expect(added['poi-fuel'], isNot(full), reason: 'the dot is not the chip');
        expect(log.where((l) => l.contains('poi-fuel')).length, 3, reason: 'two failures and the dot, logged');
      });
    });

    testWidgets('a chip that fails once is retried and gets its own chip, not the dot', (tester) async {
      await tester.runAsync(() async {
        final added = <String, Uint8List>{};
        var tries = 0;
        await addPoiChips((name, png) async => added[name] = png, mapPaletteFor(CacheThemeId.light), ratio: 3,
            render: (icon, p, {double ratio = 3, bool dot = false}) {
          if (icon.id == 'food' && !dot && ++tries == 1) throw StateError('once');
          return renderPoiChipPng(icon, p, ratio: ratio, dot: dot);
        });
        expect(added['poi-food'], await renderPoiChipPng(poiIcons.firstWhere((i) => i.id == 'food'), mapPaletteFor(CacheThemeId.light), ratio: 3));
      });
    });

    testWidgets('the POI layer is hidden until every chip is in, laid out again, then shown; and shown even when a step throws', (tester) async {
      await tester.runAsync(() async {
        final events = <String>[];
        await installPoiChips(
          add: (n, png) async => events.add('image:$n'),
          setVisible: (v) async => events.add('visible:$v'),
          relayout: () async => events.add('relayout'),
          palette: mapPaletteFor(CacheThemeId.dark),
          ratio: 3,
        );
        expect(events.first, 'visible:false');
        expect(events.sublist(1, 23), [for (final i in poiIcons) 'image:${i.image}']);
        expect(events.sublist(23), ['relayout', 'visible:true']);
        final after = <String>[];
        await installPoiChips(
          add: (n, png) async {},
          setVisible: (v) async => after.add('visible:$v'),
          relayout: () async => throw StateError('no layer'),
          palette: mapPaletteFor(CacheThemeId.dark),
          ratio: 3,
        );
        expect(after, ['visible:false', 'visible:true']);
      });
    });
  });
}
