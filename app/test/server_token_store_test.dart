import 'package:cache/settings/server_token_store.dart';
import 'package:cache_search/cache_search.dart' show CoreTransport;
import 'package:flutter_test/flutter_test.dart';

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
    expect(t.values.keys.single, 'live.key.my~002fown~0020source');
    expect(await s.read('live.key.my/own source'), 'keystore://live.key.my~002fown~0020source');
  });
}
