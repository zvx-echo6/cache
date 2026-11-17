// Add your own source: Try it while it waits for a host that does not answer. After this change a Cancel button is under it.
// flutter test test_shots/try_cancel_renders_test.dart --update-goldens  (picture in test_shots/try_cancel/)

import 'dart:async';

import 'package:cache/screens/settings/own_source_pages.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

void main() {
  setUpAll(loadShotFonts);

  testWidgets('Try it waiting: 390 x 844 light', (tester) async {
    final r = await SettingsRig.create(tester);
    r.web.hold = Completer<void>();
    phone(tester, size: const Size(390, 844), ratio: 2);
    await tester.pumpWidget(shotApp(OwnSourceFormPage(deps: r.deps), theme: CacheThemeId.light, insets: const EdgeInsets.only(top: 44, bottom: 30)));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('own-name')), 'Creek level');
    await tester.enterText(find.byKey(const ValueKey('own-address')), 'https://sensors.example.org/api/creek?lat={lat}&lon={lon}');
    await tester.tap(find.byKey(const ValueKey('own-try')));
    await tester.pump(const Duration(milliseconds: 100));
    await snap(tester, 'try_cancel', 'busy-light');
    r.web.hold!.complete();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpWidget(const SizedBox());
    await r.dispose(tester);
  });
}
