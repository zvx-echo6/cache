import 'dart:io';

import 'package:cache/settings/server_token_store.dart';
import 'package:cache/weather/own_source.dart' show fillAddress;
import 'package:cache_search/cache_search.dart' show CoreTransport;
import 'package:flutter_test/flutter_test.dart';

import '../../server/helper/bin/keystore.dart';

class FakeKeys implements CoreTransport {
  final Map<String, String> values = {};
  final List<String> calls = [];

  @override
  Future<void> close() async {}

  @override
  Future<dynamic> call(String op, Map<String, dynamic> a) async {
    calls.add(op);
    switch (op) {
      case 'keys.names':
        return values.keys.toList();
      case 'keys.set':
        values[a['name'] as String] = a['value'] as String;
        return null;
      case 'keys.delete':
        return values.remove(a['name']) != null;
      case 'keys.get':
        return values[a['name']];
    }
    throw StateError(op);
  }
}

/// The real helper keystore behind a transport.
class _Helper implements CoreTransport {
  _Helper(this.store);
  final KeyStore store;

  @override
  Future<void> close() async {}

  @override
  Future<dynamic> call(String op, Map<String, dynamic> a) async => store.handle(op, a);
}

void main() {
  test('a key is written to the server and read back only as a reference', () async {
    final t = FakeKeys();
    final s = ServerTokenStore(t);
    expect(await s.read('search.kagi.key'), isNull);
    await s.write('search.kagi.key', 'KAGI');
    expect(t.values, {'search.kagi.key': 'KAGI'});
    expect(await s.read('search.kagi.key'), 'keystore://search.kagi.key');
    await s.delete('search.kagi.key');
    expect(await s.read('search.kagi.key'), isNull);
  });

  test('the user name and the PIN hash are read raw; a token never is', () async {
    final t = FakeKeys();
    final s = ServerTokenStore(t);
    await s.write('video.peer.user', 'ann');
    await s.write('video.peer.access', 'TOKEN');
    await s.write('app.pin', '{"v":1}');
    expect(await s.read('video.peer.user'), 'ann');
    expect(await s.read('app.pin'), '{"v":1}');
    expect(await s.read('video.peer.access'), 'keystore://video.peer.access');
    expect(await s.read('video.nope.user'), isNull);
  });

  test('a name with other characters is kept under a safe name', () async {
    final t = FakeKeys();
    final s = ServerTokenStore(t);
    await s.write('live.key.my/own source', 'K');
    expect(t.values.keys.single, 'live.key.my:002fown:0020source');
    expect(await s.read('live.key.my/own source'), 'keystore://live.key.my:002fown:0020source');
  });

  test('every name it makes passes the helper\'s own pattern, and different keys give different names', () async {
    // The real KeyStore (server/helper/bin/keystore.dart) behind the store, so its real name rule is what judges the names.
    final dir = Directory.systemTemp.createTempSync('token_names');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = KeyStore(File('${dir.path}/keystore.json'));
    final s = ServerTokenStore(_Helper(store));
    final keys = [
      'search.kagi.key', 'live.key.my_src', 'live.key.a~b', 'live.key.é ü', 'live.key.日本', 'video.host:8080.access', 'video.x/y.user',
      'live.key.a:b', 'live.key.a b', 'live.key.${'x' * 200}', 'video.${'ö' * 90}.user', 'live.key.${'y' * 200}',
    ];
    final names = <String>{};
    for (final k in keys) {
      await s.write(k, 'V-$k');
      final n = ServerTokenStore.encodeName(k);
      expect(RegExp(r'^[A-Za-z0-9._:-]{1,120}$').hasMatch(n), isTrue, reason: '$k -> $n');
      names.add(n);
      expect(store.get(n), 'V-$k', reason: 'the helper kept it under that name');
    }
    expect(names.length, keys.length);
    expect(ServerTokenStore.encodeName('video.${'ö' * 90}.user').endsWith('.user'), isTrue, reason: 'a user name stays readable by the browser');
    expect(await s.read('video.${'ö' * 90}.user'), 'V-video.${'ö' * 90}.user');
    expect(await s.read('live.key.a~b'), 'keystore://${ServerTokenStore.encodeName('live.key.a~b')}');
  });

  test('a saved key\'s reference in an own source address is swapped on the server, never given to the browser', () async {
    final dir = Directory.systemTemp.createTempSync('token_try');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = KeyStore(File('${dir.path}/keystore.json'));
    final s = ServerTokenStore(_Helper(store));
    await s.write('live.key.river', 'SECRET key&1');
    final ref = await s.read('live.key.river'); // what the page holds
    expect(ref, isNot(contains('SECRET')));
    final address = fillAddress('https://api.example/v1?lat={lat}&lon={lon}&appid={api_key}', lat: 42.5, lon: -113.8, key: ref);
    // /api/fetch gets the address as a query value; the server decodes it and asks the helper to swap the reference.
    final decoded = Uri.decodeQueryComponent(Uri.encodeQueryComponent(address));
    expect(store.expandUrl(decoded), 'https://api.example/v1?lat=42.5000&lon=-113.8000&appid=SECRET%20key%261');
    expect(() => store.expandUrl('https://x/?k=keystore%3A%2F%2Flive.key.nope'), throwsA(anything), reason: 'a missing key is an error');
  });
}
