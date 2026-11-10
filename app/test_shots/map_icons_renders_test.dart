// Map icons for notebooks and places, for review (design/map-icons, renders first; nothing here is wired into the app yet): the icon
// picker, a place's view and edit screens with its tappable icon (its own and the notebook's), notebook settings with "Map icon",
// map pins and the long-press ring, at 390 and 1440 wide in the light, dark and Tactical themes. The screens are the real
// PlaceView, PlaceForm, NotebookEditor, IconPicker and RingMenu; the live map is a platform view and is not drawn in a test, so the
// map is a stand-in painted from the map palette, with the pins drawn by the same code that makes the images added to the map
// style (paintMapPin).
// flutter test test_shots/map_icons_renders_test.dart --update-goldens  (pictures in test_shots/map_icons/)

import 'dart:math' as math;

import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/maps/ui/ring_menu.dart';
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
import 'package:flutter_test/flutter_test.dart';

import '../test/support/notebook_fake.dart';
import 'shot_kit.dart';

const _out = 'map_icons';
final DateTime _now = DateTime(2026, 11, 10, 12, 0);

/// Recent icons for the picker: the last six chosen.
const _recent = RecentIcons(['river', 'water', 'danger', 'camp', 'fire_pit', 'radio_tower']);
const _setup = MapIconSetup(recent: _recent, notebookTint: Color(0xFF3FBFAE));

/// The sample places: neutral public Idaho spots. [icon] is the place's own icon (null: its notebook's, the pin).
class _P {
  const _P(this.name, this.lat, this.lon, this.color, {this.icon});
  final String name;
  final double lat, lon;
  final String color;
  final String? icon;
}

const _places = [
  _P('Lucky Peak trailhead', 43.5300, -116.0600, 'teal'),
  _P('Boise River ford', 43.6010, -116.1450, 'teal', icon: 'river'),
  _P('Hulls Gulch spring', 43.6450, -116.1850, 'teal', icon: 'water'),
  _P('Dry Creek camp', 43.7050, -116.1250, 'teal', icon: 'camp'),
  _P('Rattlesnake slide', 43.5700, -116.0950, 'teal', icon: 'danger'),
];

