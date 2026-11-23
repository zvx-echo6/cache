import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/sharing/link_url.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zxing2/qrcode.dart';

/// The link-code QR is drawn by the app's own widget, then read back the way a camera app reads one (zxing2, a pure Dart port of the
/// ZXing reader; a dev dependency only). Variants: the full picture, the same on the dark theme, and a copy shrunk to 40% with a blur
/// (what a camera frame looks like). The long legacy link at the old settings (error correction L, 260 px) is a documented
/// comparison: what happens is printed, and only the plain picture must read.

const _short = 'CACHE-7KQF-M2XD-P4WN-R7TA-H3JC-V6YB-Q5LE-W2FS-ZQ';
const _ratio = 3.0; // a 3x phone

/// A 600-character legacy link code (`CACHE1-` and Base32 text), as the engine made them before the short code.
final _legacy = 'CACHE1-${List.generate(593, (i) => 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'[(i * 7 + i ~/ 5) % 32]).join()}';

class _Pic {
  _Pic(this.w, this.h, this.gray);
  final int w, h;
  final Float64List gray; // 0 black .. 255 white
}

/// Draws [child] on a [bg] page with 24 points of its own around it, at most 326 wide (the room inside the card on a 390 wide phone), and returns the pixels.
Future<_Pic> _render(WidgetTester tester, Widget child, {required CacheThemeId theme, Color bg = Colors.white}) async {
  tester.view.physicalSize = const Size(390, 600) * _ratio;
  tester.view.devicePixelRatio = _ratio;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(theme),
      home: Scaffold(
        backgroundColor: bg,
        body: Center(
          child: RepaintBoundary(
            key: key,
            child: Container(color: bg, padding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 326), child: child)),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return (await tester.runAsync(() async {
    final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await b.toImage(pixelRatio: _ratio);
    final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    final g = Float64List(img.width * img.height);
    for (var i = 0; i < g.length; i++) {
      g[i] = 0.299 * data[i * 4] + 0.587 * data[i * 4 + 1] + 0.114 * data[i * 4 + 2];
    }
    return _Pic(img.width, img.height, g);
  }))!;
}

/// What a camera frame does to the picture: shrunk to [scale] (area average) and blurred (3x3 box, [blur] passes), plus a little noise.
_Pic _degrade(_Pic p, double scale, {int blur = 1}) {
  final w = (p.w * scale).round(), h = (p.h * scale).round();
  var g = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final x0 = x / scale, x1 = (x + 1) / scale, y0 = y / scale, y1 = (y + 1) / scale;
      var sum = 0.0, n = 0.0;
      for (var yy = y0.floor(); yy < math.min(p.h, y1.ceil()); yy++) {
        for (var xx = x0.floor(); xx < math.min(p.w, x1.ceil()); xx++) {
          final wx = math.min(xx + 1, x1) - math.max(xx, x0), wy = math.min(yy + 1, y1) - math.max(yy, y0);
          final wgt = wx * wy;
          sum += p.gray[yy * p.w + xx] * wgt;
          n += wgt;
        }
      }
      g[y * w + x] = sum / n;
    }
  }
  for (var k = 0; k < blur; k++) {
    final o = Float64List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var s = 0.0, n = 0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx, yy = y + dy;
            if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
            s += g[yy * w + xx];
            n++;
          }
        }
        o[y * w + x] = s / n;
      }
    }
    g = o;
  }
  final rnd = math.Random(7);
  for (var i = 0; i < g.length; i++) {
    g[i] = (g[i] + (rnd.nextDouble() - 0.5) * 12).clamp(0, 255);
  }
  return _Pic(w, h, g);
}

/// Reads the picture; null when no code can be read in it.
Result? _decode(_Pic p) {
  final px = Int32List(p.w * p.h);
  for (var i = 0; i < px.length; i++) {
    final v = p.gray[i].round().clamp(0, 255);
    px[i] = 0xFF000000 | (v << 16) | (v << 8) | v;
  }
  final bitmap = BinaryBitmap(HybridBinarizer(RGBLuminanceSource(p.w, p.h, px)));
  try {
    return QRCodeReader().decode(bitmap, hints: DecodeHints()..put(DecodeHintType.tryHarder));
  } on Object {
    return null; // NotFound, Checksum or Format: not readable
  }
}

String _ec(Result r) => '${r.resultMetadata[ResultMetadataType.errorCorrectionLevel]}';

/// The white margin around the black modules, in picture pixels (the smallest of the four sides).
int _quietPx(_Pic p) {
  var l = p.w, r = p.w, t = p.h, b = p.h;
  for (var y = 0; y < p.h; y++) {
    for (var x = 0; x < p.w; x++) {
      if (p.gray[y * p.w + x] < 100) {
        l = math.min(l, x);
        r = math.min(r, p.w - 1 - x);
        t = math.min(t, y);
        b = math.min(b, p.h - 1 - y);
      }
    }
  }
  return [l, r, t, b].reduce(math.min);
}

