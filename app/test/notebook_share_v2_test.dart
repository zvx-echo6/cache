import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/sync/share_format.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/share_rig.dart';

/// The notebooks share in the id layout (format 2): one folder `<id>/` per notebook; the conversion on update (journaled, resumable:
/// exact-name convergence to the lowest id, then the old folders go); a device that has not updated (the REAL engine of v1.0.30,
/// from the tag) gated off the link and then updating; tombstones; the private filter; the re-id queue. Every test syncs through the
/// simulated share (ShareLink), as cache_sync does; the link-level gate is a stub (`ShareLink.open`, `Dev.gateOn`).
Future<void> rounds(List<Dev> devs, List<ShareLink> links, {int n = 3}) async {
  for (var i = 0; i < n; i++) {
    for (final d in devs) {
      await d.sync();
    }
    for (final l in links) {
      l.sync();
    }
  }
  for (final d in devs) {
    await d.sync();
  }
}

Set<String> oldFiles(MemFolder f) => {for (final k in f.text.keys) if (k.endsWith('.md')) k};
Set<String> noteFiles(MemFolder f, String dir) => {for (final k in f.text.keys) if (k.startsWith('$dir/') && k.endsWith(kNoteExt)) k};

Future<Dev> started(String label, {bool old = false, bool autoUpgrade = true}) async {
  final d = Dev(label, old: old, autoUpgrade: autoUpgrade);
  await d.boot();
  return d;
}

