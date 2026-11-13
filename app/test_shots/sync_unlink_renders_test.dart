// Unlinking a device that is off (owner review): the Sharing page with an unlink waiting, and the Activity log with the three lines
// about unlinking, at 390 points wide, light and dark. The names are made up.
// flutter test test_shots/sync_unlink_renders_test.dart --update-goldens  (pictures in test_shots/sync_unlink/)

import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import '../test/support/sync_fake.dart';
import 'shot_kit.dart';

const _out = 'sync_unlink';

Future<void> _settle(WidgetTester tester, [int n = 14]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  setUpAll(loadShotFonts);

  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    final t = theme == CacheThemeId.dark ? 'dark' : 'light';
    testWidgets('sync unlink 390 $t', (tester) async {
      final r = await SettingsRig.create(tester);
      final now = DateTime.now().millisecondsSinceEpoch;
      final sync = FakeSync()
        ..peers.add({'id': 'peer2', 'name': 'Desk tablet', 'linked': 1, 'last_seen': now - 120000, 'via': 'direct', 'error': null})
        ..unlinks.add({'id': 'peer1', 'name': 'Trail phone', 'old': false})
        ..log.addAll([
          {'at': now - 60000, 'text': 'Trail phone unlinked this device.'}, // WORDING QUESTION (owner): draft, not yet approved
          {'at': now - 3 * 3600000, 'text': 'Desk tablet was told it is unlinked.'}, // WORDING QUESTION (owner): draft, not yet approved
          {'at': now - 26 * 3600000, 'text': 'Old spare was not reached within 30 days; it may still show this device.'}, // WORDING QUESTION (owner): draft, not yet approved
        ]);
      final sharing = SharingState(policy: r.policy, supportDir: () async => r.dir, kinds: const [], deviceName: 'Test phone', opener: (_) async => sync);
      await tester.runAsync(sharing.setUp);
      await tester.runAsync(sharing.refresh);
      phone(tester, size: const Size(390, 844), ratio: 3);
      await tester.pumpWidget(shotApp(SharingPage(sharing: sharing), theme: theme));
      await _settle(tester);
      await snap(tester, _out, '1-sharing-waiting-390-$t');

      // The Activity log opened, scrolled into view.
      await tester.ensureVisible(find.text('Activity'));
    await tester.pump();
      await tester.tap(find.text('Activity'));
      await _settle(tester);
      await tester.ensureVisible(find.text('Old spare was not reached within 30 days; it may still show this device.'));
      await _settle(tester);
      await snap(tester, _out, '2-activity-390-$t');

      await tester.pumpWidget(const SizedBox());
      sharing.dispose();
      await r.dispose(tester);
    });
  }
}
