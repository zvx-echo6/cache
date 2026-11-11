import 'dart:ffi';
import 'dart:io';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/native_io.dart';
import 'core_open.dart';
import 'fs_ops.dart';
import 'index_driver.dart';
import 'line_protocol.dart';
import 'regions_ops.dart';
import 'video_ops.dart';

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
  final indexer = IndexDriver(dispatcher, log: log, extra: serverCoreExtras(dirs));
  // The browser's way to the region engine (and the off-road pack downloads), which run on the server with no tab open.
  final regionsOps = RegionsOps(
    dirs.support,
    config: (serverCoreExtras(dirs)['regions'] as Map).cast<String, Object?>(),
    open: (c) => FfiRegionsEngine.open(lib, c),
    log: log,
  );
  await serveLines(
    stdin,
    (line) async {
      stdout.writeln(line);
      await stdout.flush();
    },
    dispatcher,
    log: log,
    handlers: [
      OpenOp(dirs, dispatcher, log: log, indexer: indexer, onOpened: regionsOps.afterOpen),
      RescanOp(dirs, dispatcher, log: log, indexer: indexer),
      IndexStateOp(indexer),
      FeaturesOp(dirs),
      FsOps(support: dirs.support, docs: dirs.docs),
      regionsOps,
      VideoOps(dirs, () => FfiCsNative(lib), log: log),
    ],
  );
  indexer.stop();
  await stdout.flush();
  exit(0);
}
