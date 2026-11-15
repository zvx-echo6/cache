// The needle pin (option A) in Light, Dark and Tactical: sheets of pins on the map's land colour at real size and 2x (some with
// icons, some without, one selected), and one sheet of the car's pictures (the images car_pins sends, at kCarPinImageRatio, shown
// at the car's size and at twice that). Only calls paintMapPin / renderPinPng, so it also compiles on rel-1.1 for the "before".
// flutter test test_shots/needle_pin_renders_test.dart --update-goldens  (pictures in test_shots/needle_pin/)

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cache/car/car_pins.dart' show kCarPinImageRatio;
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/notebook/map_icons.dart';
import 'package:cache/notebook/pin_image.dart';
import 'package:cache/notebook/place_style.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'shot_kit.dart';

const _pins = [
  ('water', 'teal'),
  (null, 'purple'),
  ('fuel', 'blue'),
  (null, 'teal'),
  ('hazard', 'orange'),
  ('target', 'green'),
  ('compass', 'sand'),
  ('radio_tower', 'purple'),
];

Future<void> _loadSymbols() async {
  final cfg = jsonDecode(File('.dart_tool/package_config.json').readAsStringSync()) as Map;
  final pkg = (cfg['packages'] as List).cast<Map>().firstWhere((p) => p['name'] == 'material_symbols_icons');
  final root = Directory.current.uri.resolve('.dart_tool/').resolve('${pkg['rootUri']}/');
  final bytes = File.fromUri(root.resolve('lib/fonts/MaterialSymbolsOutlined.ttf')).readAsBytesSync();
  final loader = FontLoader('packages/material_symbols_icons/MaterialSymbolsOutlined')..addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  await loader.load();
}

void _cap(Canvas canvas, Color col, String t, double x, double y) {
  final tp = TextPainter(text: TextSpan(text: t, style: TextStyle(fontFamily: 'Roboto', fontSize: 11, fontWeight: FontWeight.w600, color: col)), textDirection: TextDirection.ltr)..layout();
  tp.paint(canvas, Offset(x, y));
}

/// A pin with no icon of its own: the map's plain place icon.
IconData _icon(String? id) => id == null ? Icons.place : mapIcon(id).icon;

class _Phone extends CustomPainter {
  _Phone(this.id);
  final CacheThemeId id;

  @override
  void paint(Canvas canvas, Size size) {
    final tac = id == CacheThemeId.tactical;
    final red = cacheTokens[CacheThemeId.tactical]!.accent;
    final p = mapPaletteFor(id);
    final cap = p['labelPlace'] as Color;
    canvas.drawRect(Offset.zero & size, Paint()..color = p['land']);
    Color tint(String n) => tac ? red : markerColor(n).color;
    _cap(canvas, cap, '${id.name}  -  real size (30 pt)', 10, 8);
    for (var i = 0; i < _pins.length; i++) {
      final (ic, col) = _pins[i];
      paintMapPin(canvas, Offset(30 + i * 44.0, 90), 30, _icon(ic), tint(col), PinStyle.teardrop, tactical: tac);
    }
    _cap(canvas, cap, 'Selected (larger, ground ring)', 10, 112);
    canvas.drawOval(Rect.fromCenter(center: const Offset(60, 190), width: 30, height: 10), Paint()..color = tac ? red : const Color(0xFF111111)..style = PaintingStyle.stroke..strokeWidth = 1.6);
    paintMapPin(canvas, const Offset(60, 184), 40, Icons.water_drop, tint('teal'), PinStyle.teardrop, tactical: tac);
    _cap(canvas, cap, 'On the map next to a 30 pt pin', 120, 140);
    paintMapPin(canvas, const Offset(150, 190), 30, Icons.local_hospital, tint('blue'), PinStyle.teardrop, tactical: tac);
    _cap(canvas, cap, '2x zoom (60 pt)', 10, 215);
    for (var i = 0; i < 4; i++) {
      final (ic, col) = _pins[i];
      paintMapPin(canvas, Offset(50 + i * 88.0, 330), 60, _icon(ic), tint(col), PinStyle.teardrop, tactical: tac);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

class _Car extends CustomPainter {
  _Car(this.bands);
  final List<(CacheThemeId, List<ui.Image>)> bands;

  @override
  void paint(Canvas canvas, Size size) {
    const bandH = 300.0;
    for (var b = 0; b < bands.length; b++) {
      final (id, imgs) = bands[b];
      final p = mapPaletteFor(id);
      final cap = p['labelPlace'] as Color;
      canvas.save();
      canvas.translate(0, b * bandH);
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, bandH), Paint()..color = p['land']);
      _cap(canvas, cap, '${id.name}  -  the car\'s pictures (${kCarPinImageRatio}x): its size, then 2x', 10, 8);
      for (var i = 0; i < imgs.length; i++) {
        final im = imgs[i];
        final w = im.width / kCarPinImageRatio, h = im.height / kCarPinImageRatio;
        final src = Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble());
        // The picture's foot (the anchor) on a line, so the point sits on it.
        final x = 12 + i * 46.0;
        canvas.drawImageRect(im, src, Rect.fromLTWH(x, 100 - h + 0.17 * 30, w, h), Paint()..filterQuality = FilterQuality.high);
        canvas.drawImageRect(im, src, Rect.fromLTWH(x, 280 - 2 * h + 0.17 * 60, w * 2, h * 2), Paint()..filterQuality = FilterQuality.high);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

void main() {
  setUpAll(() async {
    await loadShotFonts();
    await _loadSymbols();
  });

  for (final id in [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.tactical]) {
    testWidgets('needle pin on the map, ${id.name}', (tester) async {
      phone(tester, size: const Size(390, 370), ratio: 3);
      await tester.pumpWidget(Directionality(textDirection: TextDirection.ltr, child: RepaintBoundary(key: const ValueKey('sheet'), child: CustomPaint(painter: _Phone(id), size: const Size(390, 370)))));
      await tester.pump();
      await expectLater(find.byKey(const ValueKey('sheet')), matchesGoldenFile('needle_pin/needle-${id.name}.png'));
    });
  }

  testWidgets('needle pin pictures for the car', (tester) async {
    phone(tester, size: const Size(390, 900), ratio: 3);
    final red = cacheTokens[CacheThemeId.tactical]!.accent;
    final bands = (await tester.runAsync(() async {
      return [
        for (final id in [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.tactical])
          (
            id,
            [
              for (final (ic, col) in _pins)
                await (await (await ui.instantiateImageCodec(await renderPinPng(_icon(ic), id == CacheThemeId.tactical ? red : markerColor(col).color, PinStyle.teardrop, ratio: kCarPinImageRatio, tactical: id == CacheThemeId.tactical))).getNextFrame()).image,
            ]
          ),
      ];
    }))!;
    await tester.pumpWidget(Directionality(textDirection: TextDirection.ltr, child: RepaintBoundary(key: const ValueKey('sheet'), child: CustomPaint(painter: _Car(bands), size: const Size(390, 900)))));
    await tester.pump();
    await expectLater(find.byKey(const ValueKey('sheet')), matchesGoldenFile('needle_pin/needle-car.png'));
  });
}
