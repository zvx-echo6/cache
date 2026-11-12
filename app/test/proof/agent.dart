// Notebook sync proof harness: one device = one OS process running this agent. It takes commands as JSON files in
// <PROOF_DIR>/cmd/NNNN.json ({"op":..,"args":{..}}) and writes <PROOF_DIR>/res/NNNN.json ({"ok":true,"result":..} or {"ok":false,"error":..}).
// Nothing here is faked: the callers wire the app's real NotebookState (CoreNotebookBackend over the real cache_search core),
// SharingState (real SyncCore, iroh on localhost), NotebookConnections (real IoFolder) and NotebookSync.
// This file uses only the API that v1.0.30 and the chain branch share; the wiring (and what differs) is in device_*.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache_search/cache_search.dart' show SyncCore;
import 'package:flutter/material.dart' show Icons;

/// A wifi connection that never changes (the phone's connectivity plugin does not exist on a PC); it only feeds the network policy.
class ProofProbe implements ConnectionProbe {
  @override
  Future<ConnectionKind> current() async => ConnectionKind.wifi;
  @override
  Stream<ConnectionKind> get changes => const Stream.empty();
}

DataPolicy proofPolicy() => DataPolicy(settings: AppSettings(), probe: ProofProbe());

/// The notebooks kind as main.dart declares it (the part Sharing uses).
DataKind notebooksKind(Directory shareDir) => DataKind(id: 'notebooks', label: 'Notebooks', icon: Icons.book_outlined, shared: () => {'notebooks': shareDir});

/// The opener SharingState takes: the real SyncCore, with relay, dht, mdns and lookup off and the device's fixed port.
SyncOpener proofOpener(int port) => (cfg) async {
      final c = await SyncCore.open({...cfg, 'relay': false, 'dht': false, 'mdns': false, 'lookup': false, 'interval_secs': 5, 'port': port});
      return _Real(c);
    };

class _Real implements SyncCoreLike {
  _Real(this.c);
  final SyncCore c;
  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) => c.call(method, args);
  @override
  Future<void> close() => c.close();
}

class Agent {
  Agent({
    required this.dir,
    required this.nb,
    required this.sharing,
    required this.syncFolder,
    required this.conversion,
    required this.gate,
    required this.shareDir,
    required this.closeAll,
  });

  final Directory dir; // PROOF_DIR (cmd/, res/, log.txt)
  final NotebookState nb;
  final SharingState sharing;
  final Future<void> Function() syncFolder; // NotebookConnections.syncAll
  final String Function() conversion; // 'converting' | 'removing' | 'done' | 'n/a' (legacy)
  final bool Function() gate; // SharingState.linkGateActive, or false on the legacy
  final Directory shareDir;
  final Future<void> Function() closeAll;

  void log(String s) {
    File('${dir.path}/log.txt').writeAsStringSync('${DateTime.now().toIso8601String()} $s\n', mode: FileMode.append, flush: true);
  }

  Notebook _book(String nameOrId) {
    final all = nb.notebooks;
    return all.where((n) => n.id == nameOrId).firstOrNull ?? all.firstWhere((n) => n.name == nameOrId, orElse: () => throw StateError('no notebook "$nameOrId"'));
  }

  LogField _mkField(Map f) => LogField(label: '${f['label']}', type: FieldType.values.firstWhere((t) => t.name == (f['type'] ?? 'text')), choices: (f['choices'] as List?)?.cast<String>());

  Map<String, dynamic> _byFid(Notebook n, Map<String, dynamic> byLabel) {
    final out = <String, dynamic>{};
    for (final e in byLabel.entries) {
      final f = n.def.fields.firstWhere((f) => f.label == e.key, orElse: () => throw StateError('no field "${e.key}" in ${n.name}'));
      out[f.fid!] = e.value;
    }
    return out;
  }

