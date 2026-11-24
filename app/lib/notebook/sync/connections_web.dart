import 'dart:async';

import 'package:cache_search/cache_search.dart' show CoreTransport;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'connections.dart';
import 'device_folder_picker.dart';
import 'formats.dart' show kDefaultImportTag;
import 'sync_engine.dart';

/// In a browser, the notebooks' connections to Obsidian and Logseq: the folders are folders of the computer Cache runs on, and
/// Cache there keeps them in step with the notebooks (its helper's `nbfolders.*` ops, the phone's engine) with no tab open. This
/// asks for its state (every [poll] while the page is open, and at once after each choice) and sends the person's choices; it
/// reads no folder and runs no sync. The status lines are the phone's.
class ServerConnections extends ChangeNotifier implements SyncConnections {
  ServerConnections(this._t, {this.poll = const Duration(seconds: 2), this.listFolders});

  final CoreTransport _t;

  /// How often the state is asked for while the page is open.
  final Duration poll;

  /// Lists a folder of the computer for the picker (tests give their own); the helper's `devfs.list` when null.
  final ListDeviceFolder? listFolders;

  List<SyncTargetConfig> _targets = const [];
  final Map<String, _Row> _rows = {};
  bool _syncing = false;
  bool _asking = false;
  bool _disposed = false;
  Timer? _timer;

  /// Asked for the state at least once.
  bool loaded = false;

