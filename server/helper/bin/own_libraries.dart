import 'dart:convert';
import 'dart:io';

import '../../../app/lib/sharing/share_rules.dart' show isOwnLibraryFolderName;
import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/models.dart';
import 'core_open.dart';

/// The person's own libraries (My books) that sync to this server, made to match their packs here: the core's `own_library_sync`
/// job (ownlib.rs), as the phone's LibrariesState.syncOwnLibraries runs it. Their shard and book lists are each device's own
/// (`kLibraryNotShared`); only the packs, the PDFs and the settings arrive. A library that arrived without a shard gets one (until
/// then it is not a source: [scanSources] lists folders with a shard), a pack that arrived is made searchable, and the first
/// start of this version rebuilds each once from its packs. When one was rebuilt the core gets the new list ([onChanged] tells the
/// index driver, which builds its keyword index).
class OwnLibrarySync {
  OwnLibrarySync(this.dispatcher, this.dirs, {this.onChanged, this.onDone, this.log, this.poll = const Duration(milliseconds: 200)});

  final CoreDispatcher dispatcher;
  final AppDirs dirs;
  final void Function(List<Map<String, dynamic>> sources)? onChanged;

  /// Called after every look, rebuilt or not (the index driver's kick): a keyword index job the driver started while a library
  /// was being rebuilt answered `busy` and waits for the next look, which this starts.
  final void Function()? onDone;
  final void Function(String message)? log;
  final Duration poll;
  bool _running = false;
  bool _again = false;

  /// The last look at each own library, by folder path: the job's detail, or `{"error"}`.
  final Map<String, Map<String, dynamic>> results = {};

  Future<JobProgress> _job(String kind, Map<String, dynamic> params) async {
    final job = dispatcher.handle('jobStart', {'kind': kind, 'params': params}) as int;
    try {
      while (true) {
        final p = JobProgress.fromJson((dispatcher.handle('jobProgress', {'job': job}) as Map).cast<String, dynamic>());
        if (p.isFinished) return p;
        await Future<void>.delayed(poll);
      }
    } finally {
      try {
        dispatcher.handle('jobFree', {'job': job});
      } catch (_) {}
    }
  }

  /// One look at every own library. A call while one runs is folded into one more look after it. True when one was rebuilt.
  Future<bool> run() async {
    if (_running) {
      _again = true;
      return false;
    }
    _running = true;
    var rebuilt = false;
    try {
      do {
        _again = false;
        rebuilt = await _once() || rebuilt;
      } while (_again);
    } finally {
      _running = false;
    }
    if (rebuilt) {
      try {
        final sources = scanSources(dirs);
        dispatcher.handle('setSources', {'sources': sources, 'extra': serverCoreExtras(dirs)});
        onChanged?.call(sources);
      } catch (e) {
        log?.call('own libraries: the new list could not be given to the core: $e');
      }
    }
    onDone?.call();
    return rebuilt;
  }

  Future<bool> _once() async {
    final libs = Directory('${dirs.docs.path}/libraries');
    if (!libs.existsSync()) return false;
    var rebuilt = false;
    for (final d in libs.listSync().whereType<Directory>()) {
      final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!isOwnLibraryFolderName(name)) continue;
      try {
        final s = jsonDecode(File('${d.path}/cache-library.json').readAsStringSync());
        if (s is! Map || s['own'] != true) continue;
      } catch (_) {
        continue;
      }
      try {
        final p = await _job('own_library_sync', {'library_dir': d.path});
        if (p.state == JobState.done) {
          final detail = p.detail ?? const <String, dynamic>{};
          results[d.path] = detail;
          if (detail['rebuilt'] == true) {
            rebuilt = true;
            log?.call('own library $name made from its packs (${detail['reason']}): ${detail['books']} books, ${detail['points']} pieces');
          }
          final removed = (detail['conflicts_removed'] as List?) ?? const [];
          if (removed.isNotEmpty) log?.call('own library $name: removed ${removed.length} sync conflict copies');
        } else {
          results[d.path] = {'error': p.errorCode ?? p.state.name, 'message': p.errorMessage};
          log?.call('own library $name: ${p.errorCode ?? p.state.name} ${p.errorMessage ?? ''}');
        }
      } catch (e) {
        results[d.path] = {'error': '$e'};
        log?.call('own library $name could not be made from its packs: $e');
      }
    }
    return rebuilt;
  }
}
