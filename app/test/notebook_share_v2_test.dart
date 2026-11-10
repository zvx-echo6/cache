import 'dart:convert';
import 'dart:io';

import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/sync/share_format.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/share_rig.dart';

/// Format 2 of the notebooks share: each notebook in `<id>/`, the one-time convergence of ids, and format 1 kept beside it for
/// devices that only know that (builds up to 1.0.30). Every test syncs through the simulated share (ShareLink), as cache_sync does.
typedef Run = Future<void> Function();

void exchange(List<Dev> all, {Set<String> old = const {}}) {
  for (final d in all) {
    d.peers = {for (final o in all) if (o != d) o.label: o.advertised, for (final o in old) o: null};
  }
}

/// [n] rounds: every device syncs (seeing what the others last said about themselves), then the share carries; then one more sync.
Future<void> rounds(List<Dev> devs, List<ShareLink> links, {int n = 3, List<Run> others = const [], Set<String> old = const {}}) async {
  for (var i = 0; i < n; i++) {
    for (final d in devs) {
      exchange([...devs], old: old);
      await d.sync();
    }
    for (final o in others) {
      await o();
    }
    for (final l in links) {
      l.sync();
    }
  }
  for (final d in devs) {
    exchange([...devs], old: old);
    await d.sync();
  }
}

Set<String> mdFiles(MemFolder f) => {for (final k in f.text.keys) if (k.endsWith('.md')) k};
Set<String> noteFiles(MemFolder f, String dir) => {for (final k in f.text.keys) if (k.startsWith('$dir/') && k.endsWith(kNoteExt)) k};

Future<Dev> started(String label, {DateTime Function()? clock}) async {
  final d = Dev(label, clock: clock);
  await d.boot();
  return d;
}

