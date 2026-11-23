import 'dart:convert';

import 'package:cache/maps/map_hover.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final style = jsonEncode({
    'layers': [
      {'id': 'places', 'type': 'symbol', 'paint': {'text-color': '#111111', 'text-halo-width': 1.5}},
      {'id': 'roads', 'type': 'symbol', 'paint': {'text-color': '#222222'}},
      {'id': 'trail', 'type': 'line', 'paint': {'line-color': '#333333'}},
      {'id': 'bg', 'type': 'background'},
    ],
  });
  final layers = styleLayersById(style);

  group('mouse hover is for a browser and Linux desktop only', () {
    test('gate', () {
      expect(mouseHoverOn(web: true, linuxDesktop: false), isTrue);
      expect(mouseHoverOn(web: false, linuxDesktop: true), isTrue);
      expect(mouseHoverOn(web: false, linuxDesktop: false), isFalse);
    });
  });

  group('the highlight paint', () {
    test('a symbol layer gets the colour on the hovered name only, the style\'s own for the rest', () {
      final p = hoverPaint(layers['places']!, 'Boise', '#ff8800');
      expect(p['text-color'], [
        'case',
        ['==', ['get', 'name'], 'Boise'],
        '#ff8800',
        '#111111',
      ]);
      expect((p['text-halo-width'] as List)[2], 2);
      expect((p['text-halo-width'] as List)[3], 1.5);
    });

    test('a property the style does not set falls back to its default', () {
      final p = hoverPaint(layers['roads']!, 'Main St', '#ff8800');
      expect((p['text-halo-width'] as List)[3], 0);
    });

    test('lines are coloured, a layer with nothing to highlight is left alone', () {
      expect(hoverPaint(layers['trail']!, 'Loop', '#ff8800').keys, ['line-color']);
      expect(hoverPaint(layers['bg']!, 'x', '#ff8800'), isEmpty);
    });

    test('resting paint is what the style has', () {
      expect(restPaint(layers['places']!), {'text-color': '#111111', 'text-halo-width': 1.5});
      expect(restPaint(layers['bg']!), isEmpty);
    });

    test('raw paint sends only what it holds', () {
      expect(const RawPaint({'line-color': '#fff'}).toJson(skipNulls: false), {'line-color': '#fff'});
    });
  });

  group('MapHover keeps the one highlighted feature', () {
    late List<(String, Map<String, Object?>)> calls;
    late MapHover hover;
    setUp(() {
      calls = [];
      hover = MapHover(apply: (id, paint) async => calls.add((id, paint)));
    });

    test('entering a feature draws it; moving to another puts the first back and draws the second', () async {
      await hover.show(const HoverTarget(['places'], 'Boise'), layers, '#f80');
      expect(calls.map((c) => c.$1), ['places']);
      expect(calls.single.$2.containsKey('text-color'), isTrue);
      calls.clear();
      await hover.show(const HoverTarget(['roads'], 'Main St'), layers, '#f80');
      expect(calls.map((c) => c.$1), ['places', 'roads']);
      expect(calls.first.$2, {'text-color': '#111111', 'text-halo-width': 1.5});
    });

    test('the same feature again does nothing', () async {
      await hover.show(const HoverTarget(['places'], 'Boise'), layers, '#f80');
      calls.clear();
      await hover.show(const HoverTarget(['places'], 'Boise'), layers, '#f80');
      expect(calls, isEmpty);
    });

    test('leaving puts the layers back as the style has them', () async {
      await hover.show(const HoverTarget(['places'], 'Boise'), layers, '#f80');
      calls.clear();
      await hover.show(null, layers, '');
      expect(calls, [('places', {'text-color': '#111111', 'text-halo-width': 1.5})]);
      expect(hover.current, isNull);
    });

    test('a feature with no name changes no paint (the cursor alone shows it is clickable)', () async {
      await hover.show(const HoverTarget(['places'], null), layers, '#f80');
      await hover.show(null, layers, '');
      expect(calls, isEmpty);
    });

    test('after the style is applied again nothing is put back', () async {
      await hover.show(const HoverTarget(['places'], 'Boise'), layers, '#f80');
      calls.clear();
      hover.forget();
      await hover.show(null, layers, '');
      expect(calls, isEmpty);
    });

    test('a failing layer does not stop the rest', () async {
      final h = MapHover(apply: (id, paint) async {
        calls.add((id, paint));
        if (id == 'places') throw StateError('gone');
      });
      await h.show(const HoverTarget(['places', 'roads'], 'X'), layers, '#f80');
      expect(calls.map((c) => c.$1), ['places', 'roads']);
    });
  });
}
