import 'dart:convert';
import 'dart:io';

import 'package:cache/screens/settings/own_source_pages.dart';
import 'package:cache/screens/settings/storage_page.dart';
import 'package:cache/screens/settings/source_page.dart';
import 'package:cache/screens/settings/weather_page.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/curated.dart';
import 'package:cache/weather/own_source.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';
import 'support/weather_fakes.dart';

Finder rowWith(String title) => find.ancestor(of: find.text(title), matching: find.byType(InkWell)).first;

Switch switchIn(WidgetTester tester, String title) => tester.widget<Switch>(find.descendant(of: rowWith(title), matching: find.byType(Switch)));

const secret = 'SENTINEL-KEY-77b0e2-do-not-leak';

/// A tall screen, so every source row is built.
void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Taps the refresh button and lets its work run: the source list is read again (file work outside the test's clock), then
/// the data.
Future<void> _tapRefresh(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.byKey(const ValueKey('weather-refresh')));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
  await tester.pumpAndSettle();
}

void main() {
  group('Weather and alerts', () {
    testWidgets('one line for the age with a small refresh button; the catalogue\'s featured sources, the rest under More sources; places', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await r.show(tester, WeatherPage(deps: r.deps));
      expect(find.text('Weather and alerts'), findsOneWidget);
      expect(find.text('Nothing switched on yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('weather-refresh')), findsOneWidget);
      expect(find.text('Update now'), findsNothing);
      expect(find.text('What Cache watches for your places. All free; some need a free key you get from the provider.'), findsOneWidget);
      for (final t in ['Weather alerts (NWS, by point)', 'Weather forecast (Open-Meteo)', 'Wildfires near the place (WFIGS)', 'Earthquakes near the place (USGS)']) {
        expect(find.text(t), findsOneWidget, reason: t);
        expect(switchIn(tester, t).value, isFalse, reason: '$t starts off');
      }
      // Each row says what the source gives and who provides it.
      expect(find.text('What Weather forecast (Open-Meteo) gives · Open-Meteo'), findsOneWidget);
      // A featured source that needs a key has "Get key" on its row.
      expect(find.text('Satellite fire detections near the place (NASA FIRMS)'), findsOneWidget);
      expect(find.byKey(const ValueKey('get-key-firms-viirs-near')), findsOneWidget);
      // The rest, under More sources.
      expect(find.text('Space weather: Kp index'), findsNothing);
      expect(find.text('More sources'), findsOneWidget);
      expect(find.text('3 more'), findsOneWidget);
      // Weather alerts and fires have their own icons.
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.text('Where I am'), findsNothing, reason: 'the places are the Places notebook now');
      expect(find.text('Watch these places'), findsNothing);
      expect(find.text('Advanced'), findsNothing);
      await r.dispose(tester);
    });

    testWidgets('a keyless source is switched on with its switch: it is registered with the core and in the policy', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, WeatherPage(deps: r.deps));
      const t = 'Wildfires near the place (WFIGS)';
      await tester.tap(find.descendant(of: rowWith(t), matching: find.byType(Switch)));
      await tester.pump();
      await tester.pump();
      expect(switchIn(tester, t).value, isTrue);
      expect(r.weather.registeredIds, {'wfigs-incidents-near'});
      expect(r.liveCore.policies.last!['enabled_sources'], ['wfigs-incidents-near']);
      expect(find.text('Not updated yet'), findsOneWidget);
      await tester.tap(find.descendant(of: rowWith(t), matching: find.byType(Switch)));
      await tester.pump();
      await tester.pump();
      expect(switchIn(tester, t).value, isFalse);
      expect(r.weather.registeredIds, isEmpty);
      await r.dispose(tester);
    });

    testWidgets('Get key on the row: saving checks the key, switches the source on and never shows it again', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.tap(find.byKey(const ValueKey('get-key-firms-viirs-near')));
      await tester.pumpAndSettle();
      expect(find.text('Get a key from NASA FIRMS'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('get-key')));
      await tester.pump();
      expect(r.opened, ['https://firms.modaps.eosdis.nasa.gov/api/area/']);
      // refused first
      r.liveCore.previewError = const CacheSearchException('key_missing', 'rejected');
      await tester.enterText(find.byKey(const ValueKey('key-field')), secret);
      await tester.tap(find.byKey(const ValueKey('check-and-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('key-error')), findsOneWidget);
      expect(find.textContaining("NASA FIRMS didn't accept this key"), findsOneWidget);
      expect(r.secrets.values, isEmpty);
      // then accepted
      r.liveCore.previewError = null;
      await tester.tap(find.byKey(const ValueKey('check-and-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('key-field')), findsNothing, reason: 'the sheet closed');
      expect(find.byKey(const ValueKey('get-key-firms-viirs-near')), findsNothing);
      expect(switchIn(tester, 'Satellite fire detections near the place (NASA FIRMS)').value, isTrue);
      expect(r.liveCore.keys['firms-viirs-near'], secret);
      // the key is on no screen
      expect(find.textContaining(secret), findsNothing);
      expect(find.textContaining('SENTINEL'), findsNothing);
      await r.dispose(tester);
    });

    testWidgets('the refresh button updates and says what happened; on mobile data it still updates', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.tap(find.descendant(of: rowWith('Weather alerts (NWS, by point)'), matching: find.byType(Switch)));
      await tester.pump();
      await _tapRefresh(tester);
      expect(find.text('Updated'), findsOneWidget, reason: 'the snack bar');
      expect(find.text('Updated just now'), findsOneWidget, reason: 'the status line');
      expect(r.liveCore.fetches.length, 1);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      r.probe.change(ConnectionKind.mobile);
      await tester.pumpAndSettle();
      await _tapRefresh(tester);
      expect(r.liveCore.fetches.length, 2, reason: 'updates use mobile data');
      await r.dispose(tester);
    });

    testWidgets('the refresh button checks the source list too: a newly published source shows up', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await r.show(tester, WeatherPage(deps: r.deps));
      expect(find.text('Emergency alerts (FEMA IPAWS)'), findsNothing);
      // the catalogue publishes a new source
      r.web.serve('https://data.cached.info/connectors/', buildCatalogue(connectors: [
        entry('nws-alerts-point', 'alerts', 'Weather alerts (NWS, by point)', provider: 'NWS'),
        entry('ipaws-alerts', 'alerts', 'Emergency alerts (FEMA IPAWS)', provider: 'FEMA IPAWS'),
      ]));
      final asked = r.web.requested.where((u) => u.path.endsWith('/catalogue.json')).length;
      await _tapRefresh(tester);
      expect(r.web.requested.where((u) => u.path.endsWith('/catalogue.json')).length, asked + 1, reason: 'the catalogue is read again');
      expect(find.text('Emergency alerts (FEMA IPAWS)'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('old data turns the line into a warning with the age and the reason', (tester) async {
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() async {
        await r.weather.setRowOn(kCurated.first, true);
        await r.weather.updateNow();
      });
      r.clock = r.clock.add(const Duration(days: 3));
      r.probe.change(ConnectionKind.none);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.text('Updated 3 days ago · No connection since Monday'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsWidgets);
      await r.dispose(tester);
    });

    testWidgets('More sources opens its page', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.tap(find.text('More sources'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-sources')), findsOneWidget);
      expect(find.text('Space weather: Kp index'), findsOneWidget);
      expect(find.text('Road conditions (Idaho 511)'), findsOneWidget);
      expect(find.text('Weather alerts (NWS, by point)'), findsNothing, reason: 'featured sources are on the main page');
      await tester.enterText(find.byKey(const ValueKey('search-sources')), 'winter');
      await tester.pump();
      expect(find.text('Winter road conditions (Idaho 511)'), findsOneWidget);
      expect(find.text('Space weather: Kp index'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('search-sources')), 'zzz');
      await tester.pump();
      expect(find.text('No source matches your search.'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-own-source')), findsOneWidget);
      expect(find.text('Add sources from a link'), findsNothing);
      await r.dispose(tester);
    });

    for (final theme in CacheThemeId.values) {
      testWidgets('it draws without overflow in ${theme.label}', (tester) async {
        final r = await SettingsRig.create(tester);
        await tester.runAsync(() => r.weather.setRowOn(kCurated.first, true));
        await r.show(tester, WeatherPage(deps: r.deps), theme: theme);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Weather forecast (Open-Meteo)'), findsOneWidget);
        await r.show(tester, MoreSourcesPage(deps: r.deps), theme: theme);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await r.dispose(tester);
      });
    }
  });

  group('A data source', () {
    testWidgets('what it gives, who provides it, how often, how old the copy is, the last problem, and its switch', (tester) async {
      final r = await SettingsRig.create(tester);
      r.liveCore.stored['wfigs-incidents-near'] = {'age': '12 minutes old', 'age_seconds': 720, 'expired': false, 'last_error': {'code': 'fetch_failed', 'message': 'HTTP 500: busy'}};
      await tester.runAsync(() => r.weather.setRowOn(kCurated[2], true));
      await r.show(tester, SourcePage(deps: r.deps, sourceId: 'wfigs-incidents-near'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
      expect(find.text('Wildfires near the place (WFIGS)'), findsOneWidget);
      expect(find.text('what Wildfires near the place (WFIGS) gives'), findsOneWidget);
      expect(find.text('NIFC WFIGS'), findsOneWidget);
      expect(find.text('US'), findsOneWidget);
      expect(find.text('Every 30 min'), findsOneWidget);
      expect(find.text('Data by NIFC WFIGS'), findsOneWidget);
      expect(find.text('Public domain'), findsOneWidget);
      expect(find.text('Cache connectors'), findsOneWidget);
      expect(find.text('12 minutes old'), findsOneWidget);
      expect(find.text('Current'), findsOneWidget);
      expect(find.text('HTTP 500: busy'), findsOneWidget);
      expect(switchIn(tester, 'Use this source').value, isTrue);
      await tester.tap(rowWith('Use this source'));
      await tester.pumpAndSettle();
      expect(r.weather.isOn('wfigs-incidents-near'), isFalse);
      await r.dispose(tester);
    });

    testWidgets('a source that needs a key shows Get key in place of the switch; with a key it shows Replace', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, SourcePage(deps: r.deps, sourceId: 'firms-viirs-near'));
      await tester.pumpAndSettle();
      expect(find.text('Needs your own key'), findsOneWidget);
      expect(find.text('Get key'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      await tester.tap(find.text('Get key'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('key-field')), secret);
      await tester.tap(find.byKey(const ValueKey('check-and-save')));
      await tester.pumpAndSettle();
      expect(find.text('Replace'), findsOneWidget);
      expect(find.text('Saved on this device, not shown again'), findsOneWidget);
      expect(find.textContaining(secret), findsNothing);
      expect(switchIn(tester, 'Use this source').value, isTrue);
      await r.dispose(tester);
    });
  });

  group('A key on its source', () {
    testWidgets('a saved key is never shown, and is replaced or removed (after asking) on its source', (tester) async {
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() => r.weather.saveKey(r.weather.sourceById('firms-viirs-near')!, secret));
      await r.show(tester, SourcePage(deps: r.deps, sourceId: 'firms-viirs-near'));
      await tester.pumpAndSettle();
      expect(find.textContaining(secret), findsNothing);
      // replace
      await tester.tap(find.text('Replace'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('key-field')), '$secret-2');
      await tester.tap(find.byKey(const ValueKey('check-and-save')));
      await tester.pumpAndSettle();
      expect(r.liveCore.keys['firms-viirs-near'], '$secret-2');
      expect(find.text('Key replaced'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      // remove
      await tester.tap(find.byKey(const ValueKey('remove-key')));
      await tester.pumpAndSettle();
      expect(find.textContaining('turns off'), findsOneWidget);
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(r.weather.hasKey('firms'), isTrue);
      await tester.tap(find.byKey(const ValueKey('remove-key')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-remove-key')));
      await tester.pumpAndSettle();
      expect(r.weather.hasKey('firms'), isFalse);
      expect(r.secrets.values, isEmpty);
      expect(r.liveCore.keys['firms-viirs-near'], isNull);
      expect(find.text('Get key'), findsOneWidget);
      await r.dispose(tester);
    });
  });

  group('Your own sources', () {
    const api = 'https://sensors.example.org/api/creek';
    const answer = {
      'station': {'id': 'site-12', 'latitude': 42.53, 'longitude': -113.79},
      'water': {'level': 1.42, 'trend': 'Rising'},
      'updated': '12:40',
    };

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
    }

    testWidgets('the Latitude and Longitude buttons keep the focus in the address, the cursor after what they put in', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await r.show(tester, MoreSourcesPage(deps: r.deps));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-own-source')));
      await tester.pumpAndSettle();
      final addr = find.byKey(const ValueKey('own-address'));
      await tester.tap(addr);
      await tester.pumpAndSettle();
      await tester.enterText(addr, '$api?site=12&lat=');
      await tester.pump();
      TextField f() => tester.widget<TextField>(addr);
      await tester.tap(find.byKey(const ValueKey('insert-lat')));
      await tester.pump();
      expect(f().focusNode!.hasFocus, isTrue, reason: 'the button did not take the focus');
      expect(f().controller!.text, '$api?site=12&lat={lat}');
      expect(f().controller!.selection, TextSelection.collapsed(offset: f().controller!.text.length));
      await tester.enterText(addr, '${f().controller!.text}&lon=');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('insert-lon')));
      await tester.pump();
      expect(f().focusNode!.hasFocus, isTrue);
      expect(f().controller!.text, '$api?site=12&lat={lat}&lon={lon}');
      expect(f().controller!.selection, TextSelection.collapsed(offset: f().controller!.text.length));
    });

    testWidgets('More sources: Add your own source, the form, Try it, pick what to show, Save source; it is on under Your own', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      r.web.files['$api?site=12&lat=42.5400&lon=-113.7900&key=$secret'] = utf8.encode(jsonEncode(answer));
      await r.show(tester, MoreSourcesPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.text('Your own'.toUpperCase()), findsNothing, reason: 'nothing of your own yet');
      expect(find.text('Any web service that gives data'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('add-own-source')));
      await tester.pumpAndSettle();
      expect(find.text('Add your own source'), findsWidgets);
      // nothing typed: says what is missing, asks nothing
      await tester.tap(find.byKey(const ValueKey('own-try')));
      await tester.pumpAndSettle();
      expect(find.text('Give the source a name.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('own-name')), 'Creek level at the bridge');
      await tester.enterText(find.byKey(const ValueKey('own-address')), '$api?site=12&lat=');
      await tester.tap(find.byKey(const ValueKey('insert-lat')));
      await tester.pump();
      final field = tester.widget<TextField>(find.byKey(const ValueKey('own-address')));
      field.controller!.text = '${field.controller!.text}&lon=';
      await tester.tap(find.byKey(const ValueKey('insert-lon')));
      await tester.pump();
      expect(field.controller!.text, '$api?site=12&lat={lat}&lon={lon}');
      // a key that is not in the address
      await tester.enterText(find.byKey(const ValueKey('own-key')), secret);
      await tester.tap(find.byKey(const ValueKey('own-try')));
      await tester.pumpAndSettle();
      expect(find.text('Put your key in the web address where the service asks for it.'), findsOneWidget);
      field.controller!.text = '${field.controller!.text}&key=$secret';
      await tester.tap(find.byKey(const ValueKey('own-try')));
      await settle(tester);
      expect(find.text('Pick what to show'), findsOneWidget);
      expect(find.text('It answered. Here is what came back.'), findsOneWidget);
      expect(find.text('Latitude'), findsOneWidget, reason: 'a value of the answer, named from its key');
      expect(find.text('1.42'), findsOneWidget);
      expect(find.byKey(const ValueKey('own-preview')), findsOneWidget);
      // the first three are ticked; tick the level and the trend only, and rename the level
      for (final p in ['station.id', 'station.latitude', 'station.longitude']) {
        final box = find.descendant(of: find.byKey(ValueKey('own-value-$p')), matching: find.byType(Checkbox));
        if (tester.widget<Checkbox>(box).value == true) await tester.tap(box);
        await tester.pump();
      }
      await tester.scrollUntilVisible(find.byKey(const ValueKey('own-value-water.level')), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('own-value-water.level')), matching: find.byType(Checkbox)));
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('own-value-water.trend')), matching: find.byType(Checkbox)));
      await tester.pump();
      await tester.tap(find.text('Level'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('own-rename')), 'Water level');
      await tester.tap(find.byKey(const ValueKey('own-rename-save')));
      await tester.pumpAndSettle();
      expect(find.text('Water level 1.42'), findsOneWidget, reason: 'the preview');
      await tester.tap(find.byKey(const ValueKey('own-save')));
      await settle(tester);
      // back on More sources, under Your own, on
      expect(find.text('Pick what to show'), findsNothing);
      expect(find.text('YOUR OWN'), findsOneWidget);
      expect(find.text('Creek level at the bridge'), findsOneWidget);
      expect(find.text('Your source · checked every 30 min'), findsOneWidget);
      expect(switchIn(tester, 'Creek level at the bridge').value, isTrue);
      final c = r.weather.ownSources.single;
      expect(c.id, 'own-creek-level-at-the-bridge');
      expect(r.weather.isOn(c.id), isTrue);
      expect(c.defText, isNot(contains(secret)), reason: 'the key is never in the definition');
      expect(c.defText, contains('{api_key}'));
      expect(await r.secrets.read('live.key.${c.id}'), secret);
      expect(r.liveCore.checked.last, c.defText, reason: 'the core checked it as it checks every definition');
      expect(r.liveCore.keys[c.id], secret, reason: 'the core gets the key in memory');
      expect(File('${r.liveDir.path}/${c.id}.json').readAsStringSync(), isNot(contains(secret)));
      await r.dispose(tester);
    });

    testWidgets('Try it says plainly why there are no values (HTTP error, not JSON), and Try again', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await r.show(tester, OwnSourceFormPage(deps: r.deps));
      await tester.enterText(find.byKey(const ValueKey('own-name')), 'Gauge');
      await tester.enterText(find.byKey(const ValueKey('own-address')), '$api/missing');
      await tester.tap(find.byKey(const ValueKey('own-try')));
      await settle(tester);
      expect(find.text('sensors.example.org answered with an error (HTTP 404).'), findsOneWidget);
      r.web.files['$api/missing'] = utf8.encode('<html>hello</html>');
      await tester.tap(find.byKey(const ValueKey('own-again')));
      await settle(tester);
      expect(find.text('sensors.example.org answered, but not with JSON. This version of Cache only reads JSON.'), findsOneWidget);
      r.web.files['$api/missing'] = utf8.encode('{"v": 3}');
      await tester.tap(find.byKey(const ValueKey('own-again')));
      await settle(tester);
      expect(find.text('It answered. Here is what came back.'), findsOneWidget);
      expect(r.weather.ownSources, isEmpty, reason: 'nothing is saved before Save source');
      await r.dispose(tester);
    });

    testWidgets('a source of your own opens to be edited or removed; removing takes its key too', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() => r.weather.saveOwnSource(
        const OwnDraft(name: 'Creek', address: '$api?k=$secret', key: secret),
        const [OwnPick('water.level', 'Water level')],
      ));
      final id = r.weather.ownSources.single.id;
      await r.show(tester, MoreSourcesPage(deps: r.deps));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Creek'));
      await settle(tester);
      expect(find.byKey(const ValueKey('edit-own')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('edit-own')));
      await tester.pumpAndSettle();
      expect(find.text('Edit source'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('own-address'))).controller!.text, '$api?k={api_key}');
      expect(find.text('Saved. Type a new one to replace it.'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('remove-own')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-remove-own')));
      await settle(tester);
      expect(r.weather.ownSources, isEmpty);
      expect(r.weather.isOn(id), isFalse);
      expect(await r.secrets.read('live.key.$id'), isNull);
      await r.dispose(tester);
    });

    testWidgets('Or import a source file: a list from a link is checked and shown, then added under Your own, off', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      const other = 'https://example.org/c/';
      r.web.serve(other, buildCatalogue(id: 'friends', title: 'Friends', base: other, connectors: [entry('river-x', 'hydrology', 'River X', provider: 'Friends'), entry('bad-one', 'weather', 'Bad one')]));
      r.liveCore.invalid.add('bad-one');
      await r.show(tester, MoreSourcesPage(deps: r.deps));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-own-source')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('own-import')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('import-link')), '${other}catalogue.json');
      await tester.tap(find.byKey(const ValueKey('import-check')));
      await settle(tester);
      expect(find.textContaining('This adds 1 source to Your own.'), findsOneWidget);
      expect(find.text('River X · Friends · US'), findsOneWidget);
      expect(find.text('Left out (1)'), findsOneWidget);
      expect(r.weather.sourceById('river-x'), isNull, reason: 'not kept yet');
      await tester.tap(find.byKey(const ValueKey('import-add')));
      await settle(tester);
      final x = r.weather.sourceById('river-x')!;
      expect(r.weather.isOwn(x), isTrue);
      expect(r.weather.isOn('river-x'), isFalse);
      expect(r.settings.extraCatalogues, isEmpty, reason: 'a list is read once, not followed');
      // and one source from a file
      expect(find.byType(MoreSourcesPage), findsOneWidget, reason: 'adding goes back to More sources');
      expect(find.text('River X'), findsOneWidget, reason: 'under Your own');
      Navigator.of(tester.element(find.byType(MoreSourcesPage))).push(MaterialPageRoute<void>(builder: (_) => OwnImportPage(deps: r.deps, pickText: () async => miniDefinition('my-quakes', title: 'My quakes'))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('import-file')));
      await settle(tester);
      expect(find.textContaining('This adds 1 source'), findsOneWidget);
      expect(find.text('My quakes · Provider'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('import-add')));
      await settle(tester);
      expect(r.weather.isOwn(r.weather.sourceById('my-quakes')!), isTrue);
      await r.dispose(tester);
    });

    testWidgets('a link that is not https, or not a source file, says so', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, OwnImportPage(deps: r.deps));
      await tester.enterText(find.byKey(const ValueKey('import-link')), 'http://example.org/c.json');
      await tester.tap(find.byKey(const ValueKey('import-check')));
      await settle(tester);
      expect(find.text('Enter an address that starts with https://'), findsOneWidget);
      r.web.files['https://example.org/not.json'] = 'hello'.codeUnits;
      await tester.enterText(find.byKey(const ValueKey('import-link')), 'https://example.org/not.json');
      await tester.tap(find.byKey(const ValueKey('import-check')));
      await settle(tester);
      expect(find.textContaining("This isn't a source file"), findsOneWidget);
      await r.dispose(tester);
    });
  });

  group('Storage > Advanced > Source list address', () {
    testWidgets('changes where the source list comes from, and Use the default puts it back', (tester) async {
      final r = await SettingsRig.create(tester);
      const mine = 'https://mine.example.org/c/';
      r.web.serve(mine, buildCatalogue(id: 'mine', title: 'Mine', base: mine, connectors: [entry('my-quakes', 'earthquakes', 'My quakes')]));
      await r.show(tester, IndexingSpeedPage(settings: r.settings, weather: r.weather));
      await tester.pumpAndSettle();
      expect(find.text('Source list address'), findsOneWidget);
      expect(find.textContaining('Default · https://data.cached.info/connectors/catalogue.json'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('source-list-address')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('source-list-field')), 'http://mine.example.org/c.json');
      await tester.tap(find.byKey(const ValueKey('source-list-save')));
      await tester.pumpAndSettle();
      expect(r.settings.catalogueUrl, isNull, reason: 'not https: refused');
      await tester.tap(find.byKey(const ValueKey('source-list-address')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('source-list-field')), '${mine}catalogue.json');
      await tester.tap(find.byKey(const ValueKey('source-list-save')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(r.settings.catalogueUrl, '${mine}catalogue.json');
      expect(r.weather.sourceById('my-quakes'), isNotNull);
      expect(find.text('${mine}catalogue.json'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('source-list-address')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-list-default')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(r.settings.catalogueUrl, isNull);
      expect(r.weather.sourceById('usgs-quakes-near'), isNotNull);
      await r.dispose(tester);
    });
  });
}
