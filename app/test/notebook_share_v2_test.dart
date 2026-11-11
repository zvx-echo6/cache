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

    test('with the gate unset (null) or inactive nothing is removed, however many syncs', () async {
      for (final unset in [true, false]) {
        final a = await started('a', old: true);
        await a.make('Hikes', id: 'a-1');
        await a.add('a-1', 'ea1', 'Alpha');
        await a.sync();
        a.gateUnset = unset;
        a.gateOn = false;
        await a.updateCache();
        await a.sync();
        await a.sync();
        await a.sync();
        expect(oldFiles(a.folder).length, 1, reason: unset ? 'gate unset' : 'gate inactive');
        expect(noteFiles(a.folder, 'a-1').length, 1, reason: 'the id layout is written all the same');
        expect(a.conn.conversionState, 'converting');
        expect(await a.entryIds('a-1'), {'ea1'});
      }
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

  group('what rel-1.1 added to entries and notebooks', () {
    test('an entry\'s colour, icon and on-map flag travel in the .cnote, and so do a notebook\'s icon and colour', () async {
      final a = await started('a');
      final b = await started('b');
      await a.nb.saveNotebook(id: 'p-1', template: 'places', def: const NotebookDef(name: 'Camps', fields: [], sort: NotebookSort.recent, icon: 'trailhead', color: 'teal'));
      await a.nb.saveEntry(
        id: 'ep1',
        notebookId: 'p-1',
        occurredAt: '2026-11-01T09:00:00-07:00',
        title: 'North camp',
        place: const NbPlace(lat: 43.6, lon: -116.2),
        props: {'color': 'orange', 'icon': 'tent', 'on_map': false},
      );
      final link = ShareLink(a.folder, b.folder);
      await rounds([a, b], [link]);
      final file = a.folder.text.entries.firstWhere((e) => e.key.startsWith('p-1/') && e.key.endsWith(kNoteExt)).value;
      expect(file, contains('cache_color: orange'));
      expect(file, contains('cache_icon: tent'));
      expect(file, contains('cache_on_map: false'));
      final e = (await b.nb.entry('ep1'))!;
      expect(e.props, {'color': 'orange', 'icon': 'tent', 'on_map': false});
      final nb = b.nb.notebook('p-1')!;
      expect((nb.def.icon, nb.def.color), ('trailhead', 'teal'));
      expect(jsonDecode(a.folder.text['p-1/notebook.json']!)['def'], containsPair('icon', 'trailhead'));
    });
  });

  group('a notebook\'s icon and colour travel like its name', () {
    Future<(Dev, Dev, ShareLink)> shared() async {
      final a = await started('a');
      final b = await started('b');
      await a.nb.saveNotebook(id: 'p-1', template: 'places', def: const NotebookDef(name: 'Camps', fields: [], sort: NotebookSort.recent, icon: 'trailhead', color: 'teal'));
      final link = ShareLink(a.folder, b.folder);
      await rounds([a, b], [link]);
      expect((b.nb.notebook('p-1')!.def.icon, b.nb.notebook('p-1')!.def.color), ('trailhead', 'teal'));
      return (a, b, link);
    }

    test('a change on one device arrives on the other, and a cleared icon too', () async {
      final (a, b, link) = await shared();
      await a.nb.saveNotebook(id: 'p-1', def: a.nb.notebook('p-1')!.def.copyWith(icon: 'tent', color: 'orange'));
      await rounds([a, b], [link], n: 3);
      expect((b.nb.notebook('p-1')!.def.icon, b.nb.notebook('p-1')!.def.color), ('tent', 'orange'));
      await b.nb.saveNotebook(id: 'p-1', def: b.nb.notebook('p-1')!.def.copyWith(clearIcon: true));
      await rounds([a, b], [link], n: 3);
      expect(a.nb.notebook('p-1')!.def.icon, isNull);
      expect(a.nb.notebook('p-1')!.def.color, 'orange');
    });

    test('an icon changed on one device and a colour on the other, and a rename, are all kept', () async {
      final (a, b, link) = await shared();
      await a.nb.saveNotebook(id: 'p-1', def: a.nb.notebook('p-1')!.def.copyWith(icon: 'tent'));
      await b.nb.saveNotebook(id: 'p-1', def: b.nb.notebook('p-1')!.def.copyWith(color: 'orange', name: 'Base camps'));
      await rounds([a, b], [link], n: 4);
      for (final d in [a, b]) {
        final n = d.nb.notebook('p-1')!;
        expect((n.name, n.def.icon, n.def.color), ('Base camps', 'tent', 'orange'), reason: d.label);
        expect(d.folder.text.keys.where((k) => k.contains('conflict')), isEmpty);
      }
    });

    test('two devices that change the same property get one answer', () async {
      final (a, b, link) = await shared();
      await a.nb.saveNotebook(id: 'p-1', def: a.nb.notebook('p-1')!.def.copyWith(color: 'orange'));
      await b.nb.saveNotebook(id: 'p-1', def: b.nb.notebook('p-1')!.def.copyWith(color: 'blue'));
      await rounds([a, b], [link], n: 4);
      expect(a.nb.notebook('p-1')!.def.color, b.nb.notebook('p-1')!.def.color);
      expect({'orange', 'blue'}, contains(a.nb.notebook('p-1')!.def.color));
    });

    test('a property a newer build added (a key with its _at) and a plain key survive a merge and a rewrite, whichever record wins on the name', () {
      final fields = [{'label': 'Distance', 'type': 'number'}];
      // an older build's record: no fields; its name is the later one
      NbRecord older({int nameAt = 500}) => NbRecord.live('x', nameAt: nameAt, body: {'name': 'Camps', 'def': {'name': 'Camps', 'future': 1}});
      NbRecord newer({int nameAt = 10, int fieldsAt = 100, Object? list}) =>
          NbRecord.live('x', nameAt: nameAt, body: {'name': 'Old name', 'fields': list ?? fields, 'fields_at': fieldsAt, 'note': 'kept'});
      for (final (a, b) in [(older(), newer()), (older(nameAt: 5), newer(nameAt: 50))]) {
        for (final order in [[a, b], [b, a]]) {
          final m = NbRecord.merge(order)!;
          expect(m.body['fields'], fields, reason: 'the list is not wiped by a record that has none');
          expect(m.body['fields_at'], 100);
          expect(m.body['note'], 'kept', reason: 'a key with no _at is kept');
          expect((m.body['def'] as Map)['future'], 1, reason: 'a def key this build does not know stays');
          // and a rewrite: written, read again, merged again, the same
          final again = NbRecord.merge([NbRecord.parse(m.text)!, a])!;
          expect(again.text, m.text);
          expect(again.body['fields'], fields);
        }
      }
      // two records with the pair: the later _at wins, a tie goes to the greater value
      final x = newer(fieldsAt: 200, list: [{'label': 'Miles'}]);
      expect(NbRecord.merge([older(), newer(), x])!.body['fields'], [{'label': 'Miles'}]);
      expect(NbRecord.merge([x, newer(), older()])!.body['fields_at'], 200);
      final t1 = newer(list: [{'label': 'A'}]), t2 = newer(list: [{'label': 'B'}]);
      expect(NbRecord.merge([t1, t2])!.body['fields'], NbRecord.merge([t2, t1])!.body['fields']);
      // a plain key the best record has wins over another's
      final p1 = NbRecord.live('x', nameAt: 9, body: {'name': 'N', 'extra': 'best'}), p2 = NbRecord.live('x', nameAt: 1, body: {'name': 'N', 'extra': 'other', 'more': 2});
      final pm = NbRecord.merge([p2, p1])!;
      expect((pm.body['extra'], pm.body['more']), ('best', 2));
    });

    test('equal times resolve the same way whichever order the records are met in', () {
      NbRecord rec(String? color, int at) => NbRecord.live('x', nameAt: 5, body: {'name': 'N', 'color': ?color, 'color_at': at});
      final a = rec('orange', 100), b = rec('blue', 100), c = rec('teal', 90);
      for (final order in [[a, b, c], [c, b, a], [b, c, a], [a, c, b]]) {
        expect(NbRecord.merge(order)!.color, 'orange', reason: 'the later time first, then the greater value');
        expect(NbRecord.merge(order)!.colorAt, 100);
      }
      // a clear at the same time as a value: the value (null is least)
      expect(NbRecord.merge([rec(null, 100), rec('blue', 100)])!.color, 'blue');
      // the icon and the colour are merged apart
      final x = NbRecord.live('x', nameAt: 5, body: {'name': 'N', 'icon': 'tent', 'icon_at': 200, 'color': 'old', 'color_at': 1});
      final y = NbRecord.live('x', nameAt: 5, body: {'name': 'N', 'icon': 'old', 'icon_at': 1, 'color': 'orange', 'color_at': 300});
      final m = NbRecord.merge([x, y])!;
      expect((m.icon, m.color), ('tent', 'orange'));
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
