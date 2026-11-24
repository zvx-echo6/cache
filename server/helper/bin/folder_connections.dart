import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../app/lib/files.dart' show writeStringAtomic;
import '../../../app/lib/notebook/notebook_store.dart';
import '../../../app/lib/notebook/sync/folder.dart';
import '../../../app/lib/notebook/sync/formats.dart';
import '../../../app/lib/notebook/sync/sync_engine_core.dart';
import '../../../app/lib/notebook/templates_model.dart';
import '../../../packages/cache_search/lib/src/errors.dart';
import 'core_notebook_store.dart';
import 'line_protocol.dart';

/// One folder of this computer the notebooks are kept in step with: an Obsidian vault or a Logseq graph (two-way, or export-only
/// for Logseq 2.x). The phone's `SyncTargetConfig`, as far as the server needs it.
class FolderTarget {
  const FolderTarget({required this.id, required this.kind, required this.path, this.paused = false, this.importTag});

  /// `obsidian` or `logseq`: one of each at most (the phone's ids).
  final String id;
  final SyncKind kind;

  /// The folder's absolute path on this computer.
  final String path;
  final bool paused;

  /// The tag that imports a note into Cache; null is [kDefaultImportTag].
  final String? importTag;
  String get tag => importTag ?? kDefaultImportTag;

  FolderTarget copyWith({bool? paused, String? importTag, bool clearTag = false}) =>
      FolderTarget(id: id, kind: kind, path: path, paused: paused ?? this.paused, importTag: clearTag ? null : (importTag ?? this.importTag));

  Map<String, dynamic> toJson() => {'id': id, 'kind': kind.name, 'path': path, 'paused': paused, 'import_tag': ?importTag};

  static FolderTarget? fromJson(Object? j) {
    if (j is! Map || j['path'] is! String) return null;
    final kind = const [SyncKind.obsidian, SyncKind.logseq, SyncKind.logseqExport].where((k) => k.name == j['kind']).firstOrNull;
    if (kind == null) return null;
    final tag = j['import_tag'];
    return FolderTarget(id: '${j['id']}', kind: kind, path: j['path'] as String, paused: j['paused'] == true, importTag: tag is String && validImportTag(tag) ? tag : null);
  }
}

/// Cache for Linux's Obsidian and Logseq connections, headless: the phone's `NotebookConnections` for the folders a person chose
/// (kinds `obsidian`, `logseq`, `logseqExport`), with no Flutter and no tab open, run by the helper. The notebooks in the core and
/// the chosen folder are kept the same by the one engine the phone runs (sync_engine_core.dart, its merge rules unchanged: changes
/// are combined; the same words changed on both sides keep one version and make the other a new entry), over a [NotebookStore]
/// backed by the core ([CoreNotebookStore]) and an [IoFolder] on the path.
///
///  * Triggers and timers, as the phone's: one pass at [start]; one 2 s after a change to the notebooks ([changed], several changes
///    one pass); one every [every] (2 minutes); one after connecting, resuming, setting the import tag or settling a decision.
///    A paused connection is left alone.
///  * What is kept, in `<support>/notebook-sync` as on the phone: `folders.json` (the connections; the share's `targets.json` is the
///    notebook sync host's) and `<id>.json` (the engine's record of the last pass, one per connection).
///  * Status lines, as the phone's: "Synced 4:20 PM", "Syncing...", "Can't reach the folder.", "Paused.", "2 changes need a decision".
///
/// Ops (all `nbfolders.*`; a browser polls `state` and sends the person's choices):
///   nbfolders.state {} -> {syncing, targets:[{id, kind, path, paused, import_tag, tag, status, synced_at, merged, kept_as_two,
///       not_added, conflicts:[{entry, kind, title, path}]}]}
///   nbfolders.connect {kind, path} -> {error?}      `error` is the phone's words when the folder cannot be used
///   nbfolders.disconnect {id} -> null                nbfolders.pause {id, paused} -> null
///   nbfolders.sync {} -> null                        a pass; answered when it is done
///   nbfolders.set_tag {id, tag} -> null              nbfolders.resolve {id, entry, kind, path, keep_cache} -> null
class FolderConnections implements OpHandler {
  FolderConnections({
    required this.support,
    required this.store,
    this.templates,
    this.changedNotebooks,
    DateTime Function()? clock,
    this.debounce = const Duration(seconds: 2),
    this.every = const Duration(minutes: 2),
    this.log,
  }) : _now = clock ?? DateTime.now {
    _read();
  }

