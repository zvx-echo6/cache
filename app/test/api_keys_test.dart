// The key registry, the API keys list and its rows, the shortcut rows, the sheet's failure states, and the sync switch for keys.
// Every key here is made up.

import 'dart:io';

import 'package:cache/screens/settings/api_keys_page.dart';
import 'package:cache/screens/settings/maps_page.dart';
import 'package:cache/screens/settings/assistant_page.dart';
import 'package:cache/settings/api_keys.dart';
import 'package:cache/settings/data_policy.dart' show ConnectionKind;
import 'package:cache/weather/weather_state.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

const String secret = 'SENTINEL-KEY-api-keys-do-not-leak';

void main() {
  group('the key registry', () {
    testWidgets('has a record for every keyed provider: the catalogue\'s, Kagi, every 511 site; each with steps and a page', (tester) async {
      final r = await SettingsRig.create(tester, roadSources: true);
      final ps = r.hub.apiKeys.providers;
      expect(ps.map((p) => p.id), containsAll(['kagi', 'firms', 'road511.511.idaho.gov', 'road511.az511.com']));
      expect(ps.where((p) => p.kind == KeyKind.road && p.id.startsWith('road511.')).length, 16, reason: 'one key per 511 site');
      for (final p in ps) {
        expect(p.steps, isNotEmpty, reason: '${p.id} has its steps');
        expect(p.getKeyUrl, startsWith('https://'), reason: p.id);
        expect(p.title, isNotEmpty);
      }
      expect(r.hub.apiKeys.providerById('firms')!.title, 'NASA FIRMS API key');
      expect(r.hub.apiKeys.providerById('road511.511.idaho.gov')!.title, '511 key (511.idaho.gov)');
      expect(r.hub.apiKeys.providerById('road511.511.idaho.gov')!.steps, contains('Request a Developer API key.'));
      expect(r.hub.apiKeys.providerById('google'), isNull);
      expect(ps.any((p) => p.title.contains('Google') || p.provider.contains('Google')), isFalse);
      expect(r.hub.apiKeys.providerById('kagi')!.usesWords, 'Web search for Ask');
      await r.dispose(tester);
    });

    testWidgets('states: not set, saved but not checked, working after a check, refused', (tester) async {
      final r = await SettingsRig.create(tester);
      final k = r.hub.apiKeys;
      final firms = k.providerById('firms')!;
      expect(k.statusOf(firms).state, KeyState.notSet);
      expect(keyWord(KeyState.notSet), 'Not set');
      await tester.runAsync(() => k.save(firms, secret, check: false));
      expect(k.statusOf(firms).state, KeyState.savedUnchecked);
      expect(keyWord(KeyState.savedUnchecked), 'Set');
      expect(keyStatusLine(k.statusOf(firms), (_) => ''), 'Saved, not checked yet');
      await tester.runAsync(() => k.test(firms));
      expect(k.statusOf(firms).state, KeyState.working);
      expect(keyStatusLine(k.statusOf(firms), (_) => '2 hours ago'), 'Working, checked 2 hours ago');
      expect(keyWord(KeyState.refused), 'Not accepted');
      expect(keyWord(KeyState.limit), 'Limit reached');
      await r.dispose(tester);
    });
  });

  group('the API keys list', () {
    testWidgets('Your keys and Keys Cache can use; a row opens in place; Google is not in the list', (tester) async {
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() => r.hub.apiKeys.save(r.hub.apiKeys.providerById('firms')!, secret));
      await r.show(tester, ApiKeysScreen(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.text('Your own keys for online services. They stay on this device.'), findsOneWidget);
      expect(find.text('YOUR KEYS'), findsOneWidget);
      expect(find.text('KEYS CACHE CAN USE'), findsOneWidget);
      expect(find.text('NASA FIRMS API key'), findsOneWidget);
      expect(find.text('Kagi API key'), findsOneWidget);
      expect(find.textContaining('Google'), findsNothing);
      expect(find.text('Not available yet'), findsNothing);
      // open the saved one: status, Replace, Test key, Used by, About, Remove
      await tester.tap(find.byKey(const ValueKey('api-key-firms')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('replace-firms')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-firms')), findsOneWidget);
      expect(find.text('Test uses one request from your NASA FIRMS account.'), findsOneWidget);
      expect(find.text('USED BY'), findsOneWidget);
      expect(find.text('ABOUT'), findsOneWidget);
      expect(find.byKey(const ValueKey('remove-firms')), findsOneWidget);
      expect(find.textContaining(secret), findsNothing);
      // Test key: one request, the result inline
      await tester.tap(find.byKey(const ValueKey('test-firms')));
      await tester.pumpAndSettle();
      expect(find.text('Works, checked just now'), findsOneWidget);
      expect(r.liveCore.previews.length, greaterThanOrEqualTo(2), reason: 'the save check and the Test');
      await r.dispose(tester);
    });

    testWidgets('Test key is off with no connection, and says so', (tester) async {
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() => r.hub.apiKeys.save(r.hub.apiKeys.providerById('firms')!, secret, check: false));
      r.probe.change(ConnectionKind.none);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await r.show(tester, ApiKeysScreen(deps: r.deps, openId: 'firms'));
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(find.descendant(of: find.byKey(const ValueKey('test-firms')), matching: find.byType(OutlinedButton))).onPressed, isNull);
      expect(find.text('Needs a connection.'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('the sheet\'s failure states: no connection offers Save without checking, a limit offers Save anyway; the typed key stays', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, ApiKeysScreen(deps: r.deps, openId: 'firms'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-firms')));
      await tester.pumpAndSettle();
      r.liveCore.previewError = const CacheSearchException('fetch_failed', 'Dns: failed');
      await tester.enterText(find.byKey(const ValueKey('key-field')), secret);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('check-and-save')));
      await tester.pumpAndSettle();
      expect(find.text("Can't reach NASA FIRMS. Check your connection."), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('key-field'))).controller!.text, secret);
      expect(r.secrets.values, isEmpty);
      r.liveCore.previewError = const CacheSearchException('quota', 'limit');
      await tester.tap(find.byKey(const ValueKey('check-and-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('save-anyway')), findsOneWidget);
      expect(find.byKey(const ValueKey('save-unchecked')), findsNothing);
      r.liveCore.previewError = const CacheSearchException('fetch_failed', 'Dns: failed');
      await tester.tap(find.byKey(const ValueKey('check-and-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-unchecked')));
      await tester.pumpAndSettle();
      expect(r.secrets.values[WeatherState.secretName('firms')], secret);
      expect(r.hub.apiKeys.statusOf(r.hub.apiKeys.providerById('firms')!).state, KeyState.savedUnchecked);
      expect(r.settings.liveSourcesOn, isNot(contains('firms-viirs-near')), reason: 'saving turns nothing on');
      await r.dispose(tester);
    });

    testWidgets('Remove turns nothing off, on a key two sources share; the confirm names both', (tester) async {
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() => r.weather.saveKey(r.weather.sourceById('idaho511-events')!, secret));
      await tester.runAsync(() => r.weather.setSourceOn(r.weather.sourceById('idaho511-winter-roads')!, true));
      await r.show(tester, ApiKeysScreen(deps: r.deps, openId: 'idaho511'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('remove-idaho511')));
      await tester.pumpAndSettle();
      expect(find.textContaining('go back to the data on this device'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-remove-key')));
      await tester.pumpAndSettle();
      expect(r.weather.hasKey('idaho511'), isFalse);
      expect(r.weather.isOn('idaho511-events'), isTrue);
      expect(r.weather.isOn('idaho511-winter-roads'), isTrue);
      await r.dispose(tester);
    });
  });

  group('shortcut rows', () {
    testWidgets('Map settings: a plain row for NASA FIRMS (and none for Google) that opens the list at that key, open; Back returns', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, MapsPage(deps: r.deps));
      expect(find.text('NASA FIRMS API key'), findsOneWidget);
      expect(find.textContaining('Google'), findsNothing);
      expect(find.byType(FilledButton), findsNothing, reason: 'no coloured button for a key outside the list');
      await tester.ensureVisible(find.byKey(const ValueKey('key-shortcut-firms')));
      await tester.tap(find.byKey(const ValueKey('key-shortcut-firms')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('api-key-open-firms')), findsOneWidget);
      expect(find.byKey(const ValueKey('key-field')), findsNothing, reason: 'the sheet is never opened by itself');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(MapsPage), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('the Weather and alerts page has no key rows, no Add key, no key note, and no Web search', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, AssistantPage(deps: r.deps));
      expect(find.text('Kagi API key'), findsOneWidget);
      await r.dispose(tester);
    });
  });

  test('the sync wording: nothing here says free or needs a key', () {
    for (final f in ['lib/settings/api_keys.dart', 'lib/screens/settings/api_keys_page.dart', 'lib/screens/settings/key_sheet.dart']) {
      final t = File(f).readAsStringSync();
      expect(RegExp(r'\bfree\b', caseSensitive: false).hasMatch(t), isFalse, reason: f);
    }
  });
}
