import 'dart:io';
import 'dart:typed_data';

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/sync/connections.dart';
import 'package:cache/notebook/sync/folder.dart';
import 'package:cache/notebook/sync/sync_engine.dart';

import 'notebook_fake.dart';

/// A folder in memory.
class MemFolder implements SyncFolder {
  final Map<String, String> text = {};
  final Map<String, Uint8List> bytes = {};
  bool up = true;

  @override
  String get display => 'Share';

  @override
  Future<bool> reachable() async => up;

  @override
  Future<List<FolderFile>> list(String dir) async => [
        for (final p in ({...text.keys, ...bytes.keys}.toList()..sort()))
          if (dir.isEmpty || p.startsWith('$dir/')) FolderFile(p, 0, (text[p] ?? '').length),
      ];

  @override
  Future<String?> readText(String path) async => text[path];

  @override
  Future<Uint8List?> readBytes(String path) async => bytes[path];

  @override
  Future<void> writeText(String path, String t) async => text[path] = t;

  @override
  Future<void> writeBytes(String path, Uint8List b) async => bytes[path] = b;

  @override
  Future<void> delete(String path) async {
    text.remove(path);
    bytes.remove(path);
  }

  @override
  Future<bool> exists(String path) async => text.containsKey(path) || bytes.containsKey(path);
}

/// The share between two devices as cache_sync keeps it: every file but a hidden one (a name starting with a dot, so never
/// `.cache/notebooks.json`), a change on one side goes to the other (deletes too), and when both changed a file the side with the
/// lesser content keeps its file as a conflict copy and takes the other's (the copy then goes across as a file of its own).
class ShareLink {
  ShareLink(this.a, this.b);

  final MemFolder a;
  final MemFolder b;
  Map<String, String> last = {};
  Map<String, Uint8List> lastBytes = {};

  /// Paths the share does not carry yet (a slow transfer): left as they are on both sides.
  bool Function(String path)? block;

  bool _hidden(String p) => p.split('/').any((s) => s.startsWith('.'));

  void sync() {
    final next = <String, String>{};
    final paths = {...a.text.keys, ...b.text.keys, ...last.keys}.where((p) => !_hidden(p));
    for (final p in paths.toList()..sort()) {
      final l = last[p], x = a.text[p], y = b.text[p];
      if (block?.call(p) ?? false) {
        if (l != null) next[p] = l;
        continue;
      }
      var win = x;
      if (x != y) {
        final xc = x != l, yc = y != l;
        if (xc && !yc) {
          win = x;
        } else if (yc && !xc) {
          win = y;
        } else if (x != null && y != null) {
          win = x.compareTo(y) >= 0 ? x : y;
          final loser = identical(win, x) ? b : a;
          final lost = identical(win, x) ? y : x;
          final dot = p.lastIndexOf('.');
          loser.text['${p.substring(0, dot)} (conflict, ${identical(win, x) ? 'Field tablet' : 'Home phone'}, 2026-11-10 0900)${p.substring(dot)}'] = lost;
        } else {
          win = x ?? y;
        }
        for (final f in [a, b]) {
          if (win == null) {
            f.text.remove(p);
          } else {
            f.text[p] = win;
          }
        }
      }
      if (win != null) next[p] = win;
    }
    last = next;
    // Photos: copied across, never changed.
    for (final e in {...a.bytes, ...b.bytes}.entries) {
      if (_hidden(e.key) || (block?.call(e.key) ?? false)) continue;
      a.bytes.putIfAbsent(e.key, () => e.value);
      b.bytes.putIfAbsent(e.key, () => e.value);
    }
  }
}

/// A device that has format 2: its notebooks, its folder of the share, and the connections that run notebook sync.
class Dev {
  Dev(this.label, {this.clock}) {
    _wire();
  }

  final DateTime Function()? clock;

  /// A new start of the app on the same notebooks, share folder and files (a kill and a start): new state objects, nothing in memory.
  void restart() => _wire();

  void _wire() {
    nb = fakeNotebook(store);
    nb.reidJournal = reidFile;
    conn = NotebookConnections(
      clock: clock,
      notebook: nb,
      dir: () async => stateDir,
      shareFolder: () => Directory('${stateDir.path}/share'),
      shareOn: () => on,
      folderFor: (_) => folder,
      peerCaps: () => peers,
      setCaps: (c) async => advertised = c,
      onTombstone: (id, at) async => tombstones.add('$id@$at'),
    );
  }

  final String label;
  final FakeNotebookBackend store = FakeNotebookBackend(journal: false);
  late NotebookState nb;
  late NotebookConnections conn;
  final MemFolder folder = MemFolder();
  final Directory stateDir = Directory.systemTemp.createTempSync('cache-dev-');
  late final File reidFile = File('${stateDir.path}/reid-journal.json');

  /// What this device sees of the linked devices' caps (null: it knows of none yet; a device with no caps: an older version).
  Map<String, Map<String, dynamic>?>? peers;

  /// Whether notebook sync of the share runs (a test switches it off while it sets things up, so no sync starts by itself).
  bool on = true;

  /// What this device last told the others about itself.
  Map<String, dynamic>? advertised;

  final List<String> tombstones = [];

  /// Starts the way main.dart does: what keeps notebook ids is wired first, then the journal is replayed (a failure does not stop
  /// the start), then the notebooks are read.
  Future<void> boot() async {
    nb.privateSharing = conn;
    nb.reidSteps['field names'] = conn.moveFieldMaps;
    try {
      await nb.replayReid();
    } catch (_) {}
    await nb.start();
  }

  Future<Notebook> make(String name, {String? id, bool private = false}) =>
      nb.saveNotebook(id: id, template: 'notes', def: NotebookDef(name: name, fields: const [], sort: NotebookSort.recent), private: private);

  Future<void> add(String notebookId, String id, String title, {String body = 'Body'}) =>
      nb.saveEntry(id: id, notebookId: notebookId, occurredAt: '2026-11-01T09:00:00-07:00', title: title, body: body).then((_) {});

  List<String> ids(String name) => [for (final n in nb.notebooks) if (n.name == name) n.id];

  Future<Set<String>> entryIds(String notebookId) async => {for (final e in await nb.entries(notebookId)) e.id};

  Future<void> sync() async {
    while (conn.syncing) {
      await Future<void>.delayed(Duration.zero);
    }
    await conn.syncAll();
    while (conn.syncing) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Format 1 only, as every build up to 1.0.30 syncs the notebooks share.
  Future<void> oldSync({bool includePrivate = false}) async {
    final e = NotebookSync(notebook: nb, kind: SyncKind.share, folder: folder, stateFile: File('${stateDir.path}/share.json'), includePrivate: includePrivate, skipFormat2Dirs: false);
    await e.run();
  }
}
