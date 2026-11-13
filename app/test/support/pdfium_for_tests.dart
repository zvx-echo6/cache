import 'dart:io';

import 'package:cache/pdf/pdfium_init.dart' show pdfiumLockRequired;
import 'package:pdfrx/pdfrx.dart';

/// The PDFium release the app is built with (pdfium_dart's build hook downloads the same one into the app).
const String kTestPdfiumRelease = 'chromium%2F7811';

/// Loads PDFium for a test. `flutter test` does not hand pdfium_dart its native asset, so the library is found the way a
/// person would point at it: PDFIUM_PATH, a copy the build hook already made under .dart_tool or build/, or else the same
/// release from pdfium-binaries, downloaded once into the system temp folder (tests on CI have a network).
Future<void> pdfiumForTests() async {
  // the tests that run pdfrx without the core (it has the lock the app takes)
  pdfiumLockRequired = false;
  Pdfrx.pdfiumModulePath ??= _fromEnv() ?? _built() ?? await _downloaded();
  await pdfrxInitialize(tmpPath: Directory.systemTemp.createTempSync('pdfrx-cache').path);
}

String get _libName => Platform.isWindows ? 'pdfium.dll' : (Platform.isMacOS ? 'libpdfium.dylib' : 'libpdfium.so');

String? _fromEnv() {
  final p = Platform.environment['PDFIUM_PATH'];
  return p != null && File(p).existsSync() ? p : null;
}

String? _built() {
  for (final root in ['.dart_tool', 'build']) {
    final d = Directory(root);
    if (!d.existsSync()) continue;
    try {
      for (final f in d.listSync(recursive: true, followLinks: false).whereType<File>()) {
        if (f.uri.pathSegments.last == _libName) return f.absolute.path;
      }
    } on FileSystemException {
      // A folder that cannot be listed is skipped.
    }
  }
  return null;
}

Future<String> _downloaded() async {
  final (platform, member) = Platform.isWindows
      ? ('win-x64', 'bin/pdfium.dll')
      : Platform.isMacOS
          ? ('mac-${_isArm ? 'arm64' : 'x64'}', 'lib/libpdfium.dylib')
          : ('linux-${_isArm ? 'arm64' : 'x64'}', 'lib/libpdfium.so');
  final dir = Directory('${Directory.systemTemp.path}/cache-test-pdfium-${kTestPdfiumRelease.replaceAll('%2F', '-')}-$platform');
  final lib = File('${dir.path}/$member');
  if (lib.existsSync()) return lib.path;
  dir.createSync(recursive: true);
  final tgz = '${dir.path}/pdfium.tgz';
  final url = 'https://github.com/bblanchon/pdfium-binaries/releases/download/$kTestPdfiumRelease/pdfium-$platform.tgz';
  final get = await Process.run('curl', ['-sSfL', '--retry', '3', '-o', tgz, url]);
  if (get.exitCode != 0) throw StateError('PDFium download failed: ${get.stderr}');
  final x = await Process.run('tar', ['-xzf', tgz, '-C', dir.path, member]);
  if (x.exitCode != 0) throw StateError('PDFium unpack failed: ${x.stderr}');
  return lib.path;
}

bool get _isArm => Platform.version.contains('arm64');
