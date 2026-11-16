import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

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

  test('ask.model is never applied on the server (the owner has not decided), and the rest of the log still is', () async {
    expect(kNotAppliedOnServer, contains('ask.model'));
    peers = [peer('peerA', {'mode': 'send', 'from': 'peerA'})]; // Send mine from the peer: it would apply everything
    await sync.start();
    peerLine('peerA', 'ask.model', 'big.gguf', 9000);
    peerLine('peerA', 'appearance.theme', 'light', 9001);
    await sync.tick();
    expect(file('settings.json').existsSync() ? json('settings.json').containsKey('lastModel') : false, isFalse);
    expect(json('settings.json')['theme'], 'light');
    expect(sync.applied, 1);
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
}
