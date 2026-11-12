// PDFium's font mapper must have exactly one owner for the life of the process. pdfrx used to install its own (Dart callbacks bound
// to the isolate that started it) in every Flutter engine, so a second engine (the background run) replaced the first one's and a
// font lookup from the wrong isolate, or after an engine ended, aborted the app ("Cannot invoke native callback from a different
// isolate"). The core now installs one native mapper for the process and pdfrx no longer installs its own (third_party/pdfrx_engine).
//
// Two groups, both needing PDFium (downloaded once, as pdfium_for_tests.dart does) and CACHE_PDF_FONTS=1:
// - the abort test: a child process with two isolates that both start PDFium and read a PDF with fonts that are not embedded (`exited`,
//   `alive`, `interleaved`); it exits 0 when nothing aborts. It fails on the old code, with the abort.
// - the golden test: every fixture in test/fixtures/pdf_fonts/ read by the core the way Add PDF reads it (the text layer and a SHA-256
//   of each page drawn at 72 dpi), compared byte for byte with test/fixtures/pdf_fonts/golden/<name>.json, which was made on the code
//   before this change. CACHE_PDF_FONTS_UPDATE=1 writes them instead. Also needs libcache_search on the library path.

import 'dart:convert';
import 'dart:io';

import 'package:cache/library/add_pdf/add_pdf_calls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import '../support/pdfium_for_tests.dart';

final bool _on = Platform.environment['CACHE_PDF_FONTS'] == '1';
final bool _update = Platform.environment['CACHE_PDF_FONTS_UPDATE'] == '1';

const _dir = 'test/fixtures/pdf_fonts';
const _fixtures = ['times', 'courier', 'helvetica', 'symbol', 'arial', 'calibri', 'wingdings', 'mixed', 'cjk', 'embedded', 'scanned'];

String _dart() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final d = File('$root/bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}');
    if (d.existsSync()) return d.path;
  }
  return 'dart';
}

void main() {
  setUpAll(() async {
    if (_on) await pdfiumForTests();
  });

  group('two isolates of one process use PDFium', skip: _on ? null : 'needs PDFium (CACHE_PDF_FONTS=1)', () {
    for (final mode in ['exited', 'alive', 'interleaved']) {
      for (final fixture in ['calibri', 'mixed', 'cjk']) {
        test('$mode, $fixture.pdf: nothing aborts', () async {
          final r = await Process.run(
            _dart(),
            ['--packages=.dart_tool/package_config.json', 'test/support/pdfium_two_isolates_child.dart', mode, Pdfrx.pdfiumModulePath!, '$_dir/$fixture.pdf'],
          );
          expect(r.exitCode, 0, reason: 'the process ended with ${r.exitCode}\n${r.stdout}\n${r.stderr}');
          expect('${r.stdout}'.trim(), 'ok');
        }, timeout: const Timeout(Duration(minutes: 3)));
      }
    }
  });

  group('the text and pages Add PDF reads are the same as before', skip: _on ? null : 'needs PDFium and the core (CACHE_PDF_FONTS=1)', () {
    for (final name in _fixtures) {
      test('$name.pdf', () async {
        final calls = CoreIngestCalls(init: () async {});
        final r = await calls.call('probe', {
          'engines': {'pdfium_lib': Pdfrx.pdfiumModulePath},
          'hash_model': false,
          'load_embedder': false,
          'dump': {'pdf': File('$_dir/$name.pdf').absolute.path, 'dpi': 72},
        });
        final dump = (r['dump'] as Map).cast<String, dynamic>();
        final os = Platform.operatingSystem;
        final golden = File('$_dir/golden/$name.json');
        final existing = golden.existsSync() ? (jsonDecode(golden.readAsStringSync()) as Map).cast<String, dynamic>() : null;
        // The text, labels and page sizes are the same on every platform; the SHA-256 of a drawn page is kept per operating system.
        if (_update) {
          final out = {
            'title': dump['title'],
            'pages': [
              for (final (i, p) in (dump['pages'] as List).indexed)
                {
                  for (final k in ['text', 'label', 'width', 'height', 'dpi']) k: (p as Map)[k],
                  'png_sha256': {
                    if (existing != null) ...(((existing['pages'] as List)[i] as Map)['png_sha256'] as Map).cast<String, String>(),
                    os: p['png_sha256'] as String,
                  },
                },
            ],
          };
          golden.parent.createSync(recursive: true);
          golden.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(out)}\n');
          return;
        }
        final want = (jsonDecode(golden.readAsStringSync()) as Map).cast<String, dynamic>();
        expect(dump['title'], want['title']);
        final gotPages = dump['pages'] as List;
        final wantPages = want['pages'] as List;
        expect(gotPages.length, wantPages.length, reason: 'the page count of $name.pdf changed');
        for (var i = 0; i < wantPages.length; i++) {
          final g = (gotPages[i] as Map).cast<String, dynamic>(), w = (wantPages[i] as Map).cast<String, dynamic>();
          for (final k in ['text', 'label', 'width', 'height', 'dpi']) {
            expect(g[k], w[k], reason: 'page ${i + 1} of $name.pdf: $k changed');
          }
          final hashes = (w['png_sha256'] as Map).cast<String, dynamic>();
          if (hashes[os] != null) {
            expect(g['png_sha256'], hashes[os], reason: 'page ${i + 1} of $name.pdf is drawn differently');
          } else {
            // ignore: avoid_print
            print('$name.pdf page ${i + 1}: no drawn-page hash for $os yet (${g['png_sha256']})');
          }
        }
      });
    }
  });
}
