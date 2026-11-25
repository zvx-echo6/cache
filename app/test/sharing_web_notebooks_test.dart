// The Notebooks kind in a browser (L4 slice 6c): the private notebooks' "Include in sync and sharing" switches are Cache Server's
// (its notebook sync keeps them), so the page lists every notebook with its switch as on a phone, a switch goes to the server
// (`sharing.set_private`), and nothing changes on a phone, whose switches stay NotebookConnections'.

import 'dart:io';

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/sync/sync_engine.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/sharing/server_private_sharing.dart';
import 'package:cache/sharing/share_items.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart' show testPolicy;
import 'support/notebook_fake.dart';
import 'support/sharing_host_fake.dart';

Future<Notebook> _book(NotebookState nb, String name, {bool private = false}) =>
    nb.saveNotebook(template: 'notes', def: NotebookDef(name: name, fields: const [], sort: NotebookSort.recent), private: private);

class _Rig {
  _Rig(this.dir);

  final Directory dir;
  final host = FakeSharingHost(table: {'notebooks': {'notebooks': '/srv/nb'}})..enabled = true;
  late final NotebookState nb;
  late final SharingState s;
  late Notebook camp, health;

  Future<void> start() async {
    nb = fakeNotebook(FakeNotebookBackend());
    await nb.start();
    camp = await _book(nb, 'Camp notes');
    health = await _book(nb, 'Health log', private: true);
    final kind = DataKind(
      id: 'notebooks',
      label: 'Notebooks',
      icon: Icons.book_outlined,
      shared: () => const {'notebooks': null},
      items: () => notebookItems(nb),
      remoteItem: notebookRemoteItem,
      setPrivate: (it, on) => setNotebookShared(nb, it, on),
    );
    s = SharingState(policy: testPolicy(), supportDir: () async => dir, kinds: [kind], remote: host);
    nb.privateSharing = ServerPrivateSharing(s);
    await s.init();
  }

  DataKind get kind => s.kinds.single;
  ShareItem item(Notebook n) => notebookItems(nb).firstWhere((i) => i.path == NotebookSync.folderNameOf(n));
}

void main() {
  late Directory dir;
  late _Rig r;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sharing-web-nb');
    r = _Rig(dir);
    await r.start();
  });
  tearDown(() {
    r.s.dispose();
    dir.deleteSync(recursive: true);
  });

  test('the Notebooks kind is listed in a browser, with every notebook and the private one\'s switch off', () {
    expect(r.s.shareKinds.map((k) => k.id), ['notebooks']);
    final items = notebookItems(r.nb);
    expect(items.firstWhere((i) => i.name == 'Health log').private, isTrue);
    expect(items.firstWhere((i) => i.name == 'Health log').on, isFalse);
    expect({for (final i in items) i.name: (i.private, i.on)}, containsPair('Camp notes', (false, null)),
        reason: 'a notebook that is not private has no switch of this kind; a private one starts off');
  });

  test('the private notebook\'s switch is the server\'s: it comes back with the state, and a switch is sent as sharing.set_private', () async {
    await r.s.setShared(r.kind, true);
    expect(r.s.itemOn(r.kind, r.item(r.health)), isFalse);

    await r.s.setItem(r.kind, r.item(r.health), true);
    final i = r.host.ops.lastIndexOf('sharing.set_private');
    expect(r.host.opArgs[i], {'notebook': r.health.id, 'on': true});
    expect(r.host.privateIncluded, {r.health.id});
    expect(r.s.itemOn(r.kind, r.item(r.health)), isTrue, reason: 'read back from the server\'s state');
    expect(r.item(r.health).on, isTrue);
    expect(r.host.count('sharing.set_item'), 0, reason: 'a private item is not in the host\'s off list: its own switch is');

    await r.s.setItem(r.kind, r.item(r.health), false);
    expect(r.host.privateIncluded, isEmpty);
    expect(r.s.itemOn(r.kind, r.item(r.health)), isFalse);
  });

  test('a private notebook switched on while the kind is off shares the kind with it, every other item as it is', () async {
    expect(r.s.kindOn(r.kind), isFalse);
    await r.s.setItem(r.kind, r.item(r.health), true);
    expect(r.host.privateIncluded, {r.health.id});
    final i = r.host.ops.lastIndexOf('sharing.set_item');
    expect(r.host.opArgs[i]['all'], containsAll([r.item(r.camp).key]), reason: 'every item of the kind but the private ones');
    expect(r.s.kindOn(r.kind), isTrue);
    expect(r.s.itemOn(r.kind, r.item(r.health)), isTrue);
    expect(r.s.itemOn(r.kind, r.item(r.camp)), isFalse, reason: 'the kind was switched on with that item alone');
  });

  test('the notebook editor\'s "Include in sync and sharing" works in a browser: it reaches the server', () async {
    final ps = r.nb.privateSharing!;
    expect(ps.included(r.health.id), isFalse);
    await ps.setIncluded(r.health.id, true);
    expect(ps.included(r.health.id), isTrue);
    expect(r.host.privateIncluded, {r.health.id});
  });

  test('on a phone nothing changes: the private notebooks are NotebookConnections\' and the notebook items read them', () async {
    final phone = fakeNotebook(FakeNotebookBackend());
    await phone.start();
    final p = await _book(phone, 'Medical', private: true);
    ShareItem med() => notebookItems(phone).firstWhere((i) => i.name == 'Medical');
    expect(med().on, isFalse, reason: 'no switch kept: off');
    final ps = _Kept();
    phone.privateSharing = ps;
    expect(med().on, isFalse);
    await setNotebookShared(phone, med(), true);
    expect(ps.ids, {p.id});
    expect(med().on, isTrue);
  });
}

class _Kept implements PrivateSharing {
  final Set<String> ids = {};

  @override
  bool included(String notebookId) => ids.contains(notebookId);

  @override
  Future<void> setIncluded(String notebookId, bool on) async => on ? ids.add(notebookId) : ids.remove(notebookId);
}
