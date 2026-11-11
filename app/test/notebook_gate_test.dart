import 'dart:io';

import 'package:cache/notebook/sync/share_format.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:cache/settings/data_kinds.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';
import 'support/share_rig.dart';

/// The notebooks share's conversion removes the old name folders only when the link-version gate says every linked device is
/// compatible: the wiring is `gateActive: () => sharing.linkGateActive`, read from the engine's status (`compat` per peer: "ok",
/// "peer_older", "peer_newer", "unknown"), as main.dart wires it.
Set<String> oldFiles(MemFolder f) => {for (final k in f.text.keys) if (k.endsWith('.md')) k};

Map<String, Object?> peer(String id, String compat) => {'id': id, 'name': id, 'linked': 1, 'last_seen': 1, 'via': 'direct', 'error': null, 'link_known': true, 'compat': compat};

void main() {
  Future<(SettingsRig, SharingState)> sharingWith(WidgetTester tester, List<Map<String, Object?>> peers, {bool start = true}) async {
    final r = await SettingsRig.create(tester);
    r.sync.peers.addAll(peers);
    final notebooks = Directory('${r.dir.path}/notebook-share')..createSync();
    final sharing = SharingState(
      policy: r.policy,
      supportDir: () async => r.dir,
      deviceName: 'Test phone',
      kinds: [DataKind(id: 'notebooks', label: 'Notebooks', icon: Icons.book_outlined, shared: () => {'notebooks': notebooks})],
      opener: (_) async => r.sync,
    );
    if (start) await tester.runAsync(sharing.setUp);
    return (r, sharing);
  }

  testWidgets('one compatible and one mismatched device: nothing is removed; all compatible: removed', (tester) async {
    final (r, sharing) = await sharingWith(tester, [peer('p1', 'ok'), peer('p2', 'peer_older')]);
    await tester.runAsync(() async {
      await sharing.refresh();
      expect(sharing.linkGateActive, isFalse);
      final a = Dev('a', old: true);
      await a.boot();
      await a.make('Hikes', id: 'a-1');
      await a.add('a-1', 'ea1', 'Alpha');
      await a.sync();
      final g = a..gateFn = () => sharing.linkGateActive;
      await g.updateCache();
      await g.sync();
      await g.sync();
      expect(oldFiles(g.folder).length, 1, reason: 'a mismatched device is linked');
      expect(g.conn.conversionState, 'converting');
      expect(g.folder.text.keys.where((k) => k.startsWith('a-1/') && k.endsWith(kNoteExt)).length, 1, reason: 'the id layout is written all the same');
      // the other device updates: every linked device is compatible
      r.sync.peers.firstWhere((p) => p['id'] == 'p2')['compat'] = 'ok';
      await sharing.refresh();
      expect(sharing.linkGateActive, isTrue);
      await g.sync();
      expect(oldFiles(g.folder), isEmpty);
      expect(g.conn.conversionState, 'done');
      expect(await g.entryIds('a-1'), {'ea1'});
    });
  });

  testWidgets('a device that goes from unknown to compatible enables it; an unknown or newer one blocks it', (tester) async {
    final (r, sharing) = await sharingWith(tester, [peer('p1', 'unknown')]);
    await tester.runAsync(() async {
      await sharing.refresh();
      expect(sharing.linkGateActive, isFalse, reason: 'unknown is treated as an older device');
      final a = Dev('a', old: true);
      await a.boot();
      await a.make('Hikes', id: 'a-1');
      await a.add('a-1', 'ea1', 'Alpha');
      await a.sync();
      final g = a..gateFn = () => sharing.linkGateActive;
      await g.updateCache();
      await g.sync();
      expect(oldFiles(g.folder).length, 1);
      r.sync.peers.first['compat'] = 'peer_newer';
      await sharing.refresh();
      await g.sync();
      expect(oldFiles(g.folder).length, 1, reason: 'a newer device is not compatible either');
      r.sync.peers.first['compat'] = 'ok';
      await sharing.refresh();
      await g.sync();
      expect(oldFiles(g.folder), isEmpty);
      expect(g.conn.conversionState, 'done');
    });
  });

  testWidgets('no linked device at all: all compatible, once the engine runs and its status is read', (tester) async {
    final (_, sharing) = await sharingWith(tester, [], start: false);
    expect(sharing.linkGateActive, isFalse, reason: 'the engine is not running');
    await tester.runAsync(() async {
      await sharing.setUp();
      expect(sharing.linkGateActive, isTrue);
    });
  });
}
