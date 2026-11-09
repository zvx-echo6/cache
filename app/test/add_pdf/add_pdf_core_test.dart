// Add PDF end to end on the real core (CI's add-pdf-core job; skipped elsewhere): the app's AddPdfState drives the core's ingest
// job (cs_ingest_start, step, ocr) through CoreIngestCalls, with the real PDFium (the release pdfrx ships), the real bge-m3 embedder
// (a Linux libcache_llama and the pinned model) and the shelf sorter that ships in the app. Only OCR is a stand-in (Apple Vision and
// ML Kit run on phones; the cache_ocr engines have their own emulator and simulator runs in ocr.yml). My books is made the way the
// app makes it (the core's blank template), then a small text PDF, a small scanned PDF (an image page, no text layer) and a copy of
// the text PDF are added. It ends in a searchable book and Bookshelves events.
//
// Needs: CACHE_ADD_PDF_CORE=1, libcache_search.so and libcache_llama.so on LD_LIBRARY_PATH, CACHE_EMBED_LIB and CACHE_EMBED_MODEL.

import 'dart:convert';
import 'dart:io';

import 'package:cache/library/add_pdf/add_pdf_calls.dart';
import 'package:cache/library/add_pdf/add_pdf_engines.dart' show kPdfiumVersion;
import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:cache_ocr/cache_ocr.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import '../support/pdfium_for_tests.dart';

final bool _on = Platform.environment['CACHE_ADD_PDF_CORE'] == '1';

const _water = [
  'Water purification in the field. Boil water at a rolling boil for one minute to kill bacteria, viruses and protozoa.',
  'At altitudes above two thousand meters boil it for three minutes. Let it cool in a clean covered container.',
  'Chemical treatment with household bleach: add two drops of unscented bleach per liter, stir, and wait thirty minutes.',
  'Filters remove protozoa and bacteria but most do not remove viruses. Combine filtering with chlorine or boiling.',
  'Cloudy water should settle first, then be poured through a clean cloth before it is boiled or treated with chlorine.',
  'Store treated water in clean containers with tight lids and use it within six months. Label the date on each one.',
];

const _radio = 'Amateur radio operating procedures. Call CQ on a clear frequency, give your call sign, and listen. '
    'On the two meter band use simplex calling frequency 146.52 megahertz. Keep transmissions short and identify every ten minutes. '
    'Net control stations keep a log of check ins and pass traffic in order. Use phonetics for call signs and spell names.';

/// A small PDF with a text layer: each page's lines in Helvetica.
List<int> textPdf(String title, List<List<String>> pages) {
  String esc(String s) => s.replaceAll(r'\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');
  final objs = <List<int>>[];
  final kids = <String>[];
  objs.add(utf8.encode('<< /Type /Catalog /Pages 2 0 R >>'));
  objs.add(const []); // the page tree, written once the pages are known
  objs.add(utf8.encode('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'));
  objs.add(utf8.encode('<< /Title (${esc(title)}) /Producer (cache tests) >>'));
  for (final lines in pages) {
    final id = objs.length + 1;
    kids.add('$id 0 R');
    final c = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      c.write('BT /F1 10 Tf 40 ${740 - i * 14} Td (${esc(lines[i])}) Tj ET\n');
    }
    objs.add(utf8.encode('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${id + 1} 0 R >>'));
    final body = utf8.encode(c.toString());
    objs.add([...utf8.encode('<< /Length ${body.length} >>\nstream\n'), ...body, ...utf8.encode('endstream')]);
  }
  objs[1] = utf8.encode('<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${kids.length} >>');
  return _pdf(objs, info: 4);
}

