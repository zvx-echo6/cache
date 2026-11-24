// Map icon style C: on the light and Parchment themes the Icon pins and the public-place chips are flat discs (a solid disc in the
// colour, the glyph on it, a faint 1 pixel edge, no white halo or ring); the dark and Tactical themes draw exactly what they did. The
// image names carry the look, and the icons are drawn smaller zoomed out. Every colour and name here is made up.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/maps/poi_chips.dart';
import 'package:cache/maps/style/protomaps_layout.dart';
import 'package:cache/maps/style/style_generator.dart';
import 'package:cache/notebook/notebook_map.dart' show repeaterPinName;
import 'package:cache/notebook/pin_image.dart';
import 'package:cache/theme.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String _hash(List<int> b) => sha1.convert(b).toString();

Future<({int w, int h, ByteData px})> _decode(List<int> png) async {
  final codec = await ui.instantiateImageCodec(png is Uint8List ? png : Uint8List.fromList(png));
  final img = (await codec.getNextFrame()).image;
  return (w: img.width, h: img.height, px: (await img.toByteData())!);
}

List<int> _rgba(({int w, int h, ByteData px}) i, int x, int y) => [for (var k = 0; k < 4; k++) i.px.getUint8((y * i.w + x) * 4 + k)];

void main() {
  const purple = Color(0xFFAE86F0), yellow = Color(0xFFE6C24E), sand = Color(0xFFD8C7A0);

  group('what dark and Tactical draw is what they always drew (byte for byte)', () {
    // Hashes of the PNGs of the code before this change (origin c27202ab): Icon, Teardrop and Badge pins, and the fuel chip and its dot.
    const pins = {
      'dark-purple': ['e89f9239ed75dd10e0f0e6b17900d942b6c12b65', '28452d9162de116012b6ee8bd3005829b3f69d07', '0e0e354ba2e9300dcd59c3510a580344af8c5ea4'],
      'dark-yellow': ['e1b7ac6a7bf8d9f9427fc43719a0ddd93a97a18d', '66adc5abf5342954ea1a13c5f54c442eef5d2402', '09584c8681887b0733506d32a1ee2cc31967c87c'],
      'tactical': ['142421c8c5b1dd2caa8165fa83b2c693d23e606f', 'aa0a2bc329a0fe179ff846994f9401a174c0b577', '16eff4e6206cfc3e918a9bcadf0c40930d24f74a'],
    };
    testWidgets('pins: Icon, Teardrop and Badge in dark and Tactical', (tester) async {
      await tester.runAsync(() async {
        for (final e in pins.entries) {
          final tint = e.key == 'dark-yellow' ? yellow : (e.key == 'tactical' ? const Color(0xFFFF2D1F) : purple);
          for (final (i, style) in PinStyle.values.indexed) {
            expect(_hash(await renderPinPng(Icons.place, tint, style, ratio: 3, tactical: e.key == 'tactical')), e.value[i], reason: '${e.key} ${style.name}');
          }
        }
      });
    });

    testWidgets('chips: dark and Tactical, with their ring', (tester) async {
      await tester.runAsync(() async {
        expect(_hash(await renderPoiChipPng(poiIcons.first, mapPaletteFor(CacheThemeId.dark), ratio: 3)), '3c756238a29b6c32963bceb506385110c503b3ce');
        expect(_hash(await renderPoiChipPng(poiIcons.first, mapPaletteFor(CacheThemeId.tactical), ratio: 3)), 'e5531141a4e6cd7252b14da7df06a80892193493');
        expect(_hash(await renderPoiChipPng(poiIcons.first, mapPaletteFor(CacheThemeId.dark), ratio: 3, dot: true)), '8b71a74d4f82ad93f841201ce9345a5727ab0f8a');
        expect(_hash(await renderPoiChipPng(poiIcons.first, mapPaletteFor(CacheThemeId.tactical), ratio: 3, dot: true)), '3aa1b06f07b5a22efc28f2cbc26850fff4f91921');
      });
    });

    testWidgets('Tactical is never flat: the flag changes nothing there, for every style', (tester) async {
      await tester.runAsync(() async {
        for (final style in PinStyle.values) {
          expect(_hash(await renderPinPng(Icons.place, purple, style, ratio: 3, flat: true, tactical: true)), _hash(await renderPinPng(Icons.place, purple, style, ratio: 3, tactical: true)), reason: style.name);
        }
      });
    });
  });

  group('the plain dropped pin and destination pin', () {
    // The code of e5271778, flat off: dark and Tactical are what they were.
    const plain = {
      'dark': ['7df7505915e084fc184adc580d913c8e548f07f9', 'a6d385aec45836002f00f9815027bada57f1a245', '7df7505915e084fc184adc580d913c8e548f07f9'],
      'tactical': ['d6f345d4e70c08d0cad93e1991324e30c8f59911', '751c46daf358a5ee7ac924baa1c8289f85425640', 'd6f345d4e70c08d0cad93e1991324e30c8f59911'],
    };
    testWidgets('dark and Tactical are byte for byte as they were', (tester) async {
      await tester.runAsync(() async {
        for (final e in plain.entries) {
          final tint = e.key == 'dark' ? const Color(0xFFFF6B5E) : const Color(0xFFFF2D1F);
          for (final (i, style) in PinStyle.values.indexed) {
            expect(_hash(await renderPlainPinPng(tint, style, ratio: 3, tactical: e.key == 'tactical')), e.value[i], reason: '${e.key} ${style.name}');
          }
        }
        expect(_hash(await renderPlainPinPng(const Color(0xFFFF2D1F), PinStyle.icon, ratio: 3, tactical: true, flat: true)), plain['tactical']![0], reason: 'Tactical is never flat');
      });
    });

    testWidgets('light and Parchment: no white ring, a faint edge, the same shape', (tester) async {
      await tester.runAsync(() async {
        for (final style in [PinStyle.icon, PinStyle.teardrop]) {
          final halo = await _decode(await renderPlainPinPng(const Color(0xFFFF6B5E), style, ratio: 3));
          final flat = await _decode(await renderPlainPinPng(const Color(0xFFFF6B5E), style, ratio: 3, flat: true));
          int rim(({int w, int h, ByteData px}) i) {
            var n = 0;
            for (var y = 1; y < i.h - 1; y++) {
              for (var x = 1; x < i.w - 1; x++) {
                final p = _rgba(i, x, y);
                if (!(p[3] > 200 && p[0] > 245 && p[1] > 245 && p[2] > 245)) continue;
                if (_rgba(i, x - 1, y)[3] < 200 || _rgba(i, x + 1, y)[3] < 200 || _rgba(i, x, y - 1)[3] < 200 || _rgba(i, x, y + 1)[3] < 200) n++;
              }
            }
            return n;
          }

          expect(rim(halo), greaterThan(30), reason: '${style.name}: the white ring is there today');
          expect(rim(flat), 0, reason: '${style.name}: no white ring');
          expect((flat.w, flat.h), (halo.w, halo.h));
        }
      });
    });

    test('the plain pin image of the flat look has its own name', () async {
      final names = <String>[];
      for (final flat in [false, true]) {
        final images = PinImages((n, png) async => names.add(n), PinStyle.icon, flat: flat, ratio: 3);
        await images.ensurePlain(const Color(0xFFFF6B5E));
      }
      expect(names, hasLength(2));
      expect(names.first, isNot(names.last));
      expect(names.last, contains('-f-'));
    });
  });

  group('the flat Icon pin (light and Parchment)', () {
    testWidgets('is a solid disc in the tint with no white halo, and a faint edge', (tester) async {
      await tester.runAsync(() async {
        for (final tint in [purple, yellow]) {
          final i = await _decode(await renderPinPng(Icons.place, tint, PinStyle.icon, ratio: 3, flat: true));
          final cx = i.w ~/ 2, cy = i.h ~/ 2;
          // The disc: 9/20 of the 30 point pin = 13.5 points = 40 pixels across from the middle.
          final inside = _rgba(i, cx + 30, cy), top = _rgba(i, cx, cy - 36);
          expect(inside.take(3).toList(), [tint.r * 255, tint.g * 255, tint.b * 255].map((v) => v.round()).toList(), reason: 'the disc is the tint');
          expect(inside[3], 255);
          expect(top[3], 255);
          // The edge: just outside the disc, faint and dark; further out, nothing.
          final edge = _rgba(i, cx + 41, cy);
          expect(edge[3], inInclusiveRange(40, 130), reason: 'a faint edge: $edge');
          expect(edge[0], lessThan(60), reason: 'near black');
          expect(_rgba(i, cx + 44, cy)[3], 0, reason: 'no halo beyond the edge');
          // No white pixel at all (the old halo was white and 3 points wide).
          var white = 0;
          for (var y = 0; y < i.h; y++) {
            for (var x = 0; x < i.w; x++) {
              final p = _rgba(i, x, y);
              // Outside the disc (the glyph inside it may be white).
              final dx = x - cx, dy = y - cy;
              if (dx * dx + dy * dy > 42 * 42 && p[3] > 200 && p[0] > 245 && p[1] > 245 && p[2] > 245) white++;
            }
          }
          expect(white, 0, reason: 'a white halo is left');
        }
      });
    });

    testWidgets('the Teardrop and the Badge lose the white ring too: a faint 1 pixel edge, their own shape, no white outside it', (tester) async {
      await tester.runAsync(() async {
        for (final style in [PinStyle.teardrop, PinStyle.badge]) {
          for (final tint in [purple, yellow]) {
            final flat = await _decode(await renderPinPng(Icons.place, tint, style, ratio: 3, flat: true));
            final halo = await _decode(await renderPinPng(Icons.place, tint, style, ratio: 3));
            // The halo look has a white ring around the shape; the flat look has no white pixel outside the tint.
            // White pixels on the outer boundary of the shape (a glyph's white inside it does not count): the ring is exactly that.
            int rim(({int w, int h, ByteData px}) i) {
              var n = 0;
              for (var y = 1; y < i.h - 1; y++) {
                for (var x = 1; x < i.w - 1; x++) {
                  final p = _rgba(i, x, y);
                  if (!(p[3] > 200 && p[0] > 245 && p[1] > 245 && p[2] > 245)) continue;
                  if (_rgba(i, x - 1, y)[3] < 200 || _rgba(i, x + 1, y)[3] < 200 || _rgba(i, x, y - 1)[3] < 200 || _rgba(i, x, y + 1)[3] < 200) n++;
                }
              }
              return n;
            }

            expect(rim(halo), greaterThan(50), reason: '${style.name}: the ring is white today');
            expect(rim(flat), 0, reason: '${style.name} ${tint.toARGB32().toRadixString(16)}: no white ring');
            // The shape itself is the same size: its filled body is there in the tint, with an edge of at most 1 pixel and a faint alpha.
            var tinted = 0, faint = 0;
            for (var y = 0; y < flat.h; y++) {
              for (var x = 0; x < flat.w; x++) {
                final p = _rgba(flat, x, y);
                if (p[3] == 255 && p[0] == (tint.r * 255).round() && p[1] == (tint.g * 255).round()) tinted++;
                if (p[3] > 0 && p[3] < 140 && p[0] < 60) faint++;
              }
            }
            expect(tinted, greaterThan(200), reason: style.name);
            expect(faint, greaterThan(20), reason: '${style.name}: the faint edge is drawn');
          }
        }
      });
    });

    test('the glyph is dark on a light tint (yellow, sand) and white on the rest, by glyphOn', () {
      expect(glyphOn(yellow), const Color(0xFF111111));
      expect(glyphOn(sand), const Color(0xFF111111));
      expect(glyphOn(purple), const Color(0xFFFFFFFF));
      expect(glyphOn(const Color(0xFFE08A3C)), const Color(0xFFFFFFFF));
    });
  });

  group('the flat chip (light and Parchment)', () {
    testWidgets('has no ring: just the disc and the faint edge; dark keeps its dark ring', (tester) async {
      await tester.runAsync(() async {
        for (final id in [CacheThemeId.light, CacheThemeId.parchment]) {
          final i = await _decode(await renderPoiChipPng(poiIcons.first, mapPaletteFor(id), ratio: 3));
          final c = i.w ~/ 2;
          // The old ring was white, 9.4 to 10.5 points from the middle (28 to 31 pixels); the disc is 27 pixels.
          final ring = _rgba(i, c + 29, c);
          expect(ring[3], lessThan(0x80), reason: '${id.name}: no opaque ring, only the faint edge ($ring)');
          expect(_rgba(i, c + 20, c)[3], 255, reason: 'the disc');
          expect(_rgba(i, c + 27, c)[3], inInclusiveRange(40, 130), reason: 'the faint 1 pixel edge');
        }
        final dark = await _decode(await renderPoiChipPng(poiIcons.first, mapPaletteFor(CacheThemeId.dark), ratio: 3));
        expect(_rgba(dark, dark.w ~/ 2 + 29, dark.w ~/ 2)[3], 255, reason: 'dark keeps its ring');
      });
    });
  });

  test('the Settings > Maps hint of the Icon pin style says what the light themes draw', () {
    expect(PinStyle.icon.hint, 'The icon on a colored disc');
    expect(PinStyle.icon.hint, isNot(contains('halo')));
  });

  group('the image names carry the look', () {
    test('a pin image of the flat look is not the halo look\'s, for every style', () {
      expect(pinImageId(PinStyle.icon, 'x', purple, flat: true), isNot(pinImageId(PinStyle.icon, 'x', purple)));
      expect(pinImageId(PinStyle.icon, 'x', purple, flat: true), isNot(pinImageId(PinStyle.icon, 'x', purple, tactical: true)));
      for (final style in PinStyle.values) {
        expect(pinImageId(style, 'x', purple, flat: true), isNot(pinImageId(style, 'x', purple)), reason: style.name);
        expect(pinImageId(style, 'x', purple, flat: true, tactical: true), pinImageId(style, 'x', purple, tactical: true), reason: 'Tactical is never flat');
      }
      expect(pinImageId(PinStyle.icon, 'x', purple), 'pin-icon-x-ae86f0', reason: 'dark and Tactical ids are as they were');
    });

    test('a chip image of the flat look has its own name; the themes\' styles name different images', () {
      for (final i in poiIcons) {
        expect(i.imageFor(flat: true), isNot(i.imageFor(flat: false)));
        expect(i.imageFor(flat: false), i.image);
      }
      final template = jsonDecode(File('assets/map/protomaps_v4_template.json').readAsStringSync()) as Map<String, dynamic>;
      String icons(CacheThemeId id) => jsonEncode((protomapsLayers(mapPaletteFor(id), template, 's').firstWhere((l) => l['id'] == 'pois')['layout'] as Map)['icon-image']);
      expect(icons(CacheThemeId.light), contains('poi-fuel-f'));
      expect(icons(CacheThemeId.parchment), contains('poi-fuel-f'));
      expect(icons(CacheThemeId.dark), isNot(contains('poi-fuel-f')));
      expect(icons(CacheThemeId.tactical), isNot(contains('poi-fuel-f')));
      expect(repeaterPinName(PinStyle.icon, flat: true), isNot(repeaterPinName(PinStyle.icon)));
      expect(isFlatIconTheme(CacheThemeId.light) && isFlatIconTheme(CacheThemeId.parchment) && !isFlatIconTheme(CacheThemeId.dark) && !isFlatIconTheme(CacheThemeId.tactical), isTrue);
    });
  });

  group('the icons are smaller zoomed out', () {
    test('the curve: 0.4 at zoom 5, 0.55 at 9, 0.8 at 12, 1.0 from 15, as one interpolate', () {
      final e = iconSizeByZoom(1);
      expect(e.take(3).toList(), ['interpolate', ['linear'], ['zoom']]);
      expect(e.skip(3).toList(), [5.0, 0.4, 9.0, 0.55, 12.0, 0.8, 15.0, 1.0]);
      expect(iconSizeByZoom(1 / 3).skip(3).toList(), [5.0, 0.4 / 3, 9.0, 0.55 / 3, 12.0, 0.8 / 3, 15.0, 1 / 3]);
    });

    test('repeaters, notebook pins and the pin layers and the public-place chips use it (times the image scale)', () {
      final template = jsonDecode(File('assets/map/protomaps_v4_template.json').readAsStringSync()) as Map<String, dynamic>;
      for (final id in CacheThemeId.values) {
        final style = buildMapStyle(palette: mapPaletteFor(id), omtTemplate: const {'layers': []}, layers: const [], tilesUrl: (d) => '', glyphsUrl: 'file:///f/{fontstack}/{range}.pbf', pinStyle: PinStyle.icon);
        final layers = {for (final l in style['layers'] as List) (l as Map)['id'] as String: l};
        for (final lid in [kUserRepeaters, kNotebookPins, kPinResultsIcon, kPinSelectedIcon]) {
          expect(layers[lid]!['layout']['icon-size'], iconSizeByZoom(pinIconSize(web: false)), reason: '$id $lid');
        }
        final poi = protomapsLayers(mapPaletteFor(id), template, 's').firstWhere((l) => l['id'] == 'pois');
        expect((poi['layout'] as Map)['icon-size'], iconSizeByZoom(1), reason: '$id: the public-place chips, in place of 12 to 0.78 and 16 to 1.0');
        final web = protomapsLayers(mapPaletteFor(id), template, 's', poiIconScale: 1 / 3).firstWhere((l) => l['id'] == 'pois');
        expect(((web['layout'] as Map)['icon-size'] as List).last * 3, closeTo(1.0, 1e-9));
      }
    });

    test('at zoom 5 an icon is 0.4 of its size, so nearby repeaters are small separate dots', () {
      final stops = iconSizeByZoom(1).skip(3).toList();
      double at(double z) {
        for (var i = 0; i + 3 < stops.length; i += 2) {
          final z0 = stops[i] as double, m0 = stops[i + 1] as double, z1 = stops[i + 2] as double, m1 = stops[i + 3] as double;
          if (z <= z0) return m0;
          if (z <= z1) return m0 + (m1 - m0) * (z - z0) / (z1 - z0);
        }
        return stops.last as double;
      }

      expect(at(5), 0.4);
      expect(at(7), closeTo(0.475, 1e-9));
      expect(at(10.5), closeTo(0.675, 1e-9));
      expect(at(14), closeTo(0.9333, 1e-3));
      expect(at(20), 1.0);
      expect(at(2), 0.4);
      // A 27 point disc at 0.4 is about 11 points: smaller than the gaps between repeaters a few miles apart on a country map.
      expect(27 * at(5), lessThan(12));
    });
  });
}
