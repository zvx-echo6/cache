// "Sync all now", the kind page's "Sync all" and the device page's "Sync now" first run the notebook pass (the one that writes
// pending notebook changes into the share folder) and wait for it, then start the round; a pass already running is waited for
// and one fresh pass still runs.

import 'dart:async';
import 'dart:io';

import 'package:cache/notebook/sync/connections.dart';
import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart' show testPolicy;
import 'notebook_sync_test.dart' show MemFolder;
import 'support/notebook_fake.dart';
import 'support/sync_fake.dart';

/// A fake engine that writes each round into [order].
class _OrderedSync extends FakeSync {
  _OrderedSync(this.order);
  final List<String> order;

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) {
    if (method == 'sync_now') order.add('round');
    return super.call(method, args);
  }
}

class _Rig {
  _Rig(this.dir) : sync = _OrderedSync(order);
  static final order = <String>[];
  final Directory dir;
  final _OrderedSync sync;

  /// The notebook pass: starts, then waits for [gate] before it ends.
  Completer<void> gate = Completer<void>();
  int passes = 0;

  Future<void> pass() async {
    passes++;
    order.add('pass:start');
    await gate.future;
    order.add('pass:end');
  }

  late final List<DataKind> kinds = [
    DataKind(
      id: 'library',
      label: 'Library',
      icon: Icons.menu_book_outlined,
      shared: () => {'library': Directory('${dir.path}/zims')},
      items: () => const [ShareItem(share: 'library', path: 'wikimed.zim', name: 'Medical encyclopedia', bytes: 1400 << 20)],
    ),
  ];

  SharingState make() => SharingState(
    policy: testPolicy(wifi: true),
    supportDir: () async => dir,
    kinds: kinds,
    opener: (_) async => sync,
    beforeSync: pass,
  );
}

Future<_Rig> _rig() async {
  _Rig.order.clear();
  final dir = await Directory.systemTemp.createTemp('sync-now-pass');
  Directory('${dir.path}/zims').createSync(recursive: true);
  return _Rig(dir);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await tester.pump();
}

/// Taps [button]; the pass is held open: the round has not started and the button is already disabled (the feedback covers the
/// pass); then the pass ends and the round starts after it.
Future<void> _checkOrder(WidgetTester tester, _Rig r, Finder button) async {
  await tester.tap(button);
  await _settle(tester);
  expect(_Rig.order, ['pass:start'], reason: 'the pass runs first and the round waits for it');
  expect(r.sync.argsOf['sync_now'], isNull);
  expect(find.byWidgetPredicate((w) => (w is TextButton && w.onPressed == null) || (w is FilledButton && w.onPressed == null)), findsWidgets, reason: 'the tap shows something at once');
  r.gate.complete();
  await _settle(tester);
  expect(_Rig.order, ['pass:start', 'pass:end', 'round'], reason: 'the pass finishes before the round starts');
  expect(r.passes, 1);
}

void main() {
  testWidgets('Sync all now: the notebook pass finishes before the round starts', (tester) async {
    final r = (await tester.runAsync(_rig))!;
    final s = r.make();
    await tester.runAsync(s.setUp);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: SharingPage(sharing: s)));
    await tester.pump();
    await _checkOrder(tester, r, find.byKey(const ValueKey('sync-all')));
    await tester.pumpWidget(const SizedBox());
    s.dispose();
    await tester.runAsync(() => r.dir.delete(recursive: true));
  });

  testWidgets("the kind page's Sync all: the notebook pass finishes before the round starts", (tester) async {
    final r = (await tester.runAsync(_rig))!;
    final s = r.make();
    await tester.runAsync(s.setUp);
    await tester.runAsync(() => s.setShared(r.kinds.single, true));
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: SharingPage(sharing: s)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('share-library')));
    await tester.pumpAndSettle();
    await _checkOrder(tester, r, find.byKey(const ValueKey('kind-sync')));
    await tester.pumpWidget(const SizedBox());
    s.dispose();
    await tester.runAsync(() => r.dir.delete(recursive: true));
  });

  testWidgets("the device page's Sync now: the notebook pass finishes before the round starts", (tester) async {
    final r = (await tester.runAsync(_rig))!;
    final s = r.make();
    await tester.runAsync(s.setUp);
    r.sync.peers.add({'id': 'p1', 'name': 'Desk', 'linked': 1, 'last_seen': DateTime.now().millisecondsSinceEpoch, 'via': 'direct', 'error': null, 'free_bytes': 612 << 30});
    await tester.runAsync(s.refresh);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: SharingPage(sharing: s)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('peer-p1')));
    await tester.pumpAndSettle();
    await _checkOrder(tester, r, find.byKey(const ValueKey('device-sync')));
    expect(r.sync.argsOf['sync_now']!.last, {'peer': 'p1'});
    await tester.pumpWidget(const SizedBox());
    s.dispose();
    await tester.runAsync(() => r.dir.delete(recursive: true));
  });

  test('a pass that fails does not stop the round', () async {
    final r = await _rig();
    final s = SharingState(policy: testPolicy(wifi: true), supportDir: () async => r.dir, kinds: r.kinds, opener: (_) async => r.sync, log: (_) {}, beforeSync: () async => throw StateError('x'));
    await s.setUp();
    await s.syncNow();
    expect(_Rig.order, ['round']);
    s.dispose();
    await r.dir.delete(recursive: true);
  });

  group('NotebookConnections.syncAllAndWait', () {
    Future<(NotebookConnections, List<String>, Completer<void> Function())> make({required bool gated}) async {
      final nb = fakeNotebook(FakeNotebookBackend());
      await nb.start();
      final dir = Directory.systemTemp.createTempSync('cache-pass-');
      final events = <String>[];
      var gate = Completer<void>();
      var n = 0;
      final c = NotebookConnections(
        notebook: nb,
        dir: () async => dir,
        folderFor: (_) => MemFolder(),
        shareOn: () => true,
        shareFolder: () => dir,
        prepareShare: () async {
          n++;
          events.add('pass$n:start');
          if (gated && n == 1) await gate.future;
          events.add('pass$n:end');
        },
      );
      return (c, events, () => gate);
    }

    test('nothing running: one fresh pass, and it has finished when the call returns', () async {
      final (c, events, _) = await make(gated: false);
      await c.syncAllAndWait();
      expect(events, ['pass1:start', 'pass1:end']);
      expect(c.syncing, isFalse);
    });

    test('a pass already running is waited for, then one fresh pass runs before the call returns', () async {
      final (c, events, gate) = await make(gated: true);
      unawaited(c.syncAll());
      for (var i = 0; i < 100 && events.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(events, ['pass1:start'], reason: 'a pass is in flight');
      var done = false;
      final w = c.syncAllAndWait().then((_) => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(done, isFalse, reason: 'it waits for the pass in flight');
      expect(events, ['pass1:start'], reason: 'no second pass starts alongside the first');
      gate().complete();
      await w;
      expect(events, ['pass1:start', 'pass1:end', 'pass2:start', 'pass2:end'], reason: 'then one fresh pass');
      expect(c.syncing, isFalse);
    });
  });
}
