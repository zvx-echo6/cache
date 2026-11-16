import 'dart:convert';

import 'package:cache/screens/settings/own_source_pages.dart';
import 'package:cache/weather/own_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

const _meteo =
    '{"latitude":44.07,"longitude":-114.74,"generationtime_ms":0.1,"utc_offset_seconds":0,"timezone":"GMT","timezone_abbreviation":"GMT","elevation":2371,'
    '"current_units":{"time":"iso8601","interval":"seconds","temperature_2m":"\u00b0C"},"current":{"time":"2026-11-16T15:00","interval":900,"temperature_2m":5.2}}';

void main() {
  group('Pick what to show', () {
    testWidgets('the preview is the real card: the value asked for, then the next two, no units; the list shows the unit', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final r = await SettingsRig.create(tester);
      const draft = OwnDraft(name: 'Temperature', address: 'https://api.open-meteo.com/v1/forecast?current=temperature_2m&latitude={lat}&longitude={lon}');
      final t = OwnTry.ok('api.open-meteo.com', flattenJson(jsonDecode(_meteo)), asked: const ['temperature_2m'], place: (lat: 44.0712, lon: -114.7401));
      await r.show(tester, OwnSourcePickPage(deps: r.deps, draft: draft, first: t));
      await tester.pump();

      Finder onCard(String text) => find.descendant(of: find.byKey(const ValueKey('own-preview')), matching: find.textContaining(text));
      expect(onCard('Temperature 2m 5.2'), findsOneWidget, reason: 'the value asked for is ticked and on the card');
      expect(onCard('\u00b0C'), findsNothing, reason: 'the card shows no units, so the preview shows none');
      expect(find.text('Temperature 2m'), findsOneWidget, reason: 'listed once, not as a units row too');
      expect(find.textContaining('5.2 \u00b0C'), findsOneWidget, reason: 'the pick list row shows the unit, to help choosing');
      expect(find.textContaining('iso8601'), findsNothing, reason: 'a unit only beside a number');

      // As on the real card: the first value, then the next two.
      for (final path in ['elevation', 'timezone', 'utc_offset_seconds']) {
        await tester.tap(find.descendant(of: find.byKey(ValueKey('own-value-$path')), matching: find.byType(Checkbox)));
        await tester.pump();
      }
      expect(onCard('Temperature 2m 5.2'), findsOneWidget);
      expect(onCard('Elevation 2371'), findsOneWidget);
      expect(onCard('Timezone GMT'), findsOneWidget);
      expect(onCard('Utc offset seconds'), findsNothing, reason: 'the fourth is not on the card, as in Weather and alerts');
      await r.dispose(tester);
    });
  });
}