void main() {
  group('two devices that both upgrade', () {
    test('ids converge on the lowest by exact name, nothing is lost, and format 1 goes once both have said format 2', () async {
      final a = await started('a');
      final b = await started('b');
      await a.make('Hikes', id: 'a-1');
      await a.add('a-1', 'ea1', 'Alpha');
      await b.make('Hikes', id: 'b-2');
      await b.add('b-2', 'eb1', 'Beta');
      await b.make('Trips', id: 'b-3');
      await b.add('b-3', 'eb2', 'Gamma');
      final link = ShareLink(a.folder, b.folder);
      // before the upgrade: the format 1 sync, as every build to 1.0.30 does it
      for (var i = 0; i < 2; i++) {
        await a.oldSync();
        await b.oldSync();
        link.sync();
      }
      await a.oldSync();
      await b.oldSync();
      expect(await a.entryIds('a-1'), {'ea1', 'eb1'});
      expect(await b.entryIds('b-2'), {'ea1', 'eb1'});
      final aTrips = a.ids('Trips').single;
      // the upgrade
      await rounds([a, b], [link], n: 4);
      for (final d in [a, b]) {
        expect(d.ids('Hikes'), ['a-1'], reason: '${d.label}: the lowest id for the name');
        expect(await d.entryIds('a-1'), {'ea1', 'eb1'}, reason: '${d.label}: entries intact');
        expect(d.ids('Trips').single, ([aTrips, 'b-3']..sort()).first, reason: '${d.label}: one Trips with the lower id');
        expect(await d.entryIds(d.ids('Trips').single), {'eb2'});
        expect(d.nb.notebooks.length, 2, reason: 'no notebook was made twice');
      }
      expect(jsonDecode(a.folder.text['a-1/notebook.json']!)['name'], 'Hikes');
      expect(jsonDecode(a.folder.text['b-2/notebook.json']!)['alias_of'], 'a-1', reason: 'the folder of the higher id is an alias, its entries stay');
      // both said format 2 and then that they stopped format 1: the format 1 folders are gone, with no tombstone
      for (final d in [a, b]) {
        expect(d.conn.legacyState, 'cleaned', reason: d.label);
        expect(mdFiles(d.folder), isEmpty, reason: '${d.label}: no format 1 folder left');
        expect(d.folder.text.values.where((t) => t.contains('"deleted"')), isEmpty);
      }
      // what is there now is stable
      final before = [{...a.folder.text}, {...b.folder.text}];
      await rounds([a, b], [link], n: 2);
      expect(a.folder.text, before[0]);
      expect(b.folder.text, before[1]);
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
      expect({for (final k in a.folder.text.keys.where((k) => k.endsWith('notebook.json'))) k.split('/').first}, {'a-1', 'a-2'});
      for (final d in [a, b]) {
        expect(d.ids('Trip: 2026'), ['a-1'], reason: d.label);
        expect(d.ids('Trip 2026'), ['a-2'], reason: d.label);
        expect(await d.entryIds('a-1'), {'ea1'});
        expect(await d.entryIds('a-2'), {'ea2'});
      }
    });

    test('renames made on both devices at once converge on one name', () async {
      final a = await started('a');
      final b = await started('b');
      await a.make('Hikes', id: 'a-1');
      await a.add('a-1', 'ea1', 'Alpha');
      final link = ShareLink(a.folder, b.folder);
      await rounds([a, b], [link]);
      expect(b.ids('Hikes'), ['a-1']);
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
      }
      expect(jsonDecode(a.folder.text['a-1/notebook.json']!)['name'], names.single);
      // a rename moves nothing: the entry is where it was
      expect(noteFiles(a.folder, 'a-1').length, 1);
    });

    test('a rename edits the record only: the folder and the entries stay, nothing is deleted on the other device', () async {
      final a = await started('a');
      final b = await started('b');
      await a.make('Hikes', id: 'a-1');
      await a.add('a-1', 'ea1', 'Alpha');
      final link = ShareLink(a.folder, b.folder);
      await rounds([a, b], [link]);
      final files = noteFiles(a.folder, 'a-1');
      await a.nb.saveNotebook(id: 'a-1', def: a.nb.notebook('a-1')!.def.copyWith(name: 'Trips'));
      await rounds([a, b], [link]);
      expect(b.nb.notebook('a-1')!.name, 'Trips');
      expect(await b.entryIds('a-1'), {'ea1'});
      expect(noteFiles(a.folder, 'a-1'), files);
      expect(noteFiles(b.folder, 'a-1'), files);
    });
  });

  group('one device upgraded, one not', () {
    test('no deletes either side; the old device gets the new one\'s edits through format 1; format 1 stays', () async {
      final n = await started('new');
      final o = await started('old');
      await n.make('Hikes', id: 'n-1');
      await n.add('n-1', 'en1', 'Alpha', body: 'first');
      await o.make('Hikes', id: 'o-9');
      await o.add('o-9', 'eo1', 'Beta');
      final link = ShareLink(n.folder, o.folder);
      // before the upgrade both are old
      for (var i = 0; i < 2; i++) {
        await n.oldSync();
        await o.oldSync();
        link.sync();
      }
      await n.oldSync();
      await o.oldSync();
      expect(await o.entryIds('o-9'), {'en1', 'eo1'});
      // the new device upgrades (the other says nothing about itself: it is an older version)
      Future<void> go(int count) => rounds([n], [link], n: count, others: [() => o.oldSync()], old: {'old'});
      await go(3);
      expect(n.conn.legacyState, 'on', reason: 'a device that has not said format 2');
      expect(n.advertised, {'notebook_format': 2, 'notebook_legacy': true});
      expect(await n.entryIds('n-1'), {'en1', 'eo1'});
      expect(await o.entryIds('o-9'), {'en1', 'eo1'});
      expect(n.nb.notebooks.length, 1);
      expect(o.nb.notebooks.length, 1, reason: 'the old device made no second notebook from the format 2 folders');
      expect(noteFiles(n.folder, 'n-1').length, 2, reason: 'format 2 has both entries');
      expect(mdFiles(n.folder).length, 2, reason: 'format 1 is kept current: both entries are in the name folder');
      // an edit on the new device reaches the old one through the name folder
      await n.nb.saveEntry(id: 'en1', notebookId: 'n-1', occurredAt: '2026-11-01T09:00:00-07:00', title: 'Alpha', body: 'edited on the new device');
      await go(3);
      expect((await o.nb.entry('en1'))!.body, 'edited on the new device');
      // a new entry on the old device reaches the new one
      await o.nb.saveEntry(id: 'eo2', notebookId: 'o-9', occurredAt: '2026-11-02T09:00:00-07:00', title: 'Delta', body: 'from the old device');
      await go(3);
      expect((await n.nb.entry('eo2'))!.body, 'from the old device');
      expect(noteFiles(n.folder, 'n-1').length, 3);
      // a delete on the old device is a delete; a delete on the new one too
      await o.nb.deleteEntry('eo1');
      await go(3);
      expect(await n.entryIds('n-1'), {'en1', 'eo2'});
      expect(noteFiles(n.folder, 'n-1').length, 2);
      await n.nb.deleteEntry('en1');
      await go(3);
      expect(await o.entryIds('o-9'), {'eo2'});
      // nothing else was lost, and format 1 is still kept
      expect(await n.entryIds('n-1'), {'eo2'});
      expect(n.conn.legacyState, 'on');
      expect(mdFiles(n.folder).length, 1);
    });

    test('a device that links after the format 1 folders were removed brings them back, without deleting anything', () async {
      final a = await started('a');
      final b = await started('b');
      await a.make('Hikes', id: 'a-1');
      await a.add('a-1', 'ea1', 'Alpha');
      await b.make('Hikes', id: 'a-1');
      final ab = ShareLink(a.folder, b.folder);
      await rounds([a, b], [ab], n: 4);
      expect(a.conn.legacyState, 'cleaned');
      expect(mdFiles(a.folder), isEmpty);
      // an old device links to a
      final o = await started('old');
      final ao = ShareLink(a.folder, o.folder);
      for (var i = 0; i < 3; i++) {
        exchange([a, b]);
        a.peers = {'b': b.advertised, 'old': null};
        await a.sync();
        await o.oldSync();
        ao.sync();
        ab.sync();
      }
      expect(a.conn.legacyState, 'on');
      expect(await a.entryIds('a-1'), {'ea1'}, reason: 'nothing was deleted by the folders coming back');
      expect(mdFiles(a.folder).length, 1);
      expect(await o.entryIds(o.ids('Hikes').single), {'ea1'});
    });
  });

  group('after both devices are on format 2', () {
    test('two notebooks made with one name stay two, here and on the other device, each with its own entries', () async {
      final a = await started('a');
      final b = await started('b');
      final link = ShareLink(a.folder, b.folder);
      // both devices are on format 2 and have synced once
      await rounds([a, b], [link], n: 2);
      await a.make('Shopping', id: 's-1');
      await a.add('s-1', 'ea1', 'Milk');
      await b.make('Shopping', id: 's-2');
      await b.add('s-2', 'eb1', 'Bread');
      await rounds([a, b], [link], n: 4);
      for (final d in [a, b]) {
        expect({for (final n in d.nb.notebooks) n.id}, {'s-1', 's-2'}, reason: '${d.label}: two notebooks, by id');
        expect(await d.entryIds('s-1'), {'ea1'}, reason: d.label);
        expect(await d.entryIds('s-2'), {'eb1'}, reason: d.label);
      }
      expect(a.nb.notebook('s-1')!.name, 'Shopping');
      expect(b.nb.notebook('s-2')!.name, 'Shopping');
      expect(a.nb.notebook('s-2')!.name, startsWith('Shopping ('), reason: 'the other one is kept apart by its id');
      expect(jsonDecode(a.folder.text['s-2/notebook.json']!)['name'], 'Shopping', reason: 'the record keeps its name');
      // stable
      final before = [{...a.folder.text}, {...b.folder.text}];
      await rounds([a, b], [link], n: 2);
      expect(a.folder.text, before[0]);
      expect(b.folder.text, before[1]);
      expect(a.nb.notebooks.length, 2);
      expect(b.nb.notebooks.length, 2);
    });
  });

  group('a notebook an old device makes', () {
    test('two upgraded devices that get it from the old one end with one notebook id and no duplicates', () async {
      final o = await started('old');
      final n1 = await started('n1');
      final n2 = await started('n2');
      await o.make('Camps', id: 'o-5');
      await o.add('o-5', 'eo1', 'Ridge camp');
      final on1 = ShareLink(o.folder, n1.folder);
      final n12 = ShareLink(n1.folder, n2.folder);
      Future<void> go(int n) async {
        for (var i = 0; i < n; i++) {
          exchange([n1, n2], old: {'old'});
          n1.peers = {'n2': n2.advertised, 'old': null};
          await n1.sync();
          n2.peers = {'n1': n1.advertised};
          await n2.sync();
          await o.oldSync();
          on1.sync();
          n12.sync();
        }
      }

      await go(5);
      expect(n1.ids('Camps').length, 1);
      expect(n2.ids('Camps').length, 1);
      expect(n1.ids('Camps'), n2.ids('Camps'), reason: 'the same id on both upgraded devices');
      expect(await n1.entryIds(n1.ids('Camps').single), {'eo1'});
      expect(await n2.entryIds(n2.ids('Camps').single), {'eo1'});
      expect(o.nb.notebooks.length, 1, reason: 'the old device made no second notebook');
      expect(await o.entryIds('o-5'), {'eo1'});
      expect(n1.nb.notebooks.length, 1);
      expect(n2.nb.notebooks.length, 1);
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
      expect(await a.entryIds('a-1'), {'ea1'});
      // once it is not there, notebooks sync again
      a.folder.text.remove('zzz/notebook.json');
      await a.sync();
      expect(a.conn.formatBlocked, isFalse);
      expect(a.conn.sharingNote, isNull);
      expect(a.folder.text.containsKey('a-1/notebook.json'), isTrue);
    });
  });

  group('private notebooks and a lone device', () {
    test('a private notebook that is not included writes nothing, is never matched by name and is never touched', () async {
      final a = await started('a');
      final b = await started('b');
      final meds = await a.make('Meds', id: 'm-1', private: true);
      await a.add(meds.id, 'em1', 'Private');
      await b.make('Meds', id: 'm-2');
      await b.add('m-2', 'em2', 'Other');
      final link = ShareLink(a.folder, b.folder);
      await rounds([a, b], [link], n: 4);
      expect(a.ids('Meds'), ['m-1']);
      expect(await a.entryIds('m-1'), {'em1'});
      expect(a.folder.text.keys.where((k) => k.startsWith('m-1/')), isEmpty);
      expect(b.ids('Meds'), ['m-2']);
      expect(await b.entryIds('m-2'), {'em2'});
      // included, it joins the share like any other
      a.on = false;
      await a.conn.setIncluded('m-1', true);
      a.on = true;
      await rounds([a, b], [link], n: 4);
      expect(a.ids('Meds'), ['m-1'], reason: 'the lower id');
      expect(b.ids('Meds'), ['m-1']);
      expect(await b.entryIds('m-1'), {'em1', 'em2'});
    });

    test('a single device with no peer: format 1 folders become the layout and nothing else changes, then it is stable', () async {
      final a = await started('a');
      await a.make('Hikes', id: 'a-1');
      await a.add('a-1', 'ea1', 'Alpha');
      await a.make('Trips', id: 'a-2');
      await a.add('a-2', 'ea2', 'Beta');
      await a.oldSync();
      expect(mdFiles(a.folder).length, 2);
      a.peers = {};
      await a.sync();
      expect(a.conn.legacyState, 'cleaned');
      expect(mdFiles(a.folder), isEmpty);
      expect(noteFiles(a.folder, 'a-1').length, 1);
      expect(noteFiles(a.folder, 'a-2').length, 1);
      expect(await a.entryIds('a-1'), {'ea1'});
      expect(await a.entryIds('a-2'), {'ea2'});
      expect(a.nb.notebooks.length, 2);
      final before = {...a.folder.text};
      await a.sync();
      await a.sync();
      expect(a.folder.text, before);
    });

    test('while it is not known who is linked (sharing not running), format 1 stays', () async {
      final a = await started('a');
      await a.make('Hikes', id: 'a-1');
      await a.add('a-1', 'ea1', 'Alpha');
      await a.oldSync();
      a.peers = null;
      await a.sync();
      await a.sync();
      expect(a.conn.legacyState, 'on');
      expect(mdFiles(a.folder).length, 1);
    });
  });

  group('deleting a notebook', () {
    test('leaves a tombstone, the other device is told through the hook and keeps its entries, and the tombstone goes after 30 days', () async {
      var now = DateTime(2026, 11, 10, 9);
      final a = await started('a', clock: () => now);
      final b = await started('b', clock: () => now);
      await a.make('Hikes', id: 'a-1');
      await a.make('Other', id: 'a-2');
      await a.add('a-1', 'ea1', 'Alpha');
      final link = ShareLink(a.folder, b.folder);
      await rounds([a, b], [link]);
      expect(await b.entryIds('a-1'), {'ea1'});
      await a.nb.deleteNotebook('a-1');
      await rounds([a, b], [link]);
      final t = jsonDecode(a.folder.text['a-1/notebook.json']!) as Map;
      expect((t['format'], t['id'], t['deleted'], t['at']), (2, 'a-1', true, now.millisecondsSinceEpoch));
      expect(b.tombstones, isNotEmpty);
      expect(b.tombstones.first, 'a-1@${now.millisecondsSinceEpoch}');
      expect(b.ids('Hikes'), ['a-1'], reason: 'what a tombstone does here is for the hook, not for a missing file');
      expect(await b.entryIds('a-1'), {'ea1'});
      // whoever consumes the tombstone (the delete rule) removes the notebook here; the tombstone itself goes after 30 days
      await b.nb.deleteNotebook('a-1');
      now = now.add(const Duration(days: 31));
      await rounds([a, b], [link]);
      expect(a.folder.text.containsKey('a-1/notebook.json'), isFalse);
      expect(b.folder.text.containsKey('a-1/notebook.json'), isFalse);
      expect(a.ids('Hikes'), isEmpty);
      expect(b.ids('Hikes'), isEmpty);
    });
  });

  group('a notebook id change in the migration is journaled and resumable', () {
    // a-1 and b-2 are the same notebook ("Hikes", private and included on both); b has to take a-1.
    Future<(Dev, Dev, ShareLink)> pair() async {
      final a = await started('a');
      final b = await started('b');
      a.on = false;
      b.on = false;
      await a.make('Hikes', id: 'a-1', private: true);
      await a.conn.setIncluded('a-1', true);
      await a.add('a-1', 'ea1', 'Alpha');
      await b.make('Hikes', id: 'b-2', private: true);
      await b.conn.setIncluded('b-2', true);
      await b.add('b-2', 'eb1', 'Beta');
      final link = ShareLink(a.folder, b.folder);
      // b's field names, as its share state keeps them
      File('${b.stateDir.path}/share2.json').writeAsStringSync(jsonEncode({'props': {'b-2': {'f1': 'distance'}}}));
      File('${b.stateDir.path}/share.json').writeAsStringSync(jsonEncode({'props': {'b-2': {'f1': 'distance'}}}));
      a.on = true;
      b.on = true;
      // a's record first, so that b sees it in its first pass
      exchange([a, b]);
      await a.sync();
      link.sync();
      return (a, b, link);
    }

    for (final kill in ['core', 'private sharing', 'field names']) {
      test('killed in the $kill step: the next start replays the journal before any sync, and everything is intact', () async {
        final (a, b, link) = await pair();
        var failed = false;
        // the kill: the step that fails once, at the point of the test
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
        exchange([a, b]);
        await b.sync();
        expect(b.reidFile.existsSync(), isTrue, reason: 'the journal stays until every step saved');
        expect(jsonDecode(b.reidFile.readAsStringSync()), containsPair('new', 'a-1'));
        // a start again on the same files, wired and replayed as main.dart does it, before any notebook sync
        b.restart();
        await b.boot();
        expect(b.reidFile.existsSync(), isFalse);
        expect(b.ids('Hikes'), ['a-1']);
        expect(b.conn.included('a-1'), isTrue, reason: 'the private notebook is still included in the share');
        expect(b.conn.included('b-2'), isFalse);
        for (final f in ['share.json', 'share2.json']) {
          final props = (jsonDecode(File('${b.stateDir.path}/$f').readAsStringSync()) as Map)['props'] as Map;
          expect(props.keys, ['a-1'], reason: f);
          expect(props['a-1'], {'f1': 'distance'});
        }
        await rounds([a, b], [link], n: 4);
        for (final d in [a, b]) {
          expect(d.ids('Hikes'), ['a-1'], reason: d.label);
          expect(await d.entryIds('a-1'), {'ea1', 'eb1'}, reason: d.label);
        }
        expect(noteFiles(a.folder, 'a-1').length + noteFiles(a.folder, 'b-2').length, 2, reason: 'one file per entry, wherever it is');
      });
    }

    test('a replay that keeps failing does not stop the start: it is logged, the journal stays, sync waits and says so, and it is tried again', () async {
      final (a, b, _) = await pair();
      var broken = true;
      b.nb.reidSteps['probe'] = (o, n) async {
        if (broken) throw StateError('still failing');
      };
      exchange([a, b]);
      await b.sync();
      expect(b.reidFile.existsSync(), isTrue);
      b.restart();
      b.nb.reidSteps['probe'] = (o, n) async {
        if (broken) throw StateError('still failing');
      };
      await b.boot();
      expect(b.nb.replayError, isNotNull);
      expect(b.nb.notebooks.isNotEmpty, isTrue, reason: 'the start went on');
      expect(b.conn.sharingNote, contains('paused'));
      final before = {...b.folder.text};
      await b.sync();
      expect(b.folder.text, before, reason: 'notebook sync waits');
      expect(b.reidFile.existsSync(), isTrue);
      broken = false;
      await b.sync();
      expect(b.nb.replayError, isNull);
      expect(b.reidFile.existsSync(), isFalse);
      expect(b.conn.sharingNote, isNull);
      expect(b.ids('Hikes'), ['a-1']);
    });

    test('a corrupt connection file never loses the journal: the replay waits for it', () async {
      final (a, b, _) = await pair();
      b.nb.reidSteps['probe'] = (o, n) async => throw StateError('killed');
      exchange([a, b]);
      await b.sync();
      expect(b.reidFile.existsSync(), isTrue);
      File('${b.stateDir.path}/targets.json').writeAsStringSync('{not json');
      b.restart();
      await b.boot();
      expect(b.reidFile.existsSync(), isTrue, reason: 'the journal was not dropped');
      expect(b.nb.replayError, isNotNull);
      expect(b.conn.sharingNote, contains('settings could not be read'));
      await b.sync();
      expect(b.reidFile.existsSync(), isTrue);
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