/// A small "scanned" PDF: one page that is only a picture (a grey 8-bit image), no text layer.
List<int> scannedPdf() {
  const w = 200, h = 100;
  final pixels = List<int>.generate(w * h, (i) => (i % w < 100) ? 40 : 220);
  final objs = <List<int>>[
    utf8.encode('<< /Type /Catalog /Pages 2 0 R >>'),
    utf8.encode('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    utf8.encode('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Im1 5 0 R >> >> /Contents 4 0 R >>'),
  ];
  final draw = utf8.encode('q 500 0 0 250 56 400 cm /Im1 Do Q\n');
  objs.add([...utf8.encode('<< /Length ${draw.length} >>\nstream\n'), ...draw, ...utf8.encode('endstream')]);
  objs.add([
    ...utf8.encode('<< /Type /XObject /Subtype /Image /Width $w /Height $h /ColorSpace /DeviceGray /BitsPerComponent 8 /Length ${pixels.length} >>\nstream\n'),
    ...pixels,
    ...utf8.encode('\nendstream'),
  ]);
  return _pdf(objs);
}

List<int> _pdf(List<List<int>> objs, {int? info}) {
  final out = <int>[...utf8.encode('%PDF-1.4\n%âã\n')];
  final at = <int>[];
  for (var i = 0; i < objs.length; i++) {
    at.add(out.length);
    out
      ..addAll(utf8.encode('${i + 1} 0 obj\n'))
      ..addAll(objs[i])
      ..addAll(utf8.encode('\nendobj\n'));
  }
  final xref = out.length;
  final x = StringBuffer('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n');
  for (final a in at) {
    x.write('${a.toString().padLeft(10, '0')} 00000 n \n');
  }
  x.write('trailer\n<< /Size ${objs.length + 1} /Root 1 0 R ${info == null ? '' : '/Info $info 0 R '}>>\nstartxref\n$xref\n%%EOF\n');
  out.addAll(utf8.encode(x.toString()));
  return out;
}

void main() {
  test('Add PDF on the real core: a text PDF, a scanned PDF (OCR) and a copy end in a searchable book and Bookshelves events', () async {
    await pdfiumForTests();
    final tmp = Directory.systemTemp.createTempSync('add-pdf-core');
    final env = Platform.environment;
    final core = await SearchCore.open(const []);
    try {
      // My books, as the app makes it
      final lib = '${tmp.path}/libraries/my-books';
      Directory('${tmp.path}/libraries').createSync(recursive: true);
      final settings = ownLibrarySettings(title: 'My books', id: 'my-books-ci', isDefault: true);
      await makeBlankLibrary(core, lib, settings, Directory('${tmp.path}/tmp')..createSync());
      expect(Directory('$lib/shard').existsSync(), isTrue);
      expect(jsonDecode(File('$lib/cache-library.json').readAsStringSync())['own'], isTrue);

      // the shelf sorter as the app ships it
      final classifier = File('${tmp.path}/models/cache-classifier-2.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync(File('assets/models/cache-classifier-2.bin').readAsBytesSync());
      final engines = {
        'pdfium_lib': Pdfrx.pdfiumModulePath,
        'pdfium_version': kPdfiumVersion,
        'embed_lib': env['CACHE_EMBED_LIB'],
        'embed_model': env['CACHE_EMBED_MODEL'],
        'embed_sha256': 'c98c7c907bb3ab8c3be4c8ad827cc934c7c1a7e014d1c999e0c45c8027c158bb',
        'classifier': classifier.path,
      };
      // pdfrx is up already (pdfiumForTests); a test has no Flutter plugins for pdfrxFlutterInitialize
      final calls = CoreIngestCalls(init: () async {});
      final probe = await calls('probe', {'engines': engines, 'hash_model': false});
      // ignore: avoid_print
      print('probe: ${jsonEncode(probe)}');
      expect((probe['pdfium'] as Map)['ok'], isTrue);
      expect((probe['embedder'] as Map)['ok'], isTrue);
      expect((probe['classifier'] as Map)['ok'], isTrue);

      final shelves = '${tmp.path}/bookshelves';
      final ocr = FakeOcrEngine(engine: 'fake-ocr', version: '1', pages: {1: _radio});
      final state = AddPdfState(
        calls: calls,
        dir: () async => Directory('${tmp.path}/ingest'),
        engines: () async => engines,
        ocrEngine: () async => ocr,
        bookshelves: () async => {
          'dir': shelves,
          'dev': 'ci-device',
          'libraries': [
            {'library_id': 'my-books-ci', 'dir': lib},
          ],
        },
        permit: (_) async {},
      );
      Future<AddPdfJob> add(String name, List<int> bytes) async {
        final f = File('${tmp.path}/picked/$name')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes);
        final job = await state.add(pdfPath: f.path, fileName: name, bytes: bytes.length, title: name.replaceAll('.pdf', ''), target: AddPdfTarget(title: 'My books', path: lib, isDefault: true));
        final run = await (await state.pending()).firstWhere((t) => t.key == job.key).start();
        final ok = await run.finished.timeout(const Duration(minutes: 20));
        // ignore: avoid_print
        print('$name: ${job.status.name} ${job.errorCode ?? ''} ${job.errorMessage ?? ''} ${jsonEncode(job.result)}');
        expect(ok, isTrue, reason: '$name: ${job.errorCode} ${job.errorMessage}');
        return job;
      }

      final text = textPdf('Water purification manual', [_water, _water.reversed.toList()]);
      final a = await add('Water purification manual.pdf', text);
      expect(a.result!['pieces'], greaterThan(0));
      expect(a.result!['ocr'], isNull);
      expect(File('$lib/bookshelf/${a.result!['copy']}.pdf').existsSync(), isTrue);

      final b = await add('Field radio handbook.pdf', scannedPdf());
      expect((b.result!['ocr'] as Map)['pages_ocrd'], 1);
      expect(ocr.asked.single.page, 1);
      expect(b.scans, 1);

      // the same text in another file: a spare copy of the first
      final c = await add('Water purification manual (2).pdf', [...text, ...utf8.encode('% another copy\n')]);

      // the Bookshelves log has events from this device
      final log = File('$shelves/log/ci-device.jsonl');
      expect(log.existsSync(), isTrue, reason: 'the Bookshelves events');
      final events = [for (final l in log.readAsLinesSync()) if (l.trim().isNotEmpty) jsonDecode(l) as Map];
      // ignore: avoid_print
      print('events: ${jsonEncode(events)}');
      expect(events, isNotEmpty);
      expect((c.result!['same'] as List?) ?? const [], isNotEmpty, reason: 'the copy is the same book');
      expect(events.any((e) => e['ev'] == 'same'), isTrue);
      final view = await core.shelvesResolve({
        'dir': shelves,
        'libraries': [
          {'library_id': 'my-books-ci', 'dir': lib},
        ],
      });
      expect(jsonEncode(view), contains(a.result!['copy'] as String));

      // searchable: the library opened in a core finds the first book, by meaning (the query embedded by the phone's own
      // embedder, as the Library search does) and, when the library has a keyword index, by its words
      // ignore: avoid_print
      print('library folder: ${[for (final e in Directory(lib).listSync()) e.uri.pathSegments.where((x) => x.isNotEmpty).last]}');
      final searcher = await SearchCore.open([SourceConfig.library(path: '$lib/shard', indexDir: '$lib/index', settings: settings)]);
      final embedder = CacheEmbedder(modelPath: env['CACHE_EMBED_MODEL']!);
      try {
        final v = await embedder.embed('how long do I boil water to make it safe');
        SearchResponse? r;
        for (var i = 0; i < 50 && r == null; i++) {
          try {
            r = await searcher.search('boil water purification', k: 5, queryVector: QueryVector(embedder.modelId, v));
          } on CacheSearchException catch (e) {
            if (e.code != 'busy') rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }
        // ignore: avoid_print
        print('search: ${[for (final h in r!.results) h.title]} vector ${r.vectorSources} keyword-only ${r.keywordOnlySources}');
        expect(r.results.map((h) => h.title), contains('Water purification manual'));
        try {
          final k = await searcher.search('purification', k: 5);
          // ignore: avoid_print
          print('keyword search: ${[for (final h in k.results) h.title]}');
        } on CacheSearchException catch (e) {
          // ignore: avoid_print
          print('keyword search: $e');
        }
      } finally {
        await embedder.dispose();
        await searcher.close();
      }
    } finally {
      await core.close();
      tmp.deleteSync(recursive: true);
    }
  }, skip: _on ? false : 'needs the real core (CACHE_ADD_PDF_CORE=1; CI add-pdf-core job)', timeout: const Timeout(Duration(minutes: 45)));
}
