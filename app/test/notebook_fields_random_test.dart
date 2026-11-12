import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/sync/field_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/share_rig.dart';

/// Randomised proof of a notebook's fields between 2 to 4 devices, starting from a share written by v1.0.30 (name folders, no field
/// ids). Each seeded sequence applies real operations to random devices (add, rename and take out a field, enter values, update a
/// device at a random moment, a folder error between two writes followed by a rerun, syncs of random pairs in random order), then
/// settles the share and checks what must hold:
///
///  1. every device shows the same notebook id, and the same fields in the same order (id, label, type, unit, choices);
///  2. no label appears twice on a device;
///  3. no two fields of a device share one key in the notes (its state, and every note of its folder);
///  4. every value a person entered is still in its field on every device (a device on which the field was taken out and which holds
///     no value for it keeps the value in the note file, not in a field);
///  5. a field taken out for real (after the update, or with values in it) stays out on every device;
///  6. one more full round of syncs changes nothing: no file, no field, no value.
///
/// Run more with `--dart-define=FIELD_SEEDS=300`; replay one with `--dart-define=FIELD_SEED=1234`. A failure prints the seed and the
/// operations. Seeds that failed once are kept in [kRegressionSeeds] and always run.
const int kSeeds = int.fromEnvironment('FIELD_SEEDS', defaultValue: 60);
const int kOnlySeed = int.fromEnvironment('FIELD_SEED', defaultValue: -1);

/// Seeds that found a bug once (fixed since): the case stays.
const List<int> kRegressionSeeds = [
  2, // an old state file's keys for a field renamed before the update were not used
  7, // a note rewritten before the value it holds was read into its field
  8, // a value read while its field was away stayed an extra line when the field came back
  14,
  17, // the lines of a note no field holds were dropped on the update
  86, // one entry in the folders of two merged ids was taken away by both devices
  96, // the same entry in two merged folders was made again under a new id, again and again
  103,
  108,
  111,
  112, // two fields of one old key, told by the key and the type, and the id by rule from the key
  217,
  218, // a field id given out again took the key of the field that had it
  237,
  277,
  389, // a field renamed before the update, on two devices, was two fields
];

const List<String> _labels = ['Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo', 'Foxtrot', 'Golf', 'Hotel'];
const String _nb = 'Hikes';

class _Val {
  _Val(this.dev, this.fid, this.entry, this.value, this.birth);

  /// The label the field had when it was made (the file key it began with comes from it).
  final String birth;
  final int dev;
  final String fid;
  final String entry;
  final Object value;
}

class _Removal {
  _Removal(this.dev, this.fid, this.gid, this.real, this.hidden);
  final int dev;
  final String fid;
  final String? gid;
  final bool real;

  /// The field was kept hidden (it has values): found again by its field id. Otherwise it is gone from the device, and its id as it was.
  final bool hidden;
}