  final Directory support;
  final NotebookStore store;
  final Future<Templates> Function()? templates;

  /// Told when a pass wrote to the core's notebooks (entries arrived, changed or were removed from a folder), so the other
  /// notebook sync (the linked devices') exports them.
  final void Function()? changedNotebooks;
  final DateTime Function() _now;
  final Duration debounce;
  final Duration every;
  final void Function(String message)? log;

  Directory get _dir => Directory('${support.path}/notebook-sync');
  File get _file => File('${_dir.path}/folders.json');

  List<FolderTarget> _targets = [];
  final Map<String, String> _status = {};
  final Map<String, int> _syncedAt = {};
  final Map<String, List<SyncConflict>> _conflicts = {};
  final Map<String, List<String>> _merged = {};
  final Map<String, List<String>> _keptTwo = {};
  final Map<String, int> _notAdded = {};
  Timer? _debounce, _timer;
  bool _stopped = false;
  bool _again = false;
  Future<void>? _loop;

  /// The passes made (tests read it).
  int passes = 0;

  List<FolderTarget> get targets => List.unmodifiable(_targets);
  FolderTarget? target(String id) => _targets.where((t) => t.id == id).firstOrNull;
  bool get syncing => _loop != null;
  String? status(String id) => _status[id];
  List<String> merged(String id) => _merged[id] ?? const [];
  List<String> keptAsTwo(String id) => _keptTwo[id] ?? const [];
  List<SyncConflict> conflicts(String id) => _conflicts[id] ?? const [];

  // ---- what is kept ----

  void _read() {
    try {
      if (!_file.existsSync()) return;
      final j = jsonDecode(_file.readAsStringSync());
      final list = j is Map ? j['targets'] : null;
      _targets = [for (final t in (list is List ? list : const [])) ?FolderTarget.fromJson(t)];
    } catch (e) {
      log?.call('notebook folders: the connections are unreadable: $e');
    }
  }

  Future<void> _save() async {
    await _dir.create(recursive: true);
    await writeStringAtomic(_file, jsonEncode({'targets': [for (final t in _targets) t.toJson()]}));
  }

  // ---- the passes ----

  /// The pass at start; the periodic timer starts here too. The helper calls it each time the core has opened (a pass that cannot
  /// read the notebooks yet does nothing).
  Future<void> start() {
    _timer ??= Timer.periodic(every, (_) => unawaited(syncAll()));
    return syncAll();
  }

  void stop() {
    _stopped = true;
    _debounce?.cancel();
    _debounce = null;
    _timer?.cancel();
    _timer = null;
  }

  /// The core's notebooks were written (by a browser): a pass in [debounce].
  void changed() {
    if (_stopped || _targets.isEmpty) return;
    _debounce?.cancel();
    _debounce = Timer(debounce, () => unawaited(syncAll()));
  }

  /// Syncs every connection that is not paused, one after the other; a call while a pass runs asks for another right after it.
  /// Completes when the passes are done.
  Future<void> syncAll() {
    if (_stopped) return Future.value();
    final l = _loop;
    if (l != null) {
      _again = true;
      return l;
    }
    return _loop = () async {
      try {
        do {
          _again = false;
          await _pass();
        } while (_again && !_stopped);
      } finally {
        _loop = null;
      }
    }();
  }

