import 'dart:convert';

import 'harness.dart';

const portA = 47101, portB = 47102, portC = 47103;

final Map<String, Future<void> Function(Harness)> scenarios = {
  'stage1': stage1,
  'swap': swap,
  'N1': n1,
  'roll': rollProbe,
};

Map<String, dynamic> stage1Shape = {}, stage1ShapeB = {};
final Map<String, String> ids = {};

/// Stage 1, fresh for every scenario: A and B on the legacy build (tag v1.0.30 and its dll) link, share notebooks with fields and
/// entries and sync. Both are left RUNNING on the legacy build, with the stage-1 data dirs copied to evidence/<scenario>/stage1/data.
///
/// Why live: with relay, dht, mdns and lookup off a device learns another's address only from a connection, and keeps it in memory
/// only (sync.json holds none). Two devices stopped together cannot find each other again. A restarted device is found again at its
/// fixed port by the one that stayed up. So every restart in this harness is a ROLLING one: one device at a time, the other up.
Future<void> ensureStage1(Harness h) => h.runStage1();

/// Stops [d], copies its data dir to evidence (the other device stays up and keeps the address), starts it again on [build].
Future<void> roll(Harness h, Device d, String build, {String? snapshotAs}) async {
  await d.stop();
  if (snapshotAs != null) await h.snapshot(h.scn, snapshotAs, [d.name]);
  await d.start(build);
  // The device that stayed up finds the restarted one at its port and dials it; only then does the restarted one know the other.
  final others = [for (final o in h.devices.values) if (o != d && o.proc != null) o];
  for (var i = 0; i < 2; i++) {
    for (final o in others) {
      await o.call('sync');
    }
    await d.call('sync');
  }
}

extension Stage1 on Harness {
  Future<void> runStage1() async {
    for (final n in ['A', 'B', 'C']) {
      await wipe('$root/work/$n');
    }
    final a = dev('A', portA), b = dev('B', portB);
    await a.start('legacy');
    await b.start('legacy');
    await a.call('sharing_setup');
    await b.call('sharing_setup');
    final code = ((await a.call('link_code')) as Map)['code'] as String;
    check('stage1: link code has the CACHE1- form', code.startsWith('CACHE1-'), code.substring(0, 12));
    final linked = await b.call('link', {'code': code});
    say('B linked: $linked');
    await a.call('share_on');
    await b.call('share_on');
    await a.call('nb_make', {
      'id': 'nb-trail',
      'name': 'Trail Log',
      'fields': [
        {'label': 'Miles', 'type': 'number'},
        {'label': 'Weather', 'type': 'text'},
        {'label': 'Hard', 'type': 'yesNo'},
      ],
    });
    await a.call('entry_add', {'id': 'trail-1', 'notebook': 'Trail Log', 'title': 'Ridge loop', 'body': 'Windy at the top', 'values': {'Miles': 6.5, 'Weather': 'windy', 'Hard': true}});
    await a.call('entry_add', {'id': 'trail-2', 'notebook': 'Trail Log', 'title': 'Creek walk', 'body': 'Easy and flat', 'values': {'Miles': 2, 'Weather': 'sunny', 'Hard': false}});
    await a.call('nb_make', {'id': 'nb-gear', 'name': 'Gear', 'fields': <Object>[]});
    await a.call('entry_add', {'id': 'gear-1', 'notebook': 'Gear', 'title': 'Tent', 'body': 'Two person'});
    await rounds([a, b], n: 3);
    // B makes an entry of its own in the shared notebook, which goes to A.
    await b.call('entry_add', {'id': 'trail-3', 'notebook': 'Trail Log', 'title': 'Lake', 'body': 'Cold water'});
    // (v1.0.30 syncs no field definitions: B's copy of Trail Log arrives with no fields, so B's entry carries no values.)
    await rounds([a, b], n: 3);
    final da = await a.dump(), db = await b.dump();
    final sa = Harness.shape(da), sb = Harness.shape(db);
    writeJson('dumps', 'dump-A', da, scn: scn + '/stage1');
    writeJson('dumps', 'dump-B', db, scn: scn + '/stage1');
    writeJson('dumps', 'status-A', await a.status(), scn: scn + '/stage1');
    writeJson('dumps', 'status-B', await b.status(), scn: scn + '/stage1');
    writeJson('dumps', 'files-A', await a.files(), scn: scn + '/stage1');
    writeJson('dumps', 'files-B', await b.files(), scn: scn + '/stage1');
    final trailA = (sa['Trail Log'] as Map?)?['entries'] as Map?;
    check('stage1: A has the 3 entries of Trail Log', trailA != null && trailA.length == 3, '${trailA?.keys}');
    // v1.0.30 syncs no field definitions or values of fields B does not have: B's copy has the same entries (id, title, body) and no fields.
    String idtb(Map? e) => jsonEncode({for (final x in (e ?? const {}).entries) x.key: '${x.value}'.split('|').take(2).join('|')});
    check('stage1: B has the same entries as A, by id, title and body (real legacy sync)', idtb((sb['Trail Log'] as Map?)?['entries'] as Map?) == idtb(trailA), '${(sb['Trail Log'] as Map?)?['entries']?.keys}');
    check('stage1: B has Gear too', (sb['Gear'] as Map?)?['entries']?.length == 1);
    final stA = await a.status(), stB = await b.status();
    ids['A'] = '${stA['id']}';
    ids['B'] = '${stB['id']}';
    writeJson('dumps', 'ids', ids, scn: scn + '/stage1');
    check('stage1: both are linked to each other', ((stA['peers'] as List).any((p) => (p as Map)['id'] == ids['B'])) && ((stB['peers'] as List).any((p) => (p as Map)['id'] == ids['A'])));
    stage1Shape = sa;
    stage1ShapeB = sb;
    say('stage 1 peer info A: ${(stA['peers'] as List)}');
    // The stage-1 evidence: each data dir copied while stopped, one at a time (the other stays up), then started again on the legacy build.
    // B first: B linked by A's code, so A (which showed it) knows B from B's connection, and finds a restarted B at its fixed port.
    await roll(this, b, 'legacy', snapshotAs: 'stage1/data');
    await rounds([a, b], n: 2);
    await roll(this, a, 'legacy', snapshotAs: 'stage1/data');
    await rounds([b, a], n: 2);
  }
}

