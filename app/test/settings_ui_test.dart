import 'dart:io';

import 'package:cache/screens/settings/assistant_page.dart';
import 'package:cache/screens/settings/notifications_page.dart';
import 'package:cache/screens/settings/storage_page.dart';
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/settings/location_access.dart';
import 'package:cache/settings/web_search_setup.dart';
import 'package:cache/theme.dart';
import 'package:cache/location/position_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

Finder rowWith(String title) => find.ancestor(of: find.text(title), matching: find.byType(InkWell)).first;

Switch switchIn(WidgetTester tester, String title) =>
    tester.widget<Switch>(find.descendant(of: rowWith(title), matching: find.byType(Switch)));

void main() {
  group('the Settings home: every row says its state, from the real state', () {
    testWidgets('a fresh phone: eight rows, each with its state in one line', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, SettingsScreen(deps: r.deps));
      await tester.pump();
      for (final title in [
        'Cache model and web search', 'Maps', 'Weather and alerts', 'Notifications', 'Storage', 'Sharing and sync', 'Appearance',
        'Credits and licences',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      for (final gone in ['Library', 'Videos', 'Set up Cache', 'Assistant']) {
        expect(find.text(gone), findsNothing, reason: '$gone is not a Settings row');
      }
      expect(find.text('Choose a model · web search off'), findsOneWidget);
      expect(find.text('No regions yet · miles'), findsOneWidget);
      expect(find.text('Nothing on'), findsOneWidget, reason: 'Weather and alerts');
      expect(find.text('Serious alerts · quiet 10 PM–6 AM'), findsOneWidget);
      expect(find.textContaining('41.0 GB free'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget, reason: 'Sharing and sync is not set up');
      expect(find.text('Dark'), findsOneWidget);
      expect(find.text('1.0.0 · AGPL-3.0'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('after the person changes things', (tester) async {
      final r = await SettingsRig.create(tester);
      File('${r.sources.zimsDir!.path}/a.zim').openSync(mode: FileMode.write)
        ..truncateSync(3 << 20)
        ..closeSync();
      File('${r.sources.zimsDir!.path}/b.zim').openSync(mode: FileMode.write)
        ..truncateSync(2 << 20)
        ..closeSync();
      await tester.runAsync(r.sources.refresh);
      await tester.runAsync(r.storage.measure);
      await r.show(tester, SettingsScreen(deps: r.deps));
      expect(find.text('5.0 MB used · 41.0 GB free'), findsOneWidget);
      expect(r.storage.bytesOf('library'), 5 << 20);

      r.settings.setPopUpFor(PopUpFor.all);
      r.settings.setQuiet(const QuietHours(on: true, from: 23 * 60, to: 5 * 60 + 30));
      await r.webSearch.saveKey('abc');
      await tester.runAsync(() => r.app.setTheme(CacheThemeId.tactical));
      await tester.pump();
      expect(find.text('All alerts · quiet 11 PM–5:30 AM'), findsOneWidget);
      expect(find.text('Choose a model · web search on'), findsOneWidget);
      expect(find.text('Tactical'), findsOneWidget);
      r.settings.setQuiet(r.settings.quiet.copyWith(on: false));
      await tester.pump();
      expect(find.text('All alerts'), findsOneWidget);
      r.settings.setPopUpFor(PopUpFor.none);
      await tester.pump();
      expect(find.text('No pop-ups'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('Sharing and sync is off until set up and opens its page; Weather and alerts opens its page', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, SettingsScreen(deps: r.deps));
      expect(find.text('Off'), findsOneWidget, reason: 'sharing is not set up');
      await tester.tap(find.text('Sharing and sync'));
      await tester.pumpAndSettle();
      expect(find.text('Set up sharing'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Weather and alerts'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('weather-refresh')), findsOneWidget, reason: 'the Weather and alerts page');
      await r.dispose(tester);
    });

    testWidgets('a row opens its page', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, SettingsScreen(deps: r.deps));
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      expect(find.text('Parchment'), findsOneWidget);
      await tester.tap(find.text('Light'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      expect(r.app.theme, CacheThemeId.light);
      await r.dispose(tester);
    });
  });

  group('Assistant: the search service and its key', () {
    testWidgets('web search stays off and says why until a key is saved', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, AssistantPage(deps: r.deps));
      expect(find.text('Not set up · Kagi, paid, your own key'), findsOneWidget);
      expect(find.text('Set up a search service to turn this on'), findsOneWidget);
      expect(switchIn(tester, 'Search the web when online').onChanged, isNull);
      expect(switchIn(tester, 'Search the web when online').value, isFalse);
      await r.dispose(tester);
    });

    testWidgets('Check and save: stores the key, turns web search on, tells the core, and never shows the key again', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, AssistantPage(deps: r.deps));
      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();
      expect(find.text('Web search'), findsWidgets);
      // The button opens the provider's key page in the browser.
      await tester.tap(find.byKey(const ValueKey('get-key')));
      await tester.pump();
      expect(r.opened, ['https://kagi.com/api/keys']);
      await tester.enterText(find.byKey(const ValueKey('key-field')), '  kagi-secret-123  ');
      await tester.tap(find.byKey(const ValueKey('check-and-save')));
      await tester.pumpAndSettle();
      expect(r.keysChecked, ['kagi-secret-123'], reason: 'checked once, trimmed');
      expect(r.secrets.values[WebSearchSetup.keyName], 'kagi-secret-123', reason: 'in secure storage');
      expect(r.webSearch.hasKey, isTrue);
      expect(r.settings.webSearchOn, isTrue);
      expect(r.webCalls.last, ('kagi', 'kagi-secret-123', true), reason: 'the core is told provider, key and online');
      // The sheet is closed and the key is nowhere on screen.
      expect(find.byKey(const ValueKey('key-field')), findsNothing);
      expect(find.textContaining('kagi-secret-123'), findsNothing);
      expect(find.text('Set up · Kagi key saved on this phone'), findsOneWidget);
      expect(switchIn(tester, 'Search the web when online').onChanged, isNotNull);
      expect(switchIn(tester, 'Search the web when online').value, isTrue);
      // The key is not in the saved preferences either.
      expect(File('${r.dir.path}/preferences.json').readAsStringSync(), isNot(contains('kagi-secret-123')));
      // Replacing starts with an empty field.
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('replace-key')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(const ValueKey('key-field'))).controller!.text, isEmpty);
      expect(find.textContaining('kagi-secret-123'), findsNothing);
      await r.dispose(tester);
    });

    testWidgets('a key that fails the check is not saved, and the error says why', (tester) async {
      final r = await SettingsRig.create(tester);
      r.searchContent = '{"ok":false,"error":{"type":"key_missing","detail":"web search key rejected"}}';
      await r.show(tester, AssistantPage(deps: r.deps));
      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('key-field')), 'not-a-key');
      await tester.tap(find.byKey(const ValueKey('check-and-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('key-error')), findsOneWidget);
      expect(find.text("Kagi didn't accept this key. Check you copied all of it."), findsOneWidget);
      expect(find.byKey(const ValueKey('key-field')), findsOneWidget, reason: 'the sheet stays so the key can be fixed');
      expect(r.secrets.values, isEmpty);
      expect(r.webSearch.hasKey, isFalse);
      expect(r.settings.webSearchOn, isFalse);
      expect(r.webCalls.last, (null, null, false), reason: 'the core is put back as it was: no key');
      // An empty field is refused before any call.
      await tester.enterText(find.byKey(const ValueKey('key-field')), '   ');
      await tester.tap(find.byKey(const ValueKey('check-and-save')));
      await tester.pumpAndSettle();
      expect(find.text('Paste your key first.'), findsOneWidget);
      expect(r.keysChecked, ['not-a-key']);
      await r.dispose(tester);
    });

    testWidgets('remove forgets the key and switches web search off', (tester) async {
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() => r.webSearch.saveKey('kagi-secret-123'));
      await r.show(tester, AssistantPage(deps: r.deps));
      expect(switchIn(tester, 'Search the web when online').value, isTrue);
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('remove-key')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-remove-key')));
      await tester.pumpAndSettle();
      expect(r.secrets.values, isEmpty);
      expect(r.webSearch.hasKey, isFalse);
      expect(r.webCalls.last, (null, null, false), reason: 'the core is told web search is off');
      expect(find.text('Not set up · Kagi, paid, your own key'), findsOneWidget);
      expect(switchIn(tester, 'Search the web when online').onChanged, isNull);
      await r.dispose(tester);
    });

    testWidgets('the switch turns web search on and off for the core', (tester) async {
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() => r.webSearch.saveKey('k'));
      await r.show(tester, AssistantPage(deps: r.deps));
      await tester.tap(find.descendant(of: rowWith('Search the web when online'), matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(r.settings.webSearchOn, isFalse);
      expect(r.webCalls.last.$1, isNull);
      await tester.tap(find.descendant(of: rowWith('Search the web when online'), matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(r.settings.webSearchOn, isTrue);
      expect(r.webCalls.last.$1, 'kagi');
      await r.dispose(tester);
    });

    testWidgets('a key already saved is found at start and given to the core; offline is passed on', (tester) async {
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() => r.webSearch.saveKey('k1'));
      r.probe.kind = ConnectionKind.none;
      final again = WebSearchSetup(
        settings: r.settings,
        secrets: r.secrets,
        setWeb: (p, k, o) async => r.webCalls.add((p, k, o)),
        probe: r.probe,
      );
      await tester.runAsync(again.init);
      expect(again.hasKey, isTrue);
      expect(r.webCalls.last, ('kagi', 'k1', false));
      again.dispose();
      await r.dispose(tester);
    });

    testWidgets('saved conversations are counted, open as a list, and delete-all asks first', (tester) async {
      final r = await SettingsRig.create(tester);
      r.store.create(title: 'Treating burns');
      r.store.create(title: 'Water purification');
      r.chat.historyRevision.value++;
      await r.show(tester, AssistantPage(deps: r.deps));
      expect(find.text('2 on this phone'), findsOneWidget);
      await tester.tap(find.text('Saved conversations'));
      await tester.pumpAndSettle();
      expect(find.text('Treating burns'), findsOneWidget);
      expect(find.text('Water purification'), findsOneWidget);
      await tester.tap(find.text('Water purification'));
      await tester.pumpAndSettle();
      expect(r.opened, contains('ask'), reason: 'Ask is brought forward');
      await tester.tap(find.text('Delete all conversations'));
      await tester.pumpAndSettle();
      expect(find.text('Delete all conversations?'), findsOneWidget);
      expect(r.store.list(), hasLength(2), reason: 'nothing deleted yet');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(r.store.list(), hasLength(2));
      await tester.tap(find.text('Delete all conversations'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete all'));
      await tester.pumpAndSettle();
      expect(r.store.list(), isEmpty);
      await r.dispose(tester);
    });
  });

  group('Notifications', () {
    testWidgets('one "Pop up for" choice with !!, ! and dash; None warns once; quiet hours are stored', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, NotificationsPage(deps: r.deps));
      expect(find.text('Pop up for'.toUpperCase()), findsOneWidget);
      expect(find.text('Serious only'), findsOneWidget);
      expect(find.text('!!'), findsOneWidget);
      expect(find.text('!'), findsOneWidget);
      expect(find.byIcon(Icons.remove), findsOneWidget);
      expect(find.text('10 PM–6 AM · serious still ring'), findsOneWidget);
      expect(find.text('Every alert is listed in Weather either way.'), findsOneWidget);
      expect(find.byType(Switch), findsNothing, reason: 'no pop-up switch and no ring-through switch');
      expect(r.settings.popUpFor, PopUpFor.serious);
      await tester.tap(find.text('All alerts'));
      await tester.pump();
      expect(r.settings.popUpFor, PopUpFor.all);
      // None: a one-time warning that Cache will not interrupt for evacuations.
      await tester.tap(find.text('None'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not even an evacuation order'), findsOneWidget);
      await tester.tap(find.text('Keep pop-ups'));
      await tester.pumpAndSettle();
      expect(r.settings.popUpFor, PopUpFor.all, reason: 'kept');
      await tester.tap(find.text('None'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-no-popups')));
      await tester.pumpAndSettle();
      expect(r.settings.popUpFor, PopUpFor.none);
      await tester.tap(find.text('Serious only'));
      await tester.pump();
      await tester.tap(find.text('None'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not even an evacuation order'), findsNothing, reason: 'the warning is shown once');
      expect(r.settings.popUpFor, PopUpFor.none);
      // Quiet hours page: switch, from, to.
      await tester.tap(find.text('Quiet hours'));
      await tester.pumpAndSettle();
      expect(find.text('10 PM'), findsOneWidget);
      expect(find.text('6 AM'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('quiet-from')));
      await tester.pumpAndSettle();
      expect(find.text('Quiet hours start'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.keyboard_outlined));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '9');
      await tester.enterText(fields.at(1), '30');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(r.settings.quiet.from, 21 * 60 + 30);
      expect(find.text('9:30 PM'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('quiet-to')));
      await tester.pumpAndSettle();
      expect(find.text('Quiet hours end'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(r.settings.quiet.to, 6 * 60, reason: 'cancel changes nothing');
      // The switch.
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(r.settings.quiet.on, isFalse);
      // All of it is on disk.
      final again = AppSettings(settingsDirOverride: r.dir);
      await tester.runAsync(again.init);
      expect(again.popUpFor, PopUpFor.none);
      expect(again.quiet.from, 21 * 60 + 30);
      expect(again.quiet.on, isFalse);
      await r.dispose(tester);
    });

    for (final c in [
      (LocationAccess.always, 'Always · alerts keep working in the background'),
      (LocationAccess.whileUsing, 'While using the app · alerts pause when Cache is closed'),
      (LocationAccess.denied, 'Off · tap to allow'),
      (LocationAccess.blocked, "Blocked · tap to open the phone's settings"),
    ]) {
      testWidgets('Location access shows the real permission: ${c.$1.name}', (tester) async {
        final r = await SettingsRig.create(tester, locationAccess: c.$1);
        await r.show(tester, NotificationsPage(deps: r.deps));
        await tester.pump();
        expect(find.text(c.$2), findsOneWidget);
        await r.dispose(tester);
      });
    }

    testWidgets('tapping Location access asks when it can, and opens the phone settings otherwise', (tester) async {
      final r = await SettingsRig.create(tester, locationAccess: LocationAccess.denied, permission: LocationPermissionState.denied);
      await r.show(tester, NotificationsPage(deps: r.deps));
      await tester.pump();
      await tester.tap(find.text('Location access'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(r.position.asked, 1);
      expect(r.position.settingsOpened, 0);
      // Back from the phone's settings with a different answer: the page reads it again.
      r.access.value = LocationAccess.whileUsing;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.textContaining('While using the app'), findsOneWidget);
      await tester.tap(find.text('Location access'));
      await tester.pump();
      expect(r.position.settingsOpened, 1);
      expect(r.position.asked, 1);
      await r.dispose(tester);
    });
  });

  group('Storage', () {
    testWidgets('sizes come from the files by kind, the line adds them up, Clean up, the one mobile-data switch and the space kept free', (tester) async {
      final r = await SettingsRig.create(tester);
      void file(Directory d, String name, int bytes) => File('${d.path}/$name').openSync(mode: FileMode.write)
        ..truncateSync(bytes)
        ..closeSync();
      Directory('${r.libraryDir.path}/idx').createSync();
      file(r.libraryDir, 'a.zim', 5 << 20);
      file(Directory('${r.libraryDir.path}/idx'), 'a.idx', 1 << 20);
      file(r.mapsDir, 'tiles.sqlite', 3 << 20);
      file(r.modelsDir, 'other.gguf', 2 << 20);
      await tester.runAsync(r.app.refreshModels);
      file(r.videosDir, 'v.mp4', 1 << 20);
      final leftovers = Directory('${r.dir.path}/leftovers')..createSync();
      file(leftovers, 'x.part', 1 << 20);
      await r.show(tester, StoragePage(deps: r.deps));
      for (var i = 0; i < 40 && !r.storage.measured; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      expect(r.storage.measured, isTrue);
      await tester.pump();
      expect(find.text('12.0 MB used by Cache · 41.0 GB free on the phone'), findsOneWidget);
      Finder kindText(String id, String s) => find.descendant(of: find.byKey(ValueKey('kind-$id')), matching: find.textContaining(s));
      expect(kindText('library', '6.0 MB'), findsOneWidget);
      expect(kindText('regions', '3.0 MB'), findsOneWidget);
      expect(kindText('models', '1 · 2.0 MB'), findsOneWidget);
      expect(kindText('videos', '1.0 MB'), findsOneWidget);
      // The space kept for the phone is information: 10% of a 128 GB phone.
      expect(find.text('Kept free for the phone'), findsOneWidget);
      expect(find.text('10% of storage, 5 to 20 GB'), findsOneWidget);
      expect(find.text('12.8 GB'), findsOneWidget);
      // Clean up empties the unfinished downloads.
      expect(find.text('Clean up · 1.0 MB'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Clean up'));
      for (var i = 0; i < 40 && leftovers.listSync().isNotEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      }
      await tester.pump();
      expect(leftovers.listSync(), isEmpty);
      expect(File('${r.libraryDir.path}/a.zim').existsSync(), isTrue, reason: 'nothing kept is touched');
      // One mobile-data switch, for big downloads; off by default.
      expect(find.text('Use mobile data for updates'), findsNothing);
      expect(switchIn(tester, 'Mobile data downloads').value, isFalse);
      expect(find.text('Off: big downloads wait for Wi-Fi'), findsOneWidget);
      await tester.tap(find.descendant(of: rowWith('Mobile data downloads'), matching: find.byType(Switch)));
      await tester.pump();
      expect(r.settings.mobileForDownloads, isTrue);
      final again = AppSettings(settingsDirOverride: r.dir);
      await tester.runAsync(again.init);
      expect(again.mobileForDownloads, isTrue);
      await r.dispose(tester);
    });

    testWidgets('each kind opens the list where its items are removed', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, StoragePage(deps: r.deps));
      await tester.tap(find.byKey(const ValueKey('kind-library')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-empty')), findsOneWidget, reason: 'the Library list');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('kind-models')));
      await tester.pumpAndSettle();
      expect(find.text('Models'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('kind-videos')));
      await tester.pumpAndSettle();
      expect(find.text('Saved videos'), findsOneWidget);
      await r.dispose(tester);
    });
  });
}
