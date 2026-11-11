// Map icons v2 for review (design/map-icons, renders first; nothing here is wired into the app yet): the icon picker (Google's Material
// Symbols, curated and searchable by synonyms), a place's view screen, notebook settings with the new notebook colour, and the three
// pin styles under review (A halo, B teardrop, C badge) side by side on the same places over a light or dark map, a satellite-like
// busy background and a zoomed-out panel. 390 wide, in the light, dark and Tactical themes. The screens are the real PlaceView,
// NotebookEditor and IconPicker; the live map is a platform view and is not drawn in a test, so the map is a stand-in painted from
// the map palette, with the pins drawn by the same code that makes the images added to the map style (paintMapPin).
// flutter test test_shots/map_icons_renders_test.dart --update-goldens  (pictures in test_shots/map_icons_v2/)

import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/notebook/map_icons.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/pin_image.dart';
import 'package:cache/notebook/place_style.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/screens/notebooks/icon_picker.dart';
import 'package:cache/screens/notebooks/notebook_editor.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart' show NotebookDeps;
import 'package:cache/screens/notebooks/places_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/place_alerts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import '../test/support/notebook_fake.dart';
import 'shot_kit.dart';

const _out = 'map_icons_v2';
final DateTime _now = DateTime(2026, 11, 10, 12, 0);

/// Recent icons for the picker: the last six chosen.
const _recent = RecentIcons(['river_crossing', 'water', 'danger', 'camp', 'fire_pit', 'radio_tower']);
const _setup = MapIconSetup(recent: _recent);

/// The sample places: neutral public Idaho spots. [icon] is the place's own icon (null: its notebook's, the pin); [color] its own
/// colour (null: the notebook's).
class _P {
  const _P(this.name, this.lat, this.lon, {this.color, this.icon});
  final String name;
  final double lat, lon;
  final String? color;
  final String? icon;
}

const _places = [
  _P('Lucky Peak trailhead', 43.5300, -116.0600),
  _P('Boise River ford', 43.6010, -116.1450, icon: 'river_crossing'),
  _P('Hulls Gulch spring', 43.6450, -116.1850, icon: 'water'),
  _P('Dry Creek camp', 43.7050, -116.1250, icon: 'camp'),
  _P('Rattlesnake slide', 43.5700, -116.0950, icon: 'danger', color: 'orange'),
];

class _Rig {
  _Rig() : store = FakeNotebookBackend() {
    nb = fakeNotebook(store);
  }
  final FakeNotebookBackend store;
  late final NotebookState nb;
  late Notebook book;
  final ids = <String, String>{};

  Future<void> load() async {
    await nb.start();
    final made = await nb.saveNotebook(template: 'places', def: const NotebookDef(name: 'Trail places', fields: [], sort: NotebookSort.distance), map: true);
    for (final p in _places) {
      final e = await nb.saveEntry(
        notebookId: made.id,
        occurredAt: '2026-11-01T10:00:00-07:00',
        title: p.name,
        body: switch (p.name) {
          'Lucky Peak trailhead' => 'Gravel lot, about 12 spaces. The trail starts at the east end. Vault toilet, open in summer.',
          'Boise River ford' => 'Shallow in late summer, knee deep in June. Gravel bar on the north bank.',
          _ => null,
        },
        place: NbPlace(lat: p.lat, lon: p.lon, label: 'Boise, Idaho'),
        props: {'color': ?p.color, 'on_map': true, 'icon': ?p.icon},
      );
      ids[p.name] = e.id;
    }
    // The notebook as the screens get it (the fake store keeps no icon in a definition, as the core does not yet).
    final saved = nb.notebooks.firstWhere((n) => n.id == made.id);
    book = Notebook(
      id: saved.id,
      template: 'places',
      def: saved.def.copyWith(color: 'teal'),
      map: true,
      placeCount: _places.length,
      entryCount: _places.length,
    );
  }

  NotebookDeps deps(CacheThemeId theme, {_P? pinFor}) {
    final alerts = PlaceAlerts.memory();
    return NotebookDeps(
      notebook: nb,
      places: PlaceChoices.none,
      now: () => _now,
      placesDeps: PlaceNotebookDeps(
        watched: (_) => false,
        setWatched: (_, _) {},
        alerts: alerts,
        map: (context, pin, onPick) => _StandInMap(theme: theme, pin: pin, place: pinFor, book: book),
      ),
    );
  }
}

/// The colour a pin is drawn in: its marker colour, or the theme's red in Tactical.
Color _pinTint(CacheThemeId theme, String color) => theme == CacheThemeId.tactical ? cacheTokens[CacheThemeId.tactical]!.accent : markerColor(color).color;

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

