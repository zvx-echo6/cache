// The teardrop pin's head, before and after fix/pin-icon-cut, in every theme. Before (rel-1.1): the pin image was a square
// 1.5 pins wide with the point near its foot, so the image's top edge cut the top off the round head and it came out
// flat-topped, on the phone's map and in the car (car_pins sends the same images). After: the image is as wide and taller, the
// point in the same place at its foot, so the whole head and its icon are inside it.
//
// Each picture is the exact image the app adds to the map (renderPinPng) for the phone at 2x and 3x and for the car (at
// kCarPinImageRatio), shown at twice its size on the theme's land colour with a thin line around the image's edges, so a cut top
// shows as a straight line along the top. Round icons first (target, compass, sun, no go), then a few other shapes. The last row
// is the in-app pins (PinGlyph, unchanged) at the sizes the screens use.
// flutter test test_shots/pin_icon_cut_renders_test.dart --update-goldens  (pictures in test_shots/pin_icon_cut/)

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

const _out = 'pin_icon_cut';

/// Round icons, then other shapes, with the colours the places use.
const _icons = [
  ('target', 'teal'),
  ('compass', 'blue'),
  ('sun', 'yellow'),
  ('no_go', 'orange'),
  ('rally', 'green'),
  ('cache', 'sand'),
  ('water', 'purple'),
  ('radio_tower', 'purple'),
];

/// rel-1.1's renderPinPng, as it was: a square 1.5 pins wide, the point 0.17 of a pin (0.2 in Tactical) above its foot.
Future<Uint8List> _renderBefore(IconData icon, Color tint, {double size = 30, required double ratio, required bool tactical}) async {
  final box = size * 1.5;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec)..scale(ratio);
  paintMapPin(c, Offset(box / 2, box - size * (tactical ? 0.2 : 0.17)), size, icon, tint, PinStyle.teardrop, tactical: tactical);
  final img = await rec.endRecording().toImage((box * ratio).round(), (box * ratio).round());
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

Future<ui.Image> _decode(Uint8List png) async => (await (await ui.instantiateImageCodec(png)).getNextFrame()).image;

/// Material Symbols from the package's own font file (a test does not load a font by itself).
Future<void> _loadSymbols() async {
  final cfg = jsonDecode(File('.dart_tool/package_config.json').readAsStringSync()) as Map;
  final pkg = (cfg['packages'] as List).cast<Map>().firstWhere((p) => p['name'] == 'material_symbols_icons');
  final root = Directory.current.uri.resolve('.dart_tool/').resolve('${pkg['rootUri']}/');
  final bytes = File.fromUri(root.resolve('lib/fonts/MaterialSymbolsOutlined.ttf')).readAsBytesSync();
  final loader = FontLoader('packages/material_symbols_icons/MaterialSymbolsOutlined')..addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  await loader.load();
}

/// One row of pictures: what it is, and each pin's image with the pixels per point it was drawn at.
class _Row {
  _Row(this.label, this.images, this.ratio);
  final String label;
  final List<ui.Image> images;
  final double ratio;
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.theme, required this.rows});
  final CacheThemeId theme;
  final List<_Row> rows;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final land = mapPaletteFor(theme)['land'];
    final tactical = theme == CacheThemeId.tactical;
    final red = cacheTokens[CacheThemeId.tactical]!.accent;
    Widget label(String s) => SizedBox(width: 110, child: Text(s, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.text)));
    return Scaffold(
      backgroundColor: k.background,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Teardrop pin, ${theme.label}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: k.text)),
            const SizedBox(height: 8),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    label(r.label),
                    for (final img in r.images)
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(color: land, border: Border.all(color: k.secondary, width: 1)),
                        // Twice the size it is on the map: the image's points times two.
                        child: RawImage(image: img, scale: r.ratio / 2, filterQuality: FilterQuality.none),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Row(
              children: [
                label('In the app'),
                for (final s in const [28.0, 40.0, 44.0, 52.0])
                  for (final (id, colour) in _icons.take(2))
                    Container(
                      margin: const EdgeInsets.only(right: 6),
                      color: land,
                      child: PinGlyph(icon: mapIcon(id).icon, tint: tactical ? red : markerColor(colour).color, style: PinStyle.teardrop, size: s),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  setUpAll(() async {
    await loadShotFonts();
    await _loadSymbols();
  });

  for (final theme in CacheThemeId.values) {
    testWidgets('teardrop pin images before and after, ${theme.name}', (tester) async {
      phone(tester, size: const Size(940, 1060), ratio: 2);
      final tactical = theme == CacheThemeId.tactical;
      final red = cacheTokens[CacheThemeId.tactical]!.accent;
      final rows = (await tester.runAsync(() async {
        Future<List<ui.Image>> images(double ratio, {required bool after}) async => [
              for (final (id, colour) in _icons)
                await _decode(after
                    ? await renderPinPng(mapIcon(id).icon, tactical ? red : markerColor(colour).color, PinStyle.teardrop, ratio: ratio, tactical: tactical)
                    : await _renderBefore(mapIcon(id).icon, tactical ? red : markerColor(colour).color, ratio: ratio, tactical: tactical)),
            ];
        return [
          for (final (name, ratio) in [('Phone 2x', 2.0), ('Phone 3x', 3.0), ('Car', kCarPinImageRatio)]) ...[
            _Row('$name before', await images(ratio, after: false), ratio),
            _Row('$name after', await images(ratio, after: true), ratio),
          ],
        ];
      }))!;
      await tester.pumpWidget(shotApp(_Sheet(theme: theme, rows: rows), theme: theme, insets: EdgeInsets.zero));
      await tester.pump();
      await snap(tester, _out, 'teardrop-before-after-${theme.name}');
    });
  }
}
