// Weather and alerts > Saved places: a watched place that is waiting for its saved place gets a Remove button (named places do
// not); Remove asks, then stops watching, and that goes to linked devices like any other change to the watched places.

import 'dart:convert';
import 'dart:io';

import 'package:cache/screens/settings/weather_page.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/sharing/settings_sync.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart';
import 'support/settings_rig.dart';
import 'support/sync_fake.dart';

const _remove = ValueKey('watch-remove-place:x');

Future<SettingsRig> _scene(WidgetTester tester) async {
  final r = await SettingsRig.create(tester);
  r.liveCore.saved = const [SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 43.1, lon: -114.2)];
  r.settings.setWatched('place:cabin', true);
  r.settings.setWatched('place:x', true);
  await r.show(tester, WeatherPage(deps: r.deps));
  await tester.pumpAndSettle();
  return r;
}

void main() {
  testWidgets('a place waiting for its saved place has a Remove button; a named place has none', (tester) async {
    final r = await _scene(tester);
    expect(find.text('waiting for this place'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('watch-place:x')), matching: find.text('Remove')), findsOneWidget);
    expect(find.byKey(_remove), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('watch-place:cabin')), matching: find.text('Remove')), findsNothing);
    await r.dispose(tester);
  });

  testWidgets('Remove asks first; Keep leaves it watched; Remove stops watching, the row goes, the saved places stay', (tester) async {
    final r = await _scene(tester);
    await tester.tap(find.byKey(_remove));
    await tester.pumpAndSettle();
    expect(find.text('Stop watching this place?'), findsOneWidget);
    expect(find.text("Weather and alerts stop for it on all your linked devices. The saved place itself isn't deleted."), findsOneWidget);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(r.settings.watchedPlaces, contains('place:x'));
    expect(find.byKey(_remove), findsOneWidget);

    await tester.tap(find.byKey(_remove));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-remove-place')));
    await tester.pumpAndSettle();
    expect(r.settings.watchedPlaces, isNot(contains('place:x')));
    expect(r.settings.watchedPlaces, contains('place:cabin'));
    expect(find.byKey(const ValueKey('watch-place:x')), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(r.liveCore.saved.length, 1, reason: 'the saved place itself is not deleted');
    expect(find.text('Cabin'), findsOneWidget);
    await r.dispose(tester);
  });

  group('sync', () {
    late Directory root;
    late AppSettings settings;
    late SharingState sharing;
    late SettingsSync sync;
    var clock = 1000;
    Directory dir() => Directory('${root.path}/$kSettingsShareDir');
    File log(String of) => File('${dir().path}/log/$of.jsonl');

    // This device is B, linked to A (a link from before the question was asked: Match). The setting is defined as
    // synced_settings.dart defines weather.watch_places.
    Future<void> setUpDevice() async {
      root = Directory.systemTemp.createTempSync('rmplace-sync');
      addTearDown(() {
        sync.dispose();
        sharing.dispose();
        root.deleteSync(recursive: true);
      });
      settings = AppSettings(settingsDirOverride: root);
      final core = FakeSync()..id = 'B';
      core.peers.add({'id': 'A', 'name': 'Phone', 'linked': 1, 'last_seen': 1, 'via': 'direct', 'error': null, 'link_known': true});
      sharing = SharingState(
        policy: DataPolicy(settings: settings, probe: FakeProbe(ConnectionKind.wifi)),
        supportDir: () async => root,
        kinds: const [],
        linkShares: [
          LinkShare(id: kSettingsShareId, name: 'Settings', dir: dir, modes: kSettingsShareModes),
          LinkShare(id: kBookshelvesShareId, name: 'Bookshelves', dir: () => Directory('${root.path}/$kBookshelvesDir'), modes: kBookshelvesShareModes),
        ],
        opener: (_) async => core,
      );
      await sharing.setUp();
      List<String> strings(Object? v) => [for (final x in (v is List ? v : const [])) if (x is String) x];
      sync = SettingsSync(
        sharing: sharing,
        settings: [
          SyncedSetting(
            key: kWatchPlacesKey,
            group: SettingsGroupId.weather,
            label: 'Saved places watched',
            listenable: settings,
            read: () => settings.watchedSavedPlaces.toList()..sort(),
            write: (v) async {
              settings.replaceWatched('place:', [for (final k in strings(v)) 'place:$k']);
              return true;
            },
          ),
        ],
        keys: () => const [],
        storeKey: (_, _) async => false,
        dir: () async => dir(),
        now: () => DateTime.fromMillisecondsSinceEpoch(clock),
        every: const Duration(hours: 1),
      );
      await sync.start();
    }

    Future<void> arrives(int at, List<String> ids) async {
      final f = log('A')..createSync(recursive: true);
      f.writeAsStringSync('${SettingsEvent(at: at, dev: 'A', key: kWatchPlacesKey, value: ids).toLine()}\n', mode: FileMode.append);
      await sync.pull();
    }

    List<Map<String, dynamic>> sent() => [for (final l in log('B').readAsLinesSync()) if (l.trim().isNotEmpty) (jsonDecode(l) as Map).cast<String, dynamic>()];

    // clock 1000: x and y watched. clock 2000: Remove x.
    Future<void> removeX() async {
      clock = 1000;
      settings.setWatched('place:x', true);
      settings.setWatched('place:y', true);
      await sync.flush();
      clock = 2000;
      settings.setWatched('place:x', false);
      await sync.flush();
    }

    test('Remove sends a watch_places value without the id', () async {
      await setUpDevice();
      await removeX();
      final last = sent().last;
      expect(last['k'], kWatchPlacesKey);
      expect(last['val'], ['y']);
      expect(last['at'], 2000);
    });

    test('an older incoming watch_places change that still has the id does not re-add it', () async {
      await setUpDevice();
      await removeX();
      await arrives(1500, ['x', 'y']);
      expect(settings.watchedSavedPlaces, {'y'});
    });

    // Characterises the merge (settings_log.dart applies, Match): a NEWER whole-list change from the other device is applied as
    // sent, so a list that still has the id puts it back. Per-setting latest wins; nothing here records "x was removed".
    test('a NEWER incoming watch_places change that still has the id re-adds it (latest change wins)', () async {
      await setUpDevice();
      await removeX();
      await arrives(3000, ['x', 'y']);
      expect(settings.watchedSavedPlaces, {'x', 'y'});
    });
  });
}