/// A busy, mid-tone background like satellite imagery (fields, scrub, bare ground, shadow, a track); red-toned in Tactical.
void _paintSatellite(Canvas canvas, Size size, bool red) {
  final rnd = math.Random(11);
  final base = red ? const Color(0xFF4A2A25) : const Color(0xFF66744F);
  final tones = red
      ? const [Color(0xFF6A3A30), Color(0xFF3A1C18), Color(0xFF7A4A3C), Color(0xFF5A3028), Color(0xFF8A5A48)]
      : const [Color(0xFF7E8B5A), Color(0xFF4E5E3C), Color(0xFF9A8E6A), Color(0xFF5A6A4A), Color(0xFFB0A27C), Color(0xFF3E4A34)];
  canvas.drawRect(Offset.zero & size, Paint()..color = base);
  for (var i = 0; i < 90; i++) {
    final c = tones[rnd.nextInt(tones.length)].withValues(alpha: 0.35 + rnd.nextDouble() * 0.5);
    final cx = rnd.nextDouble() * size.width, cy = rnd.nextDouble() * size.height;
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(rnd.nextDouble() * math.pi);
    canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: 14 + rnd.nextDouble() * 70, height: 8 + rnd.nextDouble() * 34), Paint()..color = c);
    canvas.restore();
  }
  final track = Path()
    ..moveTo(0, size.height * 0.7)
    ..cubicTo(size.width * 0.3, size.height * 0.5, size.width * 0.6, size.height * 0.9, size.width, size.height * 0.4);
  canvas.drawPath(track, Paint()..color = (red ? const Color(0xFFB08070) : const Color(0xFFD8CFAE)).withValues(alpha: 0.8)..style = PaintingStyle.stroke..strokeWidth = 2.5);
}

/// The map of a place's screen: the base with the place's pin in the middle.
class _StandInMap extends StatelessWidget {
  const _StandInMap({required this.theme, required this.pin, required this.place, required this.book});
  final CacheThemeId theme;
  final NbPlace? pin;
  final _P? place;
  final Notebook book;

  @override
  Widget build(BuildContext context) {
    final icon = mapIconOrTemplate(place?.icon ?? book.def.icon ?? defaultNotebookIcon(book)).icon;
    final tint = _pinTint(theme, place?.color ?? book.def.color ?? 'orange');
    return CustomPaint(painter: _OnePinPainter(mapPaletteFor(theme), icon, tint), size: Size.infinite);
  }
}

class _OnePinPainter extends CustomPainter {
  _OnePinPainter(this.p, this.icon, this.tint);
  final MapPalette p;
  final IconData icon;
  final Color tint;

