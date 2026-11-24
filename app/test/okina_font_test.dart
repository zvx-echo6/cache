import 'dart:io';

import 'package:cache/theme.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Linux web build draws text in Roboto (latin subset), which has no U+02BB (the okina in "Hawaiʻi"). The engine then asks for a
/// fallback font itself and gets an unbundled CJK one: an empty box. The theme names a bundled font that has it, so the engine never asks.
void main() {
  test('the theme names a bundled fallback font for the okina, and the font is in the app', () {
    for (final id in CacheThemeId.values) {
      final t = buildTheme(id).textTheme;
      for (final s in [t.bodyMedium, t.bodySmall, t.titleLarge, t.labelLarge]) {
        expect(s!.fontFamilyFallback, contains('Cache Okina'), reason: '$id');
      }
    }
    final pub = File('pubspec.yaml').readAsStringSync();
    expect(pub, contains('family: Cache Okina'));
    expect(pub, contains('assets/fonts/NotoSans-Okina.ttf'));
    expect(File('assets/fonts/NotoSans-Okina.ttf').lengthSync(), lessThan(20 * 1024), reason: 'a small subset, not a whole font');
    expect(File('assets/fonts/NotoSans-OFL.txt').existsSync(), isTrue, reason: 'the licence goes with the font');
  });
}
