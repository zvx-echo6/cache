// Background sync (1.1): the Sharing and sync page with the note about syncing with Cache closed, on Android and on iPhone, at 390
// points wide, light and dark.
// flutter test test_shots/sync_note_renders_test.dart --update-goldens  (pictures in test_shots/sync_note/)

import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import '../test/support/sync_fake.dart';
import 'shot_kit.dart';

const _out = 'sync_note';

void main() {
  setUpAll(loadShotFonts);

  for (final os in ['android', 'ios']) {
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      final t = theme == CacheThemeId.dark ? 'dark' : 'light';
      testWidgets('sync note $os $t', (tester) async {
        final r = await SettingsRig.create(tester);
        final sync = FakeSync();
        final sharing = SharingState(policy: r.policy, supportDir: () async => r.dir, kinds: const [], deviceName: 'Test phone', opener: (_) async => sync);
        await tester.runAsync(sharing.setUp);
        await tester.runAsync(() => sharing.link('CACHE1-TESTCODE'));
        phone(tester, size: const Size(390, 844), ratio: 3.0);
        await tester.pumpWidget(shotApp(SharingPage(sharing: sharing, onAndroid: os == 'android', onIos: os == 'ios'), theme: theme));
        for (var i = 0; i < 6; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
          await tester.pump(const Duration(milliseconds: 40));
        }
        final note = find.textContaining(os == 'ios' ? 'runs only when iOS allows it' : 'syncs about once an hour');
        await tester.ensureVisible(note);
        await tester.pump();
        expect(note, findsOneWidget);
        await snap(tester, _out, '1-$os-390-$t');
        await tester.pumpWidget(shotApp(const SizedBox(), theme: theme));
        sharing.dispose();
        await r.dispose(tester);
      });
    }
  }
}
