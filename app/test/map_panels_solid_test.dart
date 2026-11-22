import 'dart:io';

import 'package:cache/maps/ui/map_widgets.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/maps_screen.dart' show MeasurePanel;
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The panels over the map are fully solid (alpha 1) in all four themes, so the map's labels never show through them. Only the scale
/// and the credits chips are see-through, on purpose.
void main() {
  for (final id in CacheThemeId.values) {
    testWidgets('mapPanel is solid by default in the ${id.name} theme, and the surface colour is opaque', (tester) async {
      late BoxDecoration d;
      late Color surface;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(id),
        home: Builder(builder: (context) {
          d = mapPanel(context);
          surface = context.t.surface;
          return const SizedBox();
        }),
      ));
      expect(d.color!.a, 1.0);
      expect(surface.a, 1.0, reason: 'the theme surface itself is not see-through');
      expect(d.color, surface);
    });

    testWidgets('the measure panel is solid over the map in the ${id.name} theme', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(id),
        home: Scaffold(
          body: Stack(children: [
            Container(color: const Color(0xFFFF00FF)),
            Align(alignment: Alignment.bottomCenter, child: MeasurePanel(total: const Fmt(UnitSystem.imperial).distance(1932), points: 3, canUndo: true, onUndo: () {}, onDone: () {})),
          ]),
        ),
      ));
      final box = tester.widgetList<DecoratedBox>(find.descendant(of: find.byType(MeasurePanel), matching: find.byType(DecoratedBox))).map((d) => d.decoration).whereType<BoxDecoration>().firstWhere((d) => d.boxShadow != null);
      expect(box.color!.a, 1.0);
    });
  }

  test('the repeater card, route panel, route steps, elevation dock, guidance dock, search panel and place card ask for no alpha under 1', () {
    final seen = <String>[];
    for (final f in ['maps/ui/repeater_card.dart', 'nav/ui/route_panel.dart', 'nav/ui/route_steps.dart', 'nav/ui/elevation_dock.dart', 'nav/ui/guidance_panels.dart', 'nav/ui/search_panel.dart', 'nav/ui/place_card.dart']) {
      final text = File('lib/$f').readAsStringSync();
      expect(text, contains('mapPanel('), reason: '$f draws its panel with mapPanel');
      for (final m in RegExp(r'mapPanel\([^)]*alpha:\s*([0-9.]+)').allMatches(text)) {
        seen.add('$f ${m.group(1)}');
      }
    }
    expect(seen, isEmpty, reason: 'a panel that passes an alpha is see-through: $seen');
  });

  test('only the scale and credits chips pass a lower alpha', () {
    final found = <String>[];
    for (final e in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      for (final m in RegExp(r'mapPanel\([^)]*alpha:\s*([0-9.]+)').allMatches(e.readAsStringSync())) {
        if (m.group(1) != '1') found.add('${e.path} ${m.group(1)}');
      }
    }
    expect(found.map((s) => s.split(' ').last).toList()..sort(), ['0.75', '0.78'], reason: 'the two chips in map_widgets.dart: $found');
  });
}
