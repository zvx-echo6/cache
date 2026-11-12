import 'package:flutter_test/flutter_test.dart';

import 'support/share_rig.dart';

/// An entry edited on one device between the two devices' updates (the third review's N1): the edit is not lost to the older text of
/// the device that updates later.
Future<void> rounds(List<Dev> devs, ShareLink link, {int n = 4}) async {
  for (var i = 0; i < n; i++) {
    for (final d in devs) {
      await d.sync();
    }
    link.sync();
  }
}

Future<String?> bodyOf(Dev d, String nbId, String entryId) async => (await d.nb.entries(nbId)).where((e) => e.id == entryId).firstOrNull?.body;

void main() {
  for (final firstUpdated in ['b', 'a']) {
    test('N1. an entry edited on the device that updated first, before the other updates: the edit survives ($firstUpdated updates first)', () async {
      final a = Dev('a', old: true);
      final b = Dev('b', old: true);
      await a.boot();
      await b.boot();
      final link = ShareLink(a.folder, b.folder);
      link.open = () => a.old == b.old;
      await a.make('Hikes', id: 'a-1');
      await b.make('Hikes', id: 'b-2');
      await a.add('a-1', 'e1', 'Alpha', body: 'old text');
      await rounds([a, b], link);
      expect(await bodyOf(b, 'b-2', 'e1'), 'old text');
      final first = firstUpdated == 'b' ? b : a;
      final second = firstUpdated == 'b' ? a : b;
      final firstId = firstUpdated == 'b' ? 'b-2' : 'a-1';
      await first.updateCache();
      await first.sync();
      // the first device edits the entry; the second, still on the old version, has the old text
      await first.add(firstId, 'e1', 'Alpha', body: 'edited text');
      await first.sync();
      await second.updateCache();
      await second.sync();
      link.sync();
      await rounds([a, b], link, n: 6);
      for (final d in [a, b]) {
        expect(await bodyOf(d, d.ids('Hikes').single, 'e1'), 'edited text', reason: '${d.label}: the edit is kept');
      }
    });
  }

  test('N1b. an entry edited between the two updates and then deleted stays deleted, after more syncs and restarts (no old copy is left in a retired folder)', () async {
    final a = Dev('a', old: true);
    final b = Dev('b', old: true);
    await a.boot();
    await b.boot();
    final link = ShareLink(a.folder, b.folder);
    link.open = () => a.old == b.old;
    await a.make('Hikes', id: 'a-1');
    await b.make('Hikes', id: 'b-2');
    await a.add('a-1', 'e1', 'Ridge loop', body: 'old text');
    await a.add('a-1', 'e2', 'Creek walk', body: 'other');
    await rounds([a, b], link);
    await b.updateCache();
    await b.sync();
    await b.add('b-2', 'e1', 'Ridge loop', body: 'edited text');
    await b.sync();
    await a.updateCache();
    await a.sync();
    link.sync();
    await rounds([a, b], link, n: 6);
    final id = a.ids('Hikes').single;
    for (final d in [a, b]) {
      expect(await bodyOf(d, id, 'e1'), 'edited text', reason: d.label);
    }
    // the person deletes it; nothing of the old text may bring it back
    await b.nb.deleteEntry('e1');
    await rounds([a, b], link, n: 4);
    a.restart();
    await a.boot();
    b.restart();
    await b.boot();
    await rounds([a, b], link, n: 4);
    for (final d in [a, b]) {
      expect(await d.entryIds(id), {'e2'}, reason: '${d.label}: e1 stays deleted');
      expect([for (final e in d.folder.text.entries) if (e.key.endsWith('.cnote') && e.value.contains('cache_id: e1')) e.key], isEmpty, reason: '${d.label}: no copy of it is left in the share');
    }
  });
}