/// A repeater list's repeaters (a map layer, not a notebook): the radio tower by default.
const _repeaters = [('Shafer Butte', 43.7630, -116.1000), ('Deer Point', 43.7380, -116.0980), ('Table Rock', 43.6200, -116.0650)];

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
        props: {'color': p.color, 'on_map': true, 'icon': ?p.icon},
      );
      ids[p.name] = e.id;
    }
    // The notebook as the screens get it (the fake store keeps no icon in a definition, as the core does not yet).
    final saved = nb.notebooks.firstWhere((n) => n.id == made.id);
    book = Notebook(
      id: saved.id,
      template: 'places',
      def: saved.def,
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

/// The colour a place's pin is drawn in: its marker colour, or the theme's red in Tactical.
Color _pinTint(CacheThemeId theme, String color) => theme == CacheThemeId.tactical ? cacheTokens[CacheThemeId.tactical]!.accent : markerColor(color).color;

// ---- the stand-in map ----------------------------------------------------------------------------------------------

void _paintBase(Canvas canvas, Size size, MapPalette p, {double shift = 0}) {
  canvas.drawRect(Offset.zero & size, Paint()..color = p['land']);
  final w = size.width, h = size.height;
  // parks and a lake
  for (final (fx, fy, fr) in const [(0.15, 0.22, 0.17), (0.78, 0.75, 0.2), (0.62, 0.12, 0.1)]) {
    canvas.drawOval(Rect.fromCenter(center: Offset(w * fx, h * fy), width: w * fr * 2.2, height: h * fr * 1.3), Paint()..color = p['park']);
  }
  canvas.drawOval(Rect.fromCenter(center: Offset(w * 0.86, h * 0.3), width: w * 0.22, height: h * 0.12), Paint()..color = p['water']);
  // the river
  final river = Path()
    ..moveTo(-10, h * (0.62 + shift))
    ..cubicTo(w * 0.25, h * 0.45, w * 0.4, h * 0.85, w * 0.62, h * 0.6)
    ..cubicTo(w * 0.8, h * 0.42, w * 0.9, h * 0.55, w + 10, h * 0.4);
  canvas.drawPath(river, Paint()..color = p['water']..style = PaintingStyle.stroke..strokeWidth = math.max(10, w * 0.022)..strokeCap = StrokeCap.round);
  // roads
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

/// The map of a place's screen: the base with the place's pin in the middle.
class _StandInMap extends StatelessWidget {
  const _StandInMap({required this.theme, required this.pin, required this.place, required this.book});
  final CacheThemeId theme;
  final NbPlace? pin;
  final _P? place;
  final Notebook book;

  @override
  Widget build(BuildContext context) {
    final p = mapPaletteFor(theme);
    final pl = place;
    final icon = mapIconOrTemplate(pl?.icon ?? book.def.icon ?? defaultNotebookIcon(book)).icon;
    final tint = _pinTint(theme, pl?.color ?? 'teal');
    return CustomPaint(
      painter: _OnePinPainter(p, icon, tint),
      size: Size.infinite,
    );
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
    paintMapPin(canvas, size.center(Offset.zero), 34, icon, tint, p['routeCasing']);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

class _Pin {
  const _Pin(this.name, this.lat, this.lon, this.icon, this.tint);
  final String name;
  final double lat, lon;
  final MapIcon icon;
  final Color tint;
}

/// The map region with all the pins, named under each as the map labels them.
class _PinsMap extends StatelessWidget {
  const _PinsMap({required this.theme, required this.size});
  final CacheThemeId theme;
  final Size size;

  @override
  Widget build(BuildContext context) {
    final p = mapPaletteFor(theme);
    final k = context.t;
    final trail = _pinTint(theme, 'teal');
    final radio = theme == CacheThemeId.tactical ? trail : markerColor('purple').color;
    final pins = [
      for (final pl in _places) _Pin(pl.name, pl.lat, pl.lon, mapIcon(pl.icon ?? kPlacesIcon), trail),
      for (final (n, la, lo) in _repeaters) _Pin(n, la, lo, mapIcon(kRepeaterIcon), radio),
    ];
    return Stack(
      children: [
        Positioned.fill(child: CustomPaint(painter: _PinsPainter(p, pins, size, k.text))),
      ],
    );
  }
}

class _PinsPainter extends CustomPainter {
  _PinsPainter(this.p, this.pins, this.shotSize, this.textColor);
  final MapPalette p;
  final List<_Pin> pins;
  final Size shotSize;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    _paintBase(canvas, size, p);
    const minLat = 43.50, maxLat = 43.79, minLon = -116.21, maxLon = -116.04;
    final pad = 44.0;
    for (final pin in pins) {
      final x = pad + (pin.lon - minLon) / (maxLon - minLon) * (size.width - 2 * pad);
      final y = pad + (maxLat - pin.lat) / (maxLat - minLat) * (size.height - 2 * pad - 60);
      final c = Offset(x, y);
      paintMapPin(canvas, c, 32, pin.icon.icon, pin.tint, p['routeCasing']);
      final tp = TextPainter(
        text: TextSpan(text: pin.name, style: TextStyle(fontFamily: 'Roboto', fontSize: 12.5, fontWeight: FontWeight.w600, color: p['labelPlace'], shadows: [Shadow(color: p['labelHalo'], blurRadius: 3), Shadow(color: p['labelHalo'], blurRadius: 3), Shadow(color: p['labelHalo'], blurRadius: 3)])),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: 160);
      tp.paint(canvas, Offset(x - tp.width / 2, y + 19));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

// ---- the pictures --------------------------------------------------------------------------------------------------

void main() {
  setUpAll(loadShotFonts);

  for (final size in const {'390': Size(390, 844), '1440': Size(1440, 900)}.entries) {
    final insets = size.key == '390' ? const EdgeInsets.only(top: 44, bottom: 30) : EdgeInsets.zero;
    for (final theme in const [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.tactical]) {
      String name(String n) => '${size.key}-$n-${theme.name}';

      Future<_Rig> rig(WidgetTester tester) async {
        phone(tester, size: size.value, ratio: size.key == '390' ? 2 : 1);
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

      testWidgets('place view, its own icon, ${size.key}, ${theme.name}', (tester) async {
        final r = await rig(tester);
        final pl = _places[1];
        await tester.pumpWidget(shotApp(PlaceView(deps: r.deps(theme, pinFor: pl), book: r.book, entryId: r.ids[pl.name]!, icons: _setup), theme: theme, insets: insets));
        await settle(tester);
        await snap(tester, _out, name('place-view-own-icon'));
      });

      testWidgets('place view, the notebook icon, ${size.key}, ${theme.name}', (tester) async {
        final r = await rig(tester);
        final pl = _places[0];
        await tester.pumpWidget(shotApp(PlaceView(deps: r.deps(theme, pinFor: pl), book: r.book, entryId: r.ids[pl.name]!, icons: _setup), theme: theme, insets: insets));
        await settle(tester);
        await snap(tester, _out, name('place-view-notebook-icon'));
      });

      testWidgets('place edit, ${size.key}, ${theme.name}', (tester) async {
        final r = await rig(tester);
        final pl = _places[1];
        final e = (await tester.runAsync(() => r.nb.entry(r.ids[pl.name]!)))!;
        await tester.pumpWidget(shotApp(PlaceForm(deps: r.deps(theme, pinFor: pl), book: r.book, entry: e, icons: _setup), theme: theme, insets: insets));
        await settle(tester);
        await snap(tester, _out, name('place-edit'));
      });

      testWidgets('icon picker from a place, ${size.key}, ${theme.name}', (tester) async {
        final r = await rig(tester);
        final pl = _places[1];
        await tester.pumpWidget(shotApp(PlaceView(deps: r.deps(theme, pinFor: pl), book: r.book, entryId: r.ids[pl.name]!, icons: _setup), theme: theme, insets: insets));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('place-icon')));
        await settle(tester);
        await snap(tester, _out, name('icon-picker'));
      });

      testWidgets('icon picker searching, ${size.key}, ${theme.name}', (tester) async {
        final r = await rig(tester);
        final pl = _places[1];
        await tester.pumpWidget(shotApp(PlaceView(deps: r.deps(theme, pinFor: pl), book: r.book, entryId: r.ids[pl.name]!, icons: _setup), theme: theme, insets: insets));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('place-icon')));
        await settle(tester);
        await tester.enterText(find.byKey(const ValueKey('icon-search')), 'fire');
        await settle(tester);
        await snap(tester, _out, name('icon-picker-search'));
      });

      testWidgets('notebook settings, ${size.key}, ${theme.name}', (tester) async {
        final r = await rig(tester);
        final book = Notebook(id: r.book.id, template: 'places', def: r.book.def.copyWith(icon: 'trailhead'), map: true, placeCount: _places.length, entryCount: _places.length);
        await tester.pumpWidget(shotApp(NotebookEditor(notebook: r.nb, existing: book, icons: _setup), theme: theme, insets: insets));
        await settle(tester);
        await snap(tester, _out, name('notebook-settings'));
      });

      testWidgets('map pins, ${size.key}, ${theme.name}', (tester) async {
        phone(tester, size: size.value, ratio: size.key == '390' ? 2 : 1);
        await tester.pumpWidget(shotApp(Scaffold(body: _PinsMap(theme: theme, size: size.value)), theme: theme, insets: insets));
        await tester.pump();
        await snap(tester, _out, name('map-pins'));
      });

      testWidgets('long-press ring, ${size.key}, ${theme.name}', (tester) async {
        phone(tester, size: size.value, ratio: size.key == '390' ? 2 : 1);
        final p = mapPaletteFor(theme);
        const items = [
          RingItem(id: 'a', label: 'Trail places', icon: Icons.place),
          RingItem(id: 'b', label: 'Water', icon: Icons.water_drop),
          RingItem(id: 'c', label: 'Camps', icon: Icons.holiday_village),
          RingItem(id: 'd', label: 'Journal', icon: Icons.edit_note),
          RingItem(id: 'e', label: 'Notes', icon: Icons.sticky_note_2_outlined),
          RingItem(id: 'f', label: 'More', icon: Icons.more_horiz),
        ];
        await tester.pumpWidget(shotApp(
          Scaffold(
            body: Stack(
              children: [
                Positioned.fill(child: CustomPaint(painter: _OnePinPainter(p, Icons.place, _pinTint(theme, 'teal')))),
                Positioned.fill(child: ColoredBox(color: Colors.black.withValues(alpha: 0.35))),
                Center(
                  child: Builder(
                    builder: (context) => RingMenu(
                      items: items,
                      onPick: (_) {},
                      centre: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.undo, size: 16, color: context.t.text), const SizedBox(width: 4), Text('Back', style: TextStyle(fontSize: 14, color: context.t.text))]),
                    ),
                  ),
                ),
              ],
            ),
          ),
          theme: theme,
          insets: insets,
        ));
        await tester.pump();
        await snap(tester, _out, name('ring'));
      });
    }
  }
}
