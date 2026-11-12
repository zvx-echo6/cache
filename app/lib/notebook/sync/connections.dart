import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../chat/ask_focus.dart';
import '../../files.dart';
import '../notebook_model.dart';
import '../notebook_state.dart';
import 'folder.dart';
import 'folder_access.dart';
import 'formats.dart';
import 'share_format.dart';
import 'upgrade_eligibility.dart';
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
  NotebookConnections({required this.notebook, required this.dir, this.shareFolder, this.shareOn, this.storePhoto, this.folderFor, this.gateActive, this.clock});

  /// The time (tests give one).
  final DateTime Function()? clock;

  /// Whether the link-level version gate is active: a device on an older sync protocol gets nothing of any kind from this device, in
  /// either direction. The conversion of the share removes the old folders, and would otherwise reach such a device as deletes; so
  /// it waits for this to be true (null counts as not active). The one seam to the gate.
  final bool Function()? gateActive;

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

  /// Where the conversion of the share to the id layout is: `converting`, `removing` or `done` (see [_convert]).
  String _conversion = 'converting';
  bool _convRead = false;
  String get conversionState => _conversion;

  /// The notebooks from before the upgrade to format 2 (local at the first start of this version, or made from a format 1 folder):
  /// the only ones matched by exact name with other devices' notebooks. Its own file, with a backup (see [UpgradeEligibility]).
  UpgradeEligibility? _elig;

  Future<UpgradeEligibility> _eligibility() async {
    final e = _elig ??= UpgradeEligibility(File('${(await dir()).path}/upgrade-eligible.json'));
    await e.load();
    return e;
  }

  /// The first start of a version with format 2: the notebooks here now are the ones from before, and are written down once. Called
  /// at start, before anything syncs. A fresh install has none to write.
  Future<void> captureUpgrade() async {
    await init();
    final e = await _eligibility();
    if (!notebook.loading && notebook.error == null) await e.capture(notebook.notebooks.map((n) => n.id));
  }

  /// The name of the notebook folder `<id>/` in the share, as its record says (after a sync); null for a folder that is not one.
  Map<String, String> _dirNames = {};
  String? dirName(String dir) => _dirNames[dir];

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
    final d = shareFolder?.call();
    if (have != null) {
      // The app's folder path changes across iOS installs and updates: the saved one is re-rooted at the current folder.
      if (d == null || d.path == have.path) return have;
      final moved = SyncTargetConfig(id: have.id, kind: have.kind, path: d.path, paused: have.paused, display: have.display, importTag: have.importTag);
      _targets = [for (final t in _targets) t.id == have.id ? moved : t];
      return moved;
    }
    if (d == null) return null;
    final t = SyncTargetConfig(id: 'share', kind: SyncKind.share, path: d.path);
    _targets = [..._targets, t];
    return t;
  }

  /// The engine of a connection. Notebook sync has two: format 2 (`share2.json`, notebooks in `<id>/` folders) always, and, while
  /// Notebook sync keeps its state in `share2.json` (the id layout; `share.json` is what an older build kept, removed after the
  /// conversion).
  Future<NotebookSync> _engine(SyncTargetConfig t) async {
    final folder = await _folder(t.path);
    final v2 = t.kind == SyncKind.share;
    ({String format, String dir, bool org})? ls;
    if (t.kind == SyncKind.logseq || t.kind == SyncKind.logseqExport) ls = readLogseqConfig(await folder.readText('logseq/config.edn'));
    final e = NotebookSync(
      notebook: notebook,
      kind: t.kind,
      folder: folder,
      stateFile: File('${(await dir()).path}/${t.id}${v2 ? '2' : ''}.json'),
      eligible: v2 ? (await _eligibility()).ids : null,
      clock: clock,
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
          // While Ask answers, the next folder waits (the one syncing finishes); sync goes on where it left off.
          await askIdle(worker: 'Notebook sync');
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

  // ---- notebook sync's share: the id layout, and the conversion to it ----

  Future<File> _conversionFile() async => File('${(await dir()).path}/share-conversion.json');

  Future<void> _readConversion() async {
    if (_convRead) return;
    _convRead = true;
    try {
      final f = await _conversionFile();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is Map && const {'converting', 'removing', 'done'}.contains(j['phase'])) _conversion = j['phase'] as String;
    } catch (e) {
      // Unreadable: the conversion starts over from "converting", which is safe to repeat (every step can be run again).
      logError('Notebook sync: conversion state unreadable', error: e);
    }
  }

  Future<void> _saveConversion(String phase) async {
    _conversion = phase;
    final f = await _conversionFile();
    await f.parent.create(recursive: true);
    await writeStringAtomic(f, jsonEncode({'phase': phase}));
    if (phase == 'done') {
      // What an older build kept for the old folders.
      final old = File('${(await dir()).path}/share.json');
      if (await old.exists()) await old.delete();
    }
  }

  /// One sync of the notebooks share. The notebooks are kept in `<id>/` folders. The first time after the update the share is
  /// converted (see [_convert]): what was written to the folders named after the notebooks goes into the id layout, then those
  /// folders are removed.
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
    final elig = await _eligibility();
    if (!elig.captured) {
      // The notebooks from before the update are written down at the first start of this version (captureUpgrade); until then
      // nothing is matched by name, so nothing is synced.
      _status[t.id] = 'Paused.';
      return;
    }
    await _readConversion();
    try {
      final folder = await _folder(t.path);
      await readShareDirs(folder);
      _formatBlocked = false;
      final v2 = await _engine(t);
      final r = await v2.run();
      _merged[t.id] = r.merged;
      _dirNames = v2.dirNames;
      await elig.save();
      await _convert(folder, elig);
      _conflicts[t.id] = v2.conflicts;
      final n = v2.conflicts.length;
      _status[t.id] = n > 0 ? (n == 1 ? '1 change needs a decision' : '$n changes need a decision') : 'Synced ${_clock(DateTime.now())}';
    } on NotebookFormatTooNew {
      _formatBlocked = true;
      _status[t.id] = kUpdateNeededNote;
    } on FileSystemException catch (x) {
      _status[t.id] = (x.osError?.errorCode == 28 || x.osError?.errorCode == 112) ? "Can't write: storage is full." : "Can't reach the folder.";
    } catch (x) {
      // A notebook id change that failed in the middle of this sync: it is queued, and notebook sync waits until it is finished.
      _status[t.id] = notebook.replayError != null ? 'Paused.' : "Can't reach the folder.";
      logError('Notebook sync', error: x, detail: t.id);
    }
  }

  /// The conversion of the share to the id layout, after the first good sync of it (so everything is in the id layout already). Each
  /// step can be run again, and [_conversion] says where it stopped:
  /// 1. `converting`: files in the old folders that Cache has no entry for (what an older build put there and this device had not
  ///    read yet) are placed in the id layout, to be read as entries by the next sync; nothing is removed until none is left.
  /// 2. `removing`: the old folders' files go (not a tombstone in sight: nothing reads them any more).
  /// 3. `done`.
  /// Nothing is removed before the link-level gate is active ([gateActive]): without it the removals would reach a device that
  /// only knows the old folders as deletes.
  Future<void> _convert(SyncFolder folder, UpgradeEligibility elig) async {
    if (_conversion == 'done') return;
    if (gateActive?.call() != true) return;
    final old = await legacyFiles(folder);
    if (old.isEmpty) {
      await _saveConversion('done');
      return;
    }
    if (_conversion == 'converting') {
      var placed = 0;
      for (final p in old.where((p) => p.endsWith('.md'))) {
        if (await _place(folder, p, elig)) placed++;
      }
      // Placed files are read by the next sync; the old ones are removed after that.
      if (placed > 0) return;
      await _saveConversion('removing');
    }
    for (final p in old) {
      await folder.delete(p);
    }
    await _saveConversion('done');
  }

  /// An old folder's note that Cache has no entry for: written into the id layout of its notebook (made here when no notebook of that
  /// name is) so the next sync reads it as an entry. True when it was placed. A note of a notebook that is not in the share (private,
  /// not included) is left alone.
  Future<bool> _place(SyncFolder folder, String path, UpgradeEligibility elig) async {
    final text = await folder.readText(path);
    if (text == null) return false;
    final doc = parseObsidian(text, fallbackId: '', fallbackNotebook: '', fieldProps: const {});
    if (doc == null) return false;
    if (doc.id.isNotEmpty && await notebook.entry(doc.id) != null) return false;
    final name = doc.notebook.trim();
    if (name.isEmpty) return false;
    var book = notebook.notebooks.where((n) => n.name == name).firstOrNull;
    if (book != null && book.private && !_privateBooks.contains(book.id)) return false;
    book ??= await notebook.saveNotebook(template: 'notes', def: NotebookDef(name: name, fields: const [], sort: NotebookSort.recent));
    elig.add(book.id);
    // It is the old text again, and it says so: of two copies of the note that differ, one that says this loses to the other.
    final text0 = text;
    final marked = text0.contains(RegExp(r'^cache_legacy: true$', multiLine: true)) ? text0 : text0.replaceFirstMapped(RegExp(r'^(cache_id: .*\n)', multiLine: true), (m) => '${m.group(1)}cache_legacy: true\n');
    final base = path.split('/').last.replaceAll(RegExp(r'\.md$'), '');
    // The same name every time, so a kill between the write and the delete leaves one file, not two.
    var to = '${book.id}/$base$kNoteExt';
    for (var i = 2; await folder.exists(to) && await folder.readText(to) != marked; i++) {
      to = '${book.id}/$base $i$kNoteExt';
    }
    if (await folder.readText(to) != marked) await folder.writeText(to, marked);
    for (final m in RegExp(r'cache-([A-Za-z0-9-]+)\.jpg').allMatches(text)) {
      final b = await folder.readBytes('photos/cache-${m.group(1)}.jpg');
      if (b != null) await folder.writeBytes('${book.id}/photos/cache-${m.group(1)}.jpg', b);
    }
    await folder.delete(path);
    return true;
  }

  Future<void> resolve(String id, SyncConflict c, {required bool keepCache}) async {
    final t = _targets.where((x) => x.id == id).firstOrNull;
    if (t == null) return;
    final e = await _engine(t);
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
