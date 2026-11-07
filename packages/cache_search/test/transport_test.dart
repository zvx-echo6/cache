import 'dart:convert';
import 'dart:typed_data';

import 'package:cache_search/cache_search.dart';
import 'package:cache_search/src/transport_http.dart';
import 'package:cache_search/src/wire.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

HttpTransport _t(Future<http.Response> Function(http.Request) h) =>
    HttpTransport(client: MockClient(h), endpoint: Uri.parse('https://cache.test/api/core'));

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  group('wire encoding', () {
    test('a Uint8List anywhere survives jsonEncode and comes back as a Uint8List', () {
      final bytes = Uint8List.fromList([0, 1, 127, 128, 255]);
      final v = {
        'a': [bytes, 'image/png'],
        'n': {'deep': [1, 2.5, null, true, bytes]},
        's': 'text',
      };
      final text = jsonEncode(wireEncode(v));
      expect(text, contains(r'"$bytes"'));
      final back = wireDecode(jsonDecode(text)) as Map;
      expect(((back['a'] as List)[0] as Uint8List), bytes);
      expect(((back['n'] as Map)['deep'] as List).last, bytes);
      expect(back['s'], 'text');
      expect(((back['n'] as Map)['deep'] as List).sublist(0, 4), [1, 2.5, null, true]);
    });

    test('a map that only looks like bytes is left alone', () {
      final v = {r'$bytes': 5, 'x': 1};
      expect(wireDecode(v), v);
    });
  });

  group('HttpTransport', () {
    test('posts {op,args} as JSON and returns the decoded result', () async {
      late http.Request seen;
      final t = _t((r) async {
        seen = r;
        return _json({'ok': true, 'result': {'core': '1'}});
      });
      expect(await t.call('version', {'x': Uint8List.fromList([9])}), {'core': '1'});
      expect(seen.method, 'POST');
      expect(seen.url.path, '/api/core');
      expect(jsonDecode(seen.body), {'op': 'version', 'args': {'x': {r'$bytes': 'CQ=='}}});
    });

    test('bytes in a result come back as a Uint8List', () async {
      final t = _t((r) async => _json({'ok': true, 'result': [{r'$bytes': base64Encode([1, 2, 3])}, 'image/png']}));
      final r = await t.call('zimGet', {'address': 'a'}) as List;
      expect(r[0], isA<Uint8List>());
      expect(r[0], [1, 2, 3]);
    });

    test('an error becomes the CacheSearchException the phone would raise', () async {
      final t = _t((r) async => _json({'ok': false, 'error': {'code': 'index_stale', 'message': 'Rebuild the index'}}));
      await expectLater(
        t.call('search', {}),
        throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'index_stale').having((e) => e.message, 'message', 'Rebuild the index')),
      );
    });

    test('the isolate pair form of an error is accepted too', () async {
      final t = _t((r) async => _json({'ok': false, 'error': ['io', 'cannot open']}));
      await expectLater(t.call('open', {}), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'io')));
    });

    test('HTTP 401 is unauthorized', () async {
      final t = _t((r) async => http.Response('', 401));
      await expectLater(t.call('version', {}), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'unauthorized')));
    });

    test('a body that is not a result, and a network failure, are internal errors', () async {
      await expectLater(_t((r) async => http.Response('<html>', 502)).call('version', {}),
          throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'internal')));
      await expectLater(_t((r) async => throw http.ClientException('offline')).call('version', {}),
          throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'internal')));
    });
  });
}
