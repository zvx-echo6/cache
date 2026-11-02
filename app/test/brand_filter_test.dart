import 'dart:typed_data';

import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renders a dark patch and a light patch through [filter] and returns their RGBA bytes.
Future<List<List<int>>> _render(WidgetTester tester, ColorFilter? filter) async {
  final key = GlobalKey();
  Widget patches() => const Row(
        textDirection: TextDirection.ltr,
        children: [
          SizedBox(width: 10, height: 10, child: ColoredBox(color: Color(0xFF202020))),
          SizedBox(width: 10, height: 10, child: ColoredBox(color: Color(0xFFE0E0E0))),
        ],
      );
  await tester.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: RepaintBoundary(
        key: key,
        child: SizedBox(width: 20, height: 10, child: filter == null ? patches() : ColorFiltered(colorFilter: filter, child: patches())),
      ),
    ),
  ));
  late ByteData data;
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    data = (await image.toByteData())!;
  });
  List<int> px(int x) => [for (var c = 0; c < 4; c++) data.getUint8((5 * 20 + x) * 4 + c)];
  return [px(5), px(15)];
}

void main() {
  testWidgets('Tactical brand filter keeps dark and light apart, in the theme hue, never all white', (tester) async {
    final k = cacheTokens[CacheThemeId.tactical]!;
    expect(k.brandFilter, isNotNull);
    final out = await _render(tester, k.brandFilter);
    final dark = out[0], light = out[1];
    expect(dark, isNot(equals(light)), reason: 'the two patches must not collapse to one colour');
    expect(light[0], greaterThan(dark[0]), reason: 'lighter source stays lighter');
    expect(light.sublist(0, 3), isNot(equals([255, 255, 255])), reason: 'not blank white');
    // Red hue: red channel carries the tone, blue and green stay well below it.
    expect(light[0], greaterThan(light[1] + 40));
    expect(light[0], greaterThan(light[2] + 40));
    expect(dark[3], 255, reason: 'alpha passes through');
  });

  test('full-colour themes have no brand filter', () {
    for (final id in [CacheThemeId.dark, CacheThemeId.light, CacheThemeId.parchment]) {
      expect(cacheTokens[id]!.brandFilter, isNull, reason: id.name);
    }
  });
}