class _Fail implements Exception {
  _Fail(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Sim {
  _Sim(this.seed) : rnd = Random(seed);

  final int seed;
  final Random rnd;
  final List<String> log = [];
  final List<Dev> devs = [];
  final List<ShareLink> links = [];
  final Map<(int, int), ShareLink> link = {};
  final List<_Val> vals = [];
  final List<_Removal> removals = [];
  int counter = 0;
  int joiner = -1;
  final Map<int, String> _seen = {};

  bool allUpgraded() => devs.every((d) => !d.old);

  String? idOf(int i) => devs[i].ids(_nb).isEmpty ? null : devs[i].ids(_nb).first;

  Notebook? bookOf(int i) {
    final id = idOf(i);
    return id == null ? null : devs[i].nb.notebook(id);
  }

  void say(String s) => log.add(s);

  Future<void> setup() async {
    final n = 2 + rnd.nextInt(3);
    final hasJoiner = n >= 3 && rnd.nextInt(3) == 0;
    final idPool = ['a-1', 'b-2', 'c-3', 'd-4']..shuffle(rnd);
    for (var i = 0; i < n; i++) {
      final isJoiner = hasJoiner && i == n - 1;
      final d = Dev('d$i', old: !isJoiner, gateFn: allUpgraded);
      await d.boot();
      devs.add(d);
      if (isJoiner) joiner = i;
    }
    for (var i = 0; i < devs.length; i++) {
      devs[i].folder.onWrite = (path, text) {
        if (path.endsWith('.cnote') && path.contains(const String.fromEnvironment('FIELD_ENTRY', defaultValue: 'Entry 4')) && !path.contains('conflict')) say('    WRITE d$i $path: ${text.split('\n').where((l) => RegExp(r'^[a-z_0-9]+:').hasMatch(l) && !l.startsWith('cache_id') && !l.startsWith('title') && !l.startsWith('date') && !l.startsWith('time')).join(' ')}');
      };
    }
    say('devices: $n${hasJoiner ? ' (the last one joins from the record)' : ''}; ids ${idPool.take(n).toList()}');
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        final l = ShareLink(devs[i].folder, devs[j].folder);
        l.open = () => devs[i].old == devs[j].old;
        links.add(l);
        link[(i, j)] = l;
      }
    }
    // the notebook as v1.0.30 had it, with the same fields on every old device (it is what the old sync gives them)
    final base = <LogField>[];
    final take = 1 + rnd.nextInt(3);
    final pool = [..._labels]..shuffle(rnd);
    for (var k = 0; k < take; k++) {
      base.add(LogField(label: pool[k], type: rnd.nextBool() ? FieldType.text : FieldType.number));
    }
    say('first fields: ${[for (final f in base) '${f.label}:${f.type.wire}']}');
    for (var i = 0; i < n; i++) {
      if (i == joiner) continue;
      await devs[i].makeWith(_nb, base, id: idPool[i]);
      await devs[i].stripGids();
      for (final f in bookOf(i)!.def.fields) {
        _birth['$i/${f.fid}'] = normLabel(f.label);
      }
    }
    // some old entries, then one old sync round so every old device has them
    for (var i = 0; i < n; i++) {
      if (i != joiner && rnd.nextBool()) await _enter(i);
    }
    await _round(onlyOld: true, times: 3);
  }

  List<LogField> _visible(int i) => bookOf(i)?.def.visible ?? const [];

  Future<void> _enter(int i) async {
    final b = bookOf(i);
    if (b == null) return;
    final vis = b.def.visible;
    if (vis.isEmpty) return;
    final f = vis[rnd.nextInt(vis.length)];
    final c = ++counter;
    final Object v = f.type == FieldType.number ? 1000 + c : 'v$c';
    final id = 'e$c';
    await devs[i].nb.saveEntry(id: id, notebookId: b.id, occurredAt: '2026-11-01T09:00:00-07:00', title: 'Entry $c', values: {f.fid!: v});
    vals.add(_Val(i, f.fid!, id, v, _birth['$i/${f.fid}'] ?? normLabel(f.label)));
    say('d$i enters ${f.label} = $v in $id');
  }

  Future<void> _change(int i, String what, List<LogField> Function(List<LogField>) f) async {
    final b = bookOf(i);
    if (b == null) return;
    await devs[i].editFields(b.id, f);
    if (devs[i].old) await devs[i].stripGids();
    say('d$i $what');
  }

  String? _freeLabel(int i) {
    final used = {for (final f in _visible(i)) normLabel(f.label)};
    final free = [for (final l in _labels) if (!used.contains(normLabel(l))) l];
    return free.isEmpty ? null : free[rnd.nextInt(free.length)];
  }

