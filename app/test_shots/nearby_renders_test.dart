// Nearby linking on "Show my link code" (1.2): the page with two devices nearby, the question on the device that was asked, the
// three words, waiting for the other device, linked, and the messages when a link ends without linking. At 390 points wide, light
// and dark. flutter test test_shots/nearby_renders_test.dart --update-goldens  (pictures in test_shots/nearby/)

import 'package:cache/screens/settings/link_code_page.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

const _out = 'nearby';

// a code as long as the engine's real ones
const _code = 'CACHE1-PMRGSZBCHIRDOYRTMYZGGZTFMJRWIYLCGM3TKNBVGEZDGNZRGYYTCOJYGQ4DKMRTGIYTEOBQHE3DIMJSGU2TGMBXGM';

void main() {
  setUpAll(loadShotFonts);

  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    final t = theme == CacheThemeId.dark ? 'dark' : 'light';
    testWidgets('nearby $t', (tester) async {
      final r = await SettingsRig.create(tester);
      r.sync.codeOverride = _code;
      await tester.runAsync(() => r.sharing.setUp());
      phone(tester, size: const Size(390, 844), ratio: 3);

      Future<void> tick([int ms = 600]) async {
        await tester.pump(Duration(milliseconds: ms));
        await tester.pump(const Duration(milliseconds: 50));
      }

      Future<void> open() async {
        r.sync
          ..nearbyDevices.clear()
          ..nearbyDevices.addAll([
            {'id': 'a', 'name': 'Pixel 8', 'via': 'wifi'},
            {'id': 'b', 'name': null, 'via': 'wifi'},
          ])
          ..nearbyState = {'state': 'idle'};
        // opened from Sharing and sync as the app does, so the page has its back arrow
        await tester.pumpWidget(shotApp(const Scaffold(), theme: theme));
        tester.state<NavigatorState>(find.byType(Navigator)).push(MaterialPageRoute<void>(builder: (_) => LinkCodePage(sharing: r.sharing, code: _code, share: (_) async {})));
        await tick(900);
      await tick(400);
        await tick();
      }

      Future<void> close() async {
        await tester.pumpWidget(shotApp(const SizedBox(), theme: theme));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }

      await open();
      await snap(tester, _out, 't5-page-390-$t');

      r.sync.nearbyState = {'state': 'incoming', 'name': 'Pixel 8'};
      await tick(900);
      await tick(400);
      await snap(tester, _out, 't5-incoming-390-$t');

      r.sync.nearbyState = {'state': 'words', 'words': ['maple', 'river', 'seven'], 'name': 'Pixel 8'};
      await tick(900);
      await tick(400);
      await snap(tester, _out, 't5-words-390-$t');

      r.sync.nearbyState = {'state': 'waiting', 'name': 'Pixel 8'};
      await tick(900);
      await tick(400);
      await snap(tester, _out, 't5-waiting-390-$t');

      r.sync.nearbyState = {'state': 'linked', 'name': 'Pixel 8'};
      await tick(900);
      await tick(400);
      await snap(tester, _out, 't5-linked-390-$t');
      await close();

      for (final reason in ['mismatch', 'timeout', 'busy']) {
        await open();
        r.sync.nearbyState = {'state': 'waiting', 'name': 'Pixel 8'};
        await tick();
        r.sync.nearbyState = {'state': 'dropped', 'reason': reason};
        await tick(700);
        await tick(500);
        await tick(500);
        await snap(tester, _out, 't5-$reason-390-$t');
        await close();
      }
      await r.dispose(tester);
    });
  }
}
