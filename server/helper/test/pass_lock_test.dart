// One pass at a time across the notebook sync with linked devices (NotebookSyncHost) and the Obsidian and Logseq folders
// (FolderConnections), as on the phone, where one NotebookConnections runs the share folder and every target behind one guard.
// Both hosts work on the same notebooks in the core, so their passes must never overlap; a trigger that arrives during a pass
// gets one follow-up pass.
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import '../../../app/lib/notebook/sync/sync_engine_core.dart' show SyncKind;
import '../bin/core_notebook_store.dart';
import '../bin/folder_connections.dart';
import '../bin/notebook_sync_host.dart';
import '../bin/pass_lock.dart';
import 'notebook_sync_host_test.dart' show Device;

void main() {
  late Directory tmp, support, vault;
  late Device dev;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pass_lock_test');
    support = Directory('${tmp.path}/support')..createSync();
    vault = Directory('${tmp.path}/Vault')..createSync();
    dev = Device(tmp, name: 'server');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// The calls each host's store made to the core, in order, with who made them; each call takes a moment, so two passes that run
  /// at the same time interleave. [gate] holds the calls of [gated] until it completes.
  final calls = <String>[];
  CoreNotebookStore storeFor(String who, {Completer<void>? gate}) {
    return CoreNotebookStore(
      call: (op, args) async {
        calls.add(who);
        if (gate != null) await gate.future;
        await Future<void>.delayed(const Duration(milliseconds: 3));
        return dev.core.call(op, args);
      },
      mediaDir: dev.media,
    );
  }

  /// How often the calls switch from one host to the other: one pass each, not overlapping, switch once.
  int switches() {
    var n = 0;
    for (var i = 1; i < calls.length; i++) {
      if (calls[i] != calls[i - 1]) n++;
    }
    return n;
  }

  setUp(calls.clear);

  Future<({NotebookSyncHost share, FolderConnections folders})> rig({PassLock? lock, Completer<void>? shareGate}) async {
    final b = await dev.book('Journal');
    await dev.entry(b, 'One', body: 'a');
    await dev.entry(b, 'Two', body: 'b');
    final folders = FolderConnections(support: support, store: storeFor('folders'), debounce: const Duration(milliseconds: 20), every: const Duration(hours: 1), lock: lock);
    expect(await folders.connect(SyncKind.obsidian, vault.path), isNull);
    await folders.syncAll();
    final share = NotebookSyncHost(
      support: support,
      store: storeFor('share', gate: shareGate),
      shareOn: () => true,
      every: const Duration(hours: 1),
      lock: lock,
    );
    calls.clear();
    addTearDown(() {
      share.stop();
      folders.stop();
    });
    return (share: share, folders: folders);
  }

  test('the check itself: with no shared lock, a share pass and a folder pass that start together do overlap', () async {
    final r = await rig();
    await Future.wait([r.share.run(), r.folders.syncAll()]);
    expect(switches(), greaterThan(1), reason: 'the calls of the two passes interleave');
  });

  test('with one shared lock, a share pass and a folder pass that are both triggered never run at the same time', () async {
    final lock = PassLock();
    final r = await rig(lock: lock);
    await Future.wait([r.share.run(), r.folders.syncAll()]);
    expect(r.share.passes, 1);
    expect(r.folders.passes, greaterThan(1)); // the connecting pass and this one
    expect(calls.toSet(), {'share', 'folders'});
    expect(switches(), 1, reason: 'one whole pass, then the other');
  });

  test('changes, a timer and a share change triggered together still never overlap', () async {
    final lock = PassLock();
    final r = await rig(lock: lock);
    r.folders.changed();
    unawaited(r.share.shareChanged({'notebooks'}));
    r.share.changed();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await Future.wait([r.share.run(), r.folders.syncAll()]);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await Future.wait([r.share.run(), r.folders.syncAll()]);
    // the calls come in runs of one host at a time: every run is a whole pass; passes of one host in a row are one run
    final runs = switches() + 1;
    expect(runs, lessThanOrEqualTo(2 * (r.share.passes + r.folders.passes)));
    // and the lock was never held twice
    expect(lock.maxActive, 1);
  });

  test('a trigger that arrives during a pass gets its follow-up pass, one however many arrive, and it waits for the other host\'s pass', () async {
    final lock = PassLock();
    final gate = Completer<void>();
    final r = await rig(lock: lock, shareGate: gate);
    final shareBefore = r.share.passes, foldersBefore = r.folders.passes;
    final first = r.share.run(); // holds the lock: its first call waits on the gate
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final f1 = r.folders.syncAll(); // queued behind the share pass
    final s2 = r.share.run(); // during the share pass: asks for one follow-up
    final s3 = r.share.run();
    final f2 = r.folders.syncAll(); // coalesced into the folder pass's follow-up
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(r.folders.passes, foldersBefore, reason: 'the folder pass waits for the share pass');
    gate.complete();
    await Future.wait([first, f1, s2, s3, f2]);
    expect(r.share.passes - shareBefore, 2, reason: 'the pass, and one follow-up for the two triggers during it');
    expect(r.folders.passes - foldersBefore, 2, reason: 'the pass, and one follow-up for the trigger during it');
    expect(lock.maxActive, 1);
  });

  test('a trigger during a folder pass gets its follow-up pass too', () async {
    final lock = PassLock();
    final r = await rig(lock: lock);
    final before = r.folders.passes;
    final a = r.folders.syncAll();
    final b = r.folders.syncAll();
    await Future.wait([a, b]);
    expect(r.folders.passes - before, 2);
  });

  test('the lock runs one thing at a time in the order asked, and a failure frees it', () async {
    final lock = PassLock();
    final order = <int>[];
    final a = lock.run(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      order.add(1);
    });
    final b = lock.run(() async {
      order.add(2);
      throw StateError('boom');
    });
    final c = lock.run(() async => order.add(3));
    await a;
    await expectLater(b, throwsStateError);
    await c;
    expect(order, [1, 2, 3]);
    expect(lock.maxActive, 1);
  });
}