Future<void> stage1(Harness h) async {
  await ensureStage1(h);
}

/// Probe of the harness itself: does a rolling restart (one device at a time, same build) find the other again, with no lookup?
Future<void> rollProbe(Harness h) async {
  await ensureStage1(h);
  final a = h.dev('A', portA), b = h.dev('B', portB);
  for (final step in [('B', 'legacy'), ('A', 'legacy')]) {
    final d = step.$1 == 'A' ? a : b, other = step.$1 == 'A' ? b : a;
    await roll(h, d, step.$2);
    for (var i = 0; i < 4; i++) {
      await d.call('sync');
      await other.call('sync');
    }
    final st = await d.status(), so = await other.status();
    h.writeJson('roll-${step.$1}', 'status-restarted', st);
    h.writeJson('roll-${step.$1}', 'status-other', so);
    await other.call('entry_add', {'id': 'probe-${step.$1}', 'notebook': 'Gear', 'title': 'probe ${step.$1}', 'body': 'x'});
    for (var i = 0; i < 3; i++) {
      await other.call('sync');
      await d.call('sync');
    }
    final dd = await d.dump();
    h.check('roll: ${step.$1} restarted, and received an entry made on the other', jsonEncode(dd).contains('probe-${step.$1}'), '${st['peers']}');
  }
}

