import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/native_io.dart';
import 'core_open.dart';
import 'fs_ops.dart';
import 'guide_install.dart';
import 'history_ops.dart';
import 'host_load.dart';
import 'index_driver.dart';
import 'keystore.dart';
import 'pdf_zim_indexer.dart';
import 'line_protocol.dart';
import 'live_timer.dart';
import 'regions_ops.dart';
import 'sharing_host.dart';
import 'video_ops.dart';

/// Cache for Linux's core helper. CACHE_CORE_LIB is the absolute path of libcache_search.so (cache_search.dll on Windows).
/// CACHE_KEYSTORE is the keystore file (see keystore.dart). CACHE_APP_SUPPORT and CACHE_APP_DOCS are the app's support and documents folders on the server (both required); `fs.*` ops and
/// the core's config work on them. CACHE_DATA is the server's data folder: with it the helper runs the sharing host (bin/sharing_host.dart:
/// the sync engine, on `<data>/sync`), which starts here when sharing was set up and stops when stdin ends. CACHE_VALHALLA_SHIM is the full path of libvalhalla_shim.so (the core's road router).
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
  // The keystore file is outside both fs.* roots: CACHE_KEYSTORE, else beside them in <support>/../keystore.json.
  final keystorePath = Platform.environment['CACHE_KEYSTORE'];
  final keys = KeyStore(File(keystorePath != null && keystorePath.isNotEmpty ? keystorePath : '${dirs.support.parent.path}/keystore.json'), log: log);
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
  // Weather, alerts and fires stay fresh with no tab open (what a phone's background run does).
  final liveTimer = LiveTimer(dispatcher, support: dirs.support, log: log)..start();
  // The browser's way to the region engine (and the off-road pack downloads), which run on the server with no tab open.
  final regionsOps = RegionsOps(
    dirs.support,
    config: (serverCoreExtras(dirs)['regions'] as Map).cast<String, Object?>(),
    open: (c) => FfiRegionsEngine.open(lib, c),
    log: log,
  );
  final data = dirs.data;
  if (data == null) log('CACHE_DATA is not set: no sharing host');
  final SharingHost? sharing = data == null
      ? null
      : SharingHost(dataDir: data, supportDir: dirs.support, docsDir: dirs.docs, deviceName: Platform.localHostname, libraryPath: path, log: log);
  // Not awaited: the helper is ready at once, and sharing starts (when it was set up) in the background.
  if (sharing != null) unawaited(sharing.init());
  await serveLines(
    stdin,
    (line) async {
      stdout.writeln(line);
      await stdout.flush();
    },
    dispatcher,
    log: log,
    handlers: [
      OpenOp(dirs, dispatcher, log: log, indexer: indexer, guide: guide, onOpened: () {
        regionsOps.afterOpen();
        keys.replay(dispatcher);
      }),
      RescanOp(dirs, dispatcher, log: log, indexer: indexer),
      IndexStateOp(indexer),
      IndexPauseOp(indexer),
      FeaturesOp(dirs),
      FsOps(support: dirs.support, docs: dirs.docs),
      regionsOps,
      VideoOps(dirs, () => FfiCsNative(lib), log: log, resolve: keys.resolve),
      HistoryOps(Directory('${dirs.support.path}/history'), log: log),
      keys,
      if (sharing != null) SharingOps(sharing),
    ],
    hook: keys,
    onEnd: () => sharing?.stop(),
  );
  indexer.stop();
  liveTimer.stop();
  await stdout.flush();
  exit(0);
}
