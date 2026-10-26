import 'dart:io';

import 'package:cache/settings/web_search_setup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late int status;
  late List<Map<String, String?>> seen;

  setUp(() async {
    seen = [];
    status = 200;
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      final body = await utf8StringOf(req);
      seen.add({'method': req.method, 'auth': req.headers.value('authorization'), 'ua': req.headers.value('user-agent'), 'body': body});
      req.response.statusCode = status;
      req.response.write('{}');
      await req.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  Uri at() => Uri.parse('http://127.0.0.1:${server.port}/api/v1/search');

  test('one search for one result, with the key as a bearer token', () async {
    final r = await checkKagiKey('the-key', address: at());
    expect(r.ok, isTrue);
    expect(seen, hasLength(1));
    expect(seen.single['method'], 'POST');
    expect(seen.single['auth'], 'Bearer the-key');
    expect(seen.single['body'], contains('"limit":1'));
    expect(seen.single['ua'], isNot(contains('@')), reason: 'no email or name in the user agent');
  });

  test('a refused key, an empty account and a server error each say what happened', () async {
    status = 401;
    expect((await checkKagiKey('k', address: at())).message, contains('did not accept'));
    status = 403;
    expect((await checkKagiKey('k', address: at())).ok, isFalse);
    status = 402;
    expect((await checkKagiKey('k', address: at())).message, contains('no search credit'));
    status = 500;
    expect((await checkKagiKey('k', address: at())).message, contains('(500)'));
  });

  test('no connection says so', () async {
    final dead = Uri.parse('http://127.0.0.1:1/x');
    final r = await checkKagiKey('k', address: dead);
    expect(r.ok, isFalse);
    expect(r.message, contains("Can't reach Kagi"));
  });

  test('the key never appears in a message', () async {
    status = 401;
    final r = await checkKagiKey('super-secret-key', address: at());
    expect(r.message, isNot(contains('super-secret-key')));
  });
}

Future<String> utf8StringOf(HttpRequest r) async {
  final b = <int>[];
  await for (final c in r) {
    b.addAll(c);
  }
  return String.fromCharCodes(b);
}
