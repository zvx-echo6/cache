// Real text recognition on an Android emulator (ML Kit) or an iOS simulator (Apple Vision), run by .github/workflows/ocr.yml.
//
// The fixtures are what the core's ingest job hands the app: grayscale PNGs of US Letter pages at 300 dpi (2550 x 3300), made
// here from known text so the test knows what must come back. Each page is drawn with the device's own font, then made to
// look scanned (turned 0.6 degrees, softened, off-white paper with speckle), and written as an 8-bit grayscale PNG with its
// dpi in a pHYs chunk. Every page's time and memory is printed on an `OCR-MEASURE` line (the workflow copies them into the
// run's summary).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cache_ocr/cache_ocr.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const kPhrase1 = 'Boil water for one full minute before drinking it';
const kPhrase2 = 'Keep the signal mirror in your left chest pocket';

const kPage1 = 'Chapter 3. Safe Water\n\n'
    'Water from streams, lakes and springs can carry germs that make you sick even when it looks clear. '
    '$kPhrase1. At elevations above two thousand meters, boil it for three minutes. '
    'Let the water cool on its own and keep it in a clean, covered container.\n\n'
    'If you cannot boil water, filter it through a clean cloth and treat it with household bleach: '
    'eight drops for every gallon, stirred and left to stand for thirty minutes.';

const kPage2 = 'Signalling for help\n\n'
    'Three of anything is a call for help: three fires, three whistle blasts, three flashes of light. '
    '$kPhrase2 so you can reach it without taking off your pack. '
    'Sweep the flash slowly across the horizon, even when you see no aircraft, because a pilot can see it from far away.';

/// One US Letter page of [text] at [dpi] in [pt]-point type, as the core renders it, written to [path].
Future<OcrPageImage> scannedPage(String path, int page, String text, {int dpi = 300, double pt = 11, int seed = 1}) async {
  final w = (8.5 * dpi).round(), h = (11 * dpi).round();
  final margin = dpi.toDouble();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFFF1EFEA));
  if (text.isNotEmpty) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: const Color(0xFF262626), fontSize: pt / 72 * dpi, height: 1.35)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w - 2 * margin);
    canvas.save();
    canvas.translate(w / 2, h / 2);
    canvas.rotate(0.6 * math.pi / 180);
    canvas.translate(-w / 2, -h / 2);
    tp.paint(canvas, Offset(margin, margin));
    canvas.restore();
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  image.dispose();
  picture.dispose();

  // Grayscale, a little softened (a 3-tap box across each row) and speckled, as a scanner gives it.
  final gray = Uint8List(w * h);
  for (var i = 0, p = 0; i < gray.length; i++, p += 4) {
    gray[i] = (rgba[p] * 299 + rgba[p + 1] * 587 + rgba[p + 2] * 114) ~/ 1000;
  }
  final rnd = math.Random(seed);
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      final a = gray[row + (x > 0 ? x - 1 : x)], b = gray[row + x], c = gray[row + (x < w - 1 ? x + 1 : x)];
      var v = (a + 2 * b + c) ~/ 4 + rnd.nextInt(17) - 8;
      if (rnd.nextInt(4000) == 0) v = 90; // dust
      out[row + x] = v.clamp(0, 255);
    }
  }
  await File(path).writeAsBytes(grayPng(w, h, out, dpi), flush: true);
  return OcrPageImage(page: page, imagePath: path, width: w, height: h, dpi: dpi);
}

/// An 8-bit grayscale PNG (colour type 0) with its resolution in pHYs.
Uint8List grayPng(int w, int h, Uint8List pixels, int dpi) {
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < h; y++) {
    raw.addByte(0);
    raw.add(Uint8List.sublistView(pixels, y * w, (y + 1) * w));
  }
  final b = BytesBuilder();
  b.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final t = ascii.encode(type);
    b.add(_u32(data.length));
    b.add(t);
    b.add(data);
    b.add(_u32(_crc32([...t, ...data])));
  }

  final ppm = (dpi / 0.0254).round();
  chunk('IHDR', [..._u32(w), ..._u32(h), 8, 0, 0, 0, 0]);
  chunk('pHYs', [..._u32(ppm), ..._u32(ppm), 1]);
  chunk('IDAT', ZLibEncoder(level: 6).convert(raw.takeBytes()));
  chunk('IEND', const []);
  return b.takeBytes();
}

