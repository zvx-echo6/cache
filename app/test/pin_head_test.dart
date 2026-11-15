// The teardrop pin's head holds its whole icon, and its image holds the whole head (fix/pin-icon-cut): the image used to be a
// square whose top edge cut the top off the head, so a round head came out flat-topped on the map and in the car.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cache/notebook/map_icons.dart';
import 'package:cache/notebook/pin_image.dart';
import 'package:cache/notebook/place_style.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

/// Material Symbols from the package's own font file (a test does not load a font by itself; without it every icon is a box).
Future<void> _loadSymbols() async {
  final cfg = jsonDecode(File('.dart_tool/package_config.json').readAsStringSync()) as Map;
  final pkg = (cfg['packages'] as List).cast<Map>().firstWhere((p) => p['name'] == 'material_symbols_icons');
  final root = Directory.current.uri.resolve('.dart_tool/').resolve('${pkg['rootUri']}/');
  final bytes = File.fromUri(root.resolve('lib/fonts/MaterialSymbolsOutlined.ttf')).readAsBytesSync();
  final loader = FontLoader('packages/material_symbols_icons/MaterialSymbolsOutlined')..addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  await loader.load();
}

Future<(ByteData, int, int)> _rgba(ui.Image img) async => ((await img.toByteData(format: ui.ImageByteFormat.rawRgba))!, img.width, img.height);

Future<(ByteData, int, int)> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  return _rgba((await codec.getNextFrame()).image);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadSymbols);

  final icons = [...kMapIcons, ...kTemplateIcons];
  // The sizes the teardrop is drawn at: 30 on the maps (phone, browser and car), and the in-app pins (PinGlyph, 0.6 of its square:
  // squares of 24 to 52 points).
  const sizes = [30.0, 14.4, 18.0, 24.0, 28.8, 31.2];

  test('the icon\'s box is centred on the head and its corners sit inside the head\'s fill, for every icon', () {
    for (final tactical in [false, true]) {
    for (final size in sizes) {
      const at = Offset(100, 200);
      final head = teardropHead(at, size, tactical: tactical);
      for (final i in icons) {
        final tp = pinGlyph(i.icon, teardropGlyphSize(size));
        final box = teardropIconBox(at, size, tp.size, tactical: tactical);
        expect((box.center - head.centre).distance, lessThan(1e-9), reason: '${i.id} at $size');
        for (final corner in [box.topLeft, box.topRight, box.bottomLeft, box.bottomRight]) {
          expect((corner - head.centre).distance, lessThan(head.radius * 0.9), reason: '${i.id} at $size: its box reaches the head\'s edge');
        }
      }
    }
    }
  });

  test('every icon\'s drawn shape sits inside the head\'s fill with a margin', () async {
    const size = 30.0, ratio = 4.0;
    // The head's square around its centre, in pixels.
    final side = (size * 1.2 * ratio).round();
    final centre = Offset(side / 2, side / 2);
    for (final i in icons) {
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec)..scale(ratio);
      final at = Offset(side / ratio / 2, side / ratio / 2 + size * 1.3 + pinOutline(size)); // so the head's centre is the square's centre
      final tp = pinGlyph(i.icon, teardropGlyphSize(size));
      tp.paint(canvas, teardropIconBox(at, size, tp.size).topLeft);
      final (px, w, h) = await _rgba(await rec.endRecording().toImage(side, side));
      var far = 0.0, ink = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (px.getUint8((y * w + x) * 4 + 3) < 24) continue;
          ink++;
          far = math.max(far, (Offset(x + 0.5, y + 0.5) - centre).distance);
        }
      }
      expect(ink, greaterThan(0), reason: '${i.id} drew nothing (font not loaded?)');
      expect(far / ratio, lessThan(size * 0.46 - size * 0.06), reason: '${i.id} reaches the edge of the head');
    }
  });

  test('the whole pin is inside its image: nothing touches the edge, at every size the maps and the car draw it', () async {
    final circle = mapIcon('target').icon; // a round icon
    for (final style in [PinStyle.teardrop, PinStyle.badge]) {
      for (final tactical in [false, true]) {
        for (final ratio in [2.0, 2.625, 3.0]) {
          final (px, w, h) = await _decode(await renderPinPng(circle, markerColor('teal').color, style, ratio: ratio, tactical: tactical));
          bool clear(int x, int y) => px.getUint8((y * w + x) * 4 + 3) == 0;
          final where = '${style.name}${tactical ? ' tactical' : ''} at ${ratio}x';
          for (var x = 0; x < w; x++) {
            expect(clear(x, 0), isTrue, reason: '$where: the top edge cuts the pin');
          }
          for (var y = 0; y < h; y++) {
            expect(clear(0, y) && clear(w - 1, y), isTrue, reason: '$where: a side edge cuts the pin');
          }
          final box = pinImageSize(style, 30);
          expect(w, (box.width * ratio).round());
          expect(h, (box.height * ratio).round());
        }
      }
    }
  });

  test('the head\'s outline sits inside the teardrop image with room above it, and its point stays at the foot', () {
    for (final tactical in [false, true]) {
      const size = 30.0;
      final box = pinImageSize(PinStyle.teardrop, size);
      final at = pinImageAt(PinStyle.teardrop, size, tactical: tactical);
      final head = teardropHead(at, size, tactical: tactical);
      final reach = head.radius + pinOutline(size, tactical: tactical);
      expect(head.centre.dy - reach, greaterThan(size * 0.05), reason: 'top of the head');
      expect(head.centre.dx - reach, greaterThan(0));
      expect(head.centre.dx + reach, lessThan(box.width));
      expect(box.height - at.dy, closeTo(size * (tactical ? 0.2 : 0.17), 1e-9), reason: 'the point is where the map anchors it (the bottom)');
      expect(box.width, closeTo(size * 1.5, 1e-9), reason: 'as wide as before');
      // The needle: the fill's apex is an outline above the point, the straight sides are tangent to the round head.
      expect(at.dy - head.centre.dy - pinOutline(size, tactical: tactical), closeTo(size * 1.3, 1e-9), reason: 'the head sits a needle\'s length above the apex');
      expect(head.radius, greaterThanOrEqualTo(size * 0.46), reason: 'the head is as big as the icon needs');
    }
  });
}
