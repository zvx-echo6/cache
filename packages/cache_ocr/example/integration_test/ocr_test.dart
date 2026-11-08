// Real text recognition on an Android emulator (ML Kit) or an iOS simulator (Apple Vision), run by .github/workflows/ocr.yml.
//
// The fixtures are what the core's ingest job hands the app: grayscale PNGs of US Letter pages at 300 dpi (2550 x 3300), made
// from known text and made to look scanned by tool/make_fixtures.py (in CI, before the build), and bundled as assets. The test
// writes them to files, as the core does, reads them through ocrForIngest, checks the phrases come back, and prints each page's
// time and memory on an `OCR-MEASURE` line (the workflow copies them into the run's summary).
import 'dart:convert';
import 'dart:io';

import 'package:cache_ocr/cache_ocr.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

final _clock = Stopwatch()..start();

void log(String s) {
  // ignore: avoid_print
  print('[${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s] $s');
}

String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// The share of [expected]'s words that came back, order-free.
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

/// Each page within a time limit, and logged as it starts, so a stuck engine fails the test with the page named.
class _Timed implements OcrEngine {
  _Timed(this.inner);
  final OcrEngine inner;
  @override
  String get engine => inner.engine;
  @override
  String get version => inner.version;
  @override
  Future<OcrPageText> recognize(OcrPageImage image) {
    log('reading page ${image.page} (${image.width}x${image.height} at ${image.dpi} dpi)');
    return inner.recognize(image).timeout(const Duration(minutes: 4));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real OCR on grayscale 300 dpi page images', (tester) async {
    final engine = _Timed((await deviceOcrEngine())!);
    expect(engine.engine, Platform.isIOS ? 'apple-vision' : 'mlkit');
    // ignore: avoid_print
    print('OCR-ENGINE ${jsonEncode({'engine': engine.engine, 'version': engine.version, 'os': Platform.operatingSystemVersion})}');

    final spec = (jsonDecode(await rootBundle.loadString('assets/fixtures/expected.json')) as Map)['pages'] as List;
    final dir = await Directory.systemTemp.createTemp('ocrtest');
    final pages = <OcrPageImage>[];
    final expected = <int, Map>{};
    for (final p in spec.cast<Map>()) {
      final bytes = await rootBundle.load('assets/fixtures/${p['file']}');
      final path = '${dir.path}/${p['file']}';
      await File(path).writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes), flush: true);
      pages.add(OcrPageImage(page: p['page'] as int, imagePath: path, width: p['width'] as int, height: p['height'] as int, dpi: p['dpi'] as int));
      expected[p['page'] as int] = p;
    }
    log('${pages.length} page images written');
    final before = await ocrMemory();

    // The core's way: one needs_ocr batch through the entry point; then pages 1 and 2 again, warm.
    final sw = Stopwatch()..start();
    final wall = <int, double>{};
    var last = 0.0;
    final batch = await ocrForIngest(7, [for (final p in pages) p.toJson()], engine, onPage: (p) {
      final now = sw.elapsedMicroseconds / 1000;
      wall[p.page] = now - last;
      last = now;
      log('page ${p.page} done: ${p.text.length} chars');
    });
    expect(batch.failed, isEmpty, reason: '${batch.failed}');
    expect(batch.ingestParams['engine'], engine.engine);
    final warm = [for (final p in pages.take(2)) await engine.recognize(p)];

    void report(String run, OcrPageText r, double? wallMs) {
      final p = expected[r.page]!;
      final text = p['text'] as String;
      // ignore: avoid_print
      print('OCR-MEASURE ${jsonEncode({
        'run': run,
        'page': r.page,
        'dpi': p['dpi'],
        'pt': p['pt'],
        'px': '${p['width']}x${p['height']}',
        'wall_ms': wallMs?.round(),
        ...?r.stats?.toJson().map((k, v) => v is double ? MapEntry(k, v.round()) : MapEntry(k.replaceAll('_bytes', '_mb'), (v as int) ~/ 1048576)),
        'confidence': double.parse(r.confidence.toStringAsFixed(3)),
        'recall': text.isEmpty ? null : double.parse(wordRecall(text, r.text).toStringAsFixed(3)),
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
    for (final r in batch.pages) {
      log('page ${r.page} text:\n${r.text}');
    }

    final byPage = {for (final r in batch.pages) r.page: r};
    for (final n in [1, 2, 4]) {
      expect(norm(byPage[n]!.text), contains(norm(expected[n]!['phrase'] as String)), reason: 'page $n');
      expect(wordRecall(expected[n]!['text'] as String, byPage[n]!.text), greaterThanOrEqualTo(0.95), reason: 'page $n');
      expect(byPage[n]!.confidence, greaterThan(0.3), reason: 'page $n');
      expect(byPage[n]!.stats, isNotNull);
    }
    // lines joined by \n
    expect(byPage[1]!.text, contains('\n'));
    // the blank page: nothing, or at most a stray mark read from the speckle
    expect(byPage[3]!.text.length, lessThanOrEqualTo(3), reason: 'blank page read as "${byPage[3]!.text}"');

    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 20)));
}
