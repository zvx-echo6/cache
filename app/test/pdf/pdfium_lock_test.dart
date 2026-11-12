// PDFium has one lock for the whole process. The core (Rust) takes it around each PDFium call, pdfrx's worker takes it around each of
// its callbacks (third_party/pdfrx_engine), so the PDF viewer and a background Add PDF never use PDFium (which is not thread-safe) at
// the same moment. Needs PDFium and the core (CACHE_PDF_FONTS=1 and libcache_search on the library path, as pdfium_font_mapper_test).
//
// - hammer: a child process whose main isolate draws and reads pages of one PDF (the viewer) while another isolate has the core read
//   and draw the SAME document, or ANOTHER one, over and over for a few seconds. It must end cleanly. Without the lock (the child run
//   with CACHE_NO_PDFIUM_LOCK=1, which is what the code before this change did) it corrupts PDFium's memory or aborts.
// - measure: how long the viewer's page draws take alone and while the core is reading a large PDF (the numbers are printed).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import '../support/pdfium_for_tests.dart';

final bool _on = Platform.environment['CACHE_PDF_FONTS'] == '1';
const _dir = 'test/fixtures/pdf_fonts';

String _dart() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final d = File('$root/bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}');
    if (d.existsSync()) return d.path;
  }
  return 'dart';
}

Future<ProcessResult> _child(List<String> args, {bool lock = true}) => Process.run(
      _dart(),
      ['--packages=.dart_tool/package_config.json', 'test/support/pdfium_hammer_child.dart', ...args],
      environment: {if (!lock) 'CACHE_NO_PDFIUM_LOCK': '1'},
    );

void main() {
  setUpAll(() async {
    if (_on) await pdfiumForTests();
  });

  group('the viewer and the core use PDFium at once', skip: _on ? null : 'needs PDFium and the core (CACHE_PDF_FONTS=1)', () {
    for (final same in [true, false]) {
      test('${same ? 'the same' : 'different'} document: nothing is corrupted or aborted', () async {
        final r = await _child(['hammer', same ? 'same' : 'different', Pdfrx.pdfiumModulePath!, '$_dir/mixed.pdf', '$_dir/calibri.pdf', '6']);
        expect(r.exitCode, 0, reason: 'the process ended with ${r.exitCode}\n${r.stdout}\n${r.stderr}');
        expect('${r.stdout}'.trim(), startsWith('ok '));
      }, timeout: const Timeout(Duration(minutes: 3)));
    }

    // A demonstration, not a check: corruption by a race is not certain in any six seconds, so it is not part of CI (CACHE_PDF_RACE_DEMO=1).
    test('without the lock the same two sides do corrupt PDFium (the check that the test can fail)', skip: Platform.environment['CACHE_PDF_RACE_DEMO'] == '1' ? null : 'a demonstration: CACHE_PDF_RACE_DEMO=1', () async {
      final r = await _child(['hammer', 'same', Pdfrx.pdfiumModulePath!, '$_dir/mixed.pdf', '$_dir/calibri.pdf', '6'], lock: false);
      expect(r.exitCode, isNot(0), reason: 'it ended cleanly without the lock: the hammer is too gentle to prove anything');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('the viewer stays usable while the core reads a large PDF: the draw times', () async {
      final r = await _child(['measure', Pdfrx.pdfiumModulePath!, '8']);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      // ignore: avoid_print
      print('LOCK MEASURE ${const JsonEncoder().convert(jsonDecode('${r.stdout}'.trim().split('\n').last))}');
    }, timeout: const Timeout(Duration(minutes: 4)));
  });
}
