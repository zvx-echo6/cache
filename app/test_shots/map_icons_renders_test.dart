// Map icons v3 for review (feat/map-icons): the Maps settings "Pin style" group in the light and Tactical themes, and one map in each
// pin style in Tactical (every pin red; the glyph, ring and icon red, the halo and inner fill dark). 390 wide. The live map is a
// platform view and is not drawn in a test, so the map is a stand-in painted from the map palette, with the pins drawn by the same
// code that makes the images added to the map style (paintMapPin).
// flutter test test_shots/map_icons_renders_test.dart --update-goldens  (pictures in test_shots/map_icons_v3/)

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/notebook/map_icons.dart';
import 'package:cache/notebook/pin_image.dart';
import 'package:cache/notebook/place_style.dart';
import 'package:cache/screens/settings/maps_page.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

const _out = 'map_icons_v3';

// ---- the stand-in maps ---------------------------------------------------------------------------------------------

void _paintBase(Canvas canvas, Size size, MapPalette p) {
  canvas.drawRect(Offset.zero & size, Paint()..color = p['land']);
  final w = size.width, h = size.height;
  for (final (fx, fy, fr) in const [(0.15, 0.22, 0.17), (0.78, 0.75, 0.2), (0.62, 0.12, 0.1)]) {
    canvas.drawOval(Rect.fromCenter(center: Offset(w * fx, h * fy), width: w * fr * 2.2, height: h * fr * 1.3), Paint()..color = p['park']);
  }
  canvas.drawOval(Rect.fromCenter(center: Offset(w * 0.86, h * 0.3), width: w * 0.22, height: h * 0.12), Paint()..color = p['water']);
  final river = Path()
    ..moveTo(-10, h * 0.62)
    ..cubicTo(w * 0.25, h * 0.45, w * 0.4, h * 0.85, w * 0.62, h * 0.6)
    ..cubicTo(w * 0.8, h * 0.42, w * 0.9, h * 0.55, w + 10, h * 0.4);
  canvas.drawPath(river, Paint()..color = p['water']..style = PaintingStyle.stroke..strokeWidth = math.max(8, w * 0.022)..strokeCap = StrokeCap.round);
  final minor = Paint()..color = p['roadMinor']..style = PaintingStyle.stroke..strokeWidth = 2.2;
  final casing = Paint()..color = p['roadMinorCasing']..style = PaintingStyle.stroke..strokeWidth = 4;
  for (var x = w * 0.08; x < w; x += w * 0.19) {
    canvas.drawLine(Offset(x, 0), Offset(x + w * 0.05, h), casing);
    canvas.drawLine(Offset(x, 0), Offset(x + w * 0.05, h), minor);
  }
  for (var y = h * 0.12; y < h; y += h * 0.21) {
    canvas.drawLine(Offset(0, y), Offset(w, y - h * 0.04), casing);
    canvas.drawLine(Offset(0, y), Offset(w, y - h * 0.04), minor);
  }
  final major = Path()
    ..moveTo(0, h * 0.82)
    ..quadraticBezierTo(w * 0.45, h * 0.7, w, h * 0.12);
  canvas.drawPath(major, Paint()..color = p['roadMajorCasing']..style = PaintingStyle.stroke..strokeWidth = 8);
  canvas.drawPath(major, Paint()..color = p['roadMajor']..style = PaintingStyle.stroke..strokeWidth = 5.5);
}

/// One pin of the comparison: a spot on the panel (0..1 across and down), its icon and colour.
class _Pin {
  const _Pin(this.name, this.x, this.y, this.icon, this.color);
  final String name;
  final double x, y;
  final String icon;
  final String color;
}

/// The same nine places in every panel: water, camp, repeater, danger, shelter, fuel, medical, rally point and cache, from three
/// notebooks (Trail places teal, Repeaters purple, Services blue; the danger pin has a colour of its own).
const _pins = [
  _Pin('Hulls Gulch spring', 0.16, 0.26, 'water', 'teal'),
  _Pin('Dry Creek camp', 0.50, 0.19, 'camp', 'teal'),
  _Pin('Shafer Butte', 0.84, 0.24, 'radio_tower', 'purple'),
  _Pin('Rattlesnake slide', 0.28, 0.56, 'danger', 'orange'),
  _Pin('Bogus Basin hut', 0.80, 0.50, 'shelter', 'teal'),
  _Pin('Eagle fuel stop', 0.14, 0.82, 'fuel', 'blue'),
  _Pin('Eagle clinic', 0.50, 0.78, 'first_aid', 'blue'),
  _Pin('Lucky Peak rally point', 0.82, 0.8, 'rally', 'teal'),
  _Pin('Table Rock cache', 0.54, 0.44, 'cache', 'teal'),
];

