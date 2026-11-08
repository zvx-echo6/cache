// Settings between linked devices (Sharing and sync > a device > Settings): the three relationships, per-setting latest wins
// with the previous-value rule, Send mine one way with a local change standing, live apply, keys (only the ticked ones, only to
// that device, never on disk), a model not on this device, the Match-only Bookshelves share, and what never travels.

import 'dart:convert';
import 'dart:io';

import 'package:cache/layout/layout_state.dart';
import 'package:cache/screens/settings/settings_link_pages.dart';
import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/sharing/settings_sync.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/sharing/synced_settings.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart';
import 'support/settings_rig.dart';
import 'support/sync_fake.dart';

/// A value whose listeners can be told again without it changing (a model folder read again).
class Ping extends ValueNotifier<String?> {
  Ping(super.value);

  void ping() => notifyListeners();
}

/// One device: a fake engine, sharing on it, and a few settings held in notifiers.
class Dev {
  Dev(this.id, this.other, {String otherName = 'Desk', bool linked = true}) {
    core.id = id;
    if (linked) core.peers.add({'id': other, 'name': otherName, 'linked': 1, 'last_seen': 1, 'via': 'direct', 'error': null, 'link_known': true});
  }

  final String id;
  final String other;
  final FakeSync core = FakeSync();
  late final Directory root = Directory.systemTemp.createTempSync('settings-sync-$id');
  late final SharingState sharing;
  late final SettingsSync sync;
  int clock = 1000;

  final theme = ValueNotifier<String>('dark');
  final popUp = ValueNotifier<String>('serious');
  final model = Ping('small.gguf');
  final Set<String> modelsHere = {'small.gguf'};
  final keys = <String, String>{};
  final kept = <String, String>{};
  final downloads = <Map<String, Object?>>[];

  Directory get dir => Directory('${root.path}/$kSettingsShareDir');
  File log(String of) => File('${dir.path}/log/$of.jsonl');

  List<SyncedSetting> get settings => [
    SyncedSetting(
      key: 'appearance.theme',
      group: SettingsGroupId.appearance,
      label: 'Theme',
      listenable: theme,
      read: () => theme.value,
      write: (v) async {
        theme.value = v as String;
        return true;
      },
      shows: () => theme.value,
    ),
    SyncedSetting(
      key: 'alerts.pop_up',
      group: SettingsGroupId.notifications,
      label: 'Which alerts pop up',
      listenable: popUp,
      read: () => popUp.value,
      write: (v) async {
        popUp.value = v as String;
        return true;
      },
    ),
    SyncedSetting(
      key: kModelSettingKey,
      group: SettingsGroupId.ask,
      label: 'Model',
      listenable: model,
      read: () => model.value,
      write: (v) async {
        if (!modelsHere.contains(v)) return false;
        model.value = v as String?;
        return true;
      },
      note: () => {'name': 'Model ${model.value}', 'download': {'repo': 'org/models', 'path': '${model.value}', 'size': 10}},
      shows: () => '${model.value}',
    ),
  ];

  Future<void> start() async {
    final settings = AppSettings(settingsDirOverride: root);
    sharing = SharingState(
      policy: DataPolicy(settings: settings, probe: FakeProbe(ConnectionKind.wifi)),
      supportDir: () async => root,
      kinds: const [],
      linkShares: [
        LinkShare(id: kSettingsShareId, name: 'Settings', dir: () => dir, modes: kSettingsShareModes),
        LinkShare(id: kBookshelvesShareId, name: 'Bookshelves', dir: () => Directory('${root.path}/$kBookshelvesDir'), modes: kBookshelvesShareModes),
      ],
      opener: (_) async => core,
    );
    await sharing.setUp();
    sync = SettingsSync(
      sharing: sharing,
      settings: list,
      keys: () => [for (final e in keys.entries) SyncedKey(name: e.key, label: e.key, read: () async => keys[e.key])],
      storeKey: (n, v) async {
        if (!n.startsWith('live.key.')) return false;
        kept[n] = v;
        return true;
      },
      dir: () async => dir,
      downloadModel: (d) async => downloads.add(d),
      now: () => DateTime.fromMillisecondsSinceEpoch(clock),
      every: const Duration(hours: 1),
    );
    await sync.start();
  }

