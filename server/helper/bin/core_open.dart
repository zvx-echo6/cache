import 'dart:convert';
import 'dart:io';

import '../../../app/lib/search/core_config.dart';
import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/models.dart';
import 'index_driver.dart';
import 'line_protocol.dart';

/// The helper's own `open`. The Rust server sends `open {"sources": <array or null>}` when it starts the helper; this builds the
/// rest of the core's config on the server's app folders and opens the core with it.
///
/// - The extras (user, live, places, layers, routing, notebook, regions) are the app's own `buildCoreExtras` (app/lib/search/
///   core_config.dart), called as SourcesState._defaultExtras calls it on desktop Linux: filesDir is the app's documents folder
///   ([AppDirs.docs]), supportDir its support folder, layerDefsDir `<support>/layer-defs`, shim the full path the server gives
///   ([AppDirs.shim], `CACHE_VALHALLA_SHIM`: `<install>/lib/libvalhalla_shim.so`), and `<docs>/live-defs` is created. Skipped here (logged): `installIcuData` and `installStarterLayers`.
/// - The sources are the array the server sent (from `<data>/sources.json`), or, when it sent none, [scanSources].
/// Replies `{"sources": N, "extras": [keys]}` (the server logs "core opened (N sources)").
class OpenOp implements OpHandler {
  OpenOp(this.dirs, this.dispatcher, {this.log, this.indexer});

  final AppDirs dirs;
  final CoreDispatcher dispatcher;
  final void Function(String message)? log;

  /// Starts the index jobs of the sources just opened (null in tests that do not index).
  final IndexDriver? indexer;

  @override
  bool handles(String op) => op == 'open';

  @override
  Object? handle(String op, Map<String, dynamic> a) {
    final given = a['sources'];
    final List<Map<String, dynamic>> sources;
    if (given is List) {
      sources = [for (final s in given) (s as Map).cast<String, dynamic>()];
      log?.call('sources: ${sources.length} from sources.json');
    } else {
      sources = scanSources(dirs);
      log?.call('sources: ${sources.length} found in ${dirs.docs.path}/zims and /libraries');
    }
    final extra = serverCoreExtras(dirs);
    log?.call('skipped on the server for now: ICU data install, starter map layers');
    log?.call('core extras: ${(extra.keys.toList()..sort()).join(', ')}');
    final f = serverFeatures(extra);
    log?.call('road routing: shim ${(f['routing'] as Map)['shim']} ${(f['routing'] as Map)['available'] == true ? 'present' : 'missing (no road routing)'}; '
        'places: ${(f['places'] as Map)['available'] == true ? 'present' : 'none downloaded'}');
    dispatcher.handle('open', {'sources': sources, 'extra': extra});
    indexer?.useSources(sources);
    return {'sources': sources.length, 'extras': extra.keys.toList()..sort()};
  }
}

/// The helper's `sources.rescan`, which only cache may call (the server's `/api/core` refuses it from browsers, as it does
/// `open`, `close` and `setSources`). The server sends it after it has put a ZIM or a library on disk, or removed one:
/// `sources.rescan {"sources": <array or null>}`. As with [OpenOp], the array is the server's `sources.json` and `null` means
/// scan the app folders ([scanSources]). The core gets the new list with its own `setSources`.
/// Replies `{"sources": N}` and logs "sources rescanned (N)".
class RescanOp implements OpHandler {
  RescanOp(this.dirs, this.dispatcher, {this.log, this.indexer});

  final AppDirs dirs;
  final CoreDispatcher dispatcher;
  final void Function(String message)? log;

  /// Starts the index jobs of the sources just listed (null in tests that do not index).
  final IndexDriver? indexer;

  @override
  bool handles(String op) => op == 'sources.rescan';

