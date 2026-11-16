import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../app/lib/sharing/settings_files.dart' show settingsGroupOf;
import '../../../app/lib/sharing/settings_log.dart';
import '../bin/server_settings_sync.dart';

/// The host's settings sync, headless: its log over `<support>/settings-sync`, its settings in the support folder's files. The host
/// (running, its id, its peers and their link records) is faked with closures; the files are real, in a temp folder.
void main() {
  late Directory support;
  var running = true;
  var clock = 5000;
  List<Map<String, dynamic>> peers = [];
  late ServerSettingsSync sync;

  Map<String, dynamic> peer(String id, Map<String, Object?> link) => {'id': id, 'linked': 1, 'link': link};

  setUp(() {
    support = Directory.systemTemp.createTempSync('server_settings_sync_test');
    running = true;
    clock = 5000;
    peers = [peer('peerA', {'mode': 'match'})];
    sync = ServerSettingsSync(support: support, running: () => running, myId: () => 'me', peers: () => peers, askSince: () => null, now: () => DateTime.fromMillisecondsSinceEpoch(clock));
  });
  tearDown(() {
    sync.stop();
    support.deleteSync(recursive: true);
  });

  File file(String name) => File('${support.path}/$name');
  Map<String, dynamic> json(String name) => (jsonDecode(file(name).readAsStringSync()) as Map).cast<String, dynamic>();
  void put(String name, Map<String, Object?> j) {
    file(name).parent.createSync(recursive: true);
    file(name).writeAsStringSync(jsonEncode(j));
  }

  File ownLog() => file('settings-sync/log/me.jsonl');
  List<SettingsEvent> ownEvents() => ownLog().existsSync() ? [for (final l in ownLog().readAsLinesSync()) SettingsEvent.fromLine(l)!] : [];
  void peerLine(String id, String key, Object? value, int at, {Object? prev, bool hasPrev = false}) {
    final f = file('settings-sync/log/$id.jsonl')..parent.createSync(recursive: true);
    f.writeAsStringSync('${SettingsEvent(at: at, dev: id, key: key, value: value, hasPrev: hasPrev, prev: prev).toLine()}\n', mode: FileMode.append);
  }

  test('a newer event from a linked peer is applied to the file, and counted', () async {
    await sync.start();
    peerLine('peerA', 'home.bar', ['maps'], 9000);
    await sync.tick();
    expect(json('layout.json')['pinned'], ['maps']);
    expect(sync.applied, 1);
    await sync.tick();
    expect(sync.applied, 1, reason: 'a line already taken is not applied again');
  });

  test('an older event is ignored: a change made here later stands', () async {
    await sync.start();
    put('layout.json', {'pinned': ['library']});
    clock = 8000;
    await sync.fileChanged('layout.json');
    peerLine('peerA', 'home.bar', ['maps'], 6000);
    await sync.tick();
    expect(json('layout.json')['pinned'], ['library']);
    expect(sync.applied, 0);
  });

  test('ask.model is applied like the other keys: lastModel is written, nothing is loaded', () async {
    peers = [peer('peerA', {'mode': 'send', 'from': 'peerA'})];
    await sync.start();
    put('settings.json', {'theme': 'dark', 'names': {'a': 'b'}});
    peerLine('peerA', 'ask.model', 'big.gguf', 9000);
    peerLine('peerA', 'appearance.theme', 'light', 9001);
    await sync.tick();
    final j = json('settings.json');
    expect(j['lastModel'], 'big.gguf');
    expect(j['theme'], 'light');
    expect(j['names'], {'a': 'b'});
    expect(sync.applied, 2);
  });

  test('a link that does not take a key does not apply it (Send mine from here, Off, a group left out, a key unticked)', () async {
    peers = [peer('peerA', {'mode': 'send', 'from': 'me'})];
    await sync.start();
    peerLine('peerA', 'home.bar', ['maps'], 9000);
    await sync.tick();
    expect(file('layout.json').existsSync(), isFalse);
    peers = [peer('peerA', {'mode': 'off'})];
    await sync.tick();
    expect(file('layout.json').existsSync(), isFalse);
    peers = [peer('peerA', {'mode': 'match', 'off_groups': ['home']})];
    await sync.tick();
    expect(file('layout.json').existsSync(), isFalse);
    expect(sync.applied, 0);
  });

  test('a browser write of layout.json with a changed home.bar appends one event; an unchanged write appends none', () async {
    put('layout.json', {'pinned': ['ask', 'maps', 'library']});
    await sync.start();
    put('layout.json', {'pinned': ['ask', 'maps', 'library']});
    await sync.fileChanged('layout.json');
    expect(ownEvents(), isEmpty);
    put('layout.json', {'pinned': ['ask', 'library']});
    clock = 7000;
    await sync.fileChanged('layout.json');
    final evs = ownEvents();
    expect(evs, hasLength(1));
    expect(evs.single.key, 'home.bar');
    expect(evs.single.value, ['ask', 'library']);
    expect(evs.single.dev, 'me');
    expect(evs.single.at, 7000);
    expect(evs.single.hasPrev, isTrue);
    expect(evs.single.prev, ['ask', 'maps', 'library']);
    await sync.fileChanged('layout.json');
    expect(ownEvents(), hasLength(1), reason: 'the same value again is not a change');
  });

  test('a change the host applied does not echo back out as a change', () async {
    await sync.start();
    peerLine('peerA', 'home.bar', ['maps'], 9000);
    await sync.tick();
    expect(sync.applied, 1);
    await sync.fileChanged('layout.json');
    expect(ownEvents(), isEmpty);
  });

  test('nothing is sent while no link sends the key', () async {
    await sync.start();
    var n = 0;
    for (final link in [
      {'mode': 'off'},
      {'mode': 'send', 'from': 'peerA'},
      {'mode': 'match', 'off_keys': ['home.bar']},
    ]) {
      peers = [peer('peerA', link)];
      put('layout.json', {'pinned': ['x${n++}']});
      await sync.fileChanged('layout.json');
    }
    peers = [];
    put('layout.json', {'pinned': ['x']});
    await sync.fileChanged('layout.json');
    expect(ownEvents(), isEmpty);
  });

  test('start notes the files as they are: a change made while not watching is noted, not sent', () async {
    put('settings.json', {'theme': 'tactical'});
    await sync.start();
    await sync.fileChanged('settings.json');
    expect(ownEvents(), isEmpty);
    // and a change made while sharing is not running is noted, not sent, later when it runs
    running = false;
    put('settings.json', {'theme': 'light'});
    await sync.fileChanged('settings.json');
    running = true;
    await sync.fileChanged('settings.json');
    expect(ownEvents(), isEmpty);
    put('settings.json', {'theme': 'parchment'});
    await sync.fileChanged('settings.json');
    expect(ownEvents().map((e) => e.key), ['appearance.theme']);
  });

  test('which written files are settings files', () {
    for (final f in ['settings.json', 'layout.json', 'preferences.json', 'maps.json', 'live-catalogues/abc/catalogue.json']) {
      expect(ServerSettingsSync.isSettingsFile(f), isTrue, reason: f);
    }
    for (final f in ['history/x.json', 'settings.json.tmp', 'live_plan.json', 'live-catalogues']) {
      expect(ServerSettingsSync.isSettingsFile(f), isFalse, reason: f);
    }
  });

  // ---- what a browser's set_link makes the server send (the phone's _seed)

  group('a browser\'s set_link seeds what the link now sends', () {
    Map<String, dynamic> before() => {...peers.single, 'link': {...(peers.single['link'] as Map)}};

    /// The server's files, and a start that notes them (so a seed is the only thing that can append).
    Future<void> filesAndStart() async {
      put('layout.json', {'pinned': ['ask', 'maps']});
      put('settings.json', {'theme': 'dark'});
      await sync.start();
    }

    Map<String, Object?> seeded() => {for (final e in ownEvents()) e.key: e.value};

    test('Match chosen sends every included setting as it is now, once: at the time of the choice, with no previous value', () async {
      peers = [peer('peerA', {'mode': 'off'})];
      await filesAndStart();
      final was = before();
      peers = [peer('peerA', {'mode': 'match', 'off_groups': ['appearance'], 'off_keys': ['home.shortcuts']})];
      clock = 7000;
      await sync.linkSetByBrowser('peerA', was);
      final evs = ownEvents();
      expect(evs.map((e) => e.key).toSet(), hasLength(evs.length), reason: 'each key once');
      expect(seeded()['home.bar'], ['ask', 'maps']);
      expect(evs.where((e) => e.key.startsWith('appearance.')), isEmpty, reason: 'a group left out is not sent');
      expect(evs.where((e) => e.key == 'home.shortcuts'), isEmpty, reason: 'a setting unticked is not sent');
      expect(evs.every((e) => e.at == 7000 && e.dev == 'me' && !e.hasPrev), isTrue);
      // a repeat of the same record sends nothing more
      final n = evs.length;
      await sync.linkSetByBrowser('peerA', before());
      expect(ownEvents(), hasLength(n));
    });

    test('Send mine chosen (and Match moved to Send mine) sends the included settings again, as on the phone', () async {
      peers = [peer('peerA', {'mode': 'match'})];
      await filesAndStart();
      final was = before();
      peers = [peer('peerA', {'mode': 'send', 'from': 'me'})];
      clock = 7000;
      await sync.linkSetByBrowser('peerA', was);
      expect(seeded()['appearance.theme'], 'dark');
      expect(seeded()['home.bar'], ['ask', 'maps']);
    });

    test('a group switched on sends that group\'s settings once, and no other group\'s', () async {
      peers = [peer('peerA', {'mode': 'match', 'off_groups': ['home']})];
      await filesAndStart();
      final was = before();
      peers = [peer('peerA', {'mode': 'match', 'off_groups': <String>[]})];
      clock = 7000;
      await sync.linkSetByBrowser('peerA', was);
      final evs = ownEvents();
      expect(evs, isNotEmpty);
      expect(evs.every((e) => settingsGroupOf(e.key) == 'home'), isTrue, reason: evs.map((e) => e.key).join(','));
      expect(seeded()['home.bar'], ['ask', 'maps']);
      final n = evs.length;
      await sync.linkSetByBrowser('peerA', before());
      expect(ownEvents(), hasLength(n), reason: 'no resend on a repeat');
    });

    test('a single setting ticked on sends that setting alone', () async {
      peers = [peer('peerA', {'mode': 'match', 'off_keys': ['home.bar']})];
      await filesAndStart();
      final was = before();
      peers = [peer('peerA', {'mode': 'match', 'off_keys': <String>[]})];
      await sync.linkSetByBrowser('peerA', was);
      expect(ownEvents().map((e) => e.key), ['home.bar']);
    });

    test('a setting or group switched off, Off, and Take theirs send nothing', () async {
      peers = [peer('peerA', {'mode': 'match'})];
      await filesAndStart();
      for (final to in [
        {'mode': 'match', 'off_groups': ['home']},
        {'mode': 'match', 'off_keys': ['home.bar']},
        {'mode': 'off'},
        {'mode': 'send', 'from': 'peerA'},
      ]) {
        final was = before();
        peers = [peer('peerA', to)];
        await sync.linkSetByBrowser('peerA', was);
        peers = [peer('peerA', {'mode': 'match'})];
      }
      expect(ownEvents(), isEmpty);
    });

    test('a link that does not send, a peer that is gone, and sharing not running send nothing', () async {
      peers = [peer('peerA', {'mode': 'send', 'from': 'peerA'})];
      await filesAndStart();
      final was = before();
      peers = [peer('peerA', {'mode': 'send', 'from': 'peerA', 'off_groups': ['home']})];
      await sync.linkSetByBrowser('peerA', was);
      peers = [peer('peerA', {'mode': 'match'})];
      await sync.linkSetByBrowser('nobody', was);
      running = false;
      await sync.linkSetByBrowser('peerA', {'id': 'peerA', 'linked': 1, 'link': {'mode': 'off'}});
      expect(ownEvents(), isEmpty);
    });

    test('a link first answered (it was waiting for the question) and chosen Match sends the included settings', () async {
      peers = [peer('peerA', {'mode': 'off', 'ask': true})];
      await filesAndStart();
      final was = before();
      peers = [peer('peerA', {'mode': 'match', 'by': 'me', 'at': 1})];
      await sync.linkSetByBrowser('peerA', was);
      expect(seeded()['home.bar'], ['ask', 'maps']);
    });
  });
}