/// The swap check: the on-disk sync state survives the change of build. The stage-1 data dirs are started on the chain build.
Future<void> swap(Harness h) async {
  await ensureStage1(h);
  final a = h.dev('A', portA), b = h.dev('B', portB);
  // Rolling swap onto the chain build, each on its own data dir: B first (A, still legacy, stays up and finds B at its port), then A.
  await roll(h, b, 'chain');
  await roll(h, a, 'chain');
  await b.call('sync');
  final stA = await a.status(), stB = await b.status();
  h.writeJson('after-start', 'status-A', stA);
  h.writeJson('after-start', 'status-B', stB);
  h.check('swap: A keeps its identity', stA['id'] == ids['A'], '${stA['id']}');
  h.check('swap: B keeps its identity', stB['id'] == ids['B'], '${stB['id']}');
  h.check('swap: A still has the link to B', (stA['peers'] as List).any((p) => (p as Map)['id'] == ids['B']));
  h.check('swap: B still has the link to A', (stB['peers'] as List).any((p) => (p as Map)['id'] == ids['A']));
  h.check('swap: A still shares notebooks', (stA['shares'] as List).any((s) => (s as Map)['id'] == 'notebooks'));
  h.check('swap: B still shares notebooks', (stB['shares'] as List).any((s) => (s as Map)['id'] == 'notebooks'));
  final dA0 = await a.dump(), dB0 = await b.dump();
  h.writeJson('after-start', 'dump-A', dA0);
  h.writeJson('after-start', 'dump-B', dB0);
  h.writeJson('after-start', 'files-A', await a.files());
  h.writeJson('after-start', 'files-B', await b.files());
  h.check('swap: A reads its notebooks unchanged on the chain build', _same(_named(Harness.shape(dA0)), _named(stage1Shape)));
  h.check('swap: B reads its notebooks unchanged on the chain build', _same(_named(Harness.shape(dB0)), _named(stage1ShapeB)));
  // The two chain builds meet: the version gate.
  final cv = [await a.call('check_version'), await b.call('check_version')];
  h.writeJson('after-start', 'check_version', cv);
  await h.rounds([a, b], n: 4);
  final sA = await a.status(), sB = await b.status();
  h.writeJson('after-sync', 'status-A', sA);
  h.writeJson('after-sync', 'status-B', sB);
  h.check('swap: gate active on A (peer compat ok)', sA['gate_active'] == true, '${sA['peers']}');
  h.check('swap: gate active on B (peer compat ok)', sB['gate_active'] == true, '${sB['peers']}');
  h.check('swap: A converted (conversion done)', sA['conversion'] == 'done', '${sA['conversion']}');
  h.check('swap: B converted (conversion done)', sB['conversion'] == 'done', '${sB['conversion']}');
  final dA = await a.dump(), dB = await b.dump();
  h.writeJson('after-sync', 'dump-A', dA);
  h.writeJson('after-sync', 'dump-B', dB);
  final fA = await a.files(), fB = await b.files();
  h.writeJson('after-sync', 'files-A', fA);
  h.writeJson('after-sync', 'files-B', fB);
  h.note('swap: entry files left in a retired notebook-id folder (A, B)', '${_retiredIdFiles(fA, dA)} / ${_retiredIdFiles(fB, dB)}');
  h.check('swap: no old name-folder files left on A', _legacyLeft(fA, dA).isEmpty, '${_legacyLeft(fA, dA)}');
  h.check('swap: no old name-folder files left on B', _legacyLeft(fB, dB).isEmpty, '${_legacyLeft(fB, dB)}');
  final want = _named(stage1Shape);
  h.check('swap: A ends with every entry, every value and one set of fields (as A had them)', _same(_named(Harness.shape(dA)), want), jsonEncode(_named(Harness.shape(dA))));
  h.check('swap: B ends with the same as A (entries, values, one set of fields)', _same(_named(Harness.shape(dB)), want), jsonEncode(_named(Harness.shape(dB))));
  String idOf(Map d, String name) => '${[for (final n in d['notebooks']) if (n['name'] == name) n['id']]}';
  h.check('swap: one Trail Log and one Gear on each, the same id on both', idOf(dA, 'Trail Log') == idOf(dB, 'Trail Log') && idOf(dA, 'Gear') == idOf(dB, 'Gear') && !idOf(dA, 'Trail Log').contains(','), '${idOf(dA, 'Trail Log')} / ${idOf(dB, 'Trail Log')}');
  await roll(h, b, 'chain', snapshotAs: 'after-sync-data');
  await roll(h, a, 'chain', snapshotAs: 'after-sync-data');
}

/// The shared notebooks' part of a shape (the Journal every device makes for itself is not shared).
Map<String, dynamic> _named(Map<String, dynamic> shape) => {for (final k in ['Gear', 'Trail Log']) if (shape[k] != null) k: shape[k]};

/// Files of the share in a folder that is not a notebook id: the old name folders.
/// Entry files left in a folder that is no notebook's current id (a retired id after the notebook settled on another): not a failure
/// of the checks above, recorded as an observation in checks.json.
List<String> _retiredIdFiles(List<String> files, Map<String, dynamic> dump) {
  final ids = [for (final n in dump['notebooks'] as List) '${(n as Map)['id']}'];
  return [for (final f in files) if (f.contains('/') && (f.contains('.cnote') || f.contains('.md')) && !f.startsWith('.') && !ids.any((id) => f.startsWith('$id/'))) f];
}

List<String> _legacyLeft(List<String> files, Map<String, dynamic> dump) {
  final ids = [for (final n in dump['notebooks'] as List) '${(n as Map)['id']}'];
  return [for (final f in files) if (f.contains('/') && f.contains('.md') && !f.startsWith('.') && !ids.any((id) => f.startsWith('$id/'))) f];
}

