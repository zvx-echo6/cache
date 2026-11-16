// Photos leave only for an entry of a shared notebook: every notebook keeps its photos in one folder (photos/) of notebook sync's
// share, so the share's gate lists the photos something shared refers to, and the engine offers no other file of that folder.

import 'dart:io';

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/sync/sync_engine.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/sharing/share_items.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart' show testPolicy;
import 'support/notebook_fake.dart';
import 'support/sync_fake.dart';

class _Included implements PrivateSharing {
  final Set<String> ids = {};

  @override
  bool included(String notebookId) => ids.contains(notebookId);

  @override
  Future<void> setIncluded(String notebookId, bool on) async => on ? ids.add(notebookId) : ids.remove(notebookId);
}

Future<Notebook> _book(NotebookState nb, String name, {bool private = false}) async =>
    nb.saveNotebook(template: 'notes', def: NotebookDef(name: name, fields: const [], sort: NotebookSort.recent), private: private);

Future<void> _entry(NotebookState nb, Notebook book, String photo, {bool private = false}) =>
    nb.saveEntry(notebookId: book.id, occurredAt: '2026-11-16T09:00:00-07:00', title: 'e', photos: [NbPhoto(id: photo)], private: private);

void main() {
  late NotebookState nb;
  late Notebook shared, off;

  setUp(() async {
    nb = fakeNotebook(FakeNotebookBackend())..privateSharing = _Included();
    await nb.start();
    shared = await _book(nb, 'Camp notes');
    off = await _book(nb, 'Quokka Log');
  });

  Future<List<String>> toSend({List<String> offList = const ['Quokka Log']}) => notebookPhotosToSend(nb, offList);

  test('a photo in the entry of a notebook switched OFF is not sent', () async {
    await _entry(nb, off, 'aaaa');
    expect(await toSend(), isEmpty);
    expect(NotebookSync.photoPath('aaaa'), 'photos/cache-aaaa.jpg');
  });

  test('a photo in the entry of a SHARED notebook is sent, and only that one', () async {
    await _entry(nb, shared, 'bbbb');
    await _entry(nb, off, 'aaaa');
    expect(await toSend(), ['photos/cache-bbbb.jpg']);
  });

  test('a photo only a PRIVATE entry refers to is not sent; one a shared entry also refers to is', () async {
    await _entry(nb, shared, 'cccc', private: true);
    expect(await toSend(), isEmpty);
    await _entry(nb, shared, 'cccc');
    expect(await toSend(), ['photos/cache-cccc.jpg']);
  });

  test('a photo in a notebook switched from off to on starts to be sent; back to off, it stops', () async {
    await _entry(nb, off, 'aaaa');
    expect(await toSend(), isEmpty);
    expect(await toSend(offList: const []), ['photos/cache-aaaa.jpg']);
    expect(await toSend(), isEmpty);
  });

  test('a private notebook (its entries private) is sent only when it is included', () async {
    final medical = await _book(nb, 'Medical', private: true);
    await _entry(nb, medical, 'dddd', private: true);
    expect(await toSend(offList: const []), isEmpty);
    (nb.privateSharing! as _Included).ids.add(medical.id);
    expect(await toSend(offList: const []), ['photos/cache-dddd.jpg']);
  });

  test('the engine is given the gate at its start and again whenever the items switched off change', () async {
    await _entry(nb, shared, 'bbbb');
    await _entry(nb, off, 'aaaa');
    final dir = await Directory.systemTemp.createTemp('photo-gate');
    Directory('${dir.path}/notebook-share').createSync(recursive: true);
    final sync = FakeSync();
    final configs = <Map<String, Object?>>[];
    final kind = DataKind(
      id: 'notebooks',
      label: 'Notebooks',
      icon: Icons.book_outlined,
      shared: () => {'notebooks': Directory('${dir.path}/notebook-share')},
      items: () => [
        for (final n in nb.notebooks) ShareItem(share: 'notebooks', path: NotebookSync.folderNameOf(n), name: n.name),
      ],
      remoteItem: notebookRemoteItem,
      gated: const {'notebooks': 'photos'},
      allowed: (share, offList) => notebookPhotosToSend(nb, offList),
    );
    final s = SharingState(
      policy: testPolicy(wifi: true),
      supportDir: () async => dir,
      kinds: [kind],
      opener: (c) async {
        configs.add(c);
        return sync;
      },
    );
    await s.setUp();
    await s.setShared(kind, true);
    // Quokka Log is switched off from the start of this run.
    final quokka = s.itemsOf(kind).firstWhere((i) => i.item.name == 'Quokka Log').item;
    await s.setItem(kind, quokka, false);
    var gate = (sync.argsOf['set_gate'] ?? const []).last;
    expect(gate['dir'], 'photos');
    expect(gate['allow'], ['photos/cache-bbbb.jpg'], reason: 'the OFF notebook\'s photo is not allowed');

    await s.setItem(kind, quokka, true);
    gate = sync.argsOf['set_gate']!.last;
    expect(gate['allow'], ['photos/cache-aaaa.jpg', 'photos/cache-bbbb.jpg'], reason: 'switched on: its photo starts to go');

    // A photo made known after the start goes only when the gate is refreshed (what notebook sync does before it writes).
    final eeee = await nb.saveEntry(notebookId: shared.id, occurredAt: '2026-11-16T09:00:00-07:00', title: 'e', photos: [const NbPhoto(id: 'eeee')]);
    await s.refreshGate();
    expect(sync.argsOf['set_gate']!.last['allow'], contains('photos/cache-eeee.jpg'));
    // Private afterwards: refreshed, it is out again.
    await nb.saveEntry(id: eeee.id, notebookId: shared.id, occurredAt: eeee.occurredAt, title: 'e', photos: [const NbPhoto(id: 'eeee')], private: true);
    await s.refreshGate();
    expect(sync.argsOf['set_gate']!.last['allow'], isNot(contains('photos/cache-eeee.jpg')));
    s.dispose();
  });
}
