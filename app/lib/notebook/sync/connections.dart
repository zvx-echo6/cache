import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../files.dart';
import '../notebook_state.dart';
import 'folder.dart';
import 'folder_access.dart';
import 'formats.dart';
import 'sync_engine.dart';

/// Notebook sync's folder in the app's support folder (a sharing kind, "Notebooks").
const String kNotebookShareDir = 'notebook-share';

/// One connected folder: an Obsidian vault, a Logseq graph (two-way, or export-only for Logseq 2.x), or notebook sync's own
/// folder (kind share, id `share`). Private items go to Obsidian and Logseq (decided 2026-10-29); notebook sync leaves private
/// notebooks out unless each one's "Include in sync and sharing" is on.
class SyncTargetConfig {
  const SyncTargetConfig({required this.id, required this.kind, required this.path, this.paused = false, this.display});

  final String id;
  final SyncKind kind;
  final String path;
  final bool paused;

  /// The folder's name as the picker gave it (the path is a URI or a bookmark on phones).
  final String? display;

  String get name => display ?? (path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).lastOrNull ?? path);

  SyncTargetConfig copyWith({bool? paused}) => SyncTargetConfig(id: id, kind: kind, path: path, paused: paused ?? this.paused, display: display);

  Map<String, dynamic> toJson() => {'id': id, 'kind': kind.name, 'path': path, 'paused': paused, 'display': ?display};

  static SyncTargetConfig? fromJson(Object? j) {
    if (j is! Map || j['path'] is! String) return null;
    final kind = SyncKind.values.where((k) => k.name == j['kind']).firstOrNull;
    if (kind == null) return null;
    return SyncTargetConfig(id: '${j['id']}', kind: kind, path: j['path'] as String, paused: j['paused'] == true, display: j['display'] as String?);
  }
}

/// The notebooks' connections: the folders they are kept in step with, when they sync (on opening Notebooks, 2 s after a
/// change, when Cache comes back to the screen; never in the background), their status lines and the decisions they wait for.
/// Errors never block Notebooks.
class NotebookConnections extends ChangeNotifier implements PrivateSharing {
  NotebookConnections({required this.notebook, required this.dir, this.shareFolder, this.shareOn, this.storePhoto, this.folderFor});

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

  List<SyncTargetConfig> get targets => [for (final t in _targets) if (t.kind != SyncKind.share) t];
  SyncTargetConfig? target(SyncKind kind) => _targets.where((t) => t.kind == kind || (kind == SyncKind.logseq && t.kind == SyncKind.logseqExport)).firstOrNull;
  bool get syncing => _running;

  /// "Synced 4:20 PM", "Syncing...", "Can't reach the folder.", "Paused.", "2 changes need a decision".
  String? status(String id) => _status[id];
  List<SyncConflict> conflicts(String id) => _conflicts[id] ?? const [];

  /// Entries changed in both places whose changes were merged in the last run (told, not asked).
  List<String> merged(String id) => _merged[id] ?? const [];

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
      debugPrint('cache notebook connections: $e');
    }
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

  Future<NotebookSync> _engine(SyncTargetConfig t) async {
    final folder = await _folder(t.path);
    ({String format, String dir, bool org})? ls;
    if (t.kind == SyncKind.logseq || t.kind == SyncKind.logseqExport) ls = readLogseqConfig(await folder.readText('logseq/config.edn'));
    final e = NotebookSync(
      notebook: notebook,
      kind: t.kind,
      folder: folder,
      stateFile: File('${(await dir()).path}/${t.id}.json'),
      includePrivate: t.kind != SyncKind.share,
      privateBooks: t.kind == SyncKind.share ? {..._privateBooks} : const {},
      logseqConfig: ls,
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
          try {
            final e = await _engine(t);
            final r = await e.run();
            _conflicts[t.id] = e.conflicts;
            _merged[t.id] = r.merged;
            final n = e.conflicts.length;
            _status[t.id] = n > 0 ? (n == 1 ? '1 change needs a decision' : '$n changes need a decision') : 'Synced ${_clock(DateTime.now())}';
          } on FileSystemException catch (x) {
            _status[t.id] = (x.osError?.errorCode == 28 || x.osError?.errorCode == 112) ? "Can't write: storage is full." : "Can't reach the folder.";
          } catch (x) {
            _status[t.id] = "Can't reach the folder.";
            debugPrint('cache notebook sync ${t.id}: $x');
          }
          notifyListeners();
        }
      } while (_again);
    } finally {
      _running = false;
      notifyListeners();
    }
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