  Future<void> _pass() async {
    if (_targets.isEmpty) return;
    try {
      await store.reload();
    } catch (e) {
      // the core is not open yet: the next trigger does it
      log?.call('notebook folders: could not read the notebooks: $e');
      return;
    }
    passes++;
    for (final t in [..._targets]) {
      if (_stopped) return;
      if (target(t.id) == null) continue; // disconnected meanwhile
      if (t.paused) {
        _status[t.id] = 'Paused.';
        continue;
      }
      _status[t.id] = 'Syncing...';
      try {
        final e = await _engine(t);
        final r = await e.run();
        _conflicts[t.id] = e.conflicts;
        _merged[t.id] = r.merged;
        _keptTwo[t.id] = r.keptAsTwo;
        _notAdded[t.id] = r.notAdded;
        if (r.imported.isNotEmpty) log?.call('notebook folders: ${r.imported.length} notes added from ${t.kind == SyncKind.obsidian ? 'Obsidian' : 'Logseq'}');
        if (r.merged.isNotEmpty) log?.call('notebook folders: ${r.merged.length} combined with changes in ${t.kind == SyncKind.obsidian ? 'Obsidian' : 'Logseq'}');
        if (r.keptAsTwo.isNotEmpty) log?.call('notebook folders: ${r.keptAsTwo.length} changed in the same words in both places; the other version is kept as a new entry');
        if (r.read > 0 || r.removedHere > 0 || r.imported.isNotEmpty || r.merged.isNotEmpty || r.keptAsTwo.isNotEmpty || r.deleted > 0) changedNotebooks?.call();
        final n = e.conflicts.length;
        final at = _now();
        _syncedAt[t.id] = at.millisecondsSinceEpoch;
        _status[t.id] = n > 0 ? (n == 1 ? '1 change needs a decision' : '$n changes need a decision') : 'Synced ${_clock(at)}';
      } on FileSystemException catch (x) {
        _status[t.id] = (x.osError?.errorCode == 28) ? "Can't write: storage is full." : "Can't reach the folder.";
      } catch (x) {
        _status[t.id] = "Can't reach the folder.";
        log?.call('notebook folders: a pass failed (${t.id}): $x');
      }
    }
  }

  Future<NotebookSyncCore> _engine(FolderTarget t) async {
    final folder = IoFolder(t.path);
    ({String format, String dir, bool org})? ls;
    if (t.kind == SyncKind.logseq || t.kind == SyncKind.logseqExport) ls = readLogseqConfig(await folder.readText('logseq/config.edn'));
    final e = NotebookSyncCore(
      notebook: store,
      kind: t.kind,
      folder: folder,
      stateFile: File('${_dir.path}/${t.id}.json'),
      includePrivate: true,
      logseqConfig: ls,
      importTag: t.tag,
      clock: _now,
      templates: templates ?? () async => const Templates([], []),
      onError: (what, {Object? error, String? detail}) => log?.call('$what${detail == null ? '' : ' ($detail)'}${error == null ? '' : ': $error'}'),
    );
    final s = store;
    if (s is CoreNotebookStore) e.storePhotoBytes = s.storePhoto;
    await _dir.create(recursive: true);
    return e;
  }

  static String _clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  // ---- the person's choices ----

  /// Connects the folder at [path] for [kind]. Null when connected, else what is wrong (the phone's words). A pass follows.
  Future<String?> connect(SyncKind kind, String path) async {
    if (!path.startsWith('/')) throw const CacheSearchException('bad_path', 'An absolute folder path is needed');
    final folder = IoFolder(path);
    try {
      if (!await folder.reachable()) return "Can't reach the folder.";
      // readable: listing it works
      await Directory(path).list(followLinks: false).isEmpty;
      if (kind == SyncKind.logseq || kind == SyncKind.logseqExport) {
        final cfg = readLogseqConfig(await folder.readText('logseq/config.edn'));
        if (cfg.org) return 'Cache can write to Markdown graphs only.';
      }
    } on FileSystemException {
      return "Can't reach the folder.";
    }
    final id = kind == SyncKind.obsidian ? 'obsidian' : 'logseq';
    _targets = [for (final t in _targets) if (t.id != id) t, FolderTarget(id: id, kind: kind, path: path)];
    _status.remove(id);
    await _save();
    unawaited(syncAll());
    return null;
  }