  Future<void> step() async {
    final i = rnd.nextInt(devs.length);
    final d = devs[i];
    final b = bookOf(i);
    final roll = rnd.nextInt(100);
    if (roll < 20) {
      await _syncPair();
    } else if (roll < 32) {
      if (b == null || b.def.visible.length >= 12) return;
      // v1.0.30 gives a field the id of one that was taken out and keeps its key in the notes: a device that updates after doing both
      // has notes the other devices cannot tell apart, which nothing after the update can undo (see the list of invariants that cannot hold)
      if (d.old && _tookOutWhileOld.contains(i)) return;
      final l = _freeLabel(i);
      if (l == null) return;
      final t = rnd.nextBool() ? FieldType.text : FieldType.number;
      final before = {for (final f in bookOf(i)!.def.fields) f.fid};
      await _change(i, 'adds $l (${t.wire})', (fs) => [...fs, LogField(label: l, type: t)]);
      for (final f in bookOf(i)!.def.fields) {
        if (!before.contains(f.fid)) _birth['$i/${f.fid}'] = normLabel(l);
      }
      _madeAs.putIfAbsent(normLabel(l), () => {}).add(d.old ? t.wire : 'new-d$i-${t.wire}');
    } else if (roll < 42) {
      if (b == null || b.def.visible.isEmpty) return;
      final f = b.def.visible[rnd.nextInt(b.def.visible.length)];
      final l = _freeLabel(i);
      if (l == null) return;
      await _change(i, 'renames ${f.label} to $l', (fs) => [for (final x in fs) x.fid == f.fid ? x.copyWith(label: l) : x]);
    } else if (roll < 52) {
      if (b == null || b.def.visible.length < 2) return;
      final f = b.def.visible[rnd.nextInt(b.def.visible.length)];
      final gidBefore = f.gid;
      await _change(i, 'takes out ${f.label}', (fs) => fs.where((x) => x.fid != f.fid).toList());
      final after = bookOf(i)!.def.fields.where((x) => x.fid == f.fid).firstOrNull;
      // a removal is real after the update, and before it when the field has values (the store keeps it hidden)
      if (d.old) _tookOutWhileOld.add(i);
      removals.add(_Removal(i, f.fid!, gidBefore, !d.old && allUpgraded() || after != null && after.hidden, after != null && after.hidden));
    } else if (roll < 70) {
      await _enter(i);
    } else if (roll < 78) {
      if (!d.old) return;
      await _upgrade(i);
    } else if (roll < 88) {
      await _crash(i);
    } else {
      await _syncOne(i);
    }
  }

  Future<void> _upgrade(int i) async {
    final d = devs[i];
    if (!d.old) return;
    await d.stripGids();
    await d.updateCache();
    say('d$i updates Cache');
  }

  Future<void> _syncOne(int i) async {
    try {
      await devs[i].sync();
    } catch (e) {
      say('d$i sync threw $e');
    }
    for (var j = 0; j < devs.length; j++) {
      if (j != i) _linkOf(i, j).sync();
    }
    say('d$i syncs');
  }

  ShareLink _linkOf(int i, int j) => link[i < j ? (i, j) : (j, i)]!;

  Future<void> _syncPair() async {
    final i = rnd.nextInt(devs.length);
    var j = rnd.nextInt(devs.length);
    if (j == i) j = (i + 1) % devs.length;
    await syncQuiet(devs[i]);
    _linkOf(i, j).sync();
    await syncQuiet(devs[j]);
    _linkOf(i, j).sync();
    say('d$i and d$j sync');
  }

  Future<void> _crash(int i) async {
    // a device that has not updated runs the sync of v1.0.30, which is not ours to prove: only the updated ones are stopped
    if (devs[i].old) return;
    final k = rnd.nextInt(12);
    var n = 0;
    devs[i].folder.beforeWrite = (p) async {
      if (n++ >= k) throw const FormatException('the folder stopped answering');
    };
    await syncQuiet(devs[i]);
    devs[i].folder.beforeWrite = null;
    say('d$i sync stopped after $k writes');
  }

