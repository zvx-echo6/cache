// The new-place map picker for review (fix/place-picker): the Add place form with its map (it now takes drag and pinch) and the
// "Choose on map" button, and the full-screen picker (crosshair with the pin in the Pin style, live coordinates, search, Where I
// am, Use this spot, Cancel). 390 wide, light, dark and Tactical, in the default Pin style (Icon). The pin is the place's current icon
// and colour (here the Places notebook's own).
// The live map is a platform view and is not drawn in a test, so the map is a stand-in painted from the map palette (the same
// stand-in the map-icons renders use); the pin on the form's map is drawn by paintMapPin. The picker's crosshair and pin are the
// real widgets.
// flutter test test_shots/place_picker_renders_test.dart --update-goldens  (pictures in test_shots/place_picker/)

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/notebook/notebook_map.dart' show PinLook;
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/pin_image.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/screens/notebooks/icon_picker.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/screens/notebooks/places_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/place_alerts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import '../test/support/notebook_fake.dart';
import 'shot_kit.dart';

const _out = 'place_picker';

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


class _StandIn extends CustomPainter {
  _StandIn(this.theme, this.pin, [this.look]);
  final CacheThemeId theme;
  final PinStyle? pin;
  final PinLook? look;

  @override
  void paint(Canvas canvas, Size size) {
    _paintBase(canvas, size, mapPaletteFor(theme));
    final s = pin;
    if (s != null) {
      final tactical = theme == CacheThemeId.tactical;
      paintMapPin(canvas, Offset(size.width / 2, s == PinStyle.teardrop ? size.height / 2 + 18 : size.height / 2), 36, look!.glyph, look!.tint, s, tactical: tactical);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

// The default Pin style (Icon) everywhere; the teardrop and badge are not what this review is about.
PinStyle _styleFor(CacheThemeId t) => PinStyle.icon;

const _boise = NbPlace(lat: 43.61500, lon: -116.20230);

Future<List<NbPlace>> _search(String q) async => const [
      NbPlace(lat: 43.6234, lon: -116.1903, label: 'Table Rock, Boise, Idaho'),
      NbPlace(lat: 43.7351, lon: -116.1020, label: 'Table Rock Trailhead, Boise County, Idaho'),
      NbPlace(lat: 44.0682, lon: -114.7420, label: 'Table Rock Lookout, Custer County, Idaho'),
    ];

Future<({double lat, double lon})?> _here() async => (lat: 43.4799, lon: -116.4086);
Future<List<NbPlace>> _noSaved() async => const [];

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

  for (final theme in const [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.tactical]) {
    final style = _styleFor(theme);
    final choices = PlaceChoices(here: _here, saved: _noSaved, search: _search);

    Widget standIn(PinStyle? s, [PinLook? look]) => CustomPaint(painter: _StandIn(theme, s, look), size: Size.infinite);

    testWidgets('Add place form, ${theme.name}', (tester) async {
      phone(tester, size: const Size(390, 844), ratio: 2);
      final nb = fakeNotebook(FakeNotebookBackend());
      late Notebook book;
      await tester.runAsync(() async {
        await nb.start();
        book = await nb.ensureSavedPlaces();
      });
      final deps = NotebookDeps(
        notebook: nb,
        places: choices,
        icons: MapIconSetup.fixed(pinStyle: style),
        placesDeps: PlaceNotebookDeps(
          watched: (_) => false,
          setWatched: (_, _) {},
          alerts: PlaceAlerts.memory(),
          map: (context, pin, onPick, look) => standIn(style, look),
          pickerMap: (context, target, onMoving, onCentre, onTap) => standIn(null),
        ),
      );
      await tester.pumpWidget(shotApp(PlaceForm(deps: deps, book: book, at: _boise), theme: theme));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await snap(tester, _out, '390-form-${theme.name}');
    });

    for (final withSearch in [false, true]) {
      testWidgets('full-screen picker${withSearch ? ' with search results' : ''}, ${theme.name}', (tester) async {
        phone(tester, size: const Size(390, 844), ratio: 2);
        final nb = fakeNotebook(FakeNotebookBackend());
        late Notebook book;
        await tester.runAsync(() async {
          await nb.start();
          book = await nb.ensureSavedPlaces();
        });
        final deps = NotebookDeps(
          notebook: nb,
          places: choices,
          icons: MapIconSetup.fixed(pinStyle: style),
          placesDeps: PlaceNotebookDeps(
            watched: (_) => false,
            setWatched: (_, _) {},
            alerts: PlaceAlerts.memory(),
            map: (context, pin, onPick, look) => standIn(style, look),
            pickerMap: (context, target, onMoving, onCentre, onTap) => standIn(null),
          ),
        );
        // Through the form, so the pin is the icon and colour the form resolves for the place.
        await tester.pumpWidget(shotApp(PlaceForm(deps: deps, book: book, at: _boise), theme: theme));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('place-choose-on-map')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        if (withSearch) {
          await tester.enterText(find.byKey(const ValueKey('picker-search')), 'table rock');
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
        }
        await snap(tester, _out, '390-picker${withSearch ? '-search' : ''}-${theme.name}');
      });
    }
  }
}