void main() {
  final link = buildLinkUrl(_short);

  group('the short link code QR, drawn by LinkQr and read back', () {
    testWidgets('settings: Q, version and module size at 390 wide', (tester) async {
      final modules = LinkQr.modulesFor(link);
      final version = (modules - 17) ~/ 4;
      final pic = await _render(tester, LinkQr(link: link), theme: CacheThemeId.light);
      final size = tester.getSize(find.byType(LinkQr));
      final modulePx = size.width / (modules + 2 * kQrQuietModules);
      // ignore: avoid_print
      print('short link: ${link.length} chars, version $version, $modules modules, widget ${size.width} px, $modulePx logical px per module '
          '(${modulePx * _ratio} device px at ${_ratio}x)');
      expect(link.length, 65);
      expect(modulePx, greaterThanOrEqualTo(6), reason: 'at least 6 logical px per module');
      expect(size.width, lessThanOrEqualTo(326), reason: 'fits the card on a 390 wide phone');
      final quiet = _quietPx(pic) - 24 * _ratio; // the drawn page has 24 of its own white around the widget
      // ignore: avoid_print
      print('quiet zone: ${quiet / (modulePx * _ratio)} modules (${quiet}px)');
      expect(quiet, greaterThanOrEqualTo(4 * modulePx * _ratio - 1), reason: 'at least 4 modules of white round the code');
    });

    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      testWidgets('reads back exactly, at full size and as a 40% blurred camera frame (${theme.name})', (tester) async {
        // on the dark theme the page behind the white square is dark: the code must still be black on its own white
        final pic = await _render(tester, LinkQr(link: link), theme: theme, bg: theme == CacheThemeId.dark ? const Color(0xFF1B1B1B) : Colors.white);
        final modules = LinkQr.modulesFor(link);
        final full = _decode(pic);
        expect(full, isNotNull, reason: 'the picture itself reads');
        expect(full!.text, link);
        expect(_ec(full), 'Q', reason: 'error correction level read back');
        expect(full.version, (modules - 17) ~/ 4, reason: 'version read back');
        final cam = _decode(_degrade(pic, 0.4));
        expect(cam, isNotNull, reason: 'the 40% blurred copy reads');
        expect(cam!.text, link);
        // ignore: avoid_print
        print('short ${theme.name}: full OK (v${full.version}, ${_ec(full)}), 40% blur OK (${(pic.w * 0.4).round()} px wide, '
            '${(modules + 8) * 6 * _ratio * 0.4 / (modules + 8)} device px per module)');
      });
    }

    testWidgets('how small a camera frame can get (information, not a requirement)', (tester) async {
      final pic = await _render(tester, LinkQr(link: link), theme: CacheThemeId.light);
      final out = <String>[];
      for (final s in [0.4, 0.3, 0.25, 0.2, 0.17, 0.14, 0.12]) {
        final r = _decode(_degrade(pic, s));
        out.add('${(s * 100).round()}% (${(6 * _ratio * s).toStringAsFixed(1)} px/module): ${r?.text == link ? 'reads' : 'fails'}');
      }
      // ignore: avoid_print
      print('short code, shrink sweep with blur: ${out.join(', ')}');
    });
  });

  group('the 600-character legacy link (information: what the old settings did)', () {
    final legacy = buildLinkUrl(_legacy);

    testWidgets('old settings (L, 260 px, 10 px padding): plain picture reads; the 40% blurred copy is an expectation, not a requirement', (tester) async {
      final pic = await _render(
        tester,
        Container(color: Colors.white, padding: const EdgeInsets.all(10), child: QrImageView(data: legacy, size: 260, backgroundColor: Colors.white, errorCorrectionLevel: QrErrorCorrectLevel.L)),
        theme: CacheThemeId.light,
      );
      final full = _decode(pic);
      final cam = _decode(_degrade(pic, 0.4));
      // ignore: avoid_print
      print('legacy ${legacy.length} chars at old L: full ${full?.text == legacy ? 'OK' : 'FAILS'} (v${full?.version}, ${full == null ? '-' : _ec(full)}), '
          '40% blur ${cam?.text == legacy ? 'OK' : 'FAILS'}; 2.8 logical px per module (85 modules in 240)');
      final sweep = <String>[];
      for (final sc in [0.4, 0.3, 0.25, 0.2, 0.17, 0.14, 0.12]) {
        sweep.add('${(sc * 100).round()}% (${(240 / 85 * _ratio * sc).toStringAsFixed(1)} px/module): ${_decode(_degrade(pic, sc))?.text == legacy ? 'reads' : 'fails'}');
      }
      // ignore: avoid_print
      print('legacy at old L, shrink sweep with blur: ${sweep.join(', ')}');
      expect(full?.text, legacy, reason: 'a plain, full-size picture reads');
      // Expectation only: at 2.8 px per module the degraded copy is known to be at the edge. Not asserted either way.
    });

    testWidgets('the same legacy link through LinkQr now: it still renders and reads at full size', (tester) async {
      final pic = await _render(tester, LinkQr(link: legacy), theme: CacheThemeId.light);
      final modules = LinkQr.modulesFor(legacy);
      final full = _decode(pic);
      final cam = _decode(_degrade(pic, 0.4));
      // ignore: avoid_print
      print('legacy via LinkQr (Q): $modules modules, ${tester.getSize(find.byType(LinkQr)).width} px wide; full ${full?.text == legacy ? 'OK' : 'FAILS'} '
          '(v${full?.version}, ${full == null ? '-' : _ec(full)}); 40% blur ${cam?.text == legacy ? 'OK' : 'FAILS'}');
      expect(full?.text, legacy);
      expect(tester.takeException(), isNull);
    });
  });
}
