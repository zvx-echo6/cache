import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../files.dart';
import '../notebook_state.dart';
import 'folder.dart';
import 'folder_access.dart';
import 'formats.dart';
import 'share_format.dart';
import 'sync_engine.dart';
import '../../platform/app_log.dart';

/// Notebook sync's folder in the app's support folder (a sharing kind, "Notebooks").
const String kNotebookShareDir = 'notebook-share';

/// One connected folder: an Obsidian vault, a Logseq graph (two-way, or export-only for Logseq 2.x), or notebook sync's own
/// folder (kind share, id `share`). Private items go to Obsidian and Logseq (decided 2026-10-29); notebook sync leaves private
/// notebooks out unless each one's "Include in sync and sharing" is on.
class SyncTargetConfig {
  const SyncTargetConfig({required this.id, required this.kind, required this.path, this.paused = false, this.display, this.importTag});

  final String id;
  final SyncKind kind;
  final String path;
  final bool paused;

  /// The tag that imports a note into Cache (Obsidian and Logseq); null is [kDefaultImportTag].
  final String? importTag;
  String get tag => importTag ?? kDefaultImportTag;

  /// The folder's name as the picker gave it (the path is a URI or a bookmark on phones).
  final String? display;

  String get name => display ?? (path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).lastOrNull ?? path);

  SyncTargetConfig copyWith({bool? paused, String? importTag}) =>
      SyncTargetConfig(id: id, kind: kind, path: path, paused: paused ?? this.paused, display: display, importTag: importTag ?? this.importTag);

  Map<String, dynamic> toJson() => {'id': id, 'kind': kind.name, 'path': path, 'paused': paused, 'display': ?display, 'import_tag': ?importTag};

  static SyncTargetConfig? fromJson(Object? j) {
    if (j is! Map || j['path'] is! String) return null;
    final kind = SyncKind.values.where((k) => k.name == j['kind']).firstOrNull;
    if (kind == null) return null;
    final tag = j['import_tag'];
    return SyncTargetConfig(
        id: '${j['id']}', kind: kind, path: j['path'] as String, paused: j['paused'] == true, display: j['display'] as String?, importTag: tag is String && validImportTag(tag) ? tag : null);
  }
}

/// The notebooks' connections: the folders they are kept in step with, when they sync (on opening Notebooks, 2 s after a
/// change, when Cache comes back to the screen; never in the background), their status lines and the decisions they wait for.
/// Errors never block Notebooks.
class NotebookConnections extends ChangeNotifier implements PrivateSharing {
  NotebookConnections({required this.notebook, required this.dir, this.shareFolder, this.shareOn, this.storePhoto, this.folderFor, this.peerCaps, this.setCaps, this.onTombstone, this.clock});

  /// The time (tests give one).
  final DateTime Function()? clock;

  /// The linked devices and what each says about itself (its `caps`, null for a version that says nothing), by device id; null while
  /// that is not known yet (sharing is not running). Notebook sync keeps its format 1 folders until every one has said format 2.
  final Map<String, Map<String, dynamic>?>? Function()? peerCaps;

  /// Tells the linked devices this device's notebook format and whether it still keeps format 1 folders.
  final Future<void> Function(Map<String, dynamic> caps)? setCaps;

  /// A notebook another device deleted (its tombstone in the share): the decision point for what that does here.
  final Future<void> Function(String notebookId, int at)? onTombstone;

  final NotebookState notebook;

  /// Where the connections and each one's record live (`<support>/notebook-sync`).
  final Future<Directory> Function() dir;

  /// Notebook sync's folder (a sharing kind), and whether Notebooks is shared with linked devices now.
  final Directory? Function()? shareFolder;
  final bool Function()? shareOn;

  /// Stores a photo that came from a folder under its own id.
  final Future<void> Function(String id, Uint8List bytes)? storePhoto;

  /// The folder object for a path (tests give an in-memory one).
  final SyncFolder Function(String path)? folderFor;

