import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/sync/connections.dart';
import 'package:cache/notebook/sync/folder.dart';

import '../fixtures/v1030/sync_engine_v1030.dart' as v1030;
import 'notebook_fake.dart';

/// A folder in memory.
class MemFolder implements SyncFolder {
  final Map<String, String> text = {};
  final Map<String, Uint8List> bytes = {};
  bool up = true;

  /// A kill during removals: after this many deletes the next one throws (null: never).
  int? failAfterDeletes;

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
  Future<void> writeText(String path, String t) async {
    final h = beforeWrite;
    if (h != null) await h(path);
    text[path] = t;
  }

  /// A fault: called before each write of a text file; it may throw (a folder error mid-run).
  Future<void> Function(String path)? beforeWrite;

  @override
  Future<void> writeBytes(String path, Uint8List b) async => bytes[path] = b;

  @override
  Future<void> delete(String path) async {
    if (failAfterDeletes != null) {
      if (failAfterDeletes! <= 0) throw StateError('killed');
      failAfterDeletes = failAfterDeletes! - 1;
    }
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

  /// The link-level gate: while it is false the link carries nothing, in either direction (a device on an older sync protocol).
  bool Function()? open;

  bool _hidden(String p) => p.split('/').any((s) => s.startsWith('.'));

  void sync() {
    if (!(open?.call() ?? true)) return;
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

/// A device: its notebooks, its folder of the share, and either the sync of Cache v1.0.30 (the real engine, from the tag: it has not
/// updated) or the connections that run notebook sync now. [updateCache] is the update: the same notebooks and folder, the app
/// started again as the new version.
class Dev {
  Dev(this.label, {this.old = false, this.autoUpgrade = true, this.clock, this.gateFn}) {
    _wire();
  }

  final String label;
  final DateTime Function()? clock;

  /// The gate seam from the real wiring (a SharingState's linkGateActive); null: the stub (gateOn, gateUnset).
  bool Function()? gateFn;

  /// Still on v1.0.30.
  bool old;

  /// The notebooks that exist at the first sync stand for the ones from before the update (a test that wants the update to come
  /// before any notebook is made calls [upgrade] itself and sets this to false).
  bool autoUpgrade;

  void restart() => _wire();

  /// The update: the app starts again, as the new version, on the same notebooks, share folder and files.
  Future<void> updateCache() async {
    old = false;
    _wire();
    await boot();
  }

  void _wire() {
    // Each device keeps its photos in a folder of its own.
    nb = NotebookState(backend: store, mediaDir: () async => Directory('${stateDir.path}/media'));
    nb.reidJournal = reidFile;
    conn = NotebookConnections(
      notebook: nb,
      clock: clock,
      dir: () async => stateDir,
      shareFolder: () => Directory('${stateDir.path}/share'),
      shareOn: () => on,
      folderFor: (_) => folder,
      gateActive: gateFn ?? (gateUnset ? null : () => gateOn),
      storePhoto: (id, bytes) async {
        final f = await nb.photoFile(id);
        await f.parent.create(recursive: true);
        await f.writeAsBytes(bytes);
      },
    );
  }

  final FakeNotebookBackend store = FakeNotebookBackend(journal: false);
  late NotebookState nb;
  late NotebookConnections conn;
  final MemFolder folder = MemFolder();
  final Directory stateDir = Directory.systemTemp.createTempSync('cache-dev-');
  late final File reidFile = File('${stateDir.path}/reid-journal.json');

  /// Whether notebook sync of the share runs (a test switches it off while it sets things up, so no sync starts by itself).
  bool on = true;

  /// The link-level version gate (a stub: all peers gated or compatible as the test needs).
  bool gateOn = true;

  /// Leave the gate seam unset (null), as an app with no gate wired has it.
  bool gateUnset = false;
  bool _upgraded = false;

  /// Starts the way main.dart does: what keeps notebook ids is wired first, then the journal is replayed (a failure does not stop the
  /// start), then the notebooks are read.
  Future<void> boot() async {
    nb.privateSharing = conn;
    nb.reidSteps['field names'] = conn.moveFieldMaps;
    try {
      await nb.replayReid();
    } catch (_) {}
    await nb.start();
  }

  /// The first start of this version: the notebooks here now are the ones from before.
  Future<void> upgrade() async {
    await conn.captureUpgrade();
    _upgraded = true;
  }

  Future<Notebook> make(String name, {String? id, bool private = false}) =>
      nb.saveNotebook(id: id, template: 'notes', def: NotebookDef(name: name, fields: const [], sort: NotebookSort.recent), private: private);

  Future<void> add(String notebookId, String id, String title, {String body = 'Body'}) =>
      nb.saveEntry(id: id, notebookId: notebookId, occurredAt: '2026-11-01T09:00:00-07:00', title: title, body: body).then((_) {});

  /// A notebook with fields.
  Future<Notebook> makeWith(String name, List<LogField> fields, {String? id}) =>
      nb.saveNotebook(id: id, template: 'log', def: NotebookDef(name: name, fields: fields, sort: NotebookSort.recent));

  /// The notebook's fields as shown here: visible ones by label (hidden ones are not in the list), in order.
  List<String> labels(String id) => [for (final f in nb.notebook(id)!.def.visible) f.label];

  LogField field(String id, String label) => nb.notebook(id)!.def.fields.firstWhere((f) => f.label == label);

  /// Changes the fields the way the editor does (a save without `from_sync`).
  Future<void> editFields(String id, List<LogField> Function(List<LogField> now) f) async {
    final n = nb.notebook(id)!;
    await nb.saveNotebook(id: id, def: n.def.copyWith(fields: f(n.def.fields)));
  }

  /// An entry with values of fields (by label).
  Future<void> addValues(String notebookId, String id, Map<String, Object> byLabel) => nb
      .saveEntry(id: id, notebookId: notebookId, occurredAt: '2026-11-01T09:00:00-07:00', title: id, values: {for (final e in byLabel.entries) field(notebookId, e.key).fid!: e.value})
      .then((_) {});

  /// The notebooks' fields lose their ids (the fields of a device from before the field sync), what the device remembers stays.
  Future<void> stripGids() async {
    for (final n in store.notebooks) {
      for (final f in (n['def']['fields'] as List)) {
        (f as Map).remove('gid');
      }
    }
    await nb.reload();
  }

  /// What this device was before the field sync existed: fields without ids, and nothing remembered of them.
  ///
  /// With [keepGids] the notebook keeps its ids and only what the device remembers is lost: a run that stopped after the notebook took
  /// its ids and before the device wrote down that it was done.
  Future<void> beforeFields({bool keepGids = false, Map<String, String>? props}) async {
    if (!keepGids) {
      for (final n in store.notebooks) {
        for (final f in (n['def']['fields'] as List)) {
          (f as Map).remove('gid');
        }
      }
    }
    final f = File('${stateDir.path}/share2.json');
    if (await f.exists()) {
      final j = jsonDecode(await f.readAsString()) as Map;
      j.remove('fields');
      // the device's own property names from before (by notebook id, then field id)
      if (props != null) {
        final m = {...((j['props'] as Map?) ?? const {})};
        for (final e in props.entries) {
          m[e.key] = {...((m[e.key] as Map?) ?? const {}), ...jsonDecode(e.value) as Map};
        }
        j['props'] = m;
      }
      await f.writeAsString(jsonEncode(j));
    }
    await nb.reload();
  }

  /// What a build before the field sync wrote of the records: no `fields`.
  static void stripRecordFields(MemFolder folder) {
    for (final k in folder.text.keys.toList()) {
      if (!k.endsWith('/notebook.json')) continue;
      final j = jsonDecode(folder.text[k]!) as Map;
      j.remove('fields');
      j.remove('fields_at');
      folder.text[k] = '${jsonEncode(j)}\n';
    }
  }

  Map<String, dynamic>? record(String id) {
    final t = folder.text['$id/notebook.json'];
    return t == null ? null : jsonDecode(t) as Map<String, dynamic>;
  }

  List<String> ids(String name) => [for (final n in nb.notebooks) if (n.name == name) n.id];

  Future<Set<String>> entryIds(String notebookId) async => {for (final e in await nb.entries(notebookId)) e.id};

  /// One sync: the engine of v1.0.30 for a device that has not updated; the connections for one that has.
  Future<void> sync() async {
    if (old) {
      final e = v1030.NotebookSync(notebook: nb, kind: v1030.SyncKind.share, folder: folder, stateFile: File('${stateDir.path}/share.json'), includePrivate: false);
      await e.run();
      return;
    }
    if (autoUpgrade && !_upgraded) await upgrade();
    while (conn.syncing) {
      await Future<void>.delayed(Duration.zero);
    }
    await conn.syncAll();
    while (conn.syncing) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}
