import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../bin/keystore.dart';
import '../bin/line_protocol.dart';
import 'fake_native.dart';

void main() {
  late Directory tmp;
  late File file;
  late KeyStore keys;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('keystore_test');
    file = File('${tmp.path}/sub/keystore.json');
    keys = KeyStore(file);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String codeOf(void Function() f) {
    try {
      f();
    } on Exception catch (e) {
      return (e as dynamic).code as String;
    }
    return 'none';
  }

  test('set, names, delete; values survive a restart; the file is owner only', () {
    keys.handle('keys.set', {'name': 'search.kagi.key', 'value': 'KAGI'});
    keys.handle('keys.set', {'name': 'live.key.fire', 'value': 'F'});
    expect(keys.handle('keys.names', {}), ['live.key.fire', 'search.kagi.key']);
    expect(KeyStore(file).get('search.kagi.key'), 'KAGI');
    if (!Platform.isWindows) expect(file.statSync().mode & 0x1ff, 0x180); // 0600
    expect(keys.handle('keys.delete', {'name': 'live.key.fire'}), isTrue);
    expect(keys.handle('keys.delete', {'name': 'live.key.fire'}), isFalse);
    expect(KeyStore(file).names(), ['search.kagi.key']);
  });

  test('a browser reads raw only the user name and the PIN hash; other names are forbidden', () {
    keys.handle('keys.set', {'name': 'video.a.user', 'value': 'ann'});
    keys.handle('keys.set', {'name': 'video.a.access', 'value': 'TOKEN'});
    keys.handle('keys.set', {'name': 'app.pin', 'value': '{"v":1}'});
    expect(keys.handle('keys.get', {'name': 'video.a.user'}), 'ann');
    expect(keys.handle('keys.get', {'name': 'app.pin'}), '{"v":1}');
    expect(codeOf(() => keys.handle('keys.get', {'name': 'video.a.access'})), 'forbidden');
    expect(codeOf(() => keys.handle('keys.get', {'name': 'search.kagi.key'})), 'forbidden');
    expect(keys.get('video.a.access'), 'TOKEN', reason: 'code inside the helper may read it');
  });

  test('bad names and values are refused', () {
    expect(codeOf(() => keys.handle('keys.set', {'name': '../x', 'value': 'v'})), 'bad_args');
    expect(codeOf(() => keys.handle('keys.set', {'name': 'a', 'value': ''})), 'bad_args');
    expect(codeOf(() => keys.handle('keys.set', {'name': 'a'})), 'bad_args');
    expect(file.existsSync(), isFalse);
  });

  test('references in core args are swapped for the value, nested; a missing key is not_found', () {
    keys.set('k.one', 'SECRET');
    final out = keys.before('liveSetKey', {'a': KeyStore.refOf('k.one'), 'n': 3, 'l': [KeyStore.refOf('k.one'), 'plain']});
    expect(out, {'a': 'SECRET', 'n': 3, 'l': ['SECRET', 'plain']});
    expect(codeOf(() => keys.before('liveSetKey', {'a': KeyStore.refOf('nope')})), 'not_found');
    final chat = {'content': KeyStore.refOf('k.one')};
    expect(keys.before('convTool', chat), chat, reason: 'what the model or person wrote is never touched');
  });

  test('setWeb with a reference reaches the engine with the key, and is replayed after a restart; a raw key is not kept', () async {
    final fake = FakeNative()..replies['version'] = '{"core":"0.9.0","abi":3}';
    final d = CoreDispatcher(() => fake);
    keys.set('search.kagi.key', 'KAGI');
    // handleLine, not serveLines: the end of input would close the engine
    Future<List<Map<String, dynamic>>> run(KeyStore k, List<Map<String, dynamic>> reqs) async => [
          for (final q in reqs) jsonDecode(handleLine(jsonEncode(q), d, handlers: [k], hook: k)) as Map<String, dynamic>,
        ];

    var r = await run(keys, [
      {'id': 1, 'op': 'open', 'args': {'sources': []}},
      {'id': 2, 'op': 'setWeb', 'args': {'provider': 'kagi', 'key': KeyStore.refOf('search.kagi.key'), 'online': true}},
    ]);
    expect(r[1]['ok'], isTrue);
    expect(fake.calls, contains('setWeb:kagi:KAGI:true'));
    // a raw key (the check of a pasted key) does not replace what is remembered
    await run(keys, [
      {'id': 1, 'op': 'setWeb', 'args': {'provider': 'kagi', 'key': 'PASTED', 'online': true}},
    ]);
    fake.calls.clear();
    final again = KeyStore(file);
    again.replay(d);
    expect(fake.calls, ['setWeb:kagi:KAGI:true']);
    expect(file.readAsStringSync(), isNot(contains('PASTED')));
    // switching it off is remembered too
    r = await run(again, [
      {'id': 1, 'op': 'setWeb', 'args': {'provider': null, 'key': null, 'online': false}},
    ]);
    fake.calls.clear();
    KeyStore(file).replay(d);
    expect(fake.calls, ['setWeb:null:null:false']);
  });
}
