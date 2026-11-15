// The phone card that asks whether to allow voice search from the car (CarVoiceCard), shown the first time Cache is opened after a
// CarPlay connection, and the row "Search by voice from the car" in Settings (iPhone), not granted and granted. 390 wide, light and
// dark. The words are the owner's, approved 2026-11-15.
// flutter test test_shots/car_voice_card_renders_test.dart --update-goldens  (pictures in test_shots/car_voice_card/)

import 'package:cache/car/car_voice_access.dart';
import 'package:cache/car/car_voice_card.dart';
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

void main() {
  setUpAll(loadShotFonts);

  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    testWidgets('the car voice card, 390, ${theme.name}', (tester) async {
      phone(tester, size: const Size(390, 400), ratio: 2);
      await tester.pumpWidget(shotApp(
        Scaffold(
          appBar: AppBar(title: const Text('Home')),
          body: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 24), children: [
            CarVoiceCard(onAllow: () {}, onNotNow: () {}),
          ]),
        ),
        theme: theme,
        insets: const EdgeInsets.only(top: 44, bottom: 30),
      ));
      await tester.pumpAndSettle();
      await snap(tester, 'car_voice_card', 'card-390-${theme.name}');
    });
  }
  // The Settings row, in the real Settings screen, as an iPhone with the car screen shows it.
  for (final granted in [false, true]) {
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      testWidgets('the Settings row, 390, ${granted ? 'granted' : 'not granted'}, ${theme.name}', (tester) async {
        final r = await SettingsRig.create(tester);
        const channel = MethodChannel('co.cache/car');
        final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async => {'microphone': granted ? 'granted' : 'undetermined', 'speech': granted ? 'granted' : 'undetermined'});
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final v = CarVoiceAccess(settings: r.settings, ios: true, supported: () async => true);
        addTearDown(v.dispose);
        r.carVoice = v;
        await v.start();
        phone(tester, size: const Size(390, 844), ratio: 2);
        await tester.pumpWidget(shotApp(SettingsScreen(deps: r.deps), theme: theme));
        for (var i = 0; i < 6; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 40));
        }
        await snap(tester, 'car_voice_card', 'row-${granted ? 'granted' : 'not-granted'}-390-${theme.name}');
      });
    }
  }
}
