import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/models.dart';
import 'core_open.dart';

/// The library id of the setup guide that ships in the app (LibrariesState.kGuideLibraryId).
const String kGuideId = 'cache-guide';

/// Installs the Cache guide library on the server, with nobody's browser open: so guide search (Library, Ask, Home) has something to
/// search in a browser as on a phone.
///
/// The phone copies `assets/guide/cache-guide.cache-library` out of the app and adds it like any library file
/// (LibrariesState.ensureGuide -> _install). The server has the same file in its web build (`assets/assets/guide/` of the web folder;
/// the server gives its path as `CACHE_GUIDE_LIBRARY`). The steps are _install's, with the same core jobs:
/// 1. `unpack_library` of the package into a staging folder `<docs>/libraries/.add-guide-<time>/shard`;
/// 2. `documents.tsv`, `source-identities.json` and `copies.jsonl` move to the library's root, the settings it resolved go to
///    `cache-library.json`;
/// 3. the staging folder is renamed to `<docs>/libraries/cache-guide` (a new copy), or swaps in for the old one when the package's
///    `version` differs (the old copy is closed first, and put back if the new one cannot be put in place).
/// The keyword index is not built here: the [IndexDriver] builds it, as for any library whose index is missing (the phone builds it at
/// the end of _install; the result is the same index). Asking the person for a settings file (`settings_error`) is not possible
/// headless; the guide always carries its settings, so that is logged and nothing is installed.
///
/// `<support>/guide-installed.json` (the package's size and time) lets a later start skip the unpacking when nothing changed.
class GuideInstaller {
  GuideInstaller(this.dispatcher, this.dirs, this.package, {this.onChanged, this.log, this.poll = const Duration(milliseconds: 200)});

  final CoreDispatcher dispatcher;
  final AppDirs dirs;

  /// The guide package (gzip-compressed `.cache-library`).
  final File package;

  /// Called with the source list after the libraries folder changed (the core has been given it; the index driver gets it too).
  final void Function(List<Map<String, dynamic>> sources)? onChanged;
  final void Function(String message)? log;
  final Duration poll;

  bool _running = false;

  Directory get _libs => Directory('${dirs.docs.path}/libraries');
  File get _marker => File('${dirs.support.path}/guide-installed.json');

  String _stamp() => jsonEncode({'size': package.lengthSync(), 'modified': package.lastModifiedSync().millisecondsSinceEpoch});

  /// The installed guide's folder, or null. By the id the core reports, else the folder the phone gives it.
  Directory? _existing() {
    try {
      for (final s in dispatcher.handle('status', const {}) as List) {
        final m = (s as Map).cast<String, dynamic>();
        if (m['kind'] == 'library' && m['id'] == kGuideId) return Directory(m['path'] as String).parent;
      }
    } catch (_) {}
    final d = Directory('${_libs.path}/$kGuideId');
    return Directory('${d.path}/shard').existsSync() ? d : null;
  }

  static String? _version(Map<String, dynamic>? m) {
    final v = m?['version'];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    if (v is int) return '$v';
    return null;
  }

  String? _installedVersion(Directory folder) {
    try {
      return _version((jsonDecode(File('${folder.path}/cache-library.json').readAsStringSync()) as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

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

  /// Installs the guide when it is missing or older than the package. True when the folder was changed.
  Future<bool> ensure() async {
    if (_running || !package.existsSync()) return false;
    _running = true;
    final stage = Directory('${_libs.path}/.add-guide-${DateTime.now().microsecondsSinceEpoch}');
    var installed = false;
    try {
      final existing = _existing();
      final stamp = _stamp();
      if (existing != null && _marker.existsSync() && _marker.readAsStringSync() == stamp) return false;
      stage.createSync(recursive: true);
      final shard = '${stage.path}/shard';
      final p = await _job('unpack_library', {'snapshot_path': package.path, 'dir': shard});
      if (p.state != JobState.done) {
        log?.call('the guide library could not be unpacked: ${p.errorMessage ?? p.state.name}');
        return false;
      }
      final detail = p.detail ?? const <String, dynamic>{};
      if (detail['settings_error'] != null) {
        log?.call('the guide library needs a settings file, which cannot be asked for here: ${(detail['settings_error'] as Map)['message']}');
        return false;
      }
      final settings = (detail['settings'] as Map?)?.cast<String, dynamic>();
      final resolved = ((detail['resolved'] as Map?) ?? const {}).cast<String, dynamic>();
      final id = (resolved['library_id'] ?? '') as String;
      if (id != kGuideId) {
        log?.call('the guide library says it is "$id", not "$kGuideId"; not installed');
        return false;
      }
      if (existing != null && _installedVersion(existing) == (_version(settings) ?? _version(resolved))) {
        _marker.writeAsStringSync(stamp);
        return false;
      }
      for (final name in ['documents.tsv', 'source-identities.json', 'copies.jsonl']) {
        final from = File('$shard/$name');
        if (from.existsSync()) from.renameSync('${stage.path}/$name');
      }
      if (settings != null) {
        File('${stage.path}/cache-library.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(settings));
      }
      if (existing == null) {
        Directory(stage.path).renameSync('${_libs.path}/$kGuideId');
      } else if (!_swap(existing, stage)) {
        return false;
      }
      installed = true;
      _marker.writeAsStringSync(stamp);
      final sources = scanSources(dirs);
      dispatcher.handle('setSources', {'sources': sources, 'extra': serverCoreExtras(dirs)});
      onChanged?.call(sources);
      log?.call('the guide library is installed (${_version(settings) ?? 'no version'})');
      return true;
    } catch (e) {
      log?.call('the guide library could not be installed: $e');
      return false;
    } finally {
      _running = false;
      if (!installed && stage.existsSync()) {
        try {
          stage.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// The checked new copy at [stage] takes the place of [old]: the core lets go of the old one first, it is moved aside, and put back
  /// if the new one cannot be moved in. False when it was kept.
  bool _swap(Directory old, Directory stage) {
    final aside = Directory('${old.parent.path}/.${old.uri.pathSegments.where((s) => s.isNotEmpty).last}.old');
    if (aside.existsSync()) aside.deleteSync(recursive: true);
    // the core closes it when the list no longer has it
    final without = [for (final s in scanSources(dirs)) if (!(s['path'] as String).startsWith('${old.path}/')) s];
    dispatcher.handle('setSources', {'sources': without, 'extra': serverCoreExtras(dirs)});
    old.renameSync(aside.path);
    try {
      stage.renameSync(old.path);
    } catch (e) {
      aside.renameSync(old.path);
      dispatcher.handle('setSources', {'sources': scanSources(dirs), 'extra': serverCoreExtras(dirs)});
      log?.call('the new guide library could not be put in place, so the old one was kept: $e');
      return false;
    }
    aside.deleteSync(recursive: true);
    return true;
  }
}