  /// The state could not be read the last time (Cache on this computer did not answer).
  bool unreachable = false;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (_timer == null && !_disposed) {
      _timer = Timer.periodic(poll, (_) => unawaited(refresh()));
      unawaited(refresh());
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  List<SyncTargetConfig> get targets => _targets;

  @override
  SyncTargetConfig? target(SyncKind kind) => _targets.where((t) => t.kind == kind || (kind == SyncKind.logseq && t.kind == SyncKind.logseqExport)).firstOrNull;

  @override
  bool get syncing => _syncing;

  @override
  String? status(String id) => _rows[id]?.status;

  @override
  List<SyncConflict> conflicts(String id) => _rows[id]?.conflicts ?? const [];

  @override
  List<String> merged(String id) => _rows[id]?.merged ?? const [];

  @override
  List<String> keptAsTwo(String id) => _rows[id]?.keptTwo ?? const [];

  @override
  int notAdded(String id) => _rows[id]?.notAdded ?? 0;

  /// Reads Cache's state on the computer.
  Future<void> refresh() async {
    if (_asking || _disposed) return;
    _asking = true;
    try {
      final r = await _t.call('nbfolders.state', const {});
      if (_disposed) return;
      _apply(r is Map ? r.cast<String, dynamic>() : const {});
      unreachable = false;
    } catch (_) {
      if (_disposed) return;
      unreachable = true;
    } finally {
      _asking = false;
    }
    loaded = true;
    if (!_disposed) notifyListeners();
  }

  void _apply(Map<String, dynamic> s) {
    _syncing = s['syncing'] == true;
    final ts = <SyncTargetConfig>[];
    final rows = <String, _Row>{};
    for (final j in (s['targets'] as List? ?? const [])) {
      if (j is! Map) continue;
      final kind = SyncKind.values.where((k) => k.name == j['kind']).firstOrNull;
      final path = j['path'];
      if (kind == null || path is! String) continue;
      final id = '${j['id']}';
      final tag = j['import_tag'];
      // The full path is the name on a computer: the same folder name often sits in several places.
      ts.add(SyncTargetConfig(id: id, kind: kind, path: path, paused: j['paused'] == true, display: path, importTag: tag is String && tag != kDefaultImportTag ? tag : null));
      var status = j['status'] as String?;
      final at = j['synced_at'];
      // The time in the status is this browser's own clock, not the computer's.
      if (status != null && status.startsWith('Synced ') && at is int) status = 'Synced ${_clock(DateTime.fromMillisecondsSinceEpoch(at))}';
      rows[id] = _Row(
        status: status,
        merged: [for (final x in (j['merged'] as List? ?? const [])) '$x'],
        keptTwo: [for (final x in (j['kept_as_two'] as List? ?? const [])) '$x'],
        notAdded: (j['not_added'] as num?)?.toInt() ?? 0,
        conflicts: [for (final c in (j['conflicts'] as List? ?? const [])) ?SyncConflict.fromJson(c as Map)],
      );
    }
    _targets = ts;
    _rows
      ..clear()
      ..addAll(rows);
  }

  static String _clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Future<String?> connect(SyncKind kind, String path, {String? display}) async {
    try {
      final r = await _t.call('nbfolders.connect', {'kind': kind.name, 'path': path});
      final err = r is Map ? r['error'] : null;
      if (err is String) return err;
    } catch (_) {
      return "Can't reach the folder.";
    }
    await refresh();
    return null;
  }

  Future<void> _do(String op, Map<String, dynamic> args) async {
    try {
      await _t.call(op, args);
    } catch (_) {
      // Cache on this computer did not answer: [refresh] says so ([unreachable]) and the page shows what it last knew.
    }
    await refresh();
  }

  @override
  Future<void> disconnect(String id) => _do('nbfolders.disconnect', {'id': id});

  @override
  Future<void> setPaused(String id, bool paused) => _do('nbfolders.pause', {'id': id, 'paused': paused});

  @override
  Future<void> setImportTag(String id, String tag) => _do('nbfolders.set_tag', {'id': id, 'tag': tag});

  @override
  Future<void> resolve(String id, SyncConflict c, {required bool keepCache}) =>
      _do('nbfolders.resolve', {'id': id, 'entry': c.entryId, 'kind': c.kind.name, 'title': c.title, 'path': c.path, 'keep_cache': keepCache});

  /// Sync now: shows "Syncing..." at once on the connections that are not paused, and answers when the pass is done.
  @override
  Future<void> syncAll() async {
    for (final t in _targets) {
      if (t.paused) continue;
      final r = _rows[t.id];
      _rows[t.id] = _Row(status: 'Syncing...', merged: r?.merged ?? const [], keptTwo: r?.keptTwo ?? const [], notAdded: r?.notAdded ?? 0, conflicts: r?.conflicts ?? const []);
    }
    _syncing = true;
    notifyListeners();
    await _do('nbfolders.sync', const {});
  }

  @override
  Future<({String path, String display})?> Function(BuildContext context)? get ownPicker => (context) => pickOnThisComputer(context, listFolders ?? list);

  /// A folder's listing from `devfs.list`: null starts at the home folder. Throws when Cache cannot read it.
  Future<DeviceListing> list(String? path) async {
    final r = await _t.call('devfs.list', {'path': ?path});
    final m = (r as Map).cast<String, dynamic>();
    NotesKind kind(Object? k) => switch (k) {
          'obsidian' => NotesKind.obsidian,
          'logseq' => NotesKind.logseq,
          _ => NotesKind.none,
        };
    return DeviceListing(
      path: m['path'] as String,
      home: m['home'] as String,
      parent: m['parent'] as String?,
      kind: kind(m['kind']),
      folders: [for (final f in m['folders'] as List) DeviceFolderEntry((f as Map)['name'] as String, kind(f['kind']))],
    );
  }
}

class _Row {
  const _Row({this.status, this.merged = const [], this.keptTwo = const [], this.notAdded = 0, this.conflicts = const []});

  final String? status;
  final List<String> merged, keptTwo;
  final int notAdded;
  final List<SyncConflict> conflicts;
}

/// Cache's folder picker as a page of the navigator [context] is in (in a two-pane window: beside the list, in the pane); the
/// folder chosen as `(path, display)` like the phone's picker gives it, or null when the page was left.
Future<({String path, String display})?> pickOnThisComputer(BuildContext context, ListDeviceFolder list) =>
    Navigator.of(context).push<({String path, String display})>(MaterialPageRoute(builder: (_) => DeviceFolderPicker(list: list)));