class _PinsPainter extends CustomPainter {
  _PinsPainter({required this.theme, required this.style, required this.pinSize, required this.labels});
  final CacheThemeId theme;
  final PinStyle style;
  final double pinSize;
  final bool labels;

  @override
  void paint(Canvas canvas, Size size) {
    final tactical = theme == CacheThemeId.tactical;
    final p = mapPaletteFor(theme);
    _paintBase(canvas, size, p);
    final red = cacheTokens[CacheThemeId.tactical]!.accent;
    for (final pin in _pins) {
      final x = size.width * pin.x, y = size.height * (0.1 + pin.y * 0.85);
      paintMapPin(canvas, Offset(x, style == PinStyle.teardrop ? y + pinSize * 0.5 : y), pinSize, mapIcon(pin.icon).icon, tactical ? red : markerColor(pin.color).color, style, tactical: tactical);
      if (labels) {
        final tp = TextPainter(
          text: TextSpan(
            text: pin.name,
            style: TextStyle(fontFamily: 'Roboto', fontSize: 11.5, fontWeight: FontWeight.w600, color: p['labelPlace'], shadows: [for (var i = 0; i < 3; i++) Shadow(color: p['labelHalo'], blurRadius: 3)]),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout(maxWidth: 150);
        tp.paint(canvas, Offset(math.min(math.max(x - tp.width / 2, 2), size.width - tp.width - 2), y + pinSize * 0.62));
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

class _MapFrame extends StatelessWidget {
  const _MapFrame({required this.theme, required this.style});
  final CacheThemeId theme;
  final PinStyle style;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 44, 16, 8),
            child: Align(alignment: Alignment.centerLeft, child: Text('Pin style: ${style.label}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: k.text))),
          ),
          Expanded(child: CustomPaint(painter: _PinsPainter(theme: theme, style: style, pinSize: 36, labels: true), size: Size.infinite)),
        ],
      ),
    );
  }
}

/// Material Symbols from the package's own font file (a test does not load a font by itself).
Future<void> _loadSymbols() async {
  final cfg = jsonDecode(File('.dart_tool/package_config.json').readAsStringSync()) as Map;
  final pkg = (cfg['packages'] as List).cast<Map>().firstWhere((p) => p['name'] == 'material_symbols_icons');
  final root = Directory.current.uri.resolve('.dart_tool/').resolve('${pkg['rootUri']}/');
  final bytes = File.fromUri(root.resolve('lib/fonts/MaterialSymbolsOutlined.ttf')).readAsBytesSync();
  final loader = FontLoader('packages/material_symbols_icons/MaterialSymbolsOutlined')..addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  await loader.load();
}

void main() {
  setUpAll(() async {
    await loadShotFonts();
    await _loadSymbols();
  });

  for (final theme in const [CacheThemeId.light, CacheThemeId.tactical]) {
    testWidgets('Settings > Maps > Pin style, ${theme.name}', (tester) async {
      phone(tester, size: const Size(390, 844), ratio: 2);
      final r = await SettingsRig.create(tester);
      await tester.pumpWidget(shotApp(MapsPage(deps: r.deps), theme: theme, insets: const EdgeInsets.only(top: 44, bottom: 30)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await snap(tester, _out, '390-settings-pin-style-${theme.name}');
      await r.dispose(tester);
    });
  }

  for (final style in PinStyle.values) {
    testWidgets('map pins in Tactical, ${style.name}', (tester) async {
      phone(tester, size: const Size(390, 844), ratio: 2);
      await tester.pumpWidget(shotApp(_MapFrame(theme: CacheThemeId.tactical, style: style), theme: CacheThemeId.tactical, insets: EdgeInsets.zero));
      await tester.pump();
      await snap(tester, _out, '390-map-tactical-${style.name}');
    });
  }
}