void main() {
  group('the conversion on update', () {
    test('both devices update: ids converge on the lowest by exact name, nothing is lost, and the old folders are gone', () async {
      final a = await started('a', old: true);
      final b = await started('b', old: true);
      await a.make('Hikes', id: 'a-1');
      await a.add('a-1', 'ea1', 'Alpha');
      await b.make('Hikes', id: 'b-2');
      await b.add('b-2', 'eb1', 'Beta');
      await b.make('Trips', id: 'b-3');
      await b.add('b-3', 'eb2', 'Gamma');
      final link = ShareLink(a.folder, b.folder);
      await rounds([a, b], [link], n: 3);
      expect(await a.entryIds('a-1'), {'ea1', 'eb1'});
      expect(oldFiles(a.folder).length, 3);
      final aTrips = a.ids('Trips').single;
      await a.updateCache();
      await b.updateCache();
      await rounds([a, b], [link], n: 4);
      for (final d in [a, b]) {
        expect(d.ids('Hikes'), ['a-1'], reason: '${d.label}: the lowest id for the name');
        expect(await d.entryIds('a-1'), {'ea1', 'eb1'}, reason: '${d.label}: entries intact');
        expect(d.ids('Trips').single, ([aTrips, 'b-3']..sort()).first, reason: d.label);
        expect(await d.entryIds(d.ids('Trips').single), {'eb2'});
        expect(d.nb.notebooks.length, 2, reason: 'no notebook was made twice');
        expect(oldFiles(d.folder), isEmpty, reason: '${d.label}: no old folder left');
        expect(d.folder.bytes.keys.where((k) => k.startsWith('photos/')), isEmpty);
        expect(d.conn.conversionState, 'done', reason: d.label);
        expect(d.folder.text.values.where((t) => t.contains('"deleted"')), isEmpty, reason: 'no tombstone from the removal');
      }
      expect(jsonDecode(a.folder.text['a-1/notebook.json']!)['name'], 'Hikes');
      final before = [{...a.folder.text}, {...b.folder.text}];
      await rounds([a, b], [link], n: 2);
      expect(a.folder.text, before[0]);
      expect(b.folder.text, before[1]);
    });

    test('nothing is converted before the link gate is active, and notebook sync waits until the upgrade is written down', () async {
      final a = await started('a', old: true, autoUpgrade: false);
      await a.make('Hikes', id: 'a-1');
      await a.add('a-1', 'ea1', 'Alpha');
      await a.sync();
      expect(oldFiles(a.folder).length, 1);
      a.gateOn = false;
      await a.updateCache();
      a.autoUpgrade = false;
      final before = {...a.folder.text};
      await a.sync();
      expect(a.folder.text, before, reason: 'the upgrade is not written down yet: nothing syncs');
      expect(a.conn.status('share'), 'Paused.');
      await a.upgrade();
      await a.sync();
      expect(noteFiles(a.folder, 'a-1').length, 1, reason: 'the id layout is written');
      expect(oldFiles(a.folder).length, 1, reason: 'but the old folder stays while the gate is not active');
      expect(a.conn.conversionState, 'converting');
      a.gateOn = true;
      await a.sync();
      expect(oldFiles(a.folder), isEmpty);
      expect(a.conn.conversionState, 'done');
      expect(await a.entryIds('a-1'), {'ea1'});
    });

    test('a kill while the old folders are being removed: the next start finishes it, and nothing is lost', () async {
      final a = await started('a', old: true);
      await a.make('Hikes', id: 'a-1');
      await a.add('a-1', 'ea1', 'Alpha');
      await a.add('a-1', 'ea2', 'Beta');
      await a.make('Trips', id: 'a-2');
      await a.add('a-2', 'ea3', 'Gamma');
      await a.sync();
      expect(oldFiles(a.folder).length, 3);
      await a.updateCache();
      a.folder.failAfterDeletes = 1;
      await a.sync();
      expect(a.conn.conversionState, 'removing');
      expect(oldFiles(a.folder).length, 2, reason: 'one was removed, then the kill');
      expect(noteFiles(a.folder, 'a-1').length + noteFiles(a.folder, 'a-2').length, 3);
      a.folder.failAfterDeletes = null;
      a.restart();
      await a.boot();
      await a.sync();
      expect(oldFiles(a.folder), isEmpty);
      expect(a.conn.conversionState, 'done');
      expect(await a.entryIds('a-1'), {'ea1', 'ea2'});
      expect(await a.entryIds('a-2'), {'ea3'});
    });

    test('a note in an old folder that Cache has not read is placed in the id layout and read, not removed; a kill in between makes no copy', () async {
      final a = await started('a', old: true);
      await a.make('Hikes', id: 'a-1');
      await a.add('a-1', 'ea1', 'Alpha');
      await a.sync();
      // a note that came from an older device and was not read before the update
      a.folder.text['Hikes/2026-11-02 Late.md'] = '---\ncache_id: ex9\nnotebook: Hikes\ntitle: Late\ndate: 2026-11-02\ntime: 2026-11-02T09:00:00\n---\nCame late.\n';
      await a.updateCache();
      a.folder.failAfterDeletes = 0;
      await a.sync();
      expect(a.folder.text.keys.where((k) => k.startsWith('a-1/') && k.contains('Late')).length, 1);
      a.folder.failAfterDeletes = null;
      a.restart();
      await a.boot();
      await a.sync();
      await a.sync();
      expect(await a.entryIds('a-1'), {'ea1', 'ex9'}, reason: 'read once');
      expect((await a.nb.entry('ex9'))!.body, 'Came late.');
      expect(a.folder.text.keys.where((k) => k.startsWith('a-1/') && k.contains('Late')).length, 1, reason: 'one file, not two');
      expect(oldFiles(a.folder), isEmpty);
      expect(a.conn.conversionState, 'done');
    });
  });

  group('a device that has not updated (the real v1.0.30 engine)', () {
    test('gated off the link it receives nothing and loses nothing; when it updates the link resumes and they converge', () async {
      final n = await started('new', old: true);
      final d = await started('old', old: true);
      await n.make('Hikes', id: 'n-1');
      await n.add('n-1', 'en1', 'Alpha');
      await d.make('Hikes', id: 'd-9');
      await d.add('d-9', 'ed1', 'Beta');
      final link = ShareLink(n.folder, d.folder);
      await rounds([n, d], [link], n: 3);
      expect(await d.entryIds('d-9'), {'en1', 'ed1'});
      // the gate: a device on the old protocol gets nothing, in either direction
      link.open = () => n.old == d.old;
      await n.updateCache();
      final heldByD = {...d.folder.text};
      await rounds([n, d], [link], n: 3);
      expect(oldFiles(n.folder), isEmpty, reason: 'the new device converted');
      expect(noteFiles(n.folder, 'n-1').length, 2);
      expect(d.folder.text, heldByD, reason: 'the old device was sent nothing (no delete, no new folder)');
      expect(await d.entryIds('d-9'), {'en1', 'ed1'}, reason: 'and lost nothing');
      expect(d.nb.notebooks.length, 1);
      // the old device edits while gated: nothing reaches the new one
      await d.nb.saveEntry(id: 'ed2', notebookId: 'd-9', occurredAt: '2026-11-02T09:00:00-07:00', title: 'While gated', body: 'x');
      await rounds([n, d], [link], n: 2);
      expect(await n.entryIds('n-1'), {'en1', 'ed1'});
      // it updates: converts, and the link resumes
      await d.updateCache();
      await rounds([n, d], [link], n: 4);
      for (final x in [n, d]) {
        expect(x.ids('Hikes'), ['d-9'], reason: '${x.label}: the lowest id');
        expect(await x.entryIds('d-9'), {'en1', 'ed1', 'ed2'}, reason: x.label);
        expect(oldFiles(x.folder), isEmpty);
        expect(x.nb.notebooks.length, 1);
      }
    });

    test('a chain A-B, B-C, C-D with D not updated: D is left alone, then updates and the four converge', () async {
      final a = await started('a', old: true);
      final b = await started('b', old: true);
      final c = await started('c', old: true);
      final d = await started('d', old: true);
      await a.make('Hikes', id: 'h-a');
      await a.add('h-a', 'ea1', 'Alpha');
      await b.make('Hikes', id: 'h-b');
      await b.add('h-b', 'eb1', 'Beta');
      await c.make('Hikes', id: 'h-c');
      await c.add('h-c', 'ec1', 'Gamma');
      await d.make('Hikes', id: 'h-d');
      await d.add('h-d', 'ed1', 'Delta');
      final ab = ShareLink(a.folder, b.folder);
      final bc = ShareLink(b.folder, c.folder);
      final cd = ShareLink(c.folder, d.folder);
      cd.open = () => c.old == d.old;
      await rounds([a, b, c, d], [ab, bc, cd], n: 6);
      for (final x in [a, b, c, d]) {
        expect(await x.entryIds(x.ids('Hikes').single), {'ea1', 'eb1', 'ec1', 'ed1'}, reason: '${x.label} before the update');
      }
      await a.updateCache();
      await b.updateCache();
      await c.updateCache();
      final heldByD = {...d.folder.text};
      await rounds([a, b, c, d], [ab, bc, cd], n: 6);
      expect(d.folder.text, heldByD, reason: 'the old device on the end of the chain got nothing');
      expect(await d.entryIds('h-d'), {'ea1', 'eb1', 'ec1', 'ed1'});
      for (final x in [a, b, c]) {
        expect(x.ids('Hikes'), ['h-a'], reason: x.label);
        expect(await x.entryIds('h-a'), {'ea1', 'eb1', 'ec1', 'ed1'}, reason: x.label);
        expect(oldFiles(x.folder), isEmpty);
      }
      await d.updateCache();
      await rounds([a, b, c, d], [ab, bc, cd], n: 6);
      for (final x in [a, b, c, d]) {
        expect(x.ids('Hikes'), ['h-a'], reason: '${x.label}: one id on all four');
        expect(await x.entryIds('h-a'), {'ea1', 'eb1', 'ec1', 'ed1'}, reason: x.label);
        expect(x.nb.notebooks.length, 1);
        expect(oldFiles(x.folder), isEmpty);
      }
    });
  });

  group('after the update', () {
    test('two new notebooks made with one name stay two, with the sharing turned on after the update', () async {
      final a = await started('a', autoUpgrade: false);
      final b = await started('b', autoUpgrade: false);
      await a.upgrade();
      await b.upgrade();
      a.on = false;
      b.on = false;
      await a.make('Shopping', id: 's-1');
      await a.add('s-1', 'ea1', 'Milk');
      await b.make('Shopping', id: 's-2');
      await b.add('s-2', 'eb1', 'Bread');
      a.on = true;
      b.on = true;
      final link = ShareLink(a.folder, b.folder);
      await rounds([a, b], [link], n: 4);
      for (final d in [a, b]) {
        expect({for (final n in d.nb.notebooks) n.id}, {'s-1', 's-2'}, reason: '${d.label}: two notebooks, by id');
        expect(await d.entryIds('s-1'), {'ea1'}, reason: d.label);
        expect(await d.entryIds('s-2'), {'eb1'}, reason: d.label);
      }
      expect(a.nb.notebook('s-1')!.name, 'Shopping');
      expect(a.nb.notebook('s-2')!.name, startsWith('Shopping ('));
      expect(jsonDecode(a.folder.text['s-2/notebook.json']!)['name'], 'Shopping');
      final before = [{...a.folder.text}, {...b.folder.text}];
      await rounds([a, b], [link], n: 2);
      expect(a.folder.text, before[0]);
      expect(b.folder.text, before[1]);
    });

    test('the list of notebooks from before the update is not lost with a damaged file: restored from its copy, else empty', () async {
      final a = await started('a', autoUpgrade: false);
      await a.make('Hikes', id: 'a-1');
      await a.upgrade();
      final f = File('${a.stateDir.path}/upgrade-eligible.json');
      expect(jsonDecode(f.readAsStringSync())['ids'], ['a-1']);
      // a damaged file: the copy is used
      f.writeAsStringSync('{broken');
      a.restart();
      await a.boot();
      await a.upgrade();
      expect(jsonDecode(f.readAsStringSync())['ids'], ['a-1'], reason: 'restored, and not written down again from the notebooks now');
      // both damaged: nothing is eligible, and that is not undone by the next start
      await a.make('Trips', id: 'a-2');
      f.writeAsStringSync('{broken');
      File('${f.path}.bak').writeAsStringSync('{broken');
      a.restart();
      await a.boot();
      await a.upgrade();
      expect(jsonDecode(f.readAsStringSync())['ids'], isEmpty);
      expect(File('${f.path}.damaged').existsSync(), isTrue);
      a.restart();
      await a.boot();
      await a.upgrade();
      expect(jsonDecode(f.readAsStringSync())['ids'], isEmpty, reason: 'not captured again from the notebooks (a and a-2 stay apart from others by id)');
    });

    test('a rename made on both devices at once converges on one name; the folder never moves', () async {
      final a = await started('a');
      final b = await started('b');
      await a.make('Hikes', id: 'a-1');
      await a.add('a-1', 'ea1', 'Alpha');
      final link = ShareLink(a.folder, b.folder);
      await rounds([a, b], [link]);
      expect(b.ids('Hikes'), ['a-1']);
      final files = noteFiles(a.folder, 'a-1');
      await a.nb.saveNotebook(id: 'a-1', def: a.nb.notebook('a-1')!.def.copyWith(name: 'Peaks'));
      await b.nb.saveNotebook(id: 'a-1', def: b.nb.notebook('a-1')!.def.copyWith(name: 'Ridges'));
      await rounds([a, b], [link], n: 4);
      final names = {for (final d in [a, b]) d.nb.notebook('a-1')!.name};
      expect(names.length, 1, reason: 'one name on both devices: $names');
      expect({'Peaks', 'Ridges'}, contains(names.single));
      for (final d in [a, b]) {
        expect(d.nb.notebooks.length, 1);
        expect(await d.entryIds('a-1'), {'ea1'});
        expect(d.folder.text.keys.where((k) => k.contains('conflict')), isEmpty);
        expect(noteFiles(d.folder, 'a-1'), files);
      }
    });

    test('Trip: 2026 and Trip 2026 stay two notebooks, here and on the other device', () async {
      final a = await started('a');
      final b = await started('b');
      await a.make('Trip: 2026', id: 'a-1');
      await a.add('a-1', 'ea1', 'Colon');
      await a.make('Trip 2026', id: 'a-2');
      await a.add('a-2', 'ea2', 'Space');
      final link = ShareLink(a.folder, b.folder);
      await rounds([a, b], [link]);
      for (final d in [a, b]) {
        expect(d.ids('Trip: 2026'), ['a-1'], reason: d.label);
        expect(d.ids('Trip 2026'), ['a-2'], reason: d.label);
        expect(await d.entryIds('a-1'), {'ea1'});
        expect(await d.entryIds('a-2'), {'ea2'});
      }
    });

    test('a record that comes after its notes loses nothing: the notes are read once it is there; a note before its photo is read again', () async {
      final a = await started('a');
      final b = await started('b');
      await a.make('Hikes', id: 'a-1');
      await a.add('a-1', 'ea1', 'Alpha');
      await a.nb.saveEntry(id: 'ea2', notebookId: 'a-1', occurredAt: '2026-11-02T09:00:00-07:00', title: 'With a photo', body: 'p', photos: [const NbPhoto(id: 'p1')]);
      final pf = await a.nb.photoFile('p1');
      await pf.parent.create(recursive: true);
      await pf.writeAsBytes(Uint8List.fromList([1, 2, 3]));
      final link = ShareLink(a.folder, b.folder);
      // the record and the photo are late
      link.block = (p) => p.endsWith('notebook.json') || p.contains('/photos/');
      await rounds([a, b], [link], n: 3);
      expect(b.nb.notebooks, isEmpty, reason: 'no notebook from notes alone');
      link.block = (p) => p.contains('/photos/');
      await rounds([a, b], [link], n: 3);
      expect(await b.entryIds('a-1'), {'ea1', 'ea2'});
      expect((await b.nb.entry('ea2'))!.photos, isEmpty, reason: 'the note is here, its photo is not yet');
      link.block = null;
      await rounds([a, b], [link], n: 3);
      expect(await b.entryIds('a-1'), {'ea1', 'ea2'}, reason: 'no copy');
      expect((await b.nb.entry('ea2'))!.photos.map((p) => p.id), ['p1'], reason: 'read again when the photo came');
    });
  });

  group('private notebooks', () {
    test('one that is not included writes nothing, is never matched by name, and is never filled by a note of another device', () async {
      final a = await started('a');
      final b = await started('b');
      final meds = await a.make('Meds', id: 'm-1', private: true);
      await a.add(meds.id, 'em1', 'Private', body: 'mine');
      await b.make('Meds', id: 'm-2');
      await b.add('m-2', 'em2', 'Other');
      final link = ShareLink(a.folder, b.folder);
      await rounds([a, b], [link], n: 4);
      expect(a.ids('Meds'), ['m-1']);
      expect(await a.entryIds('m-1'), {'em1'});
      expect(a.folder.text.keys.where((k) => k.startsWith('m-1/')), isEmpty);
      expect(b.ids('Meds'), ['m-2']);
      expect(await b.entryIds('m-2'), {'em2'});
    });

    test('a note that carries the id of an entry of a private notebook is never applied, moved or given another flag', () async {
      final a = await started('a');
      await a.make('Hikes', id: 'a-1');
      await a.add('a-1', 'ea1', 'Alpha');
      final meds = await a.make('Meds', id: 'm-1', private: true);
      await a.add(meds.id, 'em1', 'Private', body: 'mine');
      await a.sync();
      a.folder.text['a-1/forged.cnote'] = '---\ncache_id: em1\ntitle: Private\ndate: 2026-11-01\ntime: 2026-11-01T09:00:00\n---\nchanged from outside\n';
      await a.sync();
      await a.sync();
      final e = (await a.nb.entry('em1'))!;
      expect((e.notebookId, e.body, e.private), ('m-1', 'mine', true));
      expect(await a.entryIds('a-1'), {'ea1'});
      // included, it is part of the share like any notebook
      await a.conn.setIncluded('m-1', true);
      await a.sync();
      expect(a.folder.text.keys.where((k) => k.startsWith('m-1/')), isNotEmpty);
    });
  });

  group('deleting a notebook (the tombstone, through the connections that main.dart wires)', () {
    Future<(Dev, Dev, ShareLink)> pair() async {
      final a = await started('a');
      final b = await started('b');
      await a.make('Hikes', id: 'a-1');
      await a.make('Other', id: 'a-2');
      await a.add('a-1', 'ea1', 'Alpha');
      final link = ShareLink(a.folder, b.folder);
      await rounds([a, b], [link]);
      expect(await b.entryIds('a-1'), {'ea1'});
      return (a, b, link);
    }

    test('the deleting device leaves a tombstone and takes the notebook\'s files out; the other device deletes it too', () async {
      final (a, b, link) = await pair();
      await a.nb.deleteNotebook('a-1');
      await rounds([a, b], [link]);
      final t = jsonDecode(a.folder.text['a-1/notebook.json']!) as Map;
      expect((t['format'], t['id'], t['deleted']), (2, 'a-1', true));
      expect(a.folder.text.keys.where((k) => k.startsWith('a-1/') && k != 'a-1/notebook.json'), isEmpty, reason: 'no .cnote left');
      expect(b.folder.text.keys.where((k) => k.startsWith('a-1/') && k != 'a-1/notebook.json'), isEmpty);
      expect(b.ids('Hikes'), isEmpty, reason: 'deleted on the other device through the normal delete');
      expect(await b.nb.entry('ea1'), isNull);
      expect(b.ids('Other'), ['a-2']);
      // the tombstone is not undone by the next sync, and goes after 30 days
      await rounds([a, b], [link], n: 2);
      expect(b.ids('Hikes'), isEmpty);
      expect(a.ids('Hikes'), isEmpty);
    });

    test('a notebook changed here since the last sync is kept, and its folder is written again over the tombstone', () async {
      final (a, b, link) = await pair();
      await b.nb.saveEntry(id: 'eb1', notebookId: 'a-1', occurredAt: '2026-11-02T09:00:00-07:00', title: 'Made here', body: 'new');
      await a.nb.deleteNotebook('a-1');
      await a.sync();
      link.sync();
      await b.sync();
      expect(b.ids('Hikes'), ['a-1'], reason: 'changed here: kept');
      expect(await b.entryIds('a-1'), {'ea1', 'eb1'});
      await rounds([a, b], [link], n: 4);
      for (final d in [a, b]) {
        expect(d.ids('Hikes'), ['a-1'], reason: '${d.label}: it is back where the delete was');
        expect(await d.entryIds('a-1'), {'ea1', 'eb1'}, reason: d.label);
      }
      expect(jsonDecode(a.folder.text['a-1/notebook.json']!)['deleted'], isNull);
    });

    test('a private notebook that is not included is untouched by a tombstone of the same id', () async {
      final (a, b, link) = await pair();
      await b.conn.setIncluded('a-1', false);
      await b.nb.saveNotebook(id: 'a-1', def: b.nb.notebook('a-1')!.def, private: true);
      await a.nb.deleteNotebook('a-1');
      await rounds([a, b], [link], n: 3);
      expect(b.ids('Hikes'), ['a-1']);
      expect(await b.entryIds('a-1'), {'ea1'});
    });

    test('the tombstone goes after 30 days, and a notebook consumed by then does not come back', () async {
      var now = DateTime(2026, 11, 10, 9);
      final a = Dev('a', clock: () => now);
      final b = Dev('b', clock: () => now);
      await a.boot();
      await b.boot();
      await a.make('Hikes', id: 'a-1');
      await a.make('Other', id: 'a-2');
      final link = ShareLink(a.folder, b.folder);
      await rounds([a, b], [link]);
      await a.nb.deleteNotebook('a-1');
      await rounds([a, b], [link]);
      expect(b.ids('Hikes'), isEmpty);
      now = now.add(const Duration(days: 31));
      await rounds([a, b], [link]);
      expect(a.folder.text.containsKey('a-1/notebook.json'), isFalse);
      expect(a.ids('Hikes'), isEmpty);
      expect(b.ids('Hikes'), isEmpty);
    });
  });

  group('a newer format', () {
    test('a record with a format this version does not know stops notebook sync and says why', () async {
      final a = await started('a');
      await a.make('Hikes', id: 'a-1');
      await a.add('a-1', 'ea1', 'Alpha');
      a.folder.text['zzz/notebook.json'] = jsonEncode({'format': 3, 'id': 'zzz', 'name': 'Future'});
      final before = {...a.folder.text};
      await a.sync();
      expect(a.conn.formatBlocked, isTrue);
      expect(a.conn.sharingNote, kUpdateNeededNote);
      expect(a.conn.status('share'), kUpdateNeededNote);
      expect(a.folder.text, before, reason: 'nothing was written or removed');
      a.folder.text.remove('zzz/notebook.json');
      await a.sync();
      expect(a.conn.formatBlocked, isFalse);
      expect(a.conn.sharingNote, isNull);
    });
  });

  group('notebook id changes are queued and journaled', () {
    // Hikes and Trips are the same notebooks on both devices (higher ids on b): b has to take a's ids.
    Future<(Dev, Dev, ShareLink)> pair({bool private = false}) async {
      final a = await started('a');
      final b = await started('b');
      a.on = false;
      b.on = false;
      await a.make('Hikes', id: 'a-1', private: private);
      await a.make('Trips', id: 'a-3');
      await b.make('Hikes', id: 'b-2', private: private);
      await b.make('Trips', id: 'b-4');
      if (private) {
        await a.conn.setIncluded('a-1', true);
        await b.conn.setIncluded('b-2', true);
      }
      await a.add('a-1', 'ea1', 'Alpha');
      await b.add('b-2', 'eb1', 'Beta');
      await b.add('b-4', 'eb2', 'Gamma');
      a.on = true;
      b.on = true;
      File('${b.stateDir.path}/share2.json').writeAsStringSync(jsonEncode({'props': {'b-2': {'f1': 'distance'}}}));
      final link = ShareLink(a.folder, b.folder);
      await a.sync();
      link.sync();
      return (a, b, link);
    }

    for (final kill in ['core', 'private sharing', 'field names']) {
      test('killed in the $kill step: the next start replays the queue before any sync, and everything is intact', () async {
        final (a, b, link) = await pair(private: true);
        var failed = false;
        switch (kill) {
          case 'core':
            b.store.failOpNext = 'notebook_reid';
          case 'private sharing':
            b.nb.privateSharing = _FlakyPrivate(b.conn, () => failed = true, () => failed);
          case 'field names':
            final real = b.nb.reidSteps['field names']!;
            b.nb.reidSteps['field names'] = (o, n) async {
              if (!failed) {
                failed = true;
                throw StateError('killed');
              }
              await real(o, n);
            };
        }
        await b.sync();
        expect(b.reidFile.existsSync(), isTrue, reason: 'the journal stays until every step saved');
        expect(b.nb.replayError, isNotNull);
        expect(b.conn.sharingNote, contains('paused'));
        b.restart();
        await b.boot();
        expect(b.reidFile.existsSync(), isFalse);
        expect(b.ids('Hikes'), ['a-1']);
        expect(b.conn.included('a-1'), isTrue, reason: 'the private notebook is still included in the share');
        expect(b.conn.included('b-2'), isFalse);
        final props = (jsonDecode(File('${b.stateDir.path}/share2.json').readAsStringSync()) as Map)['props'] as Map;
        expect(props['a-1'], {'f1': 'distance'});
        expect(props.containsKey('b-2'), isFalse);
        await rounds([a, b], [link], n: 4);
        for (final d in [a, b]) {
          expect(d.ids('Hikes'), ['a-1'], reason: d.label);
          expect(await d.entryIds('a-1'), {'ea1', 'eb1'}, reason: d.label);
        }
      });
    }

    test('a failure in the middle of a sync pauses notebook sync; the next sync finishes it and the next change, both complete', () async {
      final (a, b, link) = await pair();
      b.store.failOpNext = 'notebook_reid';
      await b.sync();
      expect(b.nb.replayError, isNotNull, reason: 'a change that failed mid-session pauses notebook sync, visibly');
      expect(b.conn.status('share'), 'Paused.');
      expect(b.conn.sharingNote, isNotNull);
      expect(b.reidFile.existsSync(), isTrue);
      // the next sync replays what failed and goes on to the next change
      await b.sync();
      expect(b.nb.replayError, isNull);
      expect(b.conn.sharingNote, isNull);
      expect(b.reidFile.existsSync(), isFalse);
      await rounds([a, b], [link], n: 4);
      for (final d in [a, b]) {
        expect(d.ids('Hikes'), ['a-1'], reason: d.label);
        expect(d.ids('Trips'), ['a-3'], reason: d.label);
        expect(await d.entryIds('a-1'), {'ea1', 'eb1'});
        expect(await d.entryIds('a-3'), {'eb2'});
      }
    });

    test('changes queued behind one that failed are all finished by one replay, in order', () async {
      final r = await started('r');
      await r.make('One', id: 'o-1');
      await r.make('Two', id: 't-1');
      r.store.failOpNext = 'notebook_reid';
      await expectLater(r.nb.reidNotebook('o-1', 'o-0'), throwsA(anything));
      expect(r.nb.replayError, isNotNull);
      r.store.failOpNext = 'notebook_reid';
      await expectLater(r.nb.reidNotebook('t-1', 't-0'), throwsA(anything), reason: 'the queue does not skip ahead');
      expect(jsonDecode(r.reidFile.readAsStringSync())['items'], hasLength(2));
      r.nb.reidSteps.clear();
      await r.nb.replayReid();
      expect(r.nb.replayError, isNull);
      expect(r.reidFile.existsSync(), isFalse);
      expect({for (final n in r.nb.notebooks) n.id}, {'o-0', 't-0'});
    });

    test('a journal that cannot be read is kept, and notebook sync waits', () async {
      final (a, b, _) = await pair();
      b.store.failOpNext = 'notebook_reid';
      await b.sync();
      final good = b.reidFile.readAsStringSync();
      b.reidFile.writeAsStringSync('{broken');
      b.restart();
      await b.boot();
      expect(b.nb.replayError, isNotNull);
      expect(b.reidFile.readAsStringSync(), '{broken', reason: 'not dropped');
      expect(b.conn.sharingNote, contains('paused'));
      b.reidFile.writeAsStringSync(good);
      await b.sync();
      expect(b.nb.replayError, isNull);
      expect(a.nb.notebooks.length, 2);
    });
  });
}

/// Private sharing that fails once when told of a notebook id change (the app killed there), then works.
class _FlakyPrivate implements PrivateSharing {
  _FlakyPrivate(this.inner, this.fail, this.failed);

  final PrivateSharing inner;
  final void Function() fail;
  final bool Function() failed;

  @override
  bool included(String notebookId) => inner.included(notebookId);

  @override
  Future<void> setIncluded(String notebookId, bool on) => inner.setIncluded(notebookId, on);

  @override
  Future<void> notebookReid(String oldId, String newId) async {
    if (!failed()) {
      fail();
      throw StateError('killed in private sharing');
    }
    await inner.notebookReid(oldId, newId);
  }
}
