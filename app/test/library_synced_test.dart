// "Synced with another device" (owner's design for Delete, 2026-11-15): the book's own library is in a share that is on, and at
// least one linked device takes it (its link mode is not off). SharingState.libraryTakenByAnotherDevice answers it.

import 'dart:io';

import 'package:cache/settings/data_kinds.dart';
import 'package:cache/sharing/share_items.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart' show testPolicy;
import 'support/sync_fake.dart';

void main() {
  late Directory dir;
  late FakeSync sync;
  late DataKind library;
  late SharingState s;

  Map<String, dynamic> peer(String id, {Map<String, Object?>? link}) => {'id': id, 'name': id, 'linked': 1, 'last_seen': null, 'via': null, 'error': null, 'link': ?link};

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('library-synced');
    for (final d in ['zims', 'libraries']) {
      Directory('${dir.path}/$d').createSync();
    }
    sync = FakeSync();
    library = DataKind(
      id: 'library',
      label: 'Library',
      icon: Icons.menu_book_outlined,
      shared: () => {'library': Directory('${dir.path}/zims'), 'libraries': Directory('${dir.path}/libraries')},
      items: () => const [ShareItem(share: 'libraries', path: 'my-books', name: 'My books'), ShareItem(share: 'libraries', path: 'field', name: 'Field')],
      remoteItem: libraryRemoteItem,
    );
    s = SharingState(policy: testPolicy(wifi: true), supportDir: () async => dir, kinds: [library], opener: (_) async => sync);
  });
  tearDown(() {
    s.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> start({bool shared = true}) async {
    await s.setUp();
    if (shared) await s.setShared(library, true);
    await s.refresh();
  }

  test('synced: the library is shared and a linked device takes it (a link with no mode counts as match)', () async {
    sync.peers.add(peer('p1'));
    await start();
    expect(s.libraryTakenByAnotherDevice('my-books'), isTrue);
  });

  test('synced: a device whose mode is match or send takes it', () async {
    sync.peers.add(peer('p1', link: {'mode': 'send'}));
    await start();
    expect(s.libraryTakenByAnotherDevice('my-books'), isTrue);
  });

  test('not synced: the Library share is off', () async {
    sync.peers.add(peer('p1', link: {'mode': 'match'}));
    await start(shared: false);
    expect(s.libraryTakenByAnotherDevice('my-books'), isFalse);
  });

  test('not synced: this library is switched off in the share, another one is not', () async {
    sync.peers.add(peer('p1', link: {'mode': 'match'}));
    await start();
    await s.setItem(library, const ShareItem(share: 'libraries', path: 'my-books', name: 'My books'), false);
    await s.refresh();
    expect(s.libraryTakenByAnotherDevice('my-books'), isFalse);
    expect(s.libraryTakenByAnotherDevice('field'), isTrue);
  });

  test('not synced: no linked device', () async {
    await start();
    expect(s.libraryTakenByAnotherDevice('my-books'), isFalse);
  });

  test('not synced: the only linked device is set to Off', () async {
    sync.peers.add(peer('p1', link: {'mode': 'off', 'ask': true}));
    await start();
    expect(s.libraryTakenByAnotherDevice('my-books'), isFalse);
    sync.peers.add(peer('p2', link: {'mode': 'match'}));
    await s.refresh();
    expect(s.libraryTakenByAnotherDevice('my-books'), isTrue, reason: 'one device that takes it is enough');
  });
}