  @override
  Object? handle(String op, Map<String, dynamic> a) {
    final given = a['sources'];
    final List<Map<String, dynamic>> sources;
    if (given is List) {
      sources = [for (final s in given) (s as Map).cast<String, dynamic>()];
    } else {
      sources = scanSources(dirs);
    }
    dispatcher.handle('setSources', {'sources': sources, 'extra': serverCoreExtras(dirs)});
    indexer?.useSources(sources);
    log?.call('sources rescanned (${sources.length})');
    return {'sources': sources.length};
  }
}

/// The helper's `index.state`, which a browser may call through `/api/core`: what the helper's index jobs are doing, by source path,
/// `{"<path>": {"fraction": 0..1 or null, "error": null}}` for a source being indexed or one whose index failed. The core's status
/// says a source is being built; this adds how far it is and why one stopped.
class IndexStateOp implements OpHandler {
  IndexStateOp(this.indexer);

  final IndexDriver indexer;

  @override
  bool handles(String op) => op == 'index.state';

  @override
  Object? handle(String op, Map<String, dynamic> a) => {
        for (final e in indexer.progress.entries) e.key: {'fraction': e.value, 'error': null},
        for (final e in indexer.failures.entries) e.key: {'fraction': null, 'error': e.value},
      };
}

/// The server's two app folders (CACHE_APP_SUPPORT and CACHE_APP_DOCS), the full path of the Valhalla shim
/// (CACHE_VALHALLA_SHIM; the server sets it to `libvalhalla_shim.so` next to the core library) and the server's data folder
/// (CACHE_DATA: the sharing host keeps the sync engine's identity and the Bookshelves log there).
class AppDirs {
  AppDirs(this.support, this.docs, {this.shim, this.data});

  final Directory support;
  final Directory docs;

  /// The shim's full path; null when the server gave none (then the bare name, which the core cannot route with).
  final String? shim;

  /// `<data>`, when the server gave it (without it the helper runs no sharing host).
  final Directory? data;

  /// From the environment; null when either folder is missing.
  static AppDirs? fromEnvironment(Map<String, String> env) {
    final s = env['CACHE_APP_SUPPORT'], d = env['CACHE_APP_DOCS'], v = env['CACHE_VALHALLA_SHIM'], data = env['CACHE_DATA'];
    if (s == null || s.isEmpty || d == null || d.isEmpty) return null;
    return AppDirs(Directory(s), Directory(d), shim: (v == null || v.isEmpty) ? null : v, data: (data == null || data.isEmpty) ? null : Directory(data));
  }
}

/// The helper's `server.features`, which a browser may call through `/api/core`: what the server's engine can do, from the files
/// on disk, so the browser can switch on what the phone switches on from its own opened extras (SourcesState.openedExtra).
///
/// ```
/// {"routing": {"available": bool, "shim": "<path>"},
///  "places":  {"available": bool, "merged_dir": "<support>/regions/places"},
///  "extras":  {the cs_open sections the engine was opened with; "routing" only when routing is available}}
/// ```
/// - routing is available when the shim (the `routing.valhalla.shim` the engine was given) is a file: the core's own test
///   (cache_navigate `routing_installed`); the routing tiles are the region engine's folder (`tiles` empty), filled by region
///   downloads and by the stream cache, as on the phone.
/// - places is available when the region engine's merged places database is there: `<merged_dir>/CURRENT` names a build whose
///   `<build>.sqlite` is a file (cache_places `PackSet::merged`).
class FeaturesOp implements OpHandler {
  FeaturesOp(this.dirs);

  final AppDirs dirs;

  @override
  bool handles(String op) => op == 'server.features';

  @override
  Object? handle(String op, Map<String, dynamic> a) => serverFeatures(serverCoreExtras(dirs));
}

/// [FeaturesOp]'s reply for the extras the engine was opened with.
Map<String, dynamic> serverFeatures(Map<String, dynamic> extra) {
  final routing = (extra['routing'] as Map?)?.cast<String, dynamic>();
  final shim = ((routing?['valhalla'] as Map?)?['shim'] as String?) ?? '';
  final routable = shim.isNotEmpty && File(shim).existsSync();
  final mergedDir = ((extra['places'] as Map?)?['merged_dir'] as String?) ?? '';
  return {
    'routing': {'available': routable, 'shim': shim},
    'places': {'available': mergedPlacesPresent(mergedDir), 'merged_dir': mergedDir},
    'extras': {
      for (final e in extra.entries)
        if (e.key != 'routing' || routable) e.key: e.value,
    },
  };
}

