// Shared by the child processes of test/pdf/pdfium_font_mapper_test.dart and pdfium_lock_test.dart (plain Dart: no Flutter).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';

/// What the app does wherever it starts pdfrx (app/lib/pdf/pdfium_init.dart): the core installs its one native PDFium font mapper and
/// answers with the addresses of its one PDFium lock, which pdfrx's worker then takes around each PDFium call. The core library is
/// found by CACHE_CORE_LIB or its usual name on the library path; without it PDFium has its own default fonts and no lock.
Map<String, dynamic>? core(String pdfium, [Map<String, dynamic> extra = const {}]) {
  final name = Platform.environment['CACHE_CORE_LIB'] ?? (Platform.isWindows ? 'cache_search.dll' : 'libcache_search.so');
  try {
    final lib = DynamicLibrary.open(name);
    final probe = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>('cs_ingest_probe');
    final free = lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('cs_free_string');
    final request = jsonEncode({
      'engines': {'pdfium_lib': pdfium},
      if (extra.isEmpty) ...{'fonts': true, 'fonts_only': true} else ...extra,
    });
    final arg = request.toNativeUtf8();
    final out = probe(arg);
    calloc.free(arg);
    if (out == nullptr) return null;
    final reply = out.toDartString();
    free(out);
    return (jsonDecode(reply) as Map).cast<String, dynamic>();
  } catch (e) {
    stderr.writeln('no native font mapper (the core is not here: $e)');
    return null;
  }
}

/// The lock functions the core answered with (see `core`), or null.
PdfiumLockFunctions? lockFunctionsOf(Map<String, dynamic>? reply) {
  final f = reply?['lock_fns'];
  if (f is! Map) return null;
  return (acquire: f['acquire'] as int, release: f['release'] as int, dropOwner: f['drop_owner'] as int, finalize: f['finalize'] as int);
}

Future<void> initChildPdfium(String lib) async {
  Pdfrx.pdfiumModulePath = lib;
  final reply = core(lib);
  // the core's native font mapper must be the one PDFium has: without the core, or with a mapper that was not installed, the test is
  // not testing what the app runs
  final fonts = reply?['fonts'];
  if (fonts is! Map || fonts['installed'] != true) {
    stderr.writeln('the core did not install its native font mapper: $reply');
    exit(11);
  }
  final fns = lockFunctionsOf(reply);
  if (fns != null && Platform.environment['CACHE_NO_PDFIUM_LOCK'] != '1') PdfiumLock.functions = fns;
  await pdfrxInitialize(tmpPath: Directory.systemTemp.createTempSync('pdfrx-child').path);
}

Future<String> text(String pdf) async {
  final doc = await PdfDocument.openFile(pdf);
  try {
    final b = StringBuffer();
    for (final page in doc.pages) {
      b.write((await page.loadText())?.fullText);
    }
    return b.toString();
  } finally {
    doc.dispose();
  }
}


