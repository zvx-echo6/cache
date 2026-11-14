// A bench, not a check (skipped unless CACHE_ADD_PDF_BENCH=1 and the add-pdf-core environment is set): the same PDFs added through
// the real core with the embed batch at 8 (the old step) and at 1 (one piece a step), three runs each, interleaved, so the cost
// of the finer step is measured. Prints the times.
import 'dart:convert';
import 'dart:io';

import 'package:cache/library/add_pdf/add_pdf_calls.dart';
import 'package:cache/library/add_pdf/add_pdf_engines.dart' show kPdfiumVersion;
import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import '../support/pdfium_for_tests.dart';
import 'add_pdf_core_test.dart' show textPdf;

final bool _on = Platform.environment['CACHE_ADD_PDF_BENCH'] == '1';

const _lines = [
  'Water purification in the field. Boil water at a rolling boil for one minute to kill bacteria, viruses and protozoa.',
  'At altitudes above two thousand meters boil it for three minutes. Let it cool in a clean covered container.',
  'Chemical treatment with household bleach: add two drops of unscented bleach per liter, stir, and wait thirty minutes.',
  'Filters remove protozoa and bacteria but most do not remove viruses. Combine filtering with chlorine or boiling.',
  'Cloudy water should settle first, then be poured through a clean cloth before it is boiled or treated with chlorine.',
  'Store treated water in clean containers with tight lids and use it within six months. Label the date on each one.',
];

void main() {
  test('embed batch 8 against 1: the same PDFs through the real core', () async {
    await pdfiumForTests();
    final env = Platform.environment;
    final core = await SearchCore.open(const []);
    final tmp = Directory.systemTemp.createTempSync('add-pdf-bench');
    try {
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
      final calls = CoreIngestCalls(init: () async {});
      final results = <String, List<int>>{};
      var n = 0;
      Future<void> one(String label, int pages, int batch, int round) async {
        final d = '${tmp.path}/r${n++}';
        final lib = '$d/libraries/my-books';
        Directory('$d/libraries').createSync(recursive: true);
        final settings = ownLibrarySettings(title: 'My books', id: 'bench-$n', isDefault: true);
        await makeBlankLibrary(core, lib, settings, Directory('$d/tmp')..createSync());
        final state = AddPdfState(
          calls: calls,
          dir: () async => Directory('$d/ingest'),
          engines: () async => engines,
          permit: (_) async {},
          embedBatch: batch,
          stepBudgetMs: 400,
        );
        // each PDF's text differs a little, so no run is a copy of another
        final bytes = textPdf('Bench $label $round', [for (var i = 0; i < pages; i++) [for (final l in (i.isEven ? _lines : _lines.reversed)) '$l ($round.$i)']]);
        final f = File('$d/picked.pdf')..createSync(recursive: true)..writeAsBytesSync(bytes);
        final sw = Stopwatch()..start();
        final job = await state.add(pdfPath: f.path, fileName: 'picked.pdf', bytes: bytes.length, title: 'Bench $label $round', target: AddPdfTarget(title: 'My books', path: lib, isDefault: true));
        final run = await (await state.pending()).firstWhere((t) => t.key == job.key).start();
        expect(await run.finished, isTrue, reason: '${job.errorCode} ${job.errorMessage}');
        sw.stop();
        (results['$label batch $batch'] ??= []).add(sw.elapsedMilliseconds);
        // ignore: avoid_print
        print('BENCH $label batch $batch round $round: ${sw.elapsedMilliseconds} ms, ${jsonEncode({'pieces': job.result?['pieces']})}');
      }

      // a first add the numbers do not count (the model file and the libraries are read once)
      await one('warm-up', 6, 8, 0);
      results.clear();
      for (var round = 1; round <= 3; round++) {
        for (final pages in [6, 40]) {
          await one('$pages pages', pages, 8, round);
          await one('$pages pages', pages, 1, round);
        }
      }
      for (final e in results.entries) {
        final xs = e.value..sort();
        // ignore: avoid_print
        print('BENCH SUMMARY ${e.key}: runs ${e.value} ms, median ${xs[xs.length ~/ 2]} ms');
      }
    } finally {
      await core.close();
      tmp.deleteSync(recursive: true);
    }
  }, skip: _on ? false : 'a bench (CACHE_ADD_PDF_BENCH=1 and the add-pdf-core environment)', timeout: const Timeout(Duration(minutes: 40)));
}
