// Run as its own process by test/pdf/pdfium_lock_test.dart: PDFium is used from two threads at once, as the app does when the PDF
// viewer (pdfrx's worker) and the core (Add PDF, in a background run) both read PDFs, which is only safe with the process's one PDFium
// lock (the core's, which pdfrx's worker takes around each PDFium call in third_party/pdfrx_engine).
//
//   hammer <same|different> <pdfium> <a.pdf> <b.pdf> <seconds>
//       the main isolate opens, draws and reads text from a.pdf over and over (the viewer) while another isolate has the core dump
//       (read text, draw every page) a.pdf or b.pdf over and over (the background add). Prints `ok <viewer calls> <core dumps>` and
//       exits 0 when nothing was corrupted or aborted; without the lock the process dies (a heap corruption or an access violation).
//   measure <pdfium> <seconds>
//       makes a large PDF, then times the viewer's page draws alone and with the core dumping it in a loop; prints JSON.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:pdfrx_engine/pdfrx_engine.dart';

import 'pdfium_child_support.dart';

/// The core reads [pdf] (text, labels, every page drawn) until [stop] is closed or [seconds] pass.
Future<void> _core(List<Object> a) async {
  final (lib, pdf, seconds, dpi, port) = (a[0] as String, a[1] as String, a[2] as int, a[3] as int, a[4] as SendPort);
  final end = DateTime.now().add(Duration(seconds: seconds));
  var n = 0;
  double longestText = 0, longestDraw = 0, longestOpen = 0;
  while (DateTime.now().isBefore(end)) {
    final r = core(lib, {'hash_model': false, 'load_embedder': false, 'dump': {'pdf': pdf, 'dpi': dpi, 'timings': true}});
    final d = r?['dump'];
    if (d is! Map) {
      port.send('no dump: $r');
      return;
    }
    n++;
    longestOpen = max(longestOpen, (d['open_ms'] as num).toDouble());
    for (final p in d['pages'] as List) {
      longestText = max(longestText, ((p as Map)['text_ms'] as num).toDouble());
      longestDraw = max(longestDraw, (p['draw_ms'] as num).toDouble());
    }
  }
  port.send({'dumps': n, 'longest_open_ms': longestOpen, 'longest_text_ms': longestText, 'longest_draw_ms': longestDraw});
}

/// The viewer: draw a page, read its text, move on; reopen the document every so often.
Future<({int calls, List<double> drawMs})> _viewer(String pdf, int seconds) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  var calls = 0;
  final drawMs = <double>[];
  PdfDocument? doc;
  var i = 0;
  while (DateTime.now().isBefore(end)) {
    if (doc == null || i % 40 == 0) {
      doc?.dispose();
      doc = await PdfDocument.openFile(pdf);
    }
    final page = doc.pages[i % doc.pages.length];
    final t = Stopwatch()..start();
    final img = await page.render(fullWidth: 700, fullHeight: 900);
    t.stop();
    drawMs.add(t.elapsedMicroseconds / 1000);
    img?.dispose();
    await page.loadText();
    calls += 3;
    i++;
  }
  doc?.dispose();
  return (calls: calls, drawMs: drawMs);
}

String _bigPdf(int pages) {
  final f = File('${Directory.systemTemp.createTempSync('pdf-big').path}/big.pdf');
  final objs = <String>['<< /Type /Catalog /Pages 2 0 R >>', '', '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'];
  final kids = <String>[];
  for (var p = 0; p < pages; p++) {
    final id = objs.length + 1;
    kids.add('$id 0 R');
    final c = StringBuffer();
    for (var l = 0; l < 48; l++) {
      c.write('BT /F1 10 Tf 40 ${760 - l * 14} Td (Page ${p + 1} line ${l + 1}: boil water for one minute, then let it cool in a clean covered container before use.) Tj ET\n');
    }
    objs.add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${id + 1} 0 R >>');
    objs.add('<< /Length ${c.length} >>\nstream\n$c\nendstream');
  }
  objs[1] = '<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${kids.length} >>';
  final out = StringBuffer('%PDF-1.4\n');
  final at = <int>[];
  for (var i = 0; i < objs.length; i++) {
    at.add(out.length);
    out.write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
  }
  final x = out.length;
  out.write('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n');
  for (final a in at) {
    out.write('${a.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n$x\n%%EOF\n');
  f.writeAsStringSync(out.toString());
  return f.path;
}

double _pct(List<double> v, double p) {
  final s = [...v]..sort();
  return s.isEmpty ? 0 : s[min(s.length - 1, (s.length * p).floor())];
}

Map<String, Object> _stats(List<double> v) => {'n': v.length, 'p50_ms': _pct(v, 0.5), 'p95_ms': _pct(v, 0.95), 'max_ms': v.isEmpty ? 0 : v.reduce(max)};

Future<void> main(List<String> args) async {
  final mode = args[0];
  if (mode == 'hammer') {
    final (same, lib, a, b, seconds) = (args[1] == 'same', args[2], args[3], args[4], int.parse(args[5]));
    await initChildPdfium(lib);
    final port = ReceivePort();
    final done = StreamIterator<Object?>(port);
    await Isolate.spawn(_core, <Object>[lib, same ? a : b, seconds, 72, port.sendPort]);
    final v = await _viewer(a, seconds);
    if (!await done.moveNext()) exit(3);
    final r = done.current;
    if (r is! Map) {
      stdout.writeln('$r');
      exit(4);
    }
    stdout.writeln('ok ${v.calls} ${r['dumps']}');
    exit(0);
  }
  // measure
  final (lib, seconds) = (args[1], int.parse(args[2]));
  await initChildPdfium(lib);
  final big = _bigPdf(400);
  final size = File(big).lengthSync();
  final alone = await _viewer(big, seconds);
  final port = ReceivePort();
  final done = StreamIterator<Object?>(port);
  await Isolate.spawn(_core, <Object>[lib, big, seconds, 150, port.sendPort]);
  final busy = await _viewer(big, seconds);
  if (!await done.moveNext()) exit(3);
  stdout.writeln(jsonEncode({'pdf_bytes': size, 'viewer_alone': _stats(alone.drawMs), 'viewer_with_core_dumping': _stats(busy.drawMs), 'core': done.current}));
  exit(0);
}
