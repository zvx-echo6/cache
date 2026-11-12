// What happens to PDFium's one lock when the isolate holding it is KILLED (test/support/pdfium_lock_death_child.dart). The VM kills an
// isolate when it next returns to Dart: not inside a native call, so PDFium is left consistent, but the holder's `finally` never runs
// and the unlock is lost (checked here: with nothing telling the core the holder is gone, the lock is left held). The core lets go of a
// dead owner's hold when it is told: by the spawner's exit listener, or by a NativeFinalizer that the VM runs when the owner's isolate
// group shuts down (as a destroyed Flutter engine's does). Needs PDFium and the core (CACHE_PDF_FONTS=1).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import '../support/pdfium_for_tests.dart';

final bool _on = Platform.environment['CACHE_PDF_FONTS'] == '1';

String _dart() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final d = File('$root/bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}');
    if (d.existsSync()) return d.path;
  }
  return 'dart';
}

Future<String> _run(String mode, String mechanism, String where) async {
  final r = await Process.run(_dart(), ['--packages=.dart_tool/package_config.json', 'test/support/pdfium_lock_death_child.dart', mode, mechanism, where, Pdfrx.pdfiumModulePath!]);
  // ignore: avoid_print
  print('LOCK-DEATH $mode/$mechanism/$where\n${r.stdout}${r.stderr}');
  expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
  return '${r.stdout}';
}

void main() {
  setUpAll(() async {
    if (_on) await pdfiumForTests();
  });

  group('a killed holder of the PDFium lock', skip: _on ? null : 'needs PDFium and the core (CACHE_PDF_FONTS=1)', () {
    for (final mode in ['native', 'dart', 'await']) {
      for (final where in ['same', 'group']) {
        test('$mode, $where: with nothing telling the core, the lock is left held and the finally never runs', () async {
          final out = await _run(mode, 'none', where);
          expect(out, contains('probe TIMEOUT'));
          expect(out, isNot(contains('finally ran')), reason: 'a killed isolate does not run its finally');
        }, timeout: const Timeout(Duration(minutes: 2)));
      }
    }

    test('the spawner\'s exit listener frees it', () async {
      final out = await _run('native', 'listener', 'same');
      expect(out, contains('probe acquired'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the finalizer frees it when the holder\'s isolate group shuts down', () async {
      final out = await _run('native', 'finalizer', 'group');
      expect(out, contains('probe acquired'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the finalizer, for a holder of the same isolate group (informational: it runs when the VM collects the object)', () async {
      await _run('native', 'finalizer', 'same');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