  List<SyncTargetConfig> _targets = [];
  bool _read = false;
  bool _running = false;
  bool _again = false;
  Timer? _debounce;
  final Map<String, String> _status = {};
  final Map<String, List<SyncConflict>> _conflicts = {};
  final Map<String, List<String>> _merged = {};
  final Map<String, int> _notAdded = {};
  final Map<String, ({Set<String> imported, Set<String> stopped})> _links = {};

  /// Notebook sync's share: the share has a notebook in a format newer than this version reads, so nothing of it syncs.
  bool _formatBlocked = false;
  bool get formatBlocked => _formatBlocked;

  /// The text under Notebooks in Sharing when notebook sync cannot go on, else null.
  String? get sharingNote {
    if (_formatBlocked) return kUpdateNeededNote;
    if (_corrupt) return 'Notebook sync is paused: its settings could not be read.';
    if (notebook.replayError != null) return 'Notebook sync is paused: a notebook change did not finish. Cache will try again.';
    return null;
  }

  /// `targets.json` could not be read: nothing syncs (private notebooks would look switched off) and no notebook id change is
  /// finished, until it can be.
  bool _corrupt = false;

  /// Format 1 and 2 together: `legacy` is `on` (format 1 folders kept current beside the format 2 ones), `off` (this device stopped
  /// writing and reading them) or `cleaned` (removed from the share); and what each linked device last said.
  String _legacy = 'on';

  /// The notebooks that existed before this device's migration to format 2 (local then, or made from a format 1 folder): the only
  /// ones matched by exact name with other devices' notebooks. Saved with the format state.
  final Set<String> _eligible = {};
  bool _migrated = false;

  /// The name of the notebook folder `<id>/` in the share, as its record says (after a sync); null for a folder that is not one.
  Map<String, String> _dirNames = {};
  String? dirName(String dir) => _dirNames[dir];
  final Map<String, ({bool legacyOff})> _peerFormat = {};
  Map<String, dynamic>? _advertised;
  bool _formatRead = false;

  String get legacyState => _legacy;

  /// Notes imported by their tag in the last sync: the app's name ("Obsidian") and their titles. Read and cleared by
  /// [takeImported] (the snack bar "2 notes added from Obsidian").
  final List<({String app, String target, List<String> titles, Set<String> books})> _news = [];

  List<SyncTargetConfig> get targets => [for (final t in _targets) if (t.kind != SyncKind.share) t];
  SyncTargetConfig? target(SyncKind kind) => _targets.where((t) => t.kind == kind || (kind == SyncKind.logseq && t.kind == SyncKind.logseqExport)).firstOrNull;
  bool get syncing => _running;

  /// "Synced 4:20 PM", "Syncing...", "Can't reach the folder.", "Paused.", "2 changes need a decision".
  String? status(String id) => _status[id];
  List<SyncConflict> conflicts(String id) => _conflicts[id] ?? const [];

  /// Entries changed in both places whose changes were merged in the last run (told, not asked).
  List<String> merged(String id) => _merged[id] ?? const [];

  /// Tagged notes the last sync could not import (Cache could not write its id into them).
  int notAdded(String id) => _notAdded[id] ?? 0;

  /// The app's name of a connection kind.
  static String appName(SyncKind kind) => kind == SyncKind.obsidian ? 'Obsidian' : 'Logseq';

  SyncTargetConfig? _linkTarget(String entryId, bool stopped) {
    for (final t in _targets) {
      final l = _links[t.id];
      if (l != null && (stopped ? l.stopped : l.imported).contains(entryId)) return t;
    }
    return null;
  }

  /// The app an entry was imported from by its tag and still syncs with ("Obsidian", "Logseq"), or null.
  String? importedFrom(String entryId) => switch (_linkTarget(entryId, false)) { final t? => appName(t.kind), null => null };

