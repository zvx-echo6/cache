import 'dart:io';

import 'package:cache/sharing/sharing_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

void main() {
  testWidgets('the engine is told which shares list no file lines (the notebooks)', (tester) async {
    final r = await SettingsRig.create(tester);
    Map<String, Object?>? config;
    final sharing = SharingState(
      policy: r.policy,
      supportDir: () async => r.dir,
      kinds: const [],
      quiet: const ['notebooks'],
      log: (_) {},
      opener: (c) async {
        config = c;
        return r.sync;
      },
    );
    await tester.runAsync(sharing.setUp);
    expect(config?['quiet'], ['notebooks']);
    sharing.dispose();
    await r.dispose(tester);
  });

  test('the app names the notebooks share as quiet, and the notebook sync still tells the approved summary lines', () {
    expect(File('lib/main.dart').readAsStringSync(), contains("quiet: const ['notebooks']"));
    final text = File('lib/notebook/sync/connections.dart').readAsStringSync();
    expect(text, contains('arrived from your other devices'));
    expect(text, contains('updated from your other devices'));
    expect(text, contains('removed by your other devices'));
  });
}