  @override
  void paint(Canvas canvas, Size size) {
    _paintBase(canvas, size, p);
    paintMapPin(canvas, size.center(Offset.zero) + const Offset(0, 22), 38, icon, tint, PinStyle.teardrop);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

// ---- the pin styles side by side ----------------------------------------------------------------------------------

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

enum _Ground { map, satellite }

class _PinsPainter extends CustomPainter {
  _PinsPainter({required this.theme, required this.ground, required this.style, required this.pinSize, required this.labels, this.zoom = 1});
  final CacheThemeId theme;
  final _Ground ground;
  final PinStyle style;
  final double pinSize;
  final bool labels;

  /// Below 1: the places are drawn closer together (a zoomed-out map).
  final double zoom;

  @override
  void paint(Canvas canvas, Size size) {
    final tactical = theme == CacheThemeId.tactical;
    final p = mapPaletteFor(theme);
    if (ground == _Ground.map) {
      _paintBase(canvas, size, p);
    } else {
      _paintSatellite(canvas, size, tactical);
    }
    for (final pin in _pins) {
      final x = size.width * (0.5 + (pin.x - 0.5) * zoom), y = size.height * (0.5 + (pin.y - 0.5) * zoom);
      paintMapPin(canvas, Offset(x, style == PinStyle.teardrop ? y + pinSize * 0.5 : y), pinSize, mapIcon(pin.icon).icon, _pinTint(theme, pin.color), style);
      if (labels) {
        final onSat = ground == _Ground.satellite;
        final tp = TextPainter(
          text: TextSpan(
            text: pin.name,
            style: TextStyle(
              fontFamily: 'Roboto',
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: onSat ? Colors.white : p['labelPlace'],
              shadows: [for (var i = 0; i < 3; i++) Shadow(color: onSat ? Colors.black : p['labelHalo'], blurRadius: 3)],
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout(maxWidth: 150);
        tp.paint(canvas, Offset(math.min(math.max(x - tp.width / 2, 2), size.width - tp.width - 2), y + (style == PinStyle.teardrop ? pinSize * 0.62 : pinSize * 0.62)));
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

class _Panel extends StatelessWidget {
  const _Panel({required this.theme, required this.ground, required this.style, required this.size, required this.pinSize, required this.labels, required this.caption, this.zoom = 1});
  final CacheThemeId theme;
  final _Ground ground;
  final PinStyle style;
  final Size size;
  final double pinSize;
  final bool labels;
  final String caption;
  final double zoom;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: CustomPaint(painter: _PinsPainter(theme: theme, ground: ground, style: style, pinSize: pinSize, labels: labels, zoom: zoom)),
          ),
        ),
        const SizedBox(height: 2),
        Text(caption, style: TextStyle(fontSize: 12, color: k.secondary)),
      ],
    );
  }
}

class _StylesPage extends StatelessWidget {
  const _StylesPage({required this.theme});
  final CacheThemeId theme;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final map = theme == CacheThemeId.light ? 'light map' : (theme == CacheThemeId.dark ? 'dark map' : 'Tactical map');
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 44, 16, 24),
        children: [
          Text('Pin styles, same places', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: k.text)),
          Text(theme == CacheThemeId.tactical ? 'Tactical: every pin is red; only the icon shape tells them apart.' : 'Each panel draws the same nine places.', style: TextStyle(fontSize: 13, color: k.secondary)),
          for (final (letter, name, style) in const [('A', 'Icon with a white halo', PinStyle.halo), ('B', 'Teardrop pin', PinStyle.teardrop), ('C', 'Rounded-square badge', PinStyle.badge)]) ...[
            const SizedBox(height: 14),
            Text('$letter  $name', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: k.text)),
            const SizedBox(height: 4),
            _Panel(theme: theme, ground: _Ground.map, style: style, size: const Size(358, 250), pinSize: 34, labels: true, caption: '$map, full size'),
            const SizedBox(height: 6),
            Row(
              children: [
                _Panel(theme: theme, ground: _Ground.satellite, style: style, size: const Size(175, 190), pinSize: 28, labels: false, caption: 'Satellite-like background'),
                const SizedBox(width: 8),
                _Panel(theme: theme, ground: _Ground.map, style: style, size: const Size(175, 190), pinSize: 24, labels: false, zoom: 0.62, caption: 'Zoomed out, pins at 70%'),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ---- the pictures --------------------------------------------------------------------------------------------------

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

  const insets = EdgeInsets.only(top: 44, bottom: 30);
  for (final theme in const [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.tactical]) {
    String name(String n) => '390-$n-${theme.name}';

    Future<_Rig> rig(WidgetTester tester, {double height = 844}) async {
      phone(tester, size: Size(390, height), ratio: 2);
      final r = _Rig();
      await tester.runAsync(r.load);
      return r;
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 80));
      }
    }

    Widget view(_Rig r, _P pl) => PlaceView(deps: r.deps(theme, pinFor: pl), book: r.book, entryId: r.ids[pl.name]!, icons: _setup);

    testWidgets('place view, ${theme.name}', (tester) async {
      final r = await rig(tester);
      await tester.pumpWidget(shotApp(view(r, _places[1]), theme: theme, insets: insets));
      await settle(tester);
      await snap(tester, _out, name('place-view'));
    });

    testWidgets('icon picker, ${theme.name}', (tester) async {
      final r = await rig(tester);
      await tester.pumpWidget(shotApp(view(r, _places[1]), theme: theme, insets: insets));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('place-icon')));
      await settle(tester);
      await snap(tester, _out, name('icon-picker'));
    });

    for (final (file, query) in const [('icon-picker-search-tent', 'tent'), ('icon-picker-search-spring', 'spring'), ('icon-picker-search-antenna', 'antenna')]) {
      testWidgets('icon picker searching $query, ${theme.name}', (tester) async {
        final r = await rig(tester);
        await tester.pumpWidget(shotApp(view(r, _places[1]), theme: theme, insets: insets));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('place-icon')));
        await settle(tester);
        await tester.enterText(find.byKey(const ValueKey('icon-search')), query);
        await settle(tester);
        await snap(tester, _out, name(file));
      });
    }

    testWidgets('notebook settings with a colour, ${theme.name}', (tester) async {
      final r = await rig(tester);
      final book = Notebook(id: r.book.id, template: 'places', def: r.book.def.copyWith(icon: 'trailhead', color: 'teal'), map: true, placeCount: _places.length, entryCount: _places.length);
      await tester.pumpWidget(shotApp(NotebookEditor(notebook: r.nb, existing: book, icons: _setup), theme: theme, insets: insets));
      await settle(tester);
      await snap(tester, _out, name('notebook-settings'));
    });

    testWidgets('pin styles, ${theme.name}', (tester) async {
      phone(tester, size: const Size(390, 1640), ratio: 2);
      await tester.pumpWidget(shotApp(_StylesPage(theme: theme), theme: theme, insets: EdgeInsets.zero));
      await tester.pump();
      await snap(tester, _out, name('map-pins'));
    });
  }
}