  /// The app an entry stopped syncing with (kept in Cache, unsynced), or null.
  String? stoppedWith(String entryId) => switch (_linkTarget(entryId, true)) { final t? => appName(t.kind), null => null };

  /// The notes imported since the last call, by connection.
  List<({String app, String target, List<String> titles, Set<String> books})> takeImported() {
    final out = [..._news];
    _news.clear();
    return out;
  }

  /// Sets a connection's import tag (`#cachesync` when [tag] is the default). Notes already in Cache keep syncing; the next
  /// sync looks for the new tag.
  Future<void> setImportTag(String id, String tag) async {
    await init();
    if (!validImportTag(tag)) return;
    _targets = [
      for (final t in _targets)
        t.id == id ? SyncTargetConfig(id: t.id, kind: t.kind, path: t.path, paused: t.paused, display: t.display, importTag: tag == kDefaultImportTag ? null : tag) : t,
    ];
    await _saveTargets();
    notifyListeners();
    unawaited(syncAll());
  }

  /// "Stop syncing this note": Cache's id goes out of the note in Obsidian or Logseq (it says `cachesync: off` instead), the
  /// entry stays in Cache, unsynced. Null when done, else what is wrong ("Cache cannot reach Obsidian right now. ...").
  Future<String?> stopSyncing(String entryId) async {
    await init();
    final t = _linkTarget(entryId, false);
    if (t == null) return null;
    final unreachable = 'Cache cannot reach ${appName(t.kind)} right now. Try again when it is connected.';
    try {
      final e = await _engine(t);
      if (!await e.stopSyncing(entryId)) return unreachable;
      _links[t.id] = await NotebookSync.links(e.stateFile);
    } catch (x) {
      logError('Notebook sync stopped', error: x, detail: t.id);
      return unreachable;
    }
    notifyListeners();
    return null;
  }

  Future<void> _readLinks() async {
    for (final t in _targets) {
      if (t.kind == SyncKind.share) continue;
      _links[t.id] = await NotebookSync.links(File('${(await dir()).path}/${t.id}.json'));
    }
  }

  Set<String> _privateBooks = {};

  /// Notebook sync leaves private notebooks out unless the notebook's "Include in sync and sharing" is on.
  @override
  bool included(String notebookId) => _privateBooks.contains(notebookId);

  @override
  Future<void> setIncluded(String notebookId, bool on) async {
    await init();
    on ? _privateBooks.add(notebookId) : _privateBooks.remove(notebookId);
    await _saveTargets();
    notifyListeners();
    unawaited(syncAll());
  }

  /// A notebook got another id: the field names every connected folder keeps for it (Obsidian, Logseq and notebook sync state)
  /// move to the new id. One step of the re-id journal: it can run again.
  Future<void> moveFieldMaps(String oldId, String newId) async {
    await init();
    if (_corrupt) throw StateError('the notebook connections could not be read');
    // Every connection's state, and notebook sync's two (the share is a connection only once it has synced; its files are there
    // from the version that made them): format 1's `share.json` and format 2's `share2.json`.
    for (final id in {..._targets.map((t) => t.id), 'share', 'share2'}) {
      await NotebookSync.moveProps(File('${(await dir()).path}/$id.json'), oldId, newId);
    }
  }

  @override
  Future<void> notebookReid(String oldId, String newId) async {
    await init();
    if (_corrupt) throw StateError('the notebook connections could not be read');
    if (!_privateBooks.remove(oldId)) return;
    _privateBooks.add(newId);
    await _saveTargets();
    notifyListeners();
  }

  Future<File> _targetsFile() async => File('${(await dir()).path}/targets.json');