  /// All devices sync once, in random order, then every link.
  Future<void> _round({bool onlyOld = false, int times = 1}) async {
    for (var t = 0; t < times; t++) {
      final order = [for (var i = 0; i < devs.length; i++) i]..shuffle(rnd);
      for (final i in order) {
        if (onlyOld && !devs[i].old) continue;
        await syncQuiet(devs[i]);
        _watch(i, 'after a sync');
        final now = ([for (final e in devs[i].store.entries) e['id'] as String]..sort()).join(',');
        if (_seen[i] != now) {
          final before = (_seen[i] ?? '').split(',').toSet();
          final lost = before.difference(now.split(',').toSet());
          _seen[i] = now;
          say('  round: d$i syncs and now holds: $now');
          if (lost.isNotEmpty && lost.first.isNotEmpty) {
            final f = File('${devs[i].stateDir.path}/share2.json');
            final items = f.existsSync() ? ((jsonDecode(f.readAsStringSync()) as Map)['items'] as Map?) : null;
            for (final id in lost) {
              say('    LOST $id on d$i; item before-save: ${items?[id]?.toString().replaceAll('\n', ' ')}');
              say('    files: ${[for (final k in devs[i].folder.text.keys) if (devs[i].folder.text[k]!.contains('cache_id: $id')) k]}');
              say('    other devices hold it: ${[for (var j = 0; j < devs.length; j++) if (devs[j].store.entries.any((e) => e['id'] == id)) 'd$j']}');
            }
          }
        }
      }
      for (final l in links) {
        l.sync();
      }
      _recFiles('after links');
    }
  }

  Future<void> settle() async {
    for (final d in devs) {
      d.folder.beforeWrite = null;
    }
    for (var i = 0; i < devs.length; i++) {
      if (devs[i].old) await _upgrade(i);
    }
    String? last;
    String? before;
    for (var k = 0; k < 14; k++) {
      await _round();
      final now = await snapshot();
      if (now == last) return;
      before = last;
      last = now;
    }
    throw _Fail('the share does not settle in 14 full rounds; changed in the last round:\n${_diff(before, last)}');
  }

  String _diff(String? a, String? b) {
    if (a == null || b == null) return '(no earlier snapshot)';
    final x = jsonDecode(a) as Map, y = jsonDecode(b) as Map;
    final out = StringBuffer();
    for (final k in y.keys) {
      final u = x[k], v = y[k];
      if (jsonEncode(u) == jsonEncode(v)) continue;
      if (u is Map && v is Map) {
        for (final f in {...u.keys, ...v.keys}) {
          if (u[f] != v[f]) out.writeln('  $k $f:\n    was ${u[f]?.toString().replaceAll('\n', ' | ')}\n    now ${v[f]?.toString().replaceAll('\n', ' | ')}');
        }
      } else {
        out.writeln('  $k:\n    was $u\n    now $v');
      }
    }
    return out.toString();
  }

  Future<String> snapshot() async {
    final out = <String, Object?>{};
    for (var i = 0; i < devs.length; i++) {
      final d = devs[i];
      // (the files of the old layout, `<name>/<note>.md`, are not part of what must stand still: a deleted one can come back from a
      // device that has not removed it yet, as in any sync of a file that one side deletes and another changes)
      out['folder$i'] = {for (final k in d.folder.text.keys.toList()..sort()) if (!k.endsWith('.md')) k: d.folder.text[k]};
      out['nb$i'] = [
        for (final n in d.store.notebooks) {'id': n['id'], 'def': n['def']},
      ];
      out['entries$i'] = [
        for (final e in d.store.entries) {'id': e['id'], 'nb': e['notebook_id'], 'values': e['values'], 'title': e['title']},
      ];
    }
    return jsonEncode(out);
  }

  // ---- the invariants ----

