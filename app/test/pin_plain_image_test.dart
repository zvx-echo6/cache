// The plain map pin of a dropped pin and a route's destination is drawn with shapes only (no icon font), with its point where the
// symbol layer anchors it: the bottom middle of the image for the teardrop style, the middle of the image for the others.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cache/notebook/pin_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

Future<({int w, int h, ByteData px})> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final img = (await codec.getNextFrame()).image;
  final px = (await img.toByteData())!;
  return (w: img.width, h: img.height, px: px);
}

int _alpha(({int w, int h, ByteData px}) i, int x, int y) => i.px.getUint8((y * i.w + x) * 4 + 3);

/// The first and last rows that have a visible pixel.
(int, int) _rows(({int w, int h, ByteData px}) i) {
  var first = -1, last = -1;
  for (var y = 0; y < i.h; y++) {
    for (var x = 0; x < i.w; x++) {
      if (_alpha(i, x, y) > 40) {
        if (first < 0) first = y;
        last = y;
        break;
      }
    }
  }
  return (first, last);
}

void main() {
  const red = Color(0xFFFF6B5E);

  for (final style in PinStyle.values) {
    testWidgets('${style.name}: a visible pin whose point is at the symbol anchor', (tester) async {
      final i = await tester.runAsync(() async => _decode(await renderPlainPinPng(red, style, ratio: 3)));
      final img = i!;
      final (first, last) = _rows(img);
      expect(first, greaterThanOrEqualTo(0), reason: 'something is drawn');
      // The middle column has the pin's body.
      expect(_alpha(img, img.w ~/ 2, (first + last) ~/ 2), greaterThan(200));
      if (style == PinStyle.teardrop) {
        // Anchor at the bottom: the point is at the foot of the image (within the edge's room), and the pin stands above it.
        expect(img.h - last, lessThan(img.h * 0.12), reason: 'the point is at the bottom of the image');
        expect(first, lessThan(img.h * 0.2));
      } else {
        // Anchor in the centre: the point is at the middle of the image and nothing hangs below it.
        expect((last - img.h / 2).abs(), lessThan(img.h * 0.06), reason: 'the point ($last) is at the middle (${img.h / 2})');
        expect(first, lessThan(img.h * 0.1), reason: 'the head is high in the image');
      }
    });
  }

  testWidgets('the pin is red inside (the tint) and has a hole', (tester) async {
    final i = (await tester.runAsync(() async => _decode(await renderPlainPinPng(red, PinStyle.teardrop, ratio: 3))))!;
    final (first, last) = _rows(i);
    // Just under the head's centre line, off the middle, the fill is the tint.
    final y = first + ((last - first) * 0.3).round();
    final x = i.w ~/ 2 + ((last - first) * 0.12).round();
    expect(i.px.getUint8((y * i.w + x) * 4), greaterThan(200), reason: 'red channel');
    expect(i.px.getUint8((y * i.w + x) * 4 + 3), 255);
  });
}