  Future<Map<String, dynamic>> dump() async {
    final books = <Map<String, dynamic>>[];
    for (final n in nb.notebooks) {
      final entries = await nb.entries(n.id);
      final byFid = {for (final f in n.def.fields) f.fid: f.label};
      books.add({
        'id': n.id,
        'name': n.name,
        'private': n.private,
        'fields': [
          for (final f in n.def.fields)
            {'label': f.label, 'type': f.type.name, 'hidden': f.hidden, 'gid': _gid(f), 'choices': f.choices},
        ],
        'entries': [
          for (final e in entries)
            {
              'id': e.id,
              'title': e.title,
              'body': e.body,
              'values': {for (final v in e.values.entries) (byFid[v.key] ?? '?${v.key}'): v.value},
            },
        ]..sort((a, b) => '${a['id']}'.compareTo('${b['id']}')),
      });
    }
    books.sort((a, b) => '${a['name']}|${a['id']}'.compareTo('${b['name']}|${b['id']}'));
    return {'notebooks': books};
  }

  // v1.0.30 has no field ids (gid); the chain does.
  Object? _gid(LogField f) {
    try {
      return (f as dynamic).gid;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> status() async {
    await sharing.refresh();
    final s = sharing.status;
    return {
      'id': s['id'],
      'name': s['name'],
      'rounds': s['rounds'],
      'transfer': s['transfer'],
      'paused': s['paused'],
      'direct': s['direct'],
      'gate_active': gate(),
      'conversion': conversion(),
      'peers': [
        for (final p in sharing.peers) {'id': p['id'], 'name': p['name'], 'compat': p['compat'], 'peer_proto': p['peer_proto'], 'peer_version': p['peer_version'], 'live': p['live'], 'error': p['error']},
      ],
      'shares': [
        for (final p in sharing.shares) {'id': p['id'], 'files': p['files'], 'pending_files': p['pending_files']},
      ],
      'log': ((s['log'] as List?) ?? const []).take(12).toList(),
    };
  }

  /// One sync round of what the app does: notebooks to the folder, the engine moves the folder, the folder back to the notebooks.
  Future<Map<String, dynamic>> syncOnce({int waitSecs = 60}) async {
    await syncFolder();
    String? err;
    if (sharing.running) {
      final before = ((sharing.status['rounds'] as num?) ?? 0).toInt();
      try {
        await sharing.syncNow();
      } catch (e) {
        err = '$e';
      }
      final end = DateTime.now().add(Duration(seconds: waitSecs));
      var calm = 0;
      while (DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await sharing.refresh();
        final s = sharing.status;
        final rounds = ((s['rounds'] as num?) ?? 0).toInt();
        final busy = s['transfer'] != null || sharing.shares.any((x) => ((x['pending_files'] as num?) ?? 0) > 0);
        if (rounds > before && !busy) {
          if (++calm >= 2) break;
        } else {
          calm = 0;
        }
      }
    }
    await syncFolder();
    return {'sync_error': err};
  }

  Future<dynamic> run(String op, Map<String, dynamic> a) async {
    switch (op) {
      case 'ping':
        return {'pid': pid, 'dir': dir.path};
      case 'sharing_setup':
        await sharing.setUp();
        return {'running': sharing.running, 'error': sharing.error};
      case 'link_code':
        return {'code': await sharing.linkCode()};
      case 'link':
        // The chain returns (peer, name); v1.0.30 returns the other device's name.
        final dynamic r = await (sharing as dynamic).link('${a['code']}');
        return {'linked': r is String ? r : '${r.name} (${r.peer})'};
      case 'share_on':
        await sharing.setShared(sharing.kinds.firstWhere((k) => k.id == 'notebooks'), true);
        return {'shares': sharing.shares.map((s) => s['id']).toList()};
      case 'share_off':
        await sharing.setShared(sharing.kinds.firstWhere((k) => k.id == 'notebooks'), false);
        return {'shares': sharing.shares.map((s) => s['id']).toList()};
      case 'status':
        return status();
      case 'sync':
        Map<String, dynamic> last = {};
        for (var i = 0; i < ((a['rounds'] as num?) ?? 1); i++) {
          last = await syncOnce();
        }
        return last;
      case 'sync_folder_only':
        await syncFolder();
        return {};
      case 'check_version':
        final peers = sharing.peers;
        final out = <String, String>{};
        for (final p in peers) {
          try {
            out['${p['id']}'] = await (sharing as dynamic).checkVersion('${p['id']}') as String;
          } catch (e) {
            out['${p['id']}'] = 'error: $e';
          }
        }
        await sharing.refresh();
        return out;
      case 'nb_make':
        final n = await nb.saveNotebook(
          id: a['id'] as String?,
          template: 'log',
          def: NotebookDef(name: '${a['name']}', fields: [for (final f in (a['fields'] as List? ?? const [])) _mkField(f as Map)], sort: NotebookSort.recent),
        );
        return {'id': n.id};
      case 'nb_delete':
        await nb.deleteNotebook(_book('${a['notebook']}').id);
        return {};
      case 'entry_add':
        final n = _book('${a['notebook']}');
        final e = await nb.saveEntry(
          id: a['id'] as String?,
          notebookId: n.id,
          occurredAt: '2026-11-01T09:00:00-07:00',
          title: a['title'] as String?,
          body: a['body'] as String?,
          values: _byFid(n, ((a['values'] as Map?) ?? const {}).cast<String, dynamic>()),
        );
        return {'id': e.id};
      case 'entry_edit':
        final cur = await nb.entry('${a['id']}') ?? (throw StateError('no entry ${a['id']}'));
        final n = _book(cur.notebookId);
        final byLabel = ((a['values'] as Map?) ?? const {}).cast<String, dynamic>();
        final e = await nb.saveEntry(
          id: cur.id,
          notebookId: cur.notebookId,
          occurredAt: cur.occurredAt,
          title: a.containsKey('title') ? a['title'] as String? : cur.title,
          body: a.containsKey('body') ? a['body'] as String? : cur.body,
          values: {...cur.values, ..._byFid(n, byLabel)},
        );
        return {'id': e.id};
      case 'entry_delete':
        await nb.deleteEntry('${a['id']}');
        return {};
      case 'fields_edit':
        final n = _book('${a['notebook']}');
        var fields = [...n.def.fields];
        for (final r in ((a['remove'] as List?) ?? const [])) {
          fields = [for (final f in fields) if (f.label != r) f];
        }
        for (final e in ((a['rename'] as Map?) ?? const {}).entries) {
          fields = [for (final f in fields) f.label == e.key ? f.copyWith(label: '${e.value}') : f];
        }
        for (final f in ((a['add'] as List?) ?? const [])) {
          fields.add(_mkField(f as Map));
        }
        await nb.saveNotebook(id: n.id, def: n.def.copyWith(fields: fields));
        return {};
      case 'dump':
        return dump();
      case 'files':
        final out = <String>[];
        if (await shareDir.exists()) {
          final base = shareDir.absolute.path.replaceAll('\\', '/');
          await for (final f in shareDir.list(recursive: true, followLinks: false)) {
            if (f is File) out.add('${f.absolute.path.replaceAll('\\', '/').substring(base.length + 1)} (${f.lengthSync()})');
          }
        }
        out.sort();
        return {'files': out};
      case 'quit':
        await closeAll();
        return {};
    }
    throw StateError('unknown op $op');
  }

  /// Runs until a `quit` command. Commands run one at a time, in file-name order.
  Future<void> loop() async {
    final cmd = Directory('${dir.path}/cmd')..createSync(recursive: true);
    final res = Directory('${dir.path}/res')..createSync(recursive: true);
    File('${dir.path}/ready.json').writeAsStringSync(jsonEncode({'pid': pid}));
    log('ready pid=$pid');
    while (true) {
      final files = cmd.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()..sort((a, b) => a.path.compareTo(b.path));
      var did = false;
      for (final f in files) {
        final name = f.uri.pathSegments.last;
        final out = File('${res.path}/$name');
        if (out.existsSync()) continue;
        did = true;
        String text;
        try {
          text = f.readAsStringSync();
        } on FileSystemException {
          continue; // still being written; next pass
        }
        final j = jsonDecode(text) as Map<String, dynamic>;
        log('cmd $name ${j['op']}');
        Map<String, dynamic> r;
        try {
          final v = await run('${j['op']}', ((j['args'] as Map?) ?? const {}).cast<String, dynamic>());
          r = {'ok': true, 'result': v};
        } catch (e, st) {
          log('error $e\n$st');
          r = {'ok': false, 'error': '$e'};
        }
        File('${out.path}.tmp').writeAsStringSync(jsonEncode(r));
        for (var i = 0;; i++) {
          try {
            File('${out.path}.tmp').renameSync(out.path);
            break;
          } on FileSystemException {
            if (i > 40) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        if (j['op'] == 'quit') {
          log('quit');
          return;
        }
      }
      if (!did) await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
