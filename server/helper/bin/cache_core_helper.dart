import 'dart:ffi';
import 'dart:io';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/native_io.dart';
import 'core_open.dart';
import 'fs_ops.dart';
import 'guide_install.dart';
import 'host_load.dart';
import 'index_driver.dart';
import 'pdf_zim_indexer.dart';
import 'line_protocol.dart';

/// Cache for Linux's core helper. CACHE_CORE_LIB is the absolute path of libcache_search.so (cache_search.dll on Windows).
/// CACHE_APP_SUPPORT and CACHE_APP_DOCS are the app's support and documents folders on the server (both required); `fs.*` ops and
/// the core's config work on them. CACHE_VALHALLA_SHIM is the full path of libvalhalla_shim.so (the core's road router).
/// Speaks the line protocol of bin/line_protocol.dart on stdin/stdout; logs go to stderr only.
Future<void> main() async {
  final path = Platform.environment['CACHE_CORE_LIB'];
  if (path == null || path.isEmpty) {
    stderr.writeln('cache_core_helper: CACHE_CORE_LIB is not set');
    exit(2);
  }
  final DynamicLibrary lib;
  try {
    lib = DynamicLibrary.open(path);
  } catch (e) {
    stderr.writeln('cache_core_helper: cannot open $path: $e');
    exit(2);
  }
  final dirs = AppDirs.fromEnvironment(Platform.environment);
  if (dirs == null) {
    stderr.writeln('cache_core_helper: CACHE_APP_SUPPORT and CACHE_APP_DOCS are not set');
    exit(2);
  }
  for (final d in [dirs.support, dirs.docs]) {
    d.createSync(recursive: true);
  }
  final dispatcher = CoreDispatcher(() => FfiCsNative(lib));
  void log(String m) => stderr.writeln('cache_core_helper: $m');
  final extras = serverCoreExtras(dirs);
  // The PDFs inside ZIMs are read by the server program itself (`cache pdf-text`, MuPDF); without it (a helper run by hand) they are
  // not indexed.
  final pdfExe = Platform.environment['CACHE_PDF_TEXT_EXE'];
  final indexes = extras['indexes_dir'];
  final pdf = pdfExe != null && pdfExe.isNotEmpty && indexes is String
      ? PdfWork(core: DispatcherPdfCore(dispatcher), read: PdfTextProcess(pdfExe, '${dirs.support.path}/tmp/pdf-text').read, indexesDir: indexes)
      : null;
  final indexer = IndexDriver(dispatcher, log: log, extra: extras, load: HostLoad(), pdf: pdf);
  // The guide library the app bundles, which the server's web build carries: installed here so guide search has something to search.
  final guidePath = Platform.environment['CACHE_GUIDE_LIBRARY'];
  final guide = guidePath != null && guidePath.isNotEmpty
      ? GuideInstaller(dispatcher, dirs, File(guidePath), log: log, onChanged: indexer.useSources)
      : null;
  await serveLines(
    stdin,
    (line) async {
      stdout.writeln(line);
      await stdout.flush();
    },
    dispatcher,
    log: log,
    handlers: [
      OpenOp(dirs, dispatcher, log: log, indexer: indexer, guide: guide),
      RescanOp(dirs, dispatcher, log: log, indexer: indexer),
      IndexStateOp(indexer),
      IndexPauseOp(indexer),
      FeaturesOp(dirs),
      FsOps(support: dirs.support, docs: dirs.docs),
    ],
  );
  indexer.stop();
  await stdout.flush();
  exit(0);
}