  Future<void> check() async {
    final ids = {for (var i = 0; i < devs.length; i++) idOf(i)};
    if (ids.length != 1 || ids.first == null) throw _Fail('1. the devices do not have one notebook id: $ids');
    final id = ids.first!;
    // 1
    List<String> sig(int i) => [
          for (final f in bookOf(i)!.def.visible) '${f.gid}|${f.label}|${f.type.wire}|${f.type == FieldType.number ? f.unit ?? '' : ''}|${f.type == FieldType.choice ? jsonEncode(f.choices) : ''}',
        ];
    for (var i = 1; i < devs.length; i++) {
      if (jsonEncode(sig(i)) != jsonEncode(sig(0))) throw _Fail('1. the field lists differ:\n  d0 ${sig(0)}\n  d$i ${sig(i)}');
    }
    for (var i = 0; i < devs.length; i++) {
      final fields = bookOf(i)!.def.fields;
      // 2
      final labels = [for (final f in bookOf(i)!.def.visible) normLabel(f.label)];
      if (labels.toSet().length != labels.length) throw _Fail('2. d$i shows a label twice: $labels');
      // 3
      final st = File('${devs[i].stateDir.path}/share2.json');
      if (st.existsSync()) {
        final props = ((jsonDecode(st.readAsStringSync()) as Map)['props'] as Map?)?[id] as Map?;
        if (props != null) {
          final mine = [for (final f in fields) props[f.fid]].whereType<String>().toList();
          if (mine.toSet().length != mine.length) throw _Fail('3. d$i has two fields with one key: $mine');
        }
      }
      for (final e in devs[i].folder.text.entries) {
        if (!e.key.endsWith('.cnote')) continue;
        final head = e.value.split('\n---').first;
        final keys = [for (final m in RegExp(r'^([A-Za-z0-9_]+):', multiLine: true).allMatches(head)) m.group(1)!];
        if (keys.toSet().length != keys.length) throw _Fail('3. a note of d$i has a key twice (${e.key}): $keys');
      }
    }
    // 4
    for (final v in vals) {
      if (_ambiguous.contains(v.birth)) continue;
      final gid = bookOf(v.dev)!.def.fields.where((f) => f.fid == v.fid).firstOrNull?.gid;
      if (gid == null) throw _Fail('4. d${v.dev} lost the field of ${v.entry} = ${v.value}');
      for (var j = 0; j < devs.length; j++) {
        final entry = (await devs[j].nb.entries(id)).where((e) => e.id == v.entry).firstOrNull;
        if (entry == null) throw _Fail('4. d$j has no entry ${v.entry}');
        final f = bookOf(j)!.def.fields.where((f) => f.gid == gid).firstOrNull;
        if (f != null) {
          if ('${entry.values[f.fid]}' != '${v.value}') throw _Fail('4. d$j: ${v.entry} has ${entry.values[f.fid]} in ${f.label}, expected ${v.value} (entered on d${v.dev})');
        } else {
          final held = devs[j].folder.text.entries.any((e) => e.key.endsWith('.cnote') && e.value.contains('${v.value}'));
          if (!held) throw _Fail('4. d$j has no field for the one of ${v.entry} = ${v.value} and no note that holds the value');
        }
      }
    }
    // 5
    for (final r in removals) {
      if (!r.real) continue;
      final here = bookOf(r.dev)!.def.fields.where((f) => f.fid == r.fid && f.hidden).firstOrNull;
      final gid = r.hidden ? here?.gid : r.gid;
      if (gid == null) continue;
      for (var j = 0; j < devs.length; j++) {
        if (bookOf(j)!.def.visible.any((f) => f.gid == gid)) throw _Fail('5. a field taken out on d${r.dev} is back on d$j');
      }
    }
  }

  final Set<String> _moved = {};
  final Set<int> _tookOutWhileOld = {};

  /// The label each field was made with, by device and field id; and who made a field of each label how (see [_ambiguous]).
  final Map<String, String> _birth = {};
  final Map<String, Set<String>> _madeAs = {};

