// Wording fix: the "Remove the key?" dialog agrees with the number of sources that turn off, and the empty Web address of the own
// source form says "For example:". Made-up source names, light theme, phone 390 wide.
// flutter test test_shots/wording_turn_off_renders_test.dart --update-goldens  (pictures in test_shots/wording/)

import 'package:cache/screens/settings/api_keys_page.dart';
import 'package:cache/screens/settings/weather_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import '../test/support/weather_fakes.dart';
import 'shot_kit.dart';

const _out = 'wording';

void main() {
  setUpAll(loadShotFonts);

  testWidgets('01 Remove the key? for a key two sources share', (tester) async {
    phone(tester, size: const Size(390, 844));
    final r = await SettingsRig.create(tester);
    phone(tester, size: const Size(390, 844));
    r.web.files.clear();
    r.web.serve('https://data.cached.info/connectors/', buildCatalogue(connectors: [
      entry('road-events-near', 'roads', 'Road events near the place', provider: 'Example Roads', keyAlias: 'exroads'),
      entry('road-winter-near', 'roads', 'Winter road conditions', provider: 'Example Roads', keyAlias: 'exroads'),
    ]));
    await tester.runAsync(() async {
      await r.weather.refreshCatalogues();
      await r.weather.saveKey(r.weather.sourceById('road-events-near')!, 'made-up-key');
    });
    await tester.pumpWidget(shotApp(ApiKeysScreen(deps: r.deps, openId: 'exroads')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('remove-exroads')));
    await tester.pumpAndSettle();
    await snap(tester, _out, '01-remove-key-two-sources');
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await r.dispose(tester);
  });

  testWidgets('02 Add your own source, the Web address field empty', (tester) async {
    phone(tester, size: const Size(390, 844));
    final r = await SettingsRig.create(tester);
    phone(tester, size: const Size(390, 844));
    await tester.pumpWidget(shotApp(MoreSourcesPage(deps: r.deps)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-own-source')));
    await tester.pumpAndSettle();
    await snap(tester, _out, '02-own-source-web-address-hint');
    await tester.pumpWidget(const SizedBox.shrink());
    await r.dispose(tester);
  });
}
