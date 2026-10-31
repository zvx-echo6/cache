import 'dart:convert';
import 'dart:io';

import '../../../app/lib/search/core_config.dart';
import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/models.dart';
import 'line_protocol.dart';

/// The helper's own `open`. The Rust server sends `open {"sources": <array or null>}` when it starts the helper; this builds the
/// rest of the core's config on the server's app folders and opens the core with it.
///
/// - The extras (user, live, places, layers, routing, notebook, regions) are the app's own `buildCoreExtras` (app/lib/search/
///   core_config.dart), called as SourcesState._defaultExtras calls it on desktop Linux: filesDir is the app's documents folder
///   ([AppDirs.docs]), supportDir its support folder, layerDefsDir `<support>/layer-defs`, shim `shimPath(null)`, and `<docs>/live-defs`
///   is created. Skipped here (logged): `installIcuData` and `installStarterLayers`.
/// - The sources are the array the server sent (from `<data>/sources.json`), or, when it sent none, [scanSources].
/// Replies `{"sources": N, "extras": [keys]}` (the server logs "core opened (N sources)").
class OpenOp implements OpHandler {
  OpenOp(this.dirs, this.dispatcher, {this.log});

  final AppDirs dirs;
  final CoreDispatcher dispatcher;
  final void Function(String message)? log;

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
    dispatcher.handle('open', {'sources': sources, 'extra': extra});
    return {'sources': sources.length, 'extras': extra.keys.toList()..sort()};
  }
}

/// The server's two app folders (CACHE_APP_SUPPORT and CACHE_APP_DOCS).
class AppDirs {
  AppDirs(this.support, this.docs);

  final Directory support;
  final Directory docs;

  /// From the environment; null when either is missing.
  static AppDirs? fromEnvironment(Map<String, String> env) {
    final s = env['CACHE_APP_SUPPORT'], d = env['CACHE_APP_DOCS'];
    if (s == null || s.isEmpty || d == null || d.isEmpty) return null;
    return AppDirs(Directory(s), Directory(d));
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
    shim: shimPath(null),
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