/// N1: B updates first (A still on v1.0.30). The gate is checked, B converts as far as the gate lets it, B edits an existing entry;
/// then A updates. B's edit must survive on both, with no entry lost or doubled and one set of fields.
Future<void> n1(Harness h) async {
  await ensureStage1(h);
  final a = h.dev('A', portA), b = h.dev('B', portB); // both on the legacy build, running
  await roll(h, b, 'chain'); // B updates; A has not, and stays up
  final cv = await b.call('check_version');
  h.writeJson('b-updated', 'check_version-B', cv);
  var sB = await b.status();
  h.check('N1: B is on the chain build and sees A as an older device (peer_older)', ((sB['peers'] as List).any((p) => (p as Map)['compat'] == 'peer_older')), '${sB['peers']}');
  h.check('N1: the gate is NOT active on B while A is older', sB['gate_active'] == false);
  // B syncs (it writes the id layout), A (legacy) syncs: nothing may cross the link in either direction.
  final aBefore = await a.dump();
  await h.rounds([a, b], n: 3);
  sB = await b.status();
  h.writeJson('b-updated', 'status-B', sB);
  h.check('N1: B has not removed the old name folders (conversion not done)', sB['conversion'] != 'done', '${sB['conversion']}');
  final fB1 = await b.files();
  h.writeJson('b-updated', 'files-B-before-edit', fB1);
  h.check('N1: B still has the old name-folder files', fB1.any((f) => f.startsWith('Trail Log/')), '$fB1');
  // B edits an existing entry (a body, and a title).
  await b.call('entry_edit', {'id': 'trail-1', 'title': 'Ridge loop (B)', 'body': 'Windy at the top. Edited on B after the update.'});
  await h.rounds([a, b], n: 3);
  final aMid = await a.dump();
  h.writeJson('b-updated', 'dump-A-legacy-still-running', aMid);
  h.writeJson('b-updated', 'dump-B', await b.dump());
  h.check('N1: A (not updated) received nothing from B through the closed link', _same(Harness.shape(aMid), Harness.shape(aBefore)));
  h.writeJson('b-updated', 'files-B', await b.files());
  h.writeJson('b-updated', 'files-A', await a.files());
  // A updates (B stays up).
  await roll(h, a, 'chain', snapshotAs: 'b-updated-data');
  h.writeJson('a-updated', 'check_version', [await a.call('check_version'), await b.call('check_version')]);
  await h.rounds([a, b], n: 5);
  final dA = await a.dump(), dB = await b.dump();
  final sA = await a.status();
  sB = await b.status();
  h.writeJson('a-updated', 'status-A', sA);
  h.writeJson('a-updated', 'status-B', sB);
  h.writeJson('a-updated', 'dump-A', dA);
  h.writeJson('a-updated', 'dump-B', dB);
  final fA = await a.files(), fB = await b.files();
  h.writeJson('a-updated', 'files-A', fA);
  h.writeJson('a-updated', 'files-B', fB);
  final want = _named(stage1Shape);
  // What the end state must be: A's stage-1 content, with B's edit on trail-1.
  final wantEntries = Map<String, dynamic>.from((want['Trail Log'] as Map)['entries'] as Map);
  wantEntries['trail-1'] = '${'Ridge loop (B)'}|${'Windy at the top. Edited on B after the update.'}|${jsonEncode({'Miles': 6.5, 'Weather': 'windy', 'Hard': true})}';
  for (final x in [('A', dA, sA, fA), ('B', dB, sB, fB)]) {
    final shape = _named(Harness.shape(x.$2));
    final tl = shape['Trail Log'] as Map?;
    h.check('N1: gate active on ${x.$1}', x.$3['gate_active'] == true);
    h.check('N1: conversion done on ${x.$1}', x.$3['conversion'] == 'done', '${x.$3['conversion']}');
    h.check('N1: ${x.$1} has B\'s edit of trail-1 (title and body), values kept', tl != null && '${(tl['entries'] as Map)['trail-1']}' == '${wantEntries['trail-1']}', '${(tl?['entries'] as Map?)?['trail-1']}');
    h.check('N1: ${x.$1} has exactly the 3 entries, none lost, none doubled', tl != null && _same((tl['entries'] as Map).keys.toList(), wantEntries.keys.toList()), '${(tl?['entries'] as Map?)?.keys}');
    h.check('N1: ${x.$1} has one set of fields (Miles, Weather, Hard)', tl != null && _same(tl['fields'], (want['Trail Log'] as Map)['fields']), '${tl?['fields']}');
    h.note('N1: ${x.$1} entry files left in a retired notebook-id folder', _retiredIdFiles(x.$4, x.$2).isEmpty ? 'none' : '${_retiredIdFiles(x.$4, x.$2)}');
    h.check('N1: ${x.$1} has no old name-folder files', _legacyLeft(x.$4, x.$2).isEmpty, '${_legacyLeft(x.$4, x.$2)}');
    h.check('N1: ${x.$1} has the other entries as before (trail-2, trail-3, Gear)', tl != null && _same((tl['entries'] as Map)['trail-2'], wantEntries['trail-2']) && _same((tl['entries'] as Map)['trail-3'], wantEntries['trail-3']) && _same(shape['Gear'], want['Gear']));
  }
  String idOf(Map d, String name) => '${[for (final n in d['notebooks']) if (n['name'] == name) n['id']]}';
  h.check('N1: A and B hold Trail Log under the same id, only one', idOf(dA, 'Trail Log') == idOf(dB, 'Trail Log') && !idOf(dA, 'Trail Log').contains(','), '${idOf(dA, 'Trail Log')} / ${idOf(dB, 'Trail Log')}');
  await roll(h, b, 'chain', snapshotAs: 'final-data');
  await roll(h, a, 'chain', snapshotAs: 'final-data');
}

bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