  /// Notes of a field that two devices each made with one label, as different types (before the update) or on their own (after it), are
  /// written under one key before the devices have met: nothing can tell afterwards whose they are (design: an ambiguous shared key).
  Set<String> get _ambiguous => {for (final e in _madeAs.entries) if (e.value.length > 1) e.key};

  /// A value a device entered itself must stay under its field on that device: says when and where it does not.
  final Map<int, String> _recSeen = {};

  /// Which of a device's record files (the main one and the copies kept when two devices wrote it at once) say Delta is taken out.
  void _recFiles(String when) {
    for (var i = 0; i < devs.length; i++) {
      final sig = StringBuffer();
      for (final e in devs[i].folder.text.entries) {
        if (!e.key.contains('notebook') || !e.key.endsWith('.json')) continue;
        final j = jsonDecode(e.value) as Map;
        final d = [for (final f in (j['fields'] as List? ?? const [])) if ((f as Map)['name'] == const String.fromEnvironment('FIELD_LABEL', defaultValue: 'Delta')) f].firstOrNull;
        sig.write('${e.key.contains('conflict') ? 'COPY' : e.key.split('/').first}:${d == null ? 'none' : '${d['removed']}@${d['removed_at']}'} ');
      }
      if (_recSeen[i] != sig.toString()) {
        _recSeen[i] = sig.toString();
        say('    [$when] d$i record files: $sig');
      }
    }
  }

  final Map<int, String> _fidSeen = {};

  /// Which gid each field id has on a device, written when it changes (to see a field id change its field).
  void _fids(int i) {
    final b = bookOf(i);
    if (b == null) return;
    final now = [for (final f in b.def.fields) '${f.fid}=${f.gid?.substring(0, 6)}/${f.label}${f.hidden ? '/h' : ''}'].join(' ');
    final rec = devs[i].folder.text['${b.id}/notebook.json'];
    var recSig = '';
    if (rec != null) {
      final j = jsonDecode(rec) as Map;
      recSig = [for (final f in (j['fields'] as List? ?? const [])) if ((f as Map)['name'] == const String.fromEnvironment('FIELD_LABEL', defaultValue: 'Delta')) 'F(${f['gid'].toString().substring(0, 6)} removed=${f['removed']}@${f['removed_at']} inf=${f['inferred']})'].join(' ');
    }
    if (_fidSeen[i] != '$now|$recSig') {
      _fidSeen[i] = '$now|$recSig';
      say('    (d$i fields: $now) rec: $recSig');
    }
  }

  void _watch(int i, String when) {
    _fids(i);
    for (final v in vals) {
      if (v.dev != i || _moved.contains('${v.entry}/${v.fid}')) continue;
      final e = devs[i].store.entries.where((e) => e['id'] == v.entry).firstOrNull;
      if (e == null) continue;
      final got = (e['values'] as Map)[v.fid];
      if ('$got' == '${v.value}') continue;
      _moved.add('${v.entry}/${v.fid}');
      final b = bookOf(i);
      say('    MOVED on d$i $when: ${v.entry} ${v.fid} should be ${v.value}, values now ${e['values']}');
      say('      fields ${[for (final f in b?.def.fields ?? const <LogField>[]) '${f.fid}/${f.gid?.substring(0, 6)}/${f.label}${f.hidden ? '/hidden' : ''}']}');
      final st = File('${devs[i].stateDir.path}/share2.json');
      if (st.existsSync()) say('      props(saved) ${((jsonDecode(st.readAsStringSync()) as Map)['props'])}');
      say('      files ${[for (final k in devs[i].folder.text.keys) if (devs[i].folder.text[k]!.contains('cache_id: ${v.entry}')) '$k => ${devs[i].folder.text[k]!.split('\n').where((l) => l.contains(':') && !l.startsWith('cache_id') && !l.startsWith('title') && !l.startsWith('date') && !l.startsWith('time')).join(' ')}']}');
    }
  }

