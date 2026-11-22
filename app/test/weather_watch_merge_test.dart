// The watched saved places are merged per id between linked devices: a removal is remembered, so a list from a device that had not
// heard of it yet does not put the id back (a deleted saved place came back as a nameless "waiting for this place" row), an add after
// the removal still counts, and a device that sends only the whole list (builds before this) still applies and is still read.

import 'dart:convert';
import 'dart:io';

import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/sharing/settings_log.dart';
import 'package:cache/sharing/settings_sync.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart';
import 'support/sync_fake.dart';

void main() {
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

    // [rm] and [ad] are what a build with the per-id merge sends beside the list; a build from before sends neither.
    Future<void> arrives(int at, List<String> ids, {Map<String, int>? rm, Map<String, int>? ad}) async {
      final f = log('A')..createSync(recursive: true);
      f.writeAsStringSync('${SettingsEvent(at: at, dev: 'A', key: kWatchPlacesKey, value: ids, removed: rm, added: ad).toLine()}\n', mode: FileMode.append);
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


    test('unwatching a place (the switch, setWatched false) sends a watch_places value without the id', () async {
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

    test('a NEWER whole list that still has a removed id does not put it back (failing first: it did)', () async {
      await setUpDevice();
      await removeX();
      await arrives(3000, ['x', 'y']);
      expect(settings.watchedSavedPlaces, {'y'});
    });

    test('an add made after the removal still works', () async {
      await setUpDevice();
      await removeX();
      await arrives(3000, ['x', 'y'], ad: {'x': 3000});
      expect(settings.watchedSavedPlaces, {'x', 'y'});
    });

    test('a place added here after its removal is watched again and goes out with its own time', () async {
      await setUpDevice();
      await removeX();
      clock = 4000;
      settings.setWatched('place:x', true);
      await sync.flush();
      final last = sent().last;
      expect(last['val'], ['x', 'y']);
      expect((last['ad'] as Map)['x'], 4000);
      expect(last['rm'], isNull);
    });

    test('an old build\'s whole list (no removals, no times) still applies, and wipes nothing it did not drop', () async {
      await setUpDevice();
      await removeX();
      await arrives(3000, ['y', 'z']);
      expect(settings.watchedSavedPlaces, {'y', 'z'});
    });

    test('what is sent is still a plain list an old build reads, with the removals in a field it ignores', () async {
      await setUpDevice();
      await removeX();
      final last = sent().last;
      expect(last['val'], ['y']);
      expect(last['rm'], {'x': 2000});
      final old = jsonDecode(jsonEncode({for (final e in last.entries) if (e.key != 'rm' && e.key != 'ad') e.key: e.value})) as Map;
      expect(SettingsEvent.fromLine(jsonEncode(old))!.value, ['y']);
    });

    test('a removal the other device reports takes the id off here although its list is older than a change made here', () async {
      await setUpDevice();
      clock = 1000;
      settings.setWatched('place:x', true);
      await sync.flush();
      clock = 3000;
      settings.setWatched('place:z', true);
      await sync.flush();
      await arrives(2000, ['y'], rm: {'x': 2000});
      expect(settings.watchedSavedPlaces, {'z'});
    });

  });

  test('the removals and adds are kept in the state file and read back', () {
    final a = SettingsLogState();
    trackIdChange(a, 'weather.watch_places', ['x', 'y'], ['y'], 2000);
    trackIdChange(a, 'weather.watch_places', ['y'], ['y', 'z'], 2500);
    final b = SettingsLogState()..load(jsonDecode(jsonEncode(a.toJson())));
    expect(b.removed['weather.watch_places'], {'x': 2000});
    expect(b.added['weather.watch_places'], {'z': 2500});
  });
}