/// The region engine's merged places database is in [dir]: `CURRENT` names a build and `<build>.sqlite` is a file.
bool mergedPlacesPresent(String dir) {
  if (dir.isEmpty) return false;
  try {
    final current = File('$dir/CURRENT');
    if (!current.existsSync()) return false;
    final build = current.readAsStringSync().trim();
    if (build.isEmpty || build.contains('/') || build.contains('\\') || build.startsWith('.')) return false;
    return File('$dir/$build.sqlite').existsSync();
  } catch (_) {
    return false;
  }
}

/// The app's `buildCoreExtras`, on the server paths (see [OpenOp]).
Map<String, dynamic> serverCoreExtras(AppDirs dirs) {
  try {
    Directory('${dirs.docs.path}/live-defs').createSync(recursive: true);
    Directory('${dirs.support.path}/layer-defs').createSync(recursive: true);
  } catch (e) {
    stderr.writeln('cache_core_helper: cannot make the core folders: $e');
  }
  return buildCoreExtras(
    filesDir: dirs.docs,
    supportDir: dirs.support,
    layerDefsDir: Directory('${dirs.support.path}/layer-defs'),
    shim: dirs.shim ?? shimPath(null),
    useLinkedRouter: false,
  );
}

/// The sources found on disk, as the app's SourcesState and LibrariesState would list them (reimplemented here because those
/// classes import Flutter): every `*.zim` file in `<docs>/zims` (SourcesState._scan; index `<support>/indexes/<file name>.idx`,
/// SourcesState._indexDir) and every folder in `<docs>/libraries` that holds a `shard` folder (LibrariesState._scan; its source is
/// `<folder>/shard` with index `<folder>/index` and the settings in `<folder>/cache-library.json`, LibraryItem.config). Names
/// starting with "." are skipped. ZIMs first, each group in name order.
List<Map<String, dynamic>> scanSources(AppDirs dirs) {
  final out = <Map<String, dynamic>>[];
  String nameOf(FileSystemEntity e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last;

  final zims = Directory('${dirs.docs.path}/zims');
  if (zims.existsSync()) {
    final files = zims.listSync().whereType<File>().where((f) {
      final n = nameOf(f);
      return !n.startsWith('.') && n.toLowerCase().endsWith('.zim');
    }).toList()
      ..sort((a, b) => nameOf(a).toLowerCase().compareTo(nameOf(b).toLowerCase()));
    for (final f in files) {
      out.add(SourceConfig.zim(path: '${zims.path}/${nameOf(f)}', indexDir: '${dirs.support.path}/indexes/${nameOf(f)}.idx').toJson());
    }
  }

  final libs = Directory('${dirs.docs.path}/libraries');
  if (libs.existsSync()) {
    final folders = libs.listSync().whereType<Directory>().where((d) {
      final n = nameOf(d);
      return !n.startsWith('.') && Directory('${d.path}/shard').existsSync();
    }).toList()
      ..sort((a, b) => nameOf(a).toLowerCase().compareTo(nameOf(b).toLowerCase()));
    for (final d in folders) {
      Map<String, dynamic>? settings;
      try {
        final f = File('${libs.path}/${nameOf(d)}/cache-library.json');
        if (f.existsSync()) settings = (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();
      } catch (e) {
        stderr.writeln('cache_core_helper: library settings of ${nameOf(d)}: $e');
      }
      out.add(SourceConfig.library(path: '${libs.path}/${nameOf(d)}/shard', indexDir: '${libs.path}/${nameOf(d)}/index', settings: settings).toJson());
    }
  }
  try {
    Directory('${dirs.support.path}/indexes').createSync(recursive: true);
  } catch (_) {}
  return out;
}