  late final List<SyncedSetting> list = settings;

  /// What the other device chose arrives (the engine takes the later link).
  Future<void> takeLink(Dev from) async {
    core.peers.firstWhere((p) => p['id'] == from.id)['link'] = from.core.peers.firstWhere((p) => p['id'] == id)['link'];
    await sharing.refresh();
  }

  /// The other device's log arrives (the settings share).
  Future<void> takeLog(Dev from) async {
    await from.sync.flush();
    final f = from.log(from.id);
    if (!f.existsSync()) return;
    log(from.id).parent.createSync(recursive: true);
    f.copySync(log(from.id).path);
    await sync.pull();
  }

  List<Map<String, dynamic>> events() =>
      log(id).existsSync() ? [for (final l in log(id).readAsLinesSync()) if (l.trim().isNotEmpty) (jsonDecode(l) as Map).cast<String, dynamic>()] : [];

  void dispose() {
    sync.dispose();
    sharing.dispose();
    root.deleteSync(recursive: true);
  }
}

void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 5400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// Taps [key] with its work (files, the fake engine) running on the real clock, then lets the page settle.
Future<void> tapReal(WidgetTester tester, String key) async {
  await tester.runAsync(() async {
    await tester.tap(find.byKey(ValueKey(key)));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<(Dev, Dev)> pair() async {
  final a = Dev('A', 'B', otherName: 'Phone');
  final b = Dev('B', 'A');
  await a.start();
  await b.start();
  return (a, b);
}

/// Two devices linked just now, with this version: each link starts Off, asked about once.
Future<(Dev, Dev)> pairNew() async {
  final (a, b) = await pair();
  for (final d in [a, b]) {
    d.core.peers.single['linked'] = DateTime.now().millisecondsSinceEpoch;
  }
  return (a, b);
}

void main() {
  test('the three relationships, and the device it is chosen on is where settings come from', () async {
    final (a, b) = await pair();
    expect(a.sync.linkWith('B'), SettingsLink.match, reason: 'a link from before this version counts as Match');

    await a.sync.setLink('B', SettingsLink.sending);
    expect(a.core.peers.single['link'], {'mode': 'send', 'from': 'A'});
    expect(a.sync.linkWith('B'), SettingsLink.sending);
    await b.takeLink(a);
    expect(b.sync.linkWith('A'), SettingsLink.receiving, reason: 'the other device follows');

    // Switching it on sent A's included settings as they are: B takes them at once.
    expect([for (final e in a.events()) e['k']], containsAll(['appearance.theme', 'alerts.pop_up', kModelSettingKey]));
    a.theme.value = 'light';
    await b.takeLog(a);
    expect(b.theme.value, 'light');

    await b.sync.setLink('A', SettingsLink.off);
    expect(b.sync.linkWith('A'), SettingsLink.off);
    await a.takeLink(b);
    expect(a.sync.linkWith('B'), SettingsLink.off);
    a.theme.value = 'parchment';
    await b.takeLog(a);
    expect(b.theme.value, 'light', reason: 'Off: each keeps its own');

    b.clock = 5000;
    await b.sync.setLink('A', SettingsLink.match);
    await a.takeLink(b);
    expect(a.sync.linkWith('B'), SettingsLink.match);
    expect(b.sync.linkWith('A'), SettingsLink.match);
    // Chosen on B: B's settings went, so A takes B's theme.
    await a.takeLog(b);
    expect(a.theme.value, 'light');
    a.dispose();
    b.dispose();
  });

  test('per setting, the latest change wins, and a change made on the value here applies whatever the clocks say', () async {
    final (a, b) = await pair();
    // Both start from the same value. A's clock is behind B's.
    a.clock = 100;
    b.clock = 5000;
    b.popUp.value = 'all';
    await a.takeLog(b);
    expect(a.popUp.value, 'all');

    // One-sided: A changes it (its previous value is the value on B), at a time before B's last change. It applies.
    a.clock = 200;
    a.popUp.value = 'none';
    await a.sync.flush();
    expect(a.events().last, containsPair('prev', 'all'));
    await b.takeLog(a);
    expect(b.popUp.value, 'none', reason: 'only A changed it since');

    // Both change the same setting: the later change wins on both.
    a.clock = 6000;
    a.theme.value = 'light';
    b.clock = 7000;
    b.theme.value = 'tactical';
    await a.takeLog(b);
    await b.takeLog(a);
    expect(a.theme.value, 'tactical');
    expect(b.theme.value, 'tactical');

    // Each setting on its own: a change to one never touches another.
    expect(a.popUp.value, 'none');
    expect(applies(SettingsLink.match, const SettingsEvent(at: 1, dev: 'x', key: 'k', value: 2, hasPrev: true, prev: 1), current: '1', localAt: 99), isTrue);
    expect(applies(SettingsLink.match, const SettingsEvent(at: 1, dev: 'x', key: 'k', value: 2, hasPrev: true, prev: 3), current: '1', localAt: 99), isFalse);
    expect(applies(SettingsLink.match, const SettingsEvent(at: 100, dev: 'x', key: 'k', value: 2, hasPrev: true, prev: 3), current: '1', localAt: 99), isTrue);
    expect(applies(SettingsLink.sending, const SettingsEvent(at: 100, dev: 'x', key: 'k', value: 2), current: '1', localAt: 0), isFalse);
    expect(applies(SettingsLink.off, const SettingsEvent(at: 100, dev: 'x', key: 'k', value: 2), current: '1', localAt: 0), isFalse);
    a.dispose();
    b.dispose();
  });

  test('Send mine goes one way, and a change on the device that follows stands until the sender changes that setting', () async {
    final (a, b) = await pair();
    await a.sync.setLink('B', SettingsLink.sending);
    await b.takeLink(a);
    await b.takeLog(a);

    // B's own change stays on B.
    b.clock = 9000;
    b.theme.value = 'tactical';
    await a.takeLog(b);
    expect(a.theme.value, 'dark', reason: "the sender never takes the follower's changes");

    // A changes something else: B takes it, and its own theme stands.
    a.clock = 2000;
    a.popUp.value = 'all';
    await b.takeLog(a);
    expect(b.popUp.value, 'all');
    expect(b.theme.value, 'tactical');

    // A changes the theme (its clock is behind B's): B follows, as A's change is the newer one for that setting.
    a.clock = 3000;
    a.theme.value = 'light';
    await b.takeLog(a);
    expect(b.theme.value, 'light');
    a.dispose();
    b.dispose();
  });

  test('a change applies live: the setting changes at once and its listeners hear it', () async {
    final (a, b) = await pair();
    var heard = 0;
    b.theme.addListener(() => heard++);
    a.theme.value = 'parchment';
    await b.takeLog(a);
    expect(b.theme.value, 'parchment');
    expect(heard, 1);
    expect(b.events(), isEmpty, reason: 'a change taken from another device is not sent back');

    // With the app's own settings: the pop-up choice changes in place, no restart.
    final r = Directory.systemTemp.createTempSync('live');
    final s = AppSettings(settingsDirOverride: r);
    await s.init();
    var told = 0;
    s.addListener(() => told++);
    final layout = LayoutState(settingsDirOverride: r);
    await layout.init();
    final list = [
      SyncedSetting(key: 'alerts.pop_up', group: SettingsGroupId.notifications, label: 'x', listenable: s, read: () => s.popUpFor.name, write: (v) async {
        s.setPopUpFor(PopUpFor.byName(v));
        return true;
      }),
    ];
    await list.single.write('all');
    expect(s.popUpFor, PopUpFor.all);
    expect(told, 1);
    layout.applyPinned(['maps', 'ask']);
    expect([for (final m in layout.pinned) m.name], ['maps', 'ask']);
    r.deleteSync(recursive: true);
    a.dispose();
    b.dispose();
  });

  test('keys: only the ticked ones, only to that device, never on disk; kept from the device settings come from', () async {
    final (a, b) = await pair();
    // C is a device A keeps its own settings from (Off).
    a.core.peers.add({'id': 'C', 'name': 'Tablet', 'linked': 1, 'last_seen': 1, 'link_known': true, 'link': {'mode': 'off', 'from': 'A'}});
    await a.sharing.refresh();
    a.keys['live.key.owm'] = 'OWM-SECRET-1234';
    a.keys['search.kagi.key'] = 'KAGI-SECRET-5678';
    await a.sync.pushKeys();
    expect(a.core.secrets, isEmpty, reason: 'every key starts off');

    await a.sync.setKeyOn('B', 'live.key.owm', true);
    expect(a.core.secrets['B'], {'live.key.owm': 'OWM-SECRET-1234'}, reason: 'only the ticked key');
    expect(a.core.secrets['C'], isNull, reason: 'and only to that device');

    // A follows B: A's keys stop going to B.
    await b.sync.setLink('A', SettingsLink.sending);
    await a.takeLink(b);
    await a.sync.pushKeys();
    expect(a.core.secrets['B'], isNull);

    // B sends its keys to A (A follows B): A keeps them; one from a device A does not take settings from is not kept.
    a.core.inbox['B'] = {'live.key.owm': 'FROM-B'};
    a.core.inbox['C'] = {'live.key.nws': 'FROM-C'};
    await a.sync.takeKeys();
    expect(a.kept, {'live.key.owm': 'FROM-B'});

    // Nothing on disk holds a key: not the logs, not what settings sync keeps.
    for (final f in a.root.listSync(recursive: true).whereType<File>()) {
      final text = f.readAsStringSync();
      expect(text.contains('OWM-SECRET-1234') || text.contains('KAGI-SECRET-5678'), isFalse, reason: f.path);
    }
    a.dispose();
    b.dispose();
  });

  testWidgets('a model the other device uses that is not here: "not downloaded here" and Download, never on its own', (tester) async {
    tall(tester);
    late Dev a, b;
    await tester.runAsync(() async {
      (a, b) = await pair();
      a.modelsHere.add('big.gguf');
      a.model.value = 'big.gguf';
      await b.takeLog(a);
    });
    expect(b.model.value, 'small.gguf');
    expect(b.sync.waiting(kModelSettingKey)?.value, 'big.gguf');
    expect(b.downloads, isEmpty, reason: 'nothing downloads on its own');

    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: SettingsGroupPage(sync: b.sync, peer: 'A', name: 'Desk', group: SettingsGroupId.ask)));
    await tester.pump();
    expect(find.text('Uses Model big.gguf, not downloaded here'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('model-download')));
    await tester.pump();
    expect(b.downloads.single, containsPair('path', 'big.gguf'));

    // The model arrives: it is used at once.
    b.modelsHere.add('big.gguf');
    b.model.ping();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(b.model.value, 'big.gguf');
    expect(b.sync.waiting(kModelSettingKey), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      a.dispose();
      b.dispose();
    });
  });

  test('the Bookshelves log is shared with Match devices only, the settings log with Match and Send mine', () async {
    final (a, b) = await pair();
    final open = a.core.argsOf['share_add']!;
    expect([for (final x in open) x['id']], containsAll([kSettingsShareId, kBookshelvesShareId]));
    expect(open.firstWhere((x) => x['id'] == kBookshelvesShareId)['path'], '${a.root.path}/$kBookshelvesDir');
    expect(a.sharing.shareOf(kBookshelvesShareId), isNotNull);
    expect(a.sharing.shareKinds, isEmpty, reason: 'neither is listed under Sharing and sync');
    a.dispose();
    b.dispose();

    // What the engine is told: the link kinds each is kept with.
    Map<String, Object?>? config;
    final s = SharingState(
      policy: DataPolicy(settings: AppSettings(), probe: FakeProbe(ConnectionKind.wifi)),
      supportDir: () async => Directory.systemTemp.createTempSync('cfg'),
      kinds: const [],
      linkShares: [
        LinkShare(id: kSettingsShareId, name: 'Settings', dir: () => null, modes: kSettingsShareModes),
        LinkShare(id: kBookshelvesShareId, name: 'Bookshelves', dir: () => null, modes: kBookshelvesShareModes),
      ],
      opener: (c) async {
        config = c;
        return FakeSync();
      },
    );
    await s.setUp();
    expect(config!['with'], {'settings': ['match', 'send'], 'bookshelves': ['match']});
    s.dispose();
  });

  testWidgets('what never syncs never travels: the app settings that are not in a group are not sent or taken', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    final list = appSyncedSettings(app: r.app, layout: layout, settings: r.settings, maps: r.maps, weather: r.weather);
    final keys = {for (final s in list) s.key: s.group};
    expect(keys, {
      'appearance.theme': SettingsGroupId.appearance,
      'appearance.module_icons': SettingsGroupId.appearance,
      'appearance.dark_pdf_pages': SettingsGroupId.appearance,
      'home.bar': SettingsGroupId.home,
      'home.blocks': SettingsGroupId.home,
      'home.shortcuts': SettingsGroupId.home,
      'weather.sources_on': SettingsGroupId.weather,
      'weather.watch_here': SettingsGroupId.weather,
      'weather.watch_regions': SettingsGroupId.weather,
      'weather.watch_places': SettingsGroupId.weather,
      'weather.own_sources': SettingsGroupId.weather,
      'weather.source_links': SettingsGroupId.weather,
      'alerts.pop_up': SettingsGroupId.notifications,
      'alerts.quiet_hours': SettingsGroupId.notifications,
      'maps.layers_on': SettingsGroupId.maps,
      'ask.model': SettingsGroupId.ask,
      'ask.web_search': SettingsGroupId.ask,
    });
    r.sync.id = 'A';
    r.sync.peers.add({'id': 'B', 'name': 'Desk', 'linked': 1, 'last_seen': 1, 'link_known': true});
    final dir = Directory('${r.dir.path}/$kSettingsShareDir');
    late SettingsSync sync;
    await tester.runAsync(() async {
      await r.sharing.setUp();
      sync = SettingsSync(
        sharing: r.sharing,
        settings: list,
        keys: () => const [],
        storeKey: (_, _) async => false,
        dir: () async => dir,
        every: const Duration(hours: 1),
      );
      await sync.start();
      // Never synced: mobile data downloads, indexing speed, the source list address.
      r.settings.setMobileForDownloads(true);
      r.settings.setIndexingNormal(true);
      r.settings.setCatalogueUrl('https://example.org/list.json');
      r.settings.setToldNoPopUps();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    final mine = File('${dir.path}/log/A.jsonl');
    expect(mine.existsSync(), isFalse, reason: 'nothing that never syncs is written');

    // A synced one is.
    await tester.runAsync(() async {
      r.settings.setPopUpFor(PopUpFor.all);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect([for (final l in mine.readAsLinesSync()) (jsonDecode(l) as Map)['k']], ['alerts.pop_up']);

    // And a never-synced setting in another device's log is not taken.
    final theirs = File('${dir.path}/log/B.jsonl')..createSync(recursive: true);
    theirs.writeAsStringSync(
      '${const SettingsEvent(at: 1 << 40, dev: 'B', key: 'storage.mobile_data', value: false).toLine()}\n'
      '${const SettingsEvent(at: 1 << 40, dev: 'B', key: 'mobileForDownloads', value: false).toLine()}\n',
    );
    await tester.runAsync(sync.pull);
    expect(r.settings.mobileForDownloads, isTrue);
    sync.dispose();
    layout.dispose();
    await r.dispose(tester);
  });

  testWidgets('the device page: the three choices, What\'s included, API keys; the follower says whose settings it follows', (tester) async {
    tall(tester);
    late Dev a, b;
    await tester.runAsync(() async {
      (a, b) = await pair();
      a.keys['live.key.owm'] = 'k';
    });
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: SharingDevicePage(sharing: a.sharing, peer: 'B', settingsSync: a.sync)));
    await tester.pump();
    expect(find.text('Match'), findsOneWidget);
    expect(find.text('Changes on either device go to both.'), findsOneWidget);
    expect(find.text('Send mine'), findsOneWidget);
    expect(find.text('Phone follows my settings. Its own changes stay on Phone.'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Each keeps its own.'), findsOneWidget);
    expect(find.text("What's included"), findsOneWidget);
    expect(find.text('API keys'), findsOneWidget);
    expect(find.text('None included'), findsOneWidget);

    await tapReal(tester, 'link-send');
    await tester.pump();
    expect(a.core.peers.single['link'], containsPair('mode', 'send'));

    await tapReal(tester, 'link-off');
    await tester.pump();
    expect(find.text("What's included"), findsNothing, reason: 'nothing goes, so nothing to choose');

    // On the device that follows.
    await tester.runAsync(() async {
      await a.sync.setLink('B', SettingsLink.sending);
      await b.takeLink(a);
    });
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: SharingDevicePage(sharing: b.sharing, peer: 'A', settingsSync: b.sync)));
    await tester.pump();
    expect(find.text("Follows Desk's settings"), findsOneWidget);
    expect(find.text('API keys'), findsNothing, reason: 'keys come from the device whose settings it follows');

    // What's included: six groups and what never syncs; a group's page ticks single settings.
    await tapReal(tester, 'link-included');
    for (final g in SettingsGroupId.values) {
      expect(find.text(g.label), findsOneWidget);
    }
    expect(find.text('Never synced'), findsOneWidget);
    expect(find.text(kNeverSynced), findsOneWidget);
    await tapReal(tester, 'group-appearance');
    await tapReal(tester, 'setting-appearance.theme');
    await tester.pump();
    expect(b.sync.settingOn('A', 'appearance.theme'), isFalse);
    expect(b.core.peers.single['link'], containsPair('off_keys', ['appearance.theme']));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      a.dispose();
      b.dispose();
    });
  });

  test('a watched place that has not come yet is named and waiting', () async {
    final (a, b) = await pair();
    final watched = ValueNotifier<List<String>>(['cabin', 'home']);
    final list = [
      SyncedSetting(
        key: kWatchPlacesKey,
        group: SettingsGroupId.weather,
        label: 'Saved places watched',
        listenable: watched,
        read: () => watched.value,
        write: (v) async {
          watched.value = [for (final x in v as List) '$x'];
          return true;
        },
        note: () => {'cabin': 'Cabin', 'home': 'Home'},
      ),
    ];
    final s = SettingsSync(sharing: b.sharing, settings: list, keys: () => const [], storeKey: (_, _) async => false, dir: () async => b.dir, every: const Duration(hours: 1));
    await s.start();
    File('${b.dir.path}/log/A.jsonl')
      ..createSync(recursive: true)
      ..writeAsStringSync('${const SettingsEvent(at: 1 << 40, dev: 'A', key: kWatchPlacesKey, value: ['cabin', 'home', 'trailhead'], note: {'trailhead': 'Trailhead'}).toLine()}\n');
    await s.pull();
    expect(watched.value, ['cabin', 'home', 'trailhead']);
    expect(s.placesNotHere({'cabin', 'home'}), ['Trailhead']);
    s.dispose();
    a.dispose();
    b.dispose();
  });

  // ---------------------------------------------------------------- the question right after linking

  test('a new link never counts as Match before it is answered; a link from before this version stays Match', () async {
    final (oa, ob) = await pair();
    expect(oa.sync.linkWith('B'), SettingsLink.match, reason: 'a link from before this version');
    expect(oa.sync.unanswered('B'), isFalse, reason: 'it is never asked about');
    await oa.sync.markNew('B');
    expect(oa.core.peers.single['link'], isNull, reason: 'an old link is left as it is');
    oa.dispose();
    ob.dispose();

    final (a, b) = await pairNew();
    // Seen, nothing written yet.
    expect(a.sync.linkWith('B'), SettingsLink.off);
    expect(a.sync.unanswered('B'), isTrue);
    await a.sync.markNew('B');
    await b.sync.markNew('A');
    expect(a.core.peers.single['link'], {'mode': 'off', 'from': 'A', 'ask': true}, reason: 'the engine keeps the settings and Bookshelves logs from it');
    expect(kSettingsShareModes, isNot(contains('off')));
    expect(kBookshelvesShareModes, isNot(contains('off')));
    for (final d in [a, b]) {
      expect(d.sync.linkWith(d.other), SettingsLink.off);
      expect(d.sync.unanswered(d.other), isTrue);
    }

    // Nothing goes meanwhile, either way.
    a.theme.value = 'light';
    await a.sync.flush();
    expect(a.events(), isEmpty);
    await b.takeLog(a);
    expect(b.theme.value, 'dark');

    // A group ticked on the device page meanwhile keeps it Off.
    await a.sync.setGroupOn('B', SettingsGroupId.appearance, false);
    expect((a.core.peers.single['link'] as Map?)?['mode'], 'off');
    expect(a.sync.linkWith('B'), SettingsLink.off);

    // A restart keeps old and new apart: when this version first ran is kept.
    final since = jsonDecode(File('${a.root.path}/sharing.json').readAsStringSync())['ask_since'];
    expect(since, isA<int>());
    a.dispose();
    b.dispose();
  });

  test('the first run of this version: every link there already is stays Match', () async {
    final root = Directory.systemTemp.createTempSync('ask-since');
    File('${root.path}/sharing.json').writeAsStringSync(jsonEncode({'enabled': true, 'off': {'library': ['x']}}));
    final core = FakeSync()
      ..id = 'A'
      ..peers.add({'id': 'B', 'name': 'Desk', 'linked': DateTime.now().millisecondsSinceEpoch - 1000, 'link_known': true});
    final sharing = SharingState(
      policy: DataPolicy(settings: AppSettings(settingsDirOverride: root), probe: FakeProbe(ConnectionKind.wifi)),
      supportDir: () async => root,
      kinds: const [],
      opener: (_) async => core,
    );
    await sharing.init();
    expect(sharing.linkedSinceAsking('B'), isFalse);
    final j = jsonDecode(File('${root.path}/sharing.json').readAsStringSync()) as Map;
    expect(j['ask_since'], isA<int>());
    expect(j['off'], {'library': ['x']}, reason: 'what was switched off stays');
    sharing.dispose();
    root.deleteSync(recursive: true);
  });

  test('each answer sets the right mode on both devices', () async {
    for (final (to, here, there, mode) in [
      (SettingsLink.match, SettingsLink.match, SettingsLink.match, 'match'),
      (SettingsLink.sending, SettingsLink.sending, SettingsLink.receiving, 'send'),
      (SettingsLink.off, SettingsLink.off, SettingsLink.off, 'off'),
    ]) {
      final (a, b) = await pairNew();
      await a.sync.markNew('B');
      await b.sync.markNew('A');
      await a.sync.answer('B', to);
      expect(a.core.peers.single['link'], {'mode': mode, 'from': 'A'}, reason: '$to');
      await b.takeLink(a);
      expect(a.sync.linkWith('B'), here, reason: '$to');
      expect(b.sync.linkWith('A'), there, reason: '$to');
      expect(a.sync.unanswered('B'), isFalse);
      expect(b.sync.unanswered('A'), isFalse);
      if (to != SettingsLink.off) {
        // A's settings went as they are.
        await b.takeLog(a);
        expect([for (final e in a.events()) e['k']], contains('appearance.theme'));
      }
      a.dispose();
      b.dispose();
    }
  });

  test('closing the question keeps what the other device answered meanwhile; Off chosen replaces it', () async {
    final (a, b) = await pairNew();
    await a.sync.markNew('B');
    await b.sync.markNew('A');
    await b.sync.answer('A', SettingsLink.sending);
    await a.takeLink(b);
    expect(a.sync.linkWith('B'), SettingsLink.receiving);
    await a.sync.answer('B', null);
    expect(a.sync.linkWith('B'), SettingsLink.receiving, reason: 'closing it is no choice');
    await a.sync.answer('B', SettingsLink.off);
    expect(a.sync.linkWith('B'), SettingsLink.off, reason: 'Off, chosen, is a choice as on the device page');
    a.dispose();
    b.dispose();
  });

  testWidgets('Enter a link code: the question right after, and closing it is Off', (tester) async {
    tall(tester);
    final a = Dev('me', 'peer1', linked: false);
    await tester.runAsync(a.start);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: SharingPage(sharing: a.sharing, settingsSync: a.sync)));
    await tester.pump();
    await tester.tap(find.text('Enter a link code'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'CACHE1-TESTCODE');
    await tester.runAsync(() async {
      await tester.tap(find.text('Link'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Sync Cache settings with Desk?'), findsOneWidget);
    expect(find.text('Match'), findsOneWidget);
    expect(find.text('Send mine'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Changes on either device go to both.'), findsOneWidget);
    expect(find.text('Desk follows my settings.'), findsOneWidget);
    expect(find.text("Each keeps its own. You can change this on Desk's page."), findsOneWidget);
    expect(a.core.peers.single['link'], {'mode': 'off', 'ask': true}, reason: 'Off until it is answered, as the engine made it');
    expect(a.sync.unanswered('peer1'), isTrue);

    await tester.runAsync(() async {
      await tester.tapAt(const Offset(4, 4));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Sync Cache settings with Desk?'), findsNothing);
    expect(a.core.peers.single['link'], {'mode': 'off', 'from': 'me'}, reason: 'closed: Off');
    expect(a.sync.linkWith('peer1'), SettingsLink.off);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async => a.dispose());
  });

  testWidgets('Show my link code: the sheet closes when the other device links, then the question; Send mine', (tester) async {
    tall(tester);
    final a = Dev('me', 'B', linked: false);
    await tester.runAsync(a.start);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: SharingPage(sharing: a.sharing, settingsSync: a.sync)));
    await tester.pump();
    await tapReal(tester, 'show-code');
    expect(find.text('Copy code'), findsOneWidget);

    // The other device enters the code.
    await tester.runAsync(() async {
      a.core.peers.add({'id': 'B', 'name': 'Tablet', 'linked': DateTime.now().millisecondsSinceEpoch, 'last_seen': 1, 'via': 'direct', 'error': null, 'link_known': true});
      await a.sharing.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('Copy code'), findsNothing);
    expect(find.text('Sync Cache settings with Tablet?'), findsOneWidget);
    expect(find.text('Tablet follows my settings.'), findsOneWidget);

    await tapReal(tester, 'ask-send');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Sync Cache settings with Tablet?'), findsNothing);
    expect(a.core.peers.single['link'], {'mode': 'send', 'from': 'me'});
    expect(a.sync.linkWith('B'), SettingsLink.sending);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async => a.dispose());
  });
}
