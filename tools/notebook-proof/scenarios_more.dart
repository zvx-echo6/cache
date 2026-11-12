part of 'scenarios.dart';

// ---- helpers ----

/// entry id -> "title|body|values" of the notebook [name] on a dump.
Map<String, String> _entries(Map<String, dynamic> dump, String name) {
  final shape = Harness.shape(dump)[name] as Map?;
  return {for (final e in ((shape?['entries'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'};
}

List<String> _fieldsOf(Map<String, dynamic> dump, String name) => [for (final f in ((Harness.shape(dump)[name] as Map?)?['fields'] as List? ?? const [])) '$f'];

/// The shared notebooks of a dump, by name (every notebook but the Journal each device makes for itself).
Map<String, dynamic> _shared(Map<String, dynamic> dump) {
  final s = Harness.shape(dump);
  return {for (final e in s.entries) if (e.key != 'Journal') e.key: e.value};
}

/// Rounds of sync over [ds] until their shared notebooks are the same on all and stay so for one more round.
Future<bool> converge(Harness h, List<Device> ds, {int max = 10}) async {
  String? prev;
  for (var i = 0; i < max; i++) {
    await h.rounds(ds, n: 1);
    final shapes = [for (final d in ds) jsonEncode(_shared(await d.dump()))];
    final same = shapes.every((x) => x == shapes.first);
    if (same && shapes.first == prev) return true;
    prev = same ? shapes.first : null;
  }
  return false;
}

Future<void> linkPair(Device shower, Device dialer) async {
  final code = ((await shower.call('link_code')) as Map)['code'];
  await dialer.call('link', {'code': code});
}

/// Rolling move of devices to [build], in the order given (the one that dialed with a code first).
Future<void> rollAll(Harness h, List<Device> order, String build) async {
  for (final d in order) {
    await roll(h, d, build);
  }
}

/// Every device holds [wantNames] with the same entries; [gone] ids are on none of them.
void _converged(Harness h, String what, Map<Device, Map<String, dynamic>> dumps, {List<String> gone = const []}) {
  final shapes = {for (final e in dumps.entries) e.key.name: jsonEncode(_shared(e.value))};
  h.check('$what: all devices hold the same notebooks, entries, values and fields', shapes.values.every((x) => x == shapes.values.first), shapes.length == 1 ? '' : [for (final e in shapes.entries) '${e.key}=${e.value.length}b'].join(' '));
  for (final g in gone) {
    h.check('$what: entry $g is on no device', dumps.values.every((d) => !jsonEncode(d).contains('"id":"$g"')));
  }
}

String _id(Map<String, dynamic> d, String name) => '${[for (final n in d['notebooks']) if (n['name'] == name) n['id']]}';

// ---- observation 4: can the stale pre-edit copy in the retired folder ever be read back? ----

Future<void> stale(Harness h) async {
  await ensureStage1(h);
  final a = h.dev('A', portA), b = h.dev('B', portB), c = h.dev('C', portC);
  await roll(h, b, 'chain');
  await b.call('check_version');
  await h.rounds([a, b], n: 2);
  await b.call('entry_edit', {'id': 'trail-1', 'title': 'Ridge loop (B)', 'body': 'Windy at the top. Edited on B after the update.'});
  await h.rounds([a, b], n: 2);
  await roll(h, a, 'chain');
  await a.call('check_version');
  await b.call('check_version');
  h.check('stale: A and B converged after the update', await converge(h, [a, b]));
  final f0 = await a.files();
  final stalePath = _retiredIdFiles(f0, await a.dump());
  h.note('stale: entry files in retired id folders after N1', '$stalePath');
  const oldTitle = 'Ridge loop', oldBody = 'Windy at the top';
  const newTitle = 'Ridge loop (B)', newBody = 'Windy at the top. Edited on B after the update.';
  // The old text is a title exactly "Ridge loop" or a body exactly "Windy at the top".
  bool oldBack(Map<String, dynamic> d) => d['notebooks'].any((n) => (n['entries'] as List).any((e) => e['title'] == oldTitle || e['body'] == oldBody));
  void expectNew(String what, Map<Device, Map<String, dynamic>> dumps) {
    for (final e in dumps.entries) {
      final t1 = _entries(e.value, 'Trail Log')['trail-1'];
      h.check('$what: ${e.key.name} has the edited trail-1 and the old text is not back', t1 != null && t1.startsWith('$newTitle|$newBody|') && !oldBack(e.value), '$t1');
    }
  }
  expectNew('stale after N1', {a: await a.dump(), b: await b.dump()});
  // e1: restarts, both (rolling).
  await rollAll(h, [b, a], 'chain');
  await converge(h, [a, b]);
  expectNew('stale e1 restart', {a: await a.dump(), b: await b.dump()});
  h.note('stale e1: retired-folder files after the restarts', '${_retiredIdFiles(await a.files(), await a.dump())}');
  // e2: a third device joins later (never saw v1.0.30), and links to both.
  await c.start('chain');
  await c.call('sharing_setup');
  await linkPair(a, c);
  await linkPair(b, c);
  await c.call('share_on');
  await converge(h, [a, b, c]);
  final dC = await c.dump();
  expectNew('stale e2 third device joined', {a: await a.dump(), b: await b.dump(), c: dC});
  h.note('stale e2: files C holds in retired id folders', '${_retiredIdFiles(await c.files(), dC)}');
  // e3: the folder is re-shared (switched off and on) on A.
  await a.call('share_off');
  await a.call('sync');
  await a.call('share_on');
  await converge(h, [a, b, c]);
  expectNew('stale e3 re-shared on A', {a: await a.dump(), b: await b.dump(), c: await c.dump()});
  // e4: a second edit, on C, must win over the stale copy everywhere.
  await c.call('entry_edit', {'id': 'trail-1', 'body': 'Second edit on C'});
  await converge(h, [a, b, c]);
  for (final d in [a, b, c]) {
    final t1 = _entries(await d.dump(), 'Trail Log')['trail-1'];
    h.check('stale e4: ${d.name} has the second edit', t1 != null && t1.contains('|Second edit on C|'), '$t1');
  }
  // e5: the entry is deleted: no stale copy may bring it back, also after restarts of every device.
  await b.call('entry_delete', {'id': 'trail-1'});
  await converge(h, [a, b, c]);
  _converged(h, 'stale e5 delete', {a: await a.dump(), b: await b.dump(), c: await c.dump()}, gone: ['trail-1']);
  await rollAll(h, [c, b, a], 'chain');
  await converge(h, [a, b, c]);
  final fin = {a: await a.dump(), b: await b.dump(), c: await c.dump()};
  _converged(h, 'stale e5 after restarts of all three', fin, gone: ['trail-1']);
  h.check('stale e5: the old text never came back anywhere', fin.values.every((d) => !oldBack(d)));
  for (final d in [a, b, c]) {
    h.writeJson('final', 'files-${d.name}', await d.files());
    h.writeJson('final', 'dump-${d.name}', await d.dump());
  }
}

// ---- 3 devices ----

Future<void> three(Harness h) async {
  await ensureStage1(h, withC: true);
  final a = h.dev('A', portA), b = h.dev('B', portB), c = h.dev('C', portC);
  await rollAll(h, [c, b, a], 'chain');
  for (final d in [a, b, c]) {
    await d.call('check_version');
  }
  h.check('three: A, B and C converge after the update', await converge(h, [a, b, c], max: 12));
  final dumps = {a: await a.dump(), b: await b.dump(), c: await c.dump()};
  for (final e in dumps.entries) {
    h.writeJson('after-update', 'dump-${e.key.name}', e.value);
    final st = await e.key.status();
    h.check('three: ${e.key.name} gate active and converted', st['gate_active'] == true && st['conversion'] == 'done', '${st['conversion']} ${st['peers']}');
    h.check('three: ${e.key.name} has the entries and fields as A had them', _same(_named(Harness.shape(e.value)), _named(stage1Shape)), jsonEncode(_named(Harness.shape(e.value))));
  }
  _converged(h, 'three', dumps);
  h.check('three: one Trail Log id on all three', {_id(dumps[a]!, 'Trail Log'), _id(dumps[b]!, 'Trail Log'), _id(dumps[c]!, 'Trail Log')}.length == 1);
}

// ---- concurrent edits ----

Future<void> concurrent(Harness h) async {
  await ensureStage1(h, withC: true);
  final a = h.dev('A', portA), b = h.dev('B', portB), c = h.dev('C', portC);
  await rollAll(h, [c, b, a], 'chain');
  await converge(h, [a, b, c], max: 12);
  // Different entries at once, no sync in between.
  await a.call('entry_edit', {'id': 'trail-1', 'body': 'A edits the body of one'});
  await b.call('entry_edit', {'id': 'trail-2', 'title': 'Creek walk (B)'});
  await c.call('entry_edit', {'id': 'trail-3', 'body': 'C edits three', 'values': {'Miles': 5}});
  await c.call('entry_add', {'id': 'trail-4', 'notebook': 'Trail Log', 'title': 'New on C', 'body': 'c', 'values': {'Miles': 1}});
  await a.call('entry_add', {'id': 'trail-5', 'notebook': 'Trail Log', 'title': 'New on A', 'body': 'a'});
  h.check('concurrent: converged (different entries)', await converge(h, [a, b, c], max: 12));
  final d1 = {a: await a.dump(), b: await b.dump(), c: await c.dump()};
  _converged(h, 'concurrent different entries', d1);
  final e = _entries(d1[a]!, 'Trail Log');
  h.check('concurrent: every edit survived, nothing lost, nothing doubled', e['trail-1']!.contains('|A edits the body of one|') && e['trail-2']!.startsWith('Creek walk (B)|') && e['trail-3']!.contains('|C edits three|') && e['trail-3']!.contains('"Miles":5') && e.containsKey('trail-4') && e.containsKey('trail-5') && e.length == 5, jsonEncode(e));
  // The same entry on all three at once, in different words and different fields.
  await a.call('entry_edit', {'id': 'trail-1', 'title': 'Ridge A', 'values': {'Weather': 'rain'}});
  await b.call('entry_edit', {'id': 'trail-1', 'body': 'Body from B', 'values': {'Miles': 7}});
  await c.call('entry_edit', {'id': 'trail-1', 'title': 'Ridge C'});
  h.check('concurrent: converged (same entry)', await converge(h, [a, b, c], max: 12));
  final d2 = {a: await a.dump(), b: await b.dump(), c: await c.dump()};
  _converged(h, 'concurrent same entry', d2);
  final t1 = _entries(d2[a]!, 'Trail Log');
  h.note('concurrent: trail-1 after three concurrent edits', '${t1['trail-1']}');
  h.check('concurrent: one trail-1, no duplicates', t1.keys.where((k) => k.startsWith('trail-1')).length == 1 && t1.length == 5, '${t1.keys}');
  h.check('concurrent: the field edits of different fields both survive (Weather rain, Miles 7)', t1['trail-1']!.contains('"Weather":"rain"') && t1['trail-1']!.contains('"Miles":7'), '${t1['trail-1']}');
  h.check('concurrent: B\'s body survived', t1['trail-1']!.contains('|Body from B|'), '${t1['trail-1']}');
  // Delete on one, edit on another.
  await a.call('entry_delete', {'id': 'trail-5'});
  await b.call('entry_edit', {'id': 'trail-5', 'body': 'edited while A deleted it'});
  await converge(h, [a, b, c], max: 12);
  final d3 = {a: await a.dump(), b: await b.dump(), c: await c.dump()};
  _converged(h, 'concurrent delete vs edit', d3);
  h.note('concurrent: delete vs edit of trail-5 settled as', _entries(d3[a]!, 'Trail Log').containsKey('trail-5') ? 'kept (edit won)' : 'deleted');
}

// ---- fields after the update ----

Future<void> fields(Harness h) async {
  await ensureStage1(h);
  final a = h.dev('A', portA), b = h.dev('B', portB);
  await rollAll(h, [b, a], 'chain');
  h.check('fields: converged after the update', await converge(h, [a, b]));
  // Add, rename and remove on A.
  await a.call('fields_edit', {
    'notebook': 'Trail Log',
    'add': [{'label': 'Gear', 'type': 'text'}],
    'rename': {'Weather': 'Sky'},
    'remove': ['Hard'],
  });
  await a.call('entry_edit', {'id': 'trail-1', 'values': {'Gear': 'tent'}});
  h.check('fields: converged after add, rename and remove', await converge(h, [a, b]));
  var dA = await a.dump(), dB = await b.dump();
  h.writeJson('after-a-edit', 'dump-A', dA);
  h.writeJson('after-a-edit', 'dump-B', dB);
  _converged(h, 'fields A edits', {a: dA, b: dB});
  var fb = _fieldsOf(dB, 'Trail Log');
  h.note('fields: B\'s fields after A added Gear, renamed Weather to Sky, removed Hard', '$fb');
  h.check('fields: B has Gear and Sky, each once, and no Weather', fb.where((f) => f.startsWith('Gear:')).length == 1 && fb.where((f) => f.startsWith('Sky:')).length == 1 && !fb.any((f) => f.startsWith('Weather:')), '$fb');
  h.check('fields: Hard is removed (hidden or gone) on B', !fb.any((f) => f.startsWith('Hard:') && !f.endsWith(':hidden')), '$fb');
  final t1 = _entries(dB, 'Trail Log')['trail-1']!;
  h.check('fields: B keeps trail-1 values under the new names (Miles 6.5, Sky windy, Gear tent)', t1.contains('"Miles":6.5') && t1.contains('"Sky":"windy"') && t1.contains('"Gear":"tent"'), t1);
  // At once: A renames Miles, B adds Elevation.
  await a.call('fields_edit', {'notebook': 'Trail Log', 'rename': {'Miles': 'Distance'}});
  await b.call('fields_edit', {'notebook': 'Trail Log', 'add': [{'label': 'Elevation', 'type': 'number'}]});
  h.check('fields: converged after concurrent rename and add', await converge(h, [a, b]));
  dA = await a.dump();
  dB = await b.dump();
  _converged(h, 'fields concurrent', {a: dA, b: dB});
  fb = _fieldsOf(dB, 'Trail Log');
  h.check('fields: Distance and Elevation each once on both', fb.where((f) => f.startsWith('Distance:')).length == 1 && fb.where((f) => f.startsWith('Elevation:')).length == 1 && !fb.any((f) => f.startsWith('Miles:')), '$fb');
  h.check('fields: trail-1 kept its value under Distance', _entries(dB, 'Trail Log')['trail-1']!.contains('"Distance":6.5'));
  // B removes Gear, A adds a value to a new entry.
  await b.call('fields_edit', {'notebook': 'Trail Log', 'remove': ['Gear']});
  await a.call('entry_add', {'id': 'trail-6', 'notebook': 'Trail Log', 'title': 'After fields', 'body': 'x', 'values': {'Distance': 3, 'Sky': 'fog'}});
  h.check('fields: converged after remove and a new entry', await converge(h, [a, b]));
  dA = await a.dump();
  dB = await b.dump();
  _converged(h, 'fields remove', {a: dA, b: dB});
  h.check('fields: Gear is removed on A too, and the new entry is on both with its values', !_fieldsOf(dA, 'Trail Log').any((f) => f.startsWith('Gear:') && !f.endsWith(':hidden')) && _entries(dB, 'Trail Log')['trail-6']!.contains('"Distance":3'), '${_fieldsOf(dA, 'Trail Log')}');
  // Restart, still the same.
  await rollAll(h, [b, a], 'chain');
  await converge(h, [a, b]);
  _converged(h, 'fields after restarts', {a: await a.dump(), b: await b.dump()});
}

// ---- removal made before the update ----

Future<void> removal(Harness h) async {
  await ensureStage1(h);
  final a = h.dev('A', portA), b = h.dev('B', portB);
  // On v1.0.30: an entry removed and synced, a second entry removed and NOT synced, a notebook removed and synced.
  await a.call('entry_delete', {'id': 'trail-2'});
  await h.rounds([a, b], n: 3);
  h.check('removal: trail-2 (removed on A, synced) is gone on B before the update', !(await b.dump()).toString().contains('trail-2'));
  await b.call('nb_delete', {'notebook': 'Gear'});
  await h.rounds([b, a], n: 3);
  final preA = await a.dump(), preB = await b.dump();
  h.writeJson('before-update', 'dump-A', preA);
  h.writeJson('before-update', 'dump-B', preB);
  h.note('removal: Gear notebook deleted on B (legacy), A before the update has it', '${(Harness.shape(preA)).containsKey('Gear')}');
  await a.call('entry_delete', {'id': 'trail-3'}); // not synced before the update
  await rollAll(h, [b, a], 'chain');
  for (final d in [a, b]) {
    await d.call('check_version');
  }
  h.check('removal: converged after the update', await converge(h, [a, b], max: 12));
  final dA = await a.dump(), dB = await b.dump();
  h.writeJson('after-update', 'dump-A', dA);
  h.writeJson('after-update', 'dump-B', dB);
  h.writeJson('after-update', 'files-A', await a.files());
  h.writeJson('after-update', 'files-B', await b.files());
  _converged(h, 'removal', {a: dA, b: dB}, gone: ['trail-2', 'trail-3']);
  h.check('removal: trail-1 is still there on both', _entries(dA, 'Trail Log').containsKey('trail-1') && _entries(dB, 'Trail Log').containsKey('trail-1'));
  for (final d in [a, b]) {
    final f = (await d.files()).where((x) => x.contains('Creek walk') || x.contains('Lake')).toList();
    h.check('removal: no file of a removed entry is left on ${d.name}', f.isEmpty, '$f');
  }
  h.check('removal: the removed Gear notebook did not come back (A and B)', !Harness.shape(dA).containsKey('Gear') && !Harness.shape(dB).containsKey('Gear'), '${Harness.shape(dA).keys} / ${Harness.shape(dB).keys}');
}

// ---- a kill mid-sync and mid-conversion ----

Future<void> crash(Harness h) async {
  await ensureStage1(h);
  final a = h.dev('A', portA), b = h.dev('B', portB);
  await roll(h, b, 'chain');
  await b.call('check_version');
  await h.rounds([a, b], n: 2);
  await b.call('entry_edit', {'id': 'trail-1', 'title': 'Ridge loop (B)', 'body': 'Edited on B before the crashes.'});
  await roll(h, a, 'chain'); // A updates: the gate opens, the conversion starts on the next syncs
  await a.call('check_version');
  await b.call('check_version');
  // Crash cycles: each starts a sync (the conversion work) and kills that device's process by PID a little later.
  var cycle = 0;
  for (final step in [(b, 700), (a, 900), (b, 1800), (a, 2600), (b, 3500)]) {
    final d = step.$1, delay = step.$2;
    final other = d == a ? b : a;
    cycle++;
    d.send('sync');
    other.send('sync');
    await Future<void>.delayed(Duration(milliseconds: delay));
    final before = await _tryState(other);
    await d.crash();
    h.say('crash cycle $cycle: killed ${d.name} $delay ms into a sync (other: $before)');
    h.writeJson('cycle-$cycle', 'files-${d.name}-after-kill', _listShare(d));
    // Rolling restart (the other is up; give its running sync time to end first).
    await Future<void>.delayed(const Duration(seconds: 3));
    await d.start('chain');
    await reconnect(h, d);
  }
  h.check('crash: converged after five kills and restarts', await converge(h, [a, b], max: 14));
  final dA = await a.dump(), dB = await b.dump();
  _converged(h, 'crash', {a: dA, b: dB});
  for (final d in [a, b]) {
    final st = await d.status();
    h.check('crash: ${d.name} finished the conversion', st['conversion'] == 'done', '${st['conversion']} ${st['peers']}');
  }
  final t = _entries(dA, 'Trail Log');
  h.check('crash: B\'s edit survived every kill', (t['trail-1'] ?? '').startsWith('Ridge loop (B)|Edited on B before the crashes.|'), '${t['trail-1']}');
  final was = ((stage1Shape['Trail Log'] as Map)['entries'] as Map);
  h.check('crash: exactly the 3 entries with their values, none lost, none doubled', t.length == 3 && t['trail-2'] == was['trail-2'] && t['trail-3'] == was['trail-3'], '${t.keys}');
  h.check('crash: one set of fields on both', _same(_fieldsOf(dA, 'Trail Log'), _fieldsOf(dB, 'Trail Log')) && _fieldsOf(dA, 'Trail Log').length == 3, '${_fieldsOf(dA, 'Trail Log')}');
  for (final d in [a, b]) {
    final f = await d.files();
    h.check('crash: no old name-folder files on ${d.name}', _legacyLeft(f, await d.dump()).isEmpty, '${_legacyLeft(f, await d.dump())}');
    h.note('crash: entry files in retired id folders on ${d.name}', '${_retiredIdFiles(f, await d.dump())}');
  }
}

Future<String> _tryState(Device d) async {
  try {
    return 'alive';
  } catch (e) {
    return 'error $e';
  }
}

List<String> _listShare(Device d) {
  final base = Directory('${d.dir.path}/data/notebook-share');
  if (!base.existsSync()) return const [];
  final root = base.absolute.path.replaceAll('\\', '/');
  return [for (final f in base.listSync(recursive: true).whereType<File>()) '${f.absolute.path.replaceAll('\\', '/').substring(root.length + 1)} (${f.lengthSync()})']..sort();
}

// ---- old name-folder files from a device that has not updated ----

Future<void> oldfolder(Harness h) async {
  await ensureStage1(h);
  final a = h.dev('A', portA), b = h.dev('B', portB);
  // A updates first; B (v1.0.30) stays on and keeps writing old name-folder files while the gate keeps the link closed.
  await roll(h, a, 'chain');
  await a.call('check_version');
  await b.call('entry_add', {'id': 'trail-9', 'notebook': 'Trail Log', 'title': 'Made on old B', 'body': 'written to the old name folder'});
  await b.call('entry_edit', {'id': 'trail-2', 'body': 'Easy and flat. Old B edit.'});
  await h.rounds([b, a], n: 3);
  final fB = await b.files();
  h.writeJson('b-old', 'files-B', fB);
  h.check('oldfolder: B (not updated) wrote its entry into the old name folder', fB.any((f) => f.startsWith('Trail Log/') && f.contains('Made on old B')), '$fB');
  h.check('oldfolder: A got nothing of it while B is old (closed link)', !jsonEncode(await a.dump()).contains('trail-9'));
  // B updates: its old-folder files must be placed in the id layout and reach A.
  await roll(h, b, 'chain');
  await b.call('check_version');
  h.check('oldfolder: converged after B updated', await converge(h, [a, b], max: 12));
  final dA = await a.dump(), dB = await b.dump();
  h.writeJson('after-update', 'dump-A', dA);
  h.writeJson('after-update', 'dump-B', dB);
  _converged(h, 'oldfolder', {a: dA, b: dB});
  final e = _entries(dA, 'Trail Log');
  h.check('oldfolder: the entry made on the old device is on both, once', e.containsKey('trail-9') && e.length == 4, '${e.keys}');
  h.check('oldfolder: the edit made on the old device is on both', (e['trail-2'] ?? '').contains('Old B edit'), '${e['trail-2']}');
  for (final d in [a, b]) {
    final st = await d.status();
    final f = await d.files();
    h.check('oldfolder: ${d.name} converted and has no old name-folder files', st['conversion'] == 'done' && _legacyLeft(f, await d.dump()).isEmpty, '${st['conversion']} ${_legacyLeft(f, await d.dump())}');
  }
}

// ---- the stale copy in the retired folder: does a delete stay deleted? ----
// N1's steps (B updates first and edits trail-1, then A updates), then two deletes: trail-1 (a stale pre-edit copy of it is left in the
// retired folder nb-trail/) and, as the control, trail-2 (no stale copy). Every round records where each entry is and with what text.

Future<void> resurrect(Harness h) async {
  await ensureStage1(h);
  final a = h.dev('A', portA), b = h.dev('B', portB);
  await roll(h, b, 'chain');
  await b.call('check_version');
  await h.rounds([a, b], n: 2);
  await b.call('entry_edit', {'id': 'trail-1', 'title': 'Ridge loop (B)', 'body': 'Windy at the top. Edited on B after the update.'});
  await roll(h, a, 'chain');
  await a.call('check_version');
  await b.call('check_version');
  h.check('resurrect: converged after the update', await converge(h, [a, b]));
  h.note('resurrect: retired-folder files before the deletes (A, B)', '${_retiredIdFiles(await a.files(), await a.dump())} / ${_retiredIdFiles(await b.files(), await b.dump())}');
  await b.call('entry_delete', {'id': 'trail-1'}); // has a stale pre-edit copy in nb-trail/
  await b.call('entry_delete', {'id': 'trail-2'}); // control: no stale copy
  for (var round = 1; round <= 6; round++) {
    for (final d in [b, a]) {
      await d.call('sync');
      final dump = await d.dump();
      final e = _entries(dump, 'Trail Log');
      h.writeJson('rounds', 'r$round-${d.name}-dump', dump);
      h.writeJson('rounds', 'r$round-${d.name}-files', await d.files());
      h.note('resurrect round $round after ${d.name} syncs: ${d.name} holds', 'trail-1=${e['trail-1']}  trail-2=${e['trail-2']}  entries=${e.keys.toList()}');
    }
  }
  final dA = await a.dump(), dB = await b.dump();
  final eA = _entries(dA, 'Trail Log'), eB = _entries(dB, 'Trail Log');
  h.check('resurrect: the control (trail-2, no stale copy) stays deleted on A and B', !eA.containsKey('trail-2') && !eB.containsKey('trail-2'));
  h.check('resurrect: trail-1 deleted on B stays deleted on A and B', !eA.containsKey('trail-1') && !eB.containsKey('trail-1'), 'A=${eA['trail-1']} B=${eB['trail-1']}');
  // After restarts of both.
  await rollAll(h, [b, a], 'chain');
  await converge(h, [a, b]);
  final rA = _entries(await a.dump(), 'Trail Log'), rB = _entries(await b.dump(), 'Trail Log');
  h.check('resurrect: still deleted after restarts of both', !rA.containsKey('trail-1') && !rB.containsKey('trail-1'), 'A=${rA['trail-1']} B=${rB['trail-1']}');
  h.writeJson('final', 'files-A', await a.files());
  h.writeJson('final', 'files-B', await b.files());
}
