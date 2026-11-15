// The phone card that asks whether to allow voice search from the car (CarVoiceCard), shown the first time Cache is opened after a
// CarPlay connection. 390 wide, light and dark. The words are drafts awaiting the owner's approval; the card is not wired in.
// flutter test test_shots/car_voice_card_renders_test.dart --update-goldens  (pictures in test_shots/car_voice_card/)

import 'package:cache/car/car_voice_card.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