  Future<void> init() async {
    if (_read) return;
    _read = true;
    try {
      final f = await _targetsFile();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        final list = j is Map ? j['targets'] : j;
        _targets = [for (final t in (list is List ? list : const [])) ?SyncTargetConfig.fromJson(t)];
        if (j is Map && j['private_included'] is List) _privateBooks = {for (final x in j['private_included'] as List) '$x'};
      }
    } catch (e) {
      _corrupt = true;
      logError('Notebook connections', error: e);
    }
    try {
      await _readLinks();
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _saveTargets() async {
    final f = await _targetsFile();
    await f.parent.create(recursive: true);
    await writeStringAtomic(f, jsonEncode({'targets': [for (final t in _targets) t.toJson()], 'private_included': [..._privateBooks]..sort()}));
  }

  Future<SyncFolder> _folder(String path) async => folderFor?.call(path) ?? await openSyncFolder(path);

  /// Connects a folder for [kind]. Null when connected, else what is wrong ("Cache can write to Markdown graphs only.").
  Future<String?> connect(SyncKind kind, String path, {String? display}) async {
    await init();
    final SyncFolder folder;
    try {
      folder = await _folder(path);
    } catch (_) {
      return "Can't reach the folder.";
    }
    if (!await folder.reachable()) return "Can't reach the folder.";
    if (kind == SyncKind.logseq || kind == SyncKind.logseqExport) {
      final cfg = readLogseqConfig(await folder.readText('logseq/config.edn'));
      if (cfg.org) return 'Cache can write to Markdown graphs only.';
    }
    final id = kind == SyncKind.obsidian ? 'obsidian' : 'logseq';
    _targets = [for (final t in _targets) if (t.id != id) t, SyncTargetConfig(id: id, kind: kind, path: path, display: display)];
    await _saveTargets();
    notifyListeners();
    unawaited(syncAll());
    return null;
  }

  Future<void> disconnect(String id) async {
    await init();
    final t = _targets.where((x) => x.id == id).firstOrNull;
    if (t == null) return;
    await (await _engine(t)).forget();
    _targets = [for (final x in _targets) if (x.id != id) x];
    _status.remove(id);
    _conflicts.remove(id);
    _links.remove(id);
    _notAdded.remove(id);
    await _saveTargets();
    notifyListeners();
  }

  Future<void> setPaused(String id, bool paused) async {
    _targets = [for (final t in _targets) t.id == id ? t.copyWith(paused: paused) : t];
    await _saveTargets();
    if (paused) _status[id] = 'Paused.';
    notifyListeners();
    if (!paused) unawaited(syncAll());
  }

  SyncTargetConfig? _shareTarget() {
    final have = _targets.where((t) => t.kind == SyncKind.share).firstOrNull;
    if (have != null) return have;
    final d = shareFolder?.call();
    if (d == null) return null;
    final t = SyncTargetConfig(id: 'share', kind: SyncKind.share, path: d.path);
    _targets = [..._targets, t];
    return t;
  }

  /// The engine of a connection. Notebook sync has two: format 2 (`share2.json`, notebooks in `<id>/` folders) always, and, while
  /// [legacy] is asked for, format 1 (`share.json`, one folder per notebook name) for the devices that only know that.
  Future<NotebookSync> _engine(SyncTargetConfig t, {bool legacy = false}) async {
    final folder = await _folder(t.path);
    final v2 = t.kind == SyncKind.share && !legacy;
    ({String format, String dir, bool org})? ls;
    if (t.kind == SyncKind.logseq || t.kind == SyncKind.logseqExport) ls = readLogseqConfig(await folder.readText('logseq/config.edn'));
    final e = NotebookSync(
      notebook: notebook,
      kind: t.kind,
      folder: folder,
      stateFile: File('${(await dir()).path}/${t.id}${v2 ? '2' : ''}.json'),
      idLayout: v2,
      eligible: v2 ? _eligible : null,
      onLegacyMade: t.kind == SyncKind.share && legacy ? _eligible.add : null,
      clock: clock,
      onTombstone: v2 ? onTombstone : null,
      idForName: t.kind == SyncKind.share && legacy ? (name) async => (await idsByName(folder))[name] : null,
      includePrivate: t.kind != SyncKind.share,
      privateBooks: t.kind == SyncKind.share ? {..._privateBooks} : const {},
      logseqConfig: ls,
      importTag: t.tag,
    );
    final sp = storePhoto;
    if (sp != null) e.storePhotoBytes = sp;
    return e;
  }

  /// A change was saved: sync in 2 seconds (several changes, one sync).
  void changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () => unawaited(syncAll()));
  }

  /// Syncs every connected folder that is not paused, one after the other (a call while one runs runs again after it).
  Future<void> syncAll() async {
    await init();
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        final share = shareOn?.call() == true ? _shareTarget() : null;
        for (final t in [..._targets.where((t) => t.kind != SyncKind.share), ?share]) {
          if (t.paused) {
            _status[t.id] = 'Paused.';
            continue;
          }
          _status[t.id] = 'Syncing...';
          notifyListeners();
          if (t.kind == SyncKind.share) {
            await _syncShare(t);
            notifyListeners();
            continue;
          }
          try {
            final e = await _engine(t);
            final r = await e.run();
            _conflicts[t.id] = e.conflicts;
            _merged[t.id] = r.merged;
            if (t.kind != SyncKind.share) {
              _notAdded[t.id] = r.notAdded;
              _links[t.id] = await NotebookSync.links(e.stateFile);
              if (r.imported.isNotEmpty) _news.add((app: appName(t.kind), target: t.id, titles: [...r.imported], books: {...r.importedBooks}));
            }
            final n = e.conflicts.length;
            _status[t.id] = n > 0 ? (n == 1 ? '1 change needs a decision' : '$n changes need a decision') : 'Synced ${_clock(DateTime.now())}';
          } on FileSystemException catch (x) {
            _status[t.id] = (x.osError?.errorCode == 28 || x.osError?.errorCode == 112) ? "Can't write: storage is full." : "Can't reach the folder.";
          } catch (x) {
            _status[t.id] = "Can't reach the folder.";
            logError('Notebook sync', error: x, detail: t.id);
          }
          notifyListeners();
        }
      } while (_again);
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  // ---- notebook sync's share: format 2, and format 1 beside it for devices that only know that ----

  Future<File> _formatFile() async => File('${(await dir()).path}/share-format.json');

  Future<void> _readFormat() async {
    if (_formatRead) return;
    _formatRead = true;
    try {
      final f = await _formatFile();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return;
      _legacy = const {'on', 'off', 'cleaned'}.contains(j['legacy']) ? j['legacy'] as String : 'on';
      _migrated = j['migrated'] == true;
      _eligible.addAll([for (final x in (j['eligible'] as List? ?? const [])) '$x']);
      for (final e in (j['peers'] as Map? ?? const {}).entries) {
        _peerFormat['${e.key}'] = (legacyOff: (e.value as Map)['legacy_off'] == true);
      }
    } catch (e) {
      // Unreadable: format 1 folders are kept (the safe side) until the devices have said it again.
      logError('Notebook sync: share format state unreadable', error: e);
    }
  }

  Future<void> _saveFormat() async {
    final f = await _formatFile();
    await f.parent.create(recursive: true);
    await writeStringAtomic(f, jsonEncode({'legacy': _legacy, 'migrated': _migrated, 'eligible': [..._eligible]..sort(), 'peers': {for (final e in _peerFormat.entries) e.key: {'legacy_off': e.value.legacyOff}}}));
  }

  /// One sync of the notebooks share. While any linked device has not said it keeps format 2, the format 1 folders (one per
  /// notebook name) are kept current beside the `<id>/` ones: what an older device writes there is read in, and what is written
  /// here is written there too. Only when every linked device has said format 2, and then that it stopped reading them, are they
  /// removed (without a tombstone: nothing reads that as a delete).
  Future<void> _syncShare(SyncTargetConfig t) async {
    if (_corrupt) {
      _status[t.id] = 'Paused.';
      return;
    }
    if (notebook.replayError != null) {
      try {
        await notebook.replayReid();
      } catch (_) {}
      if (notebook.replayError != null) {
        _status[t.id] = 'Paused.';
        return;
      }
    }
    await _readFormat();
    // The first time: the notebooks here now are the ones from before the migration, the only ones matched by name.
    if (!_migrated && !notebook.loading && notebook.error == null) {
      _eligible.addAll(notebook.notebooks.map((n) => n.id));
      _migrated = true;
      await _saveFormat();
    }
    NotebookSync? v2;
    NotebookSync? v1;
    try {
      final folder = await _folder(t.path);
      await readShareDirs(folder);
      _formatBlocked = false;
      if (_legacy == 'on') {
        v1 = await _engine(t, legacy: true);
        await v1.run();
      }
      v2 = await _engine(t);
      final r = await v2.run();
      _merged[t.id] = r.merged;
      _dirNames = v2.dirNames;
      await _formatStep(folder, t);
      await _saveFormat();
      _conflicts[t.id] = [...v2.conflicts, ...?v1?.conflicts];
      final n = _conflicts[t.id]!.length;
      _status[t.id] = n > 0 ? (n == 1 ? '1 change needs a decision' : '$n changes need a decision') : 'Synced ${_clock(DateTime.now())}';
    } on NotebookFormatTooNew {
      _formatBlocked = true;
      _status[t.id] = kUpdateNeededNote;
    } on FileSystemException catch (x) {
      _status[t.id] = (x.osError?.errorCode == 28 || x.osError?.errorCode == 112) ? "Can't write: storage is full." : "Can't reach the folder.";
    } catch (x) {
      _status[t.id] = "Can't reach the folder.";
      logError('Notebook sync', error: x, detail: t.id);
    }
  }

  /// After a good sync: what the linked devices say decides whether format 1 goes on, stops, or is removed; and this device says
  /// the same to them.
  Future<void> _formatStep(SyncFolder folder, SyncTargetConfig t) async {
    final peers = peerCaps?.call();
    if (peers != null) {
      for (final e in peers.entries) {
        final caps = e.value;
        final f = caps?['notebook_format'];
        if (f is num && f >= kShareFormat) _peerFormat[e.key] = (legacyOff: caps?['notebook_legacy'] == false);
      }
      _peerFormat.removeWhere((id, _) => !peers.containsKey(id));
      final allV2 = peers.keys.every(_peerFormat.containsKey);
      final allOff = peers.keys.every((id) => _peerFormat[id]?.legacyOff == true);
      if (_legacy == 'on' && allV2) {
        _legacy = 'off';
      } else if (_legacy != 'on' && !allV2) {
        _legacy = 'on';
      }
      if (_legacy == 'off' && allOff) {
        for (final p in await legacyFiles(folder)) {
          await folder.delete(p);
        }
        final old = File('${(await dir()).path}/${t.id}.json');
        if (await old.exists()) await old.delete();
        _legacy = 'cleaned';
      }
      await _saveFormat();
    }
    final caps = {'notebook_format': kShareFormat, 'notebook_legacy': _legacy == 'on'};
    if (!mapEquals(caps, _advertised)) {
      _advertised = caps;
      await setCaps?.call(caps);
    }
  }

  Future<void> resolve(String id, SyncConflict c, {required bool keepCache}) async {
    final t = _targets.where((x) => x.id == id).firstOrNull;
    if (t == null) return;
    final e = await _engine(t, legacy: t.kind == SyncKind.share && !c.path.endsWith(kNoteExt));
    await e.resolve(c, keepCache: keepCache);
    _conflicts[id] = [for (final x in conflicts(id)) if (!(x.entryId == c.entryId && x.kind == c.kind && x.path == c.path)) x];
    notifyListeners();
    unawaited(syncAll());
  }

  static String _clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
