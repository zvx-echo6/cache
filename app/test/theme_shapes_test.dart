// Every control is a 14 dp rounded rectangle, never a pill: the theme gives the buttons, segmented buttons, chips, the nav bar's
// indicator and the fields that corner, and no hard-coded pill is left in the code.

import 'dart:io';

import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _radius(ShapeBorder? s) {
  expect(s, isA<RoundedRectangleBorder>(), reason: 'a rounded rectangle, not $s');
  final r = (s as RoundedRectangleBorder).borderRadius.resolve(TextDirection.ltr);
  expect(r.topLeft.x, r.bottomRight.x);
  return r.topLeft.x;
}

void main() {
  test('the one constant is 14 dp', () => expect(kControlRadius, 14));

  for (final id in CacheThemeId.values) {
    group('${id.name} theme', () {
      final t = buildTheme(id);

      test('filled, outlined, text and elevated buttons are 14 dp rounded rectangles', () {
        for (final style in [t.filledButtonTheme.style, t.outlinedButtonTheme.style, t.textButtonTheme.style, t.elevatedButtonTheme.style]) {
          expect(_radius(style!.shape!.resolve({})), 14);
        }
      });

      test('segmented buttons, chips, the nav bar and the rail indicator are 14 dp', () {
        expect(_radius(t.segmentedButtonTheme.style!.shape!.resolve({})), 14);
        expect(_radius(t.chipTheme.shape), 14);
        expect(_radius(t.navigationBarTheme.indicatorShape), 14);
        expect(_radius(t.navigationRailTheme.indicatorShape), 14);
      });

      test('text fields are 14 dp rounded rectangles', () {
        for (final b in [t.inputDecorationTheme.border, t.inputDecorationTheme.enabledBorder, t.inputDecorationTheme.focusedBorder]) {
          expect((b! as OutlineInputBorder).borderRadius.resolve(TextDirection.ltr).topLeft.x, 14);
        }
      });
    });
  }

  testWidgets('a FilledButton, an OutlinedButton and a SegmentedButton really draw with that corner', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.parchment),
      home: Scaffold(
        body: Column(children: [
          FilledButton(onPressed: () {}, child: const Text('Go')),
          OutlinedButton(onPressed: () {}, child: const Text('Stop')),
          SegmentedButton<int>(segments: const [ButtonSegment(value: 1, label: Text('A')), ButtonSegment(value: 2, label: Text('B'))], selected: const {1}),
        ]),
      ),
    ));
    final shapes = tester.widgetList<Material>(find.descendant(of: find.byType(FilledButton), matching: find.byType(Material))).map((m) => m.shape).whereType<RoundedRectangleBorder>();
    expect(shapes, isNotEmpty);
    for (final s in shapes) {
      expect(_radius(s), 14);
    }
    expect(find.byType(SegmentedButton<int>), findsOneWidget);
  });

  test('no StadiumBorder and no radius-999 pill is left under lib/', () {
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (l.trimLeft().startsWith('//') || l.trimLeft().startsWith('///')) continue;
        if (l.contains('StadiumBorder') || l.contains('circular(999)') || RegExp(r'BorderRadius\.circular\((2[4-9]|[3-9]\d)\)').hasMatch(l) && !l.contains('Colors.black')) {
          hits.add('${f.path}:${i + 1}: ${l.trim()}');
        }
      }
    }
    expect(hits, isEmpty, reason: 'a pill is left:\n${hits.join('\n')}');
  });

  test('the search bar and the "Directions to" header use the control radius', () {
    for (final p in ['lib/nav/ui/search_panel.dart', 'lib/nav/ui/route_panel.dart']) {
      expect(File(p).readAsStringSync(), contains('mapPanel(context, radius: kControlRadius)'), reason: p);
      expect(File(p).readAsStringSync(), isNot(contains('radius: 28')), reason: p);
    }
  });
}
