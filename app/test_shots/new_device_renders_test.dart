// Identity backup (I-0): the Sharing and sync page the first time after a restored copy was moved aside, at 390 points wide.
// flutter test test_shots/new_device_renders_test.dart --update-goldens  (pictures in test_shots/new_device/)

import 'dart:io';

import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/sharing/install_marker.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

const _out = 'new_device';

class _Store implements InstallMarkerStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String id) async => value = id;
  @override
  Future<void> excludeFromBackup(String path) async {}
}

void main() {
  setUpAll(loadShotFonts);

  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    final t = theme == CacheThemeId.dark ? 'dark' : 'light';
    testWidgets('new device message $t', (tester) async {
      final r = await SettingsRig.create(tester);
      final old = Directory('${r.dir.path}/sync')..createSync(recursive: true);
      File('${old.path}/install-id').writeAsStringSync('from-the-old-phone');
      final sharing = SharingState(
        policy: r.policy,
        supportDir: () async => r.dir,
        kinds: const [],
        deviceName: 'Test phone',
        installMarker: _Store(),
        opener: (_) async => r.sync,
      );
      await tester.runAsync(sharing.setUp);
      phone(tester, size: const Size(390, 844), ratio: 3.0);
      await tester.pumpWidget(shotApp(SharingPage(sharing: sharing, onAndroid: true, onIos: false), theme: theme));
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(find.text('This is a new device: link it to your other devices again'), findsOneWidget);
      await snap(tester, _out, '1-restored-390-$t');
      await tester.pumpWidget(shotApp(const SizedBox(), theme: theme));
      sharing.dispose();
      await r.dispose(tester);
    });
  }
}
