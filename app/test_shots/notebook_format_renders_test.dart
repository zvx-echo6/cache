// Notebook sync's format 2 (1.1.0): what Sharing says under Notebooks when the share has a notebook in a format newer than this
// version reads: "Update Cache on this device to keep syncing notebooks". At 390 and 1440 points wide, light, dark and Tactical.
// flutter test test_shots/notebook_format_renders_test.dart --update-goldens  (pictures in test_shots/notebook_format/)

import 'dart:io';

import 'package:cache/notebook/sync/share_format.dart';
import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

const _out = 'notebook_format';

const Map<String, Size> _sizes = {'390': Size(390, 844), '1440': Size(1440, 900)};

Future<void> _settle(WidgetTester tester, [int n = 14]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  setUpAll(loadShotFonts);

  for (final e in _sizes.entries) {
    for (final theme in [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.tactical]) {
      final t = theme.name;
      testWidgets('update needed ${e.key} $t', (tester) async {
        final r = await SettingsRig.create(tester);
        r.sync.peers.add({'id': 'peer1', 'name': 'Desk', 'linked': 1, 'last_seen': DateTime.now().millisecondsSinceEpoch - 120000, 'via': 'direct', 'error': null, 'link_known': true});
        final notebooks = Directory('${r.dir.path}/notebook-share')..createSync();
        final sharing = SharingState(
          policy: r.policy,
          supportDir: () async => r.dir,
          deviceName: 'Test phone',
          kinds: [
            DataKind(id: 'library', label: 'Library', icon: Icons.menu_book_outlined, shared: () => {'library': r.libraryDir}),
            DataKind(id: 'notebooks', label: 'Notebooks', icon: Icons.book_outlined, shared: () => {'notebooks': notebooks}),
          ],
          opener: (_) async => r.sync,
        );
        await tester.runAsync(() async {
          await sharing.setUp();
          await sharing.setShared(sharing.kinds.last, true);
        });
        sharing.kindWarning = (id) => id == 'notebooks' ? kUpdateNeededNote : null;
        final ratio = e.value.width < 600 ? 3.0 : 1.0;
        phone(tester, size: e.value, ratio: ratio);
        await tester.pumpWidget(shotApp(SharingPage(sharing: sharing), theme: theme, insets: e.value.width < 600 ? null : EdgeInsets.zero));
        await _settle(tester);
        expect(find.text(kUpdateNeededNote), findsOneWidget);
        await snap(tester, _out, '1-update-needed-${e.key}-$t');
        sharing.dispose();
      });
    }
  }
}