  Future<void> disconnect(String id) async {
    final t = target(id);
    if (t == null) return;
    try {
      await (await _engine(t)).forget();
    } catch (e) {
      log?.call('notebook folders: could not clear the record of $id: $e');
    }
    _targets = [for (final x in _targets) if (x.id != id) x];
    for (final m in [_status, _syncedAt, _conflicts, _merged, _keptTwo, _notAdded]) {
      m.remove(id);
    }
    await _save();
  }

  Future<void> setPaused(String id, bool paused) async {
    if (target(id) == null) return;
    _targets = [for (final t in _targets) t.id == id ? t.copyWith(paused: paused) : t];
    await _save();
    if (paused) {
      _status[id] = 'Paused.';
    } else {
      unawaited(syncAll());
    }
  }

  Future<void> setImportTag(String id, String tag) async {
    if (!validImportTag(tag) || target(id) == null) return;
    _targets = [for (final t in _targets) t.id == id ? t.copyWith(importTag: tag == kDefaultImportTag ? null : tag, clearTag: tag == kDefaultImportTag) : t];
    await _save();
    unawaited(syncAll());
  }

  Future<void> resolve(String id, SyncConflict c, {required bool keepCache}) async {
    final t = target(id);
    if (t == null) return;
    await store.reload();
    final e = await _engine(t);
    await e.resolve(c, keepCache: keepCache);
    _conflicts[id] = [for (final x in conflicts(id)) if (!(x.entryId == c.entryId && x.kind == c.kind && x.path == c.path)) x];
    unawaited(syncAll());
  }

  // ---- the ops ----

  @override
  bool handles(String op) => op.startsWith('nbfolders.');

  Map<String, dynamic> stateJson() => {
        'syncing': syncing,
        'targets': [
          for (final t in _targets)
            {
              ...t.toJson(),
              'tag': t.tag,
              'status': _status[t.id],
              'synced_at': _syncedAt[t.id],
              'merged': merged(t.id),
              'kept_as_two': keptAsTwo(t.id),
              'not_added': _notAdded[t.id] ?? 0,
              'conflicts': [for (final c in conflicts(t.id)) c.toJson()],
            },
        ],
      };

  @override
  Future<Object?> handle(String op, Map<String, dynamic> a) async {
    String id() => a['id'] is String ? a['id'] as String : throw const CacheSearchException('bad_args', 'id is needed');
    switch (op) {
      case 'nbfolders.state':
        return stateJson();
      case 'nbfolders.connect':
        final kind = const [SyncKind.obsidian, SyncKind.logseq, SyncKind.logseqExport].where((k) => k.name == a['kind']).firstOrNull;
        final path = a['path'];
        if (kind == null || path is! String) throw const CacheSearchException('bad_args', 'kind and path are needed');
        final err = await connect(kind, path);
        return {'error': ?err};
      case 'nbfolders.disconnect':
        await disconnect(id());
        return null;
      case 'nbfolders.pause':
        await setPaused(id(), a['paused'] == true);
        return null;
      case 'nbfolders.sync':
        await syncAll();
        return null;
      case 'nbfolders.set_tag':
        await setImportTag(id(), '${a['tag']}');
        return null;
      case 'nbfolders.resolve':
        final kind = ConflictKind.values.where((k) => k.name == a['kind']).firstOrNull;
        if (kind == null) throw const CacheSearchException('bad_args', 'kind is needed');
        await resolve(id(), SyncConflict(entryId: '${a['entry']}', kind: kind, title: '${a['title'] ?? ''}', path: '${a['path'] ?? ''}'), keepCache: a['keep_cache'] == true);
        return null;
    }
    throw CacheSearchException('unsupported', 'unknown op $op');
  }
}
