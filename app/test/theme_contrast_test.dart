import 'dart:math' as math;

import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _lin(double c) => c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
double _lum(Color c) => 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b);
double ratio(Color a, Color b) {
  final x = _lum(a), y = _lum(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

void main() {
  // Tactical is left as it was (red on black for night vision), so it is not held to the palette check.
  for (final id in CacheThemeId.values.where((i) => i != CacheThemeId.tactical)) {
    final k = cacheTokens[id]!;
    test('${id.name}: text and actions are readable (WCAG AA 4.5:1)', () {
      final pairs = <String, double>{
        'text/background': ratio(k.text, k.background),
        'text/surface': ratio(k.text, k.surface),
        'secondary/background': ratio(k.secondary, k.background),
        'secondary/surface': ratio(k.secondary, k.surface),
        'accent/background': ratio(k.accent, k.background),
        'accent/surface': ratio(k.accent, k.surface),
        'onPrimary/primary': ratio(k.onPrimary, k.primary),
        'ok/surface': ratio(k.ok, k.surface),
        'warning/surface': ratio(k.warning, k.surface),
        'emergency/surface': ratio(k.emergency, k.surface),
      };
      pairs.forEach((name, r) {
        // ignore: avoid_print
        print('CONTRAST ${id.name} $name ${r.toStringAsFixed(2)}');
        expect(r, greaterThanOrEqualTo(4.5), reason: '${id.name} $name');
      });
    });
  }
}
