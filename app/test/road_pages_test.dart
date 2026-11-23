// Settings > Maps > Road events: adding a 511 site or a road work feed, the key rows, the switches. Every key here is made up.

import 'dart:convert';

import 'package:cache/screens/settings/maps_page.dart';
import 'package:cache/screens/settings/road_pages.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

const String _registry =
    '[{"feedname":"iddot","url":"https://511.idaho.gov/api/wzdx","version":"4.1"},'
    '{"feedname":"ohio","url":"https://example.org/ohio?api-key=SENTINEL-OHIO","version":"4.2"},'
    '{"feedname":"ptc","url":"https://example.org/ptc?api_key=SENTINEL-PTC","version":"4.1"},'
    '{"feedname":"cdot_cwz","url":"https://example.org/cwz","version":"CWZ 1.0"}]';

Future<void> _tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).first);
  await tester.tap(find.text(text).first);
  await tester.pumpAndSettle();
}

/// Lets a tap's work and a notice's slide-in happen, without waiting out the notice (pumpAndSettle would).
Future<void> _brief(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('Maps: the Road events group has the two ways to add a source and nothing else at first', (tester) async {
    final r = await SettingsRig.create(tester, roadSources: true);
    await r.show(tester, MapsPage(deps: r.deps));
    expect(find.text('ROAD EVENTS'), findsOneWidget);
    expect(find.text('Add a 511 site'), findsOneWidget);
    expect(find.text('16 state and provincial sites', findRichText: true), findsOneWidget);
    expect(find.text('Add a road work feed'), findsOneWidget);
    expect(find.text('511 road events'), findsNothing);
    expect(find.text('ROAD EVENT KEYS'), findsNothing);
    await r.dispose(tester);
  });

  testWidgets('without road sources the Maps page is as it was', (tester) async {
    final r = await SettingsRig.create(tester);
    await r.show(tester, MapsPage(deps: r.deps));
    expect(find.text('ROAD EVENTS'), findsNothing);
    await r.dispose(tester);
  });

  testWidgets('adding a 511 site: search, the sites by country, a tap adds it and opens its key sheet; adding turns nothing on', (tester) async {
    final r = await SettingsRig.create(tester, roadSources: true);
    await r.show(tester, MapsPage(deps: r.deps));
    await _tapText(tester, 'Add a 511 site');
    expect(find.text('Search 16 sites'), findsOneWidget);
    expect(find.text('Enter another site'), findsOneWidget);
    expect(find.text('Idaho'), findsOneWidget);
    expect(find.text('511.idaho.gov'), findsOneWidget);
    expect(find.text('UNITED STATES'), findsOneWidget);
    expect(find.text('CANADA'), findsOneWidget);
    // search by name or host
    await tester.enterText(find.byKey(const ValueKey('road-search')), 'ont');
    await tester.pumpAndSettle();
    expect(find.text('Ontario'), findsOneWidget);
    expect(find.text('Idaho'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('road-search')), 'udot');
    await tester.pumpAndSettle();
    expect(find.text('Utah'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('road-search')), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No site matches "zzz".'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('road-search')), '');
    await tester.pumpAndSettle();
    // a tap adds it and opens the API keys list at its key, open (never the sheet itself)
    await tester.tap(find.byKey(const ValueKey('site-511.idaho.gov')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('api-key-open-road511.511.idaho.gov')), findsOneWidget);
    expect(find.byKey(const ValueKey('key-field')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('add-road511.511.idaho.gov')));
    await tester.pumpAndSettle();
    expect(find.text('Add your 511 key (511.idaho.gov)'), findsOneWidget);
    expect(find.text('Get a key from Idaho'), findsOneWidget);
    expect(find.text('https://511.idaho.gov/developers/doc'), findsWidgets);
    expect(find.text('Create an account on the site, or sign in.'), findsOneWidget);
    expect(find.text('Request a Developer API key.'), findsOneWidget);
    expect(find.textContaining('Ten calls every 60 seconds'), findsWidgets);
    expect(find.textContaining('Saving turns nothing on'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('get-key')));
    await tester.pump();
    expect(r.opened, ['https://511.idaho.gov/developers/doc']);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(MapsPage), findsOneWidget);
    expect(find.text('511 road events'), findsOneWidget);
    expect(find.textContaining('Idaho · 511.idaho.gov', findRichText: true), findsOneWidget);
    expect(find.textContaining('Needs a key', findRichText: true), findsNothing, reason: 'a keyed source with no key is silent');
    expect(find.text('511 key (511.idaho.gov)'), findsOneWidget);
    expect(find.text('Not set'), findsWidgets);
    expect(r.settings.liveSourcesOn.where((id) => id.contains('idaho')), isEmpty, reason: 'adding a site turns nothing on');
    await r.dispose(tester);
  });

  testWidgets('saving the key keeps it for the one site and turns nothing on; the switch turns on both of the site\'s sources', (tester) async {
    final r = await SettingsRig.create(tester, roadSources: true);
    await r.show(tester, MapsPage(deps: r.deps));
    await _tapText(tester, 'Add a 511 site');
    await tester.tap(find.byKey(const ValueKey('site-511.idaho.gov')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-road511.511.idaho.gov')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('key-field')), 'SENTINEL-511-KEY');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('check-and-save')));
    await _brief(tester);
    expect(find.text('Key saved'), findsOneWidget);
    expect(r.secrets.values['live.key.road511.511.idaho.gov'], 'SENTINEL-511-KEY');
    expect(find.text('Set'), findsWidgets);
    await tester.pump(const Duration(seconds: 5));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(r.settings.liveSourcesOn.where((id) => id.contains('idaho')), isEmpty, reason: 'saving a key turns nothing on');
    expect(jsonEncode(r.liveCore.everythingSeen()), isNot(contains('SENTINEL-511-KEY')));
    // the switch
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(r.settings.liveSourcesOn, containsAll(['idaho511-events', 'idaho511-winter-roads']));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(r.settings.liveSourcesOn.where((id) => id.contains('idaho')), isEmpty);
    await r.dispose(tester);
  });

  testWidgets('Enter another site: a host name adds a site that is not listed; text that is not an address is refused', (tester) async {
    final r = await SettingsRig.create(tester, roadSources: true);
    await r.show(tester, MapsPage(deps: r.deps));
    await _tapText(tester, 'Add a 511 site');
    await _tapText(tester, 'Enter another site');
    await tester.enterText(find.byKey(const ValueKey('other-site-field')), 'not an address');
    await tester.tap(find.byKey(const ValueKey('other-site-add')));
    await _brief(tester);
    expect(find.text("That isn't a web address."), findsOneWidget);
    await _tapText(tester, 'Enter another site');
    await tester.enterText(find.byKey(const ValueKey('other-site-field')), 'https://511.example.gov/developers');
    await tester.tap(find.byKey(const ValueKey('other-site-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('api-key-open-road511.511.example.gov')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-road511.511.example.gov')));
    await tester.pumpAndSettle();
    expect(find.text('Add your 511 key (511.example.gov)'), findsOneWidget);
    expect(find.text('https://511.example.gov/developers/doc'), findsWidgets);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('511 key (511.example.gov)'), findsOneWidget);
    expect(r.settings.roadSources.single['id'], '511.example.gov');
    await r.dispose(tester);
  });

  testWidgets('adding road work: the feeds with what each needs, not usable ones greyed with the reason, a feed with no key added at once', (tester) async {
    final r = await SettingsRig.create(tester, roadSources: true);
    // the registry is read through the page's own fetch: here the page is shown with a fake one
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: RoadWorkPickerPage(deps: r.deps, fetch: (_) async => utf8.encode(_registry))));
    await tester.pumpAndSettle();
    expect(find.text('Search 42 feeds'), findsOneWidget);
    expect(find.text('Paste a feed URL'), findsOneWidget);
    expect(find.text('Idaho DOT'), findsOneWidget);
    expect(find.text('Ohio DOT'), findsOneWidget);
    expect(find.textContaining('Idaho · version 4.1 · every 1m', findRichText: true), findsOneWidget);
    expect(find.textContaining('Ohio · version 4.2', findRichText: true), findsOneWidget);
    expect(find.textContaining('key needed', findRichText: true), findsWidgets);
    // by request and not supported yet: listed, greyed, with the reason (found by searching: the list is long)
    await tester.enterText(find.byKey(const ValueKey('road-search')), 'pennsylvania');
    await tester.pumpAndSettle();
    expect(find.text('BY REQUEST'), findsOneWidget);
    expect(find.textContaining('Access by request from the publisher', findRichText: true), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('road-search')), 'illinois');
    await tester.pumpAndSettle();
    expect(find.text('NOT SUPPORTED YET'), findsOneWidget);
    expect(find.textContaining('Connected Work Zones 1.0 is not supported yet', findRichText: true), findsOneWidget);
    expect(find.textContaining('Key instructions not verified yet', findRichText: true), findsOneWidget);
    // searching
    await tester.enterText(find.byKey(const ValueKey('road-search')), 'york');
    await tester.pumpAndSettle();
    expect(find.text('New York DOT'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('road-search')), 'pennsylvania');
    await tester.pumpAndSettle();
    // a by-request feed says so and adds nothing
    await tester.tap(find.byKey(const ValueKey('feed-ptc')));
    await _brief(tester);
    expect(find.text('Access is by request from the publisher.'), findsOneWidget);
    expect(r.settings.roadSources, isEmpty);
    await r.dispose(tester);
  });

  testWidgets('a feed that needs a key opens its key sheet; the publisher\'s own token is never stored; a feed with no key is added and says to switch it on', (tester) async {
    final r = await SettingsRig.create(tester, roadSources: true);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: RoadWorkPickerPage(deps: r.deps, fetch: (_) async => utf8.encode(_registry))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('road-search')), 'ohio');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('feed-ohio')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('api-key-open-wzdx.ohio')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-wzdx.ohio')));
    await tester.pumpAndSettle();
    expect(find.text('Add your WZDx key (Ohio DOT)'), findsOneWidget);
    expect(find.text('Get a key from Ohio DOT'), findsOneWidget);
    expect(find.textContaining('SENTINEL'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(r.settings.roadSources.single['id'], 'ohio');
    expect(r.settings.roadSources.single['url'], 'https://example.org/ohio', reason: 'the publisher\'s token was removed');
    expect(jsonEncode(r.settings.roadSources), isNot(contains('SENTINEL')));
    await r.dispose(tester);
  });

  testWidgets('Paste a feed URL: a key in the address is removed and the person is told, without the value', (tester) async {
    final r = await SettingsRig.create(tester, roadSources: true);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: Scaffold(body: Builder(builder: (context) => Center(child: FilledButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RoadWorkPickerPage(deps: r.deps, fetch: (_) async => utf8.encode(_registry)))), child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await _tapText(tester, 'Paste a feed URL');
    await tester.enterText(find.byKey(const ValueKey('paste-feed-field')), 'ftp://example.org/feed');
    await tester.tap(find.byKey(const ValueKey('paste-feed-add')));
    await tester.pumpAndSettle();
    expect(find.text('Enter an address that starts with https://'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('paste-feed-field')), 'https://example.org/feed?token=SENTINEL-PASTE&state=ID');
    await tester.tap(find.byKey(const ValueKey('paste-feed-add')));
    await _brief(tester);
    expect(find.text('Any key in the address was removed. Add your key in Settings > API keys.'), findsOneWidget);
    expect(r.settings.roadSources.single['url'], 'https://example.org/feed?state=ID');
    expect(jsonEncode(r.settings.roadSources), isNot(contains('SENTINEL')));
    await r.dispose(tester);
  });

  testWidgets('pressing and holding a source removes it after asking; its key stays', (tester) async {
    final r = await SettingsRig.create(tester, roadSources: true);
    r.weather.roads!.addSite(r.weather.roads!.file.siteByHost('511wi.gov')!);
    r.secrets.values['live.key.road511.511wi.gov'] = 'SENTINEL-WI';
    await r.show(tester, MapsPage(deps: r.deps));
    await tester.pumpAndSettle();
    expect(find.textContaining('Wisconsin · 511wi.gov', findRichText: true), findsOneWidget);
    await tester.longPress(find.text('511 road events'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('remove-road-source')));
    await tester.pumpAndSettle();
    expect(find.text('511 road events'), findsNothing);
    expect(r.settings.roadSources, isEmpty);
    expect(r.secrets.values['live.key.road511.511wi.gov'], 'SENTINEL-WI');
    await r.dispose(tester);
  });
}
