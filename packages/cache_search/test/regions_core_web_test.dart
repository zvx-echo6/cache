import 'dart:convert';

import 'package:cache_search/cache_search.dart' show CacheSearchException;
import 'package:cache_search/src/regions_core_web.dart';
import 'package:cache_search/src/transport_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// The browser's RegionsCore talks to the server's regions.* ops through /api/core (server/helper/bin/regions_ops.dart).
void main() {
  late List<Map<String, dynamic>> sent;
  Map<String, dynamic> Function(Map<String, dynamic>) answer = (_) => {'ok': true, 'result': null};

  HttpTransport transport() => HttpTransport(
        client: MockClient((http.Request r) async {
          final body = jsonDecode(r.body) as Map<String, dynamic>;
          sent.add(body);
          return http.Response(jsonEncode(answer(body)), 200, headers: {'content-type': 'application/json'});
        }),
        endpoint: Uri.parse('https://cache.test/api/core'),
      );

  setUp(() {
    sent = [];
    answer = (_) => {'ok': true, 'result': {'ok': true}};
  });

  test('open asks the server to open its engine and sends no phone folders', () async {
    await RegionsCore.open({'dir': '/phone/regions'}, transport: transport());
    expect(sent.single['op'], 'regions.open');
    expect(sent.single['args'], isEmpty);
  });

  test('a call is one regions.call with the method and its arguments, and the answer comes back', () async {
    final core = await RegionsCore.open(const {}, transport: transport());
    answer = (_) => {
          'ok': true,
          'result': {'build': 'na-1', 'regions': []}
        };
    final r = await core.call('status');
    expect(r['build'], 'na-1');
    expect(sent.last['op'], 'regions.call');
    expect(sent.last['args'], {'method': 'status', 'args': <String, dynamic>{}});
    answer = (_) => {'ok': true, 'result': {'ok': true}};
    await core.call('add', {'id': 'idaho', 'name': 'Idaho'});
    expect((sent.last['args'] as Map)['args'], {'id': 'idaho', 'name': 'Idaho'});
  });

  test('the engine\'s error arrives as the same exception the phone gets', () async {
    final core = await RegionsCore.open(const {}, transport: transport());
    answer = (_) => {
          'ok': false,
          'error': {'code': 'offline', 'message': 'no index'}
        };
    expect(
      core.call('plan', {'id': 'x'}),
      throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'offline').having((e) => e.message, 'message', 'no index')),
    );
  });

  test('open fails with the server\'s reason when its core has no region engine', () async {
    answer = (_) => {
          'ok': false,
          'error': {'code': 'unavailable', 'message': 'no region engine'}
        };
    expect(RegionsCore.open(const {}, transport: transport()), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'unavailable')));
  });

  test('a closed core answers nothing', () async {
    final core = await RegionsCore.open(const {}, transport: transport());
    await core.close();
    expect(core.call('status'), throwsA(isA<CacheSearchException>()));
  });
}
