import 'dart:io';

import 'package:test/test.dart';

import '../bin/keystore.dart';
import '../bin/server_settings_sync.dart';

/// The host's keys between devices (the phone's pushKeys and takeKeys, headless): the ticked key names come from the settings log's
/// `.local/state.json` (`keys`), the values from the server keystore, and the host's setSecrets and takeSecrets are faked with
/// closures. The files are real, in a temp folder. No key value may reach a log line or the settings log's files.
void main() {
  late Directory support;
  late KeyStore store;
  late ServerSettingsSync sync;
  var running = true;
  List<Map<String, dynamic>> peers = [];
  final given = <(String, Map<String, String>)>[];
  var arrived = <String, Map<String, String>>{};
  final logs = <String>[];

  Map<String, dynamic> peer(String id, Map<String, Object?> link) => {'id': id, 'linked': 1, 'link': link};

  setUp(() {
    support = Directory.systemTemp.createTempSync('server_settings_keys_test');
    store = KeyStore(File('${support.path}/ks/keystore.json'));
    running = true;
    peers = [peer('peerA', {'mode': 'match'})];
    given.clear();
    arrived = {};
    logs.clear();
    sync = ServerSettingsSync(
      support: Directory('${support.path}/support')..createSync(),
      running: () => running,
      myId: () => 'me',
      peers: () => peers,
      askSince: () => null,
      log: logs.add,
      keys: store,
      setSecrets: (p, s) async => given.add((p, {...s})),
      takeSecrets: () async {
        final r = arrived;
        arrived = {};
        return r;
      },
    );
  });
  tearDown(() {
    sync.stop();
    support.deleteSync(recursive: true);
  });

  Map<String, String> lastGivenTo(String id) => given.lastWhere((g) => g.$1 == id).$2;
  Iterable<Map<String, String>> allGivenTo(String id) => given.where((g) => g.$1 == id).map((g) => g.$2);

  test('push: only ticked keys that exist in the keystore and are real go, with their real values, to a link that sends', () async {
    store.set('search.kagi.key', 'KAGI-SECRET-1');
    store.set('live.key.owm', 'OWM-SECRET-2');
    store.set('live.key.unticked', 'UNTICKED-SECRET-3');
    await sync.start();
    await sync.setKeyOn('peerA', 'search.kagi.key', true);
    await sync.setKeyOn('peerA', 'live.key.owm', true);
    await sync.setKeyOn('peerA', 'live.key.missing', true);
    expect(lastGivenTo('peerA'), {'search.kagi.key': 'KAGI-SECRET-1', 'live.key.owm': 'OWM-SECRET-2'});
    expect(sync.keyOn('peerA', 'live.key.owm'), isTrue);
    expect(sync.keyOn('peerA', 'live.key.unticked'), isFalse);
  });

  test('push: a key whose name needs encoding is read from the keystore under the browser\'s name', () async {
    store.set(encodeKeyName('live.key.a~b'), 'TILDE-SECRET');
    await sync.start();
    await sync.setKeyOn('peerA', 'live.key.a~b', true);
    expect(lastGivenTo('peerA'), {'live.key.a~b': 'TILDE-SECRET'});
  });

  test('push: nothing goes for an Off link or a Take-only link', () async {
    store.set('search.kagi.key', 'KAGI-SECRET-1');
    peers = [
      peer('off', {'mode': 'off'}),
      peer('theirs', {'mode': 'send', 'from': 'theirs'}),
      peer('mine', {'mode': 'send', 'from': 'me'}),
    ];
    await sync.start();
    for (final id in ['off', 'theirs', 'mine']) {
      await sync.setKeyOn(id, 'search.kagi.key', true);
    }
    expect(allGivenTo('off').every((m) => m.isEmpty), isTrue);
    expect(allGivenTo('theirs').every((m) => m.isEmpty), isTrue);
    expect(lastGivenTo('mine'), {'search.kagi.key': 'KAGI-SECRET-1'});
  });

  test('push: a keystore:// reference is never a key and is never sent; a name this app does not keep is not sent either', () async {
    store.set('search.kagi.key', 'keystore://search.kagi.key');
    store.set('app.pin', 'PIN-HASH-9');
    await sync.start();
    await sync.setKeyOn('peerA', 'search.kagi.key', true);
    await sync.setKeyOn('peerA', 'app.pin', true);
    expect(allGivenTo('peerA').every((m) => m.isEmpty), isTrue);
  });

  test('push: a link change and a key change are given again; an unchanged state is not', () async {
    store.set('search.kagi.key', 'KAGI-SECRET-1');
    await sync.start();
    await sync.setKeyOn('peerA', 'search.kagi.key', true);
    final n = given.length;
    await sync.setKeyOn('peerA', 'search.kagi.key', true);
    expect(given.length, n, reason: 'nothing changed');
    peers = [peer('peerA', {'mode': 'off'})];
    await sync.tick();
    expect(lastGivenTo('peerA'), isEmpty, reason: 'the link no longer sends');
    peers = [peer('peerA', {'mode': 'match'})];
    await sync.tick();
    expect(lastGivenTo('peerA'), {'search.kagi.key': 'KAGI-SECRET-1'});
    store.set('search.kagi.key', 'KAGI-SECRET-NEW');
    await sync.setKeyOn('peerA', 'search.kagi.key', true);
    expect(lastGivenTo('peerA'), {'search.kagi.key': 'KAGI-SECRET-NEW'});
  });

  test('the ticks are kept in state.json (names only) and come back after a restart', () async {
    store.set('search.kagi.key', 'KAGI-SECRET-1');
    await sync.start();
    await sync.setKeyOn('peerA', 'search.kagi.key', true);
    final state = File('${support.path}/support/settings-sync/.local/state.json').readAsStringSync();
    expect(state, contains('search.kagi.key'));
    expect(state, isNot(contains('KAGI-SECRET-1')));
    sync.stop();
    given.clear();
    final again = ServerSettingsSync(
      support: Directory('${support.path}/support'),
      running: () => running,
      myId: () => 'me',
      peers: () => peers,
      askSince: () => null,
      log: logs.add,
      keys: store,
      setSecrets: (p, s) async => given.add((p, {...s})),
      takeSecrets: () async => {},
    );
    await again.start();
    await again.tick();
    again.stop();
    expect(lastGivenTo('peerA'), {'search.kagi.key': 'KAGI-SECRET-1'});
  });

  test('take: allowed names are written into the keystore, others are dropped and logged by name only', () async {
    await sync.start();
    arrived = {
      'peerA': {
        'search.kagi.key': 'KAGI-ARRIVED-1',
        'live.key.owm': 'OWM-ARRIVED-2',
        'live.key.a~b': 'TILDE-ARRIVED-3',
        'live.key.': 'EMPTY-ALIAS-4',
        'app.pin': 'PIN-ARRIVED-5',
        'video.x.token': 'VIDEO-ARRIVED-6',
      },
    };
    await sync.tick();
    expect(store.get('search.kagi.key'), 'KAGI-ARRIVED-1');
    expect(store.get('live.key.owm'), 'OWM-ARRIVED-2');
    expect(store.get(encodeKeyName('live.key.a~b')), 'TILDE-ARRIVED-3');
    expect(store.names(), isNot(contains('app.pin')));
    expect(store.names(), isNot(contains('video.x.token')));
    expect(store.names(), isNot(contains('live.key.')));
    expect(logs.where((l) => l.contains('app.pin')), isNotEmpty);
    expect(logs.where((l) => l.contains('video.x.token')), isNotEmpty);
    expect(logs.where((l) => l.contains('ARRIVED')), isEmpty);
  });

  test('take: keys from a device whose settings this one does not take are not kept', () async {
    peers = [
      peer('off', {'mode': 'off'}),
      peer('mine', {'mode': 'send', 'from': 'me'}),
      peer('theirs', {'mode': 'send', 'from': 'theirs'}),
    ];
    await sync.start();
    arrived = {
      'off': {'live.key.a': 'FROM-OFF'},
      'mine': {'live.key.b': 'FROM-MINE'},
      'theirs': {'live.key.c': 'FROM-THEIRS'},
      'stranger': {'live.key.d': 'FROM-STRANGER'},
    };
    await sync.tick();
    expect(store.names(), ['live.key.c']);
  });

  test('take: not while sharing is not running', () async {
    await sync.start();
    running = false;
    arrived = {'peerA': {'live.key.a': 'LATE'}};
    await sync.tick();
    expect(store.names(), isEmpty);
  });

  test('no key value appears in any log line or in the settings log\'s files', () async {
    store.set('search.kagi.key', 'PUSHED-SECRET-ABC');
    await sync.start();
    await sync.setKeyOn('peerA', 'search.kagi.key', true);
    arrived = {'peerA': {'live.key.owm': 'TAKEN-SECRET-DEF', 'app.pin': 'DROPPED-SECRET-GHI', 'live.key.${'x' * 200}': 'BIG-SECRET-JKL'}};
    await sync.tick();
    final files = Directory('${support.path}/support').listSync(recursive: true).whereType<File>();
    final all = [...logs, for (final f in files) f.readAsStringSync()].join('\n');
    for (final v in ['PUSHED-SECRET-ABC', 'TAKEN-SECRET-DEF', 'DROPPED-SECRET-GHI', 'BIG-SECRET-JKL']) {
      expect(all, isNot(contains(v)));
    }
    expect(store.get('live.key.owm'), 'TAKEN-SECRET-DEF');
  });

  test('a failing setSecrets or takeSecrets is logged without values and does not stop the pull', () async {
    store.set('search.kagi.key', 'FAIL-SECRET-1');
    final failing = ServerSettingsSync(
      support: Directory('${support.path}/support'),
      running: () => running,
      myId: () => 'me',
      peers: () => peers,
      askSince: () => null,
      log: logs.add,
      keys: store,
      setSecrets: (p, s) async => throw StateError('no engine for ${s.values.join()}'),
      takeSecrets: () async => throw StateError('gone'),
    );
    await failing.start();
    await failing.setKeyOn('peerA', 'search.kagi.key', true);
    await failing.tick();
    failing.stop();
    expect(logs.any((l) => l.contains('could not give the keys')), isTrue);
    expect(logs.join(), isNot(contains('FAIL-SECRET-1')));
  });

  test('encodeKeyName: plain names are themselves, others are reversible and fit the keystore\'s pattern', () {
    expect(encodeKeyName('search.kagi.key'), 'search.kagi.key');
    expect(encodeKeyName('live.key.a~b'), 'live.key.a:007eb');
    expect(encodeKeyName('a b:c'), 'a:0020b:003ac');
    final long = encodeKeyName('live.key.${'ö' * 90}');
    expect(long.length <= 120, isTrue);
    expect(RegExp(r'^[A-Za-z0-9._:-]{1,120}$').hasMatch(long), isTrue);
    expect(encodeKeyName('video.${'ö' * 90}.user').endsWith('.user'), isTrue);
    expect(encodeKeyName('live.key.${'ö' * 90}'), isNot(encodeKeyName('live.key.${'ö' * 91}')));
  });
}