  /// What each device has, for a failure message.
  Future<String> dump() async {
    final b = StringBuffer();
    for (var i = 0; i < devs.length; i++) {
      final d = devs[i];
      b.writeln('  d$i ${d.old ? '(old)' : ''} notebooks: ${[for (final n in d.nb.notebooks) '${n.id}:${n.name}']}');
      for (final n in d.nb.notebooks) {
        b.writeln('    fields: ${[for (final f in n.def.fields) '${f.fid}/${f.gid?.substring(0, 6)}/${f.label}/${f.type.wire}${f.hidden ? '/hidden' : ''}']}');
        for (final e in await d.nb.entries(n.id)) {
          b.writeln('    ${e.id}: ${e.values}');
        }
      }
      final st = File('${d.stateDir.path}/share2.json');
      if (st.existsSync()) {
        final j = jsonDecode(st.readAsStringSync()) as Map;
        b.writeln('    props: ${j['props']}');
        b.writeln('    fieldsnap: ${j['fields']}');
        b.writeln('    extras: ${{for (final e in (j['items'] as Map? ?? const {}).entries) if ((e.value as Map)['extra'] != null) e.key: (e.value as Map)['extra']}}');
      }
      for (final e in d.folder.text.entries) {
        if (e.key.endsWith('.cnote')) b.writeln('    ${e.key}: ${e.value.replaceAll('\n', ' | ')}');
      }
      for (final e in d.folder.text.entries) {
        if (e.key.endsWith('/notebook.json')) b.writeln('    ${e.key}: ${(jsonDecode(e.value) as Map)['fields']}');
      }
    }
    return b.toString();
  }

  Future<void> run() async {
    try {
      await _run();
    } on _Fail catch (e) {
      throw _Fail('$e\n${await dump()}');
    }
  }

  Future<void> _run() async {
    await setup();
    final steps = 10 + rnd.nextInt(16);
    final mid = steps ~/ 2;
    final seen = <int, String>{};
    for (var k = 0; k < steps; k++) {
      await step();
      for (var i = 0; i < devs.length; i++) {
        _fids(i);
      }
      // what each device holds changes: written into the log, to see where an entry goes
      for (var i = 0; i < devs.length; i++) {
        final now = ([for (final e in devs[i].store.entries) e['id'] as String]..sort()).join(',');
        if (seen[i] != now) {
          seen[i] = now;
          say('  (d$i now holds: $now)');
        }
      }
      if (k == mid && allUpgraded()) {
        await settle();
        await check();
        say('(checked in the middle)');
      }
    }
    await settle();
    await check();
    // 6: one more round changes nothing
    final before = await snapshot();
    await _round();
    final after = await snapshot();
    if (before != after) throw _Fail('6. one more full round changed something');
  }
}

Future<void> syncQuiet(Dev d) async {
  try {
    await d.sync();
  } catch (_) {}
}

void main() {
  final seeds = kOnlySeed >= 0 ? [kOnlySeed] : [...kRegressionSeeds, for (var s = 1; s <= kSeeds; s++) s];
  test('randomised fields between devices: ${seeds.length} seeded sequences', () async {
    final sw = Stopwatch()..start();
    final failures = <String>[];
    for (final seed in seeds) {
      final sim = _Sim(seed);
      try {
        await sim.run();
      } catch (e, st) {
        failures.add('SEED $seed: $e\n  ${sim.log.join('\n  ')}\n$st');
        if (failures.length >= const int.fromEnvironment('FIELD_MAXFAIL', defaultValue: 5)) break;
      }
    }
    // ignore: avoid_print
    print('${seeds.length} sequences in ${sw.elapsed.inSeconds} s; ${failures.length} failed');
    // ignore: avoid_print
    print('failed seeds: ${[for (final f in failures) f.split(':').first.replaceAll('SEED ', '')]}');
    if (failures.isNotEmpty) fail(failures.join('\n\n'));
  }, timeout: const Timeout(Duration(minutes: 40)));
}
