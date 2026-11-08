import 'dart:io';

import 'package:cache/discover/discover_state.dart';
import 'package:cache/discover/ui/activity_page.dart';
import 'package:cache/discover/ui/discover_screen.dart';
import 'package:cache/discover/ui/progress_page.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/discover_fakes.dart';

Widget _app(Widget home) => MaterialApp(theme: buildTheme(CacheThemeId.light), home: home);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late FakeDiscoverDevice dev;

  setUp(() {
    dev = FakeDiscoverDevice();
    // sizes as the live catalogue would give them
    dev.sizes['library:wikipedia_en_medicine:maxi'] = 1400 << 20;
  });

  Future<void> tapKey(WidgetTester tester, String key) async {
    final f = find.byKey(ValueKey(key));
    await tester.ensureVisible(f);
    await tester.tap(f);
    await _settle(tester);
  }

  group('the wizard', () {
    testWidgets('Next through five steps with the defaults, then Start adds the picked activities and shows their progress', (tester) async {
      // tall enough that the summary's full list is built without scrolling
      tester.view.physicalSize = const Size(390, 2400) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final d = await makeDiscover(dev, firstRunDone: false);
      var asked = 0;
      await tester.pumpWidget(_app(DiscoverScreen(
        discover: d,
        links: DiscoverLinks(askLocation: (_) async => asked++),
      )));
      await _settle(tester);

      expect(find.text('1 of 5'), findsOneWidget);
      expect(find.text('Welcome to Cache'), findsOneWidget);
      await tapKey(tester, 'wizard-next');

      expect(find.text('2 of 5'), findsOneWidget);
      expect(find.text('Where are you?'), findsOneWidget);
      await tapKey(tester, 'wizard-next');
      expect(asked, 1, reason: 'Where I am now (the default) asks for the location on Next');

      expect(find.text('3 of 5'), findsOneWidget);
      // Ready and Backcountry are picked by default; Backcountry's size is what it adds on top of Ready
      expect(find.textContaining('selected'), findsOneWidget);
      expect(find.textContaining('+'), findsOneWidget);
      await tapKey(tester, 'wizard-activity-homestead');
      await tapKey(tester, 'wizard-activity-homestead');
      await tapKey(tester, 'wizard-next');

      expect(find.text('4 of 5'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      await tapKey(tester, 'wizard-next');

      expect(find.text('5 of 5'), findsOneWidget);
      expect(find.text('Ready to start'), findsOneWidget);
      expect(find.text('to download · 38.0 GB free'), findsOneWidget);
      expect(find.text('National Weather Service'), findsOneWidget, reason: 'outside sources by name');
      expect(find.text('Field manuals · 7.7 GB'), findsNothing, reason: 'the full list is behind See everything');
      await tapKey(tester, 'wizard-see-everything');
      expect(find.textContaining('Field manuals · 7.7 GB'), findsOneWidget);
      expect(dev.added, isEmpty, reason: 'nothing installs before Start');

      await tapKey(tester, 'wizard-next');
      expect(d.ledger.activities.keys, ['ready', 'backcountry']);
      expect(d.firstRunDone, isTrue);
      expect(dev.added, contains('library:armypubs_en_all'));
      expect(dev.settings['live:nws-alerts-point'], true);
      expect(find.byType(ProgressPage), findsOneWidget);
      expect(find.text('Adding Ready and Backcountry'), findsOneWidget);
    });

    testWidgets('Skip skips a step; with no activity the summary adds nothing and Start only finishes first run', (tester) async {
      final d = await makeDiscover(dev, firstRunDone: false);
      await tester.pumpWidget(_app(DiscoverScreen(discover: d, links: const DiscoverLinks())));
      await _settle(tester);
      await tapKey(tester, 'wizard-skip');
      expect(find.text('2 of 5'), findsOneWidget);
      await tapKey(tester, 'wizard-skip');
      await tapKey(tester, 'wizard-skip'); // the activities step: none picked
      await tapKey(tester, 'wizard-skip');
      expect(find.text('5 of 5'), findsOneWidget);
      expect(find.text('Nothing to add'), findsOneWidget);
      await tapKey(tester, 'wizard-next');
      expect(d.firstRunDone, isTrue);
      expect(d.ledger.activities, isEmpty);
      expect(dev.added, isEmpty);
      expect(find.text('Discover'), findsWidgets, reason: 'the store once first run is done');
    });
  });

  group('the Get sheet', () {
    Future<DiscoverState> listing(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final d = await makeDiscover(dev);
      final ready = d.catalogue.activity('ready')!;
      // Ready without the fire feed, so Backcountry has a source to turn on
      d.setLeftOut(ready, 'live:wfigs-incidents-near', true);
      await d.get(ready);
      dev.added.clear();
      dev.writes.clear();
      await tester.pumpWidget(_app(ActivityPage(discover: d, activity: d.catalogue.activity('backcountry')!)));
      await _settle(tester);
      return d;
    }

    testWidgets('names the size against free space, every outside source and the changes before anything installs', (tester) async {
      final d = await listing(tester);
      await tapKey(tester, 'activity-get');
      expect(find.byKey(const ValueKey('get-sheet')), findsOneWidget);
      expect(find.text('Add Backcountry'), findsOneWidget);
      final size = tester.widget<Text>(find.byKey(const ValueKey('sheet-size'))).data!;
      expect(size, endsWith('38.0 GB free'));
      final connects = tester.widget<Text>(find.descendant(of: find.byKey(const ValueKey('get-connects')), matching: find.byType(Text)).last).data!;
      expect(connects, contains('Kiwix'));
      expect(connects, contains('Fire incident feed'));
      expect(find.text('Turns on weather and alerts'), findsOneWidget);

      await tapKey(tester, 'get-details');
      final lines = tester.widget<Text>(find.descendant(of: find.byKey(const ValueKey('get-downloads')), matching: find.byType(Text))).data!;
      // every item it adds, and not the ones Ready already brought
      for (final t in ['Military medicine', 'Medical encyclopedia · 1.4 GB', 'Outdoors Q&A', 'Knots', 'Hikes', 'Wildlife sightings']) {
        expect(lines, contains(t));
      }
      expect(lines, isNot(contains('Water treatment')));
      expect(lines, isNot(contains('Field and emergency medicine')));
      final changes = tester.widget<Text>(find.descendant(of: find.byKey(const ValueKey('get-change-lines')), matching: find.byType(Text))).data!;
      expect(changes, contains('Wildfires near the place (WFIGS) on'));

      await tapKey(tester, 'get-cancel');
      expect(dev.added, isEmpty, reason: 'Cancel adds nothing');
      expect(d.ledger.has('backcountry'), isFalse);

      await tapKey(tester, 'activity-get');
      await tapKey(tester, 'get-confirm');
      expect(d.ledger.has('backcountry'), isTrue);
      expect(dev.added, containsAll(['library:irp.fas.org_en_military-medicine', 'library:zimgit-knots_en']));
      expect(dev.added, isNot(contains('library:zimgit-water_en')), reason: 'shared with Ready: downloaded once');
      expect(find.text('Adding Backcountry'), findsOneWidget);
    });

    testWidgets('Get is off when it does not fit the free space', (tester) async {
      dev.free = 100 << 20;
      await listing(tester);
      await tapKey(tester, 'activity-get');
      expect(find.byKey(const ValueKey('sheet-too-big')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.descendant(of: find.byKey(const ValueKey('get-confirm')), matching: find.byType(FilledButton))).onPressed, isNull);
    });

    testWidgets('Remove on an added activity says what stays and removes only what nothing else holds', (tester) async {
      final d = await listing(tester);
      await d.get(d.catalogue.activity('backcountry')!);
      await _settle(tester);
      await tapKey(tester, 'activity-added');
      expect(find.byKey(const ValueKey('remove-sheet')), findsOneWidget);
      expect(find.text('Your notes, places and settings you changed'), findsOneWidget);
      await tapKey(tester, 'remove-confirm');
      expect(d.ledger.has('backcountry'), isFalse);
      expect(dev.dropped, contains('library:zimgit-knots_en'));
      expect(dev.dropped, isNot(contains('library:zimgit-water_en')), reason: 'Ready still holds it');
      expect(dev.settings['live:nws-alerts-point'], true, reason: 'Ready still holds it');
    });
  });

  test('discover.json keeps what was added and whether first run is done', () async {
    final dir = Directory.systemTemp.createTempSync('discover');
    addTearDown(() => dir.deleteSync(recursive: true));
    final d = await makeDiscover(dev, dir: dir);
    await d.get(d.catalogue.activity('homestead')!);
    final again = await makeDiscover(dev, dir: dir, firstRunDone: false);
    expect(again.firstRunDone, isTrue);
    expect(again.ledger.has('homestead'), isTrue);
    expect(again.ledger.items.keys, contains('library:usda-2015_en'));
  });
}
