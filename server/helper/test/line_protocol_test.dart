import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/errors.dart';
import '../../../packages/cache_search/lib/src/native_api.dart';
import '../../../packages/cache_search/lib/src/transport_http.dart';
import '../bin/line_protocol.dart';
import 'fake_native.dart';

FakeNative _fake() => FakeNative()
  ..replies['version'] = '{"core":"0.9.0","abi":3}'
  ..replies['search'] =
      '{"results":[{"address":"zim:u/A","title":"A","snippet":"s","source_id":"u","source_kind":"zim","source_title":"U"}],"total_estimate":1}'
  ..replies['status'] =
      '{"sources":[{"id":"u","kind":"zim","path":"/z/a.zim","title":"U","indexed":true,"building":false,"stale":false,"opening":false,"updating":false,"docs":7,"keyword_source":"own","embedding_model":null,"error":null}]}'
  ..zim = ZimBytes(Uint8List.fromList([0, 1, 2, 250, 255]), 'image/png');

/// Feeds [requests] through the line protocol and returns the lines it printed.
Future<List<Map<String, dynamic>>> _run(CoreDispatcher d, List<Object> requests) async {
  final out = <String>[];
  await serveLines(Stream.value(utf8.encode('${requests.map((r) => r is String ? r : jsonEncode(r)).join('\n')}\n')), out.add, d);
  return [for (final l in out) jsonDecode(l) as Map<String, dynamic>];
}

Map<String, dynamic> _req(int id, String op, [Map<String, dynamic> args = const {}]) => {'id': id, 'op': op, 'args': args};

void main() {
  test('prints ready first, answers open, version, search and status in order', () async {
    final fake = _fake();
    final out = await _run(CoreDispatcher(() => fake), [
      _req(1, 'open', {'sources': [], 'extra': null}),
      _req(2, 'version'),
      _req(3, 'search', {'query': 'a', 'k': 5, 'offset': 0, 'sources': null, 'queryVector': null}),
      _req(4, 'status'),
    ]);
    expect(out[0], {'ready': true});
    expect(out[1], {'id': 1, 'ok': true, 'result': null});
    expect(out[2], {'id': 2, 'ok': true, 'result': {'core': '0.9.0', 'abi': 3}});
    expect(out[3]['id'], 3);
    expect(((out[3]['result'] as Map)['results'] as List).single['title'], 'A');
    expect(((out[4]['result'] as List).single as Map)['docs'], 7);
    expect(out, hasLength(5));
    expect(fake.calls.last, 'close:7', reason: 'end of input closes the core');
  });

  test('an error comes back as the exception code and message, and the next request still runs', () async {
    final fake = _fake()
      ..error = '{"code":"not_found","message":"no such page"}'
      ..replies['read'] = null;
    final out = await _run(CoreDispatcher(() => fake), [
      _req(1, 'open', {'sources': []}),
      _req(2, 'read', {'address': 'zim:u/Z', 'maxChars': 100}),
      _req(3, 'nonsense'),
      'this is not json',
      _req(5, 'version'),
    ]);
    expect(out[2], {'id': 2, 'ok': false, 'error': {'code': 'not_found', 'message': 'no such page'}});
    expect(out[3], {'id': 3, 'ok': false, 'error': {'code': 'internal', 'message': 'Unknown call nonsense'}});
    expect(out[4]['ok'], false);
    expect((out[4]['error'] as Map)['code'], 'bad_json');
    expect(out[5]['ok'], true);
  });

  test('a call before open fails like the phone: the core is not open', () async {
    final out = await _run(CoreDispatcher(_fake), [_req(1, 'version')]);
    expect(out[1], {'id': 1, 'ok': false, 'error': {'code': 'internal', 'message': 'The search core is not open'}});
  });

  test('zimGet bytes travel as {"\$bytes": base64}', () async {
    final fake = _fake();
    final out = await _run(CoreDispatcher(() => fake), [
      _req(1, 'open', {'sources': []}),
      _req(2, 'zimGet', {'address': 'zim:u/logo.png'}),
    ]);
    final result = out[2]['result'] as List;
    expect(result[0], {r'$bytes': base64Encode([0, 1, 2, 250, 255])});
    expect(result[1], 'image/png');
  });

  test('HttpTransport against the helper protocol: results, bytes and errors round trip', () async {
    final fake = _fake()..replies['read'] = null..error = '{"code":"not_found","message":"no such page"}';
    final d = CoreDispatcher(() => fake);
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final reply = jsonDecode(handleLine(jsonEncode({'id': 1, ...body}), d)) as Map<String, dynamic>;
      reply.remove('id');
      return http.Response(jsonEncode(reply), 200, headers: {'content-type': 'application/json'});
    });
    final t = HttpTransport(client: client, endpoint: Uri.parse('https://cache.test/api/core'));
    await t.call('open', {'sources': <Object>[]});
    expect(await t.call('version', {}), {'core': '0.9.0', 'abi': 3});
    final z = await t.call('zimGet', {'address': 'zim:u/x'}) as List;
    expect(z[0], isA<Uint8List>());
    expect(z[0], [0, 1, 2, 250, 255]);
    await expectLater(
      t.call('read', {'address': 'zim:u/Z', 'maxChars': 10}),
      throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'not_found').having((e) => e.message, 'message', 'no such page')),
    );
    await t.close();
  });
}