List<int> _u32(int v) => [(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255];

final List<int> _crcTable = List.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final x in data) {
    c = _crcTable[(c ^ x) & 255] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// The share of [expected]'s words that came back, in order-free form.
double wordRecall(String expected, String got) {
  final want = norm(expected).split(' ');
  final have = <String, int>{};
  for (final w in norm(got).split(' ')) {
    have[w] = (have[w] ?? 0) + 1;
  }
  var hit = 0;
  for (final w in want) {
    final n = have[w] ?? 0;
    if (n > 0) {
      hit++;
      have[w] = n - 1;
    }
  }
  return hit / want.length;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real OCR on grayscale 300 dpi page images', (tester) async {
    final engine = (await deviceOcrEngine())!;
    expect(engine.engine, Platform.isIOS ? 'apple-vision' : 'mlkit');
    // ignore: avoid_print
    print('OCR-ENGINE ${jsonEncode({'engine': engine.engine, 'version': engine.version, 'os': Platform.operatingSystemVersion})}');

    final dir = await Directory.systemTemp.createTemp('ocrtest');
    final before = await ocrMemory();
    final pages = [
      await scannedPage('${dir.path}/1.png', 1, kPage1, seed: 1),
      await scannedPage('${dir.path}/2.png', 2, kPage2, pt: 9, seed: 2),
      await scannedPage('${dir.path}/3.png', 3, '', seed: 3),
      // the same small-type page at 200 dpi, to see what a lower ocr_dpi would cost in accuracy and save in time and memory
      await scannedPage('${dir.path}/4.png', 4, kPage2, dpi: 200, pt: 9, seed: 4),
    ];
    final expected = {1: kPage1, 2: kPage2, 3: '', 4: kPage2};

    // First the core's way: one needs_ocr batch through the entry point; then pages 1 and 2 again, warm.
    final sw = Stopwatch()..start();
    final wall = <int, double>{};
    var last = 0.0;
    final batch = await ocrForIngest(7, [for (final p in pages) p.toJson()], engine, onPage: (p) {
      wall[p.page] = sw.elapsedMicroseconds / 1000 - last;
      last = sw.elapsedMicroseconds / 1000;
    });
    expect(batch.failed, isEmpty);
    expect(batch.ingestParams['engine'], engine.engine);
    final warm = [for (final p in pages.take(2)) await engine.recognize(p)];

    void report(String run, OcrPageText r, double? wallMs) {
      final p = pages.firstWhere((x) => x.page == r.page);
      // ignore: avoid_print
      print('OCR-MEASURE ${jsonEncode({
        'run': run,
        'page': r.page,
        'dpi': p.dpi,
        'px': '${p.width}x${p.height}',
        'wall_ms': wallMs?.round(),
        ...?r.stats?.toJson().map((k, v) => v is double ? MapEntry(k, v.round()) : MapEntry(k.replaceAll('_bytes', '_mb'), (v as int) ~/ 1048576)),
        'confidence': double.parse(r.confidence.toStringAsFixed(3)),
        'recall': expected[r.page]!.isEmpty ? null : double.parse(wordRecall(expected[r.page]!, r.text).toStringAsFixed(3)),
        'chars': r.text.length,
      })}');
    }

    for (final r in batch.pages) {
      report('cold', r, wall[r.page]);
    }
    for (final r in warm) {
      report('warm', r, null);
    }
    final after = await ocrMemory();
    // ignore: avoid_print
    print('OCR-MEMORY ${jsonEncode({'start_mb': before.currentBytes ~/ 1048576, 'end_mb': after.currentBytes ~/ 1048576, 'peak_mb': after.peakBytes ~/ 1048576})}');
    // ignore: avoid_print
    print('OCR-TEXT page 2:\n${batch.pages[1].text}');

    final byPage = {for (final r in batch.pages) r.page: r};
    expect(norm(byPage[1]!.text), contains(norm(kPhrase1)));
    expect(norm(byPage[2]!.text), contains(norm(kPhrase2)));
    expect(wordRecall(kPage1, byPage[1]!.text), greaterThanOrEqualTo(0.95));
    expect(wordRecall(kPage2, byPage[2]!.text), greaterThanOrEqualTo(0.95));
    expect(byPage[1]!.confidence, greaterThan(0.3));
    // the blank page: nothing, or at most a stray mark read from the speckle
    expect(byPage[3]!.text.length, lessThanOrEqualTo(3), reason: 'blank page read as "${byPage[3]!.text}"');
    expect(byPage[1]!.text, contains('\n'));
    expect(byPage[1]!.stats, isNotNull);

    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
