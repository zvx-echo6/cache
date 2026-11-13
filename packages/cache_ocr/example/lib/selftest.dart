import 'dart:convert';
import 'dart:io';

import 'package:cache_ocr/cache_ocr.dart';
import 'package:flutter/services.dart';

/// Reads the bundled fixture pages through deviceOcrEngine() and ocrForIngest, as the app does, and prints
/// `OCR-RESULT pass` or `OCR-RESULT fail <page> <code> <message>` (one line per failed page). Release-build check.
Future<void> runOcrSelfTest() async {
  // ignore: avoid_print
  void out(String s) => print(s);
  try {
    final engine = await deviceOcrEngine();
    if (engine == null) {
      out('OCR-RESULT fail 0 no_engine deviceOcrEngine() returned null');
      return;
    }
    out('OCR-ENGINE ${engine.engine} ${engine.version} ${Platform.operatingSystemVersion}');
    final spec = (jsonDecode(await rootBundle.loadString('assets/fixtures/expected.json')) as Map)['pages'] as List;
    final dir = await Directory.systemTemp.createTemp('ocrself');
    final needs = <Map<String, dynamic>>[];
    for (final p in spec.cast<Map>()) {
      final bytes = await rootBundle.load('assets/fixtures/${p['file']}');
      final path = '${dir.path}/${p['file']}';
      await File(path).writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes), flush: true);
      needs.add({'page': p['page'], 'image_path': path, 'width': p['width'], 'height': p['height'], 'dpi': p['dpi']});
    }
    final sw = Stopwatch()..start();
    final batch = await ocrForIngest(7, needs, engine, onPage: (p) => out('OCR-PAGE ${p.page} chars=${p.text.length} t=${sw.elapsedMilliseconds}ms'));
    if (batch.failed.isEmpty) {
      out('OCR-RESULT pass');
    } else {
      batch.failed.forEach((page, e) => out('OCR-RESULT fail $page ${e.code} ${e.message}'));
    }
  } catch (e, st) {
    out('OCR-RESULT fail 0 exception $e\n$st');
  }
}
