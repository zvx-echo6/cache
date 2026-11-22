import 'dart:io';

import 'package:cache/net/fetch.dart';
import 'package:flutter_test/flutter_test.dart';

// 1.1 audit: fetchBytes checked the first address (https, or this machine) and let the client follow redirects by itself, which
// goes from https to plain http. Redirects are now followed one checked hop at a time.
void main() {
  test('a redirect never leaves https, and with https only every hop is checked like the first address', () {
    final secure = Uri.parse('https://data.example.org/list.json'), local = Uri.parse('http://127.0.0.1:8080/list.json');
    for (final httpsOnly in [true, false]) {
      expect(isRedirectAllowed(secure, Uri.parse('http://data.example.org/list.json'), httpsOnly: httpsOnly), isFalse, reason: 'the same host over http');
      expect(isRedirectAllowed(secure, Uri.parse('http://other.example.net/x'), httpsOnly: httpsOnly), isFalse);
      expect(isRedirectAllowed(secure, Uri.parse('http://127.0.0.1:8080/x'), httpsOnly: httpsOnly), isFalse, reason: 'not to this machine either');
      expect(isRedirectAllowed(secure, Uri.parse('ftp://data.example.org/x'), httpsOnly: httpsOnly), isFalse);
      expect(isRedirectAllowed(secure, Uri.parse('https://cdn.example.net/list.json'), httpsOnly: httpsOnly), isTrue, reason: 'another https host is fine');
      expect(isRedirectAllowed(local, Uri.parse('https://data.example.org/x'), httpsOnly: httpsOnly), isTrue);
      expect(isRedirectAllowed(local, Uri.parse('http://localhost:8081/x'), httpsOnly: httpsOnly), isTrue);
    }
    expect(isRedirectAllowed(local, Uri.parse('http://other.example.net/x')), isFalse, reason: 'plain http only on this machine');
    expect(isRedirectAllowed(Uri.parse('http://video.example.net/a.vtt'), Uri.parse('http://video.example.net/b.vtt'), httpsOnly: false), isTrue, reason: 'a read that allows plain http');
  });

  group('against servers on this machine', () {
    late HttpServer server, other;
    late String base;

    Future<HttpServer> serve(void Function(HttpRequest r) answer) async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      s.listen((r) async {
        try {
          answer(r);
          await r.response.close();
        } catch (_) {}
      });
      return s;
    }

    void to(HttpRequest r, String location, [int status = 302]) {
      r.response.statusCode = status;
      r.response.headers.set(HttpHeaders.locationHeader, location);
    }

    final asked = <String>[];

    setUp(() async {
      asked.clear();
      other = await serve((r) {
        asked.add('other ${r.uri.path}');
        r.response.write('from the other server');
      });
      server = await serve((r) {
        asked.add(r.uri.path);
        switch (r.uri.path) {
          case '/moved':
            to(r, '/here?x=1', 301);
          case '/here':
            r.response.write('here ${r.uri.query}');
          case '/elsewhere':
            to(r, 'http://127.0.0.1:${other.port}/file');
          case '/out':
            // a documentation address: refused by the rule, before anything connects
            to(r, 'http://192.0.2.1/list.json');
          case '/round':
            to(r, '/round');
          case '/nowhere':
            r.response.statusCode = 302;
        }
      });
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async {
      await server.close(force: true);
      await other.close(force: true);
    });

    test('a redirect on the same server, and one to another server that is allowed, are followed', () async {
      expect(String.fromCharCodes(await fetchBytes(Uri.parse('$base/moved'))), 'here x=1');
      expect(String.fromCharCodes(await fetchBytes(Uri.parse('$base/elsewhere'))), 'from the other server');
      expect(asked, ['/moved', '/here', '/elsewhere', 'other /file']);
    });

    test('a redirect to an address the first one could not have been is refused, and nothing is asked there', () async {
      final watch = Stopwatch()..start();
      await expectLater(fetchBytes(Uri.parse('$base/out')), throwsA(isA<FetchException>().having((e) => e.failure, 'failure', FetchFailure.notAllowed).having((e) => e.host, 'host', '192.0.2.1')));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('redirects that never end stop after five, and one without an address is the error it is', () async {
      await expectLater(fetchBytes(Uri.parse('$base/round')), throwsA(isA<FetchException>().having((e) => e.failure, 'failure', FetchFailure.unreadable)));
      expect(asked.length, kFetchRedirects + 1);
      await expectLater(fetchBytes(Uri.parse('$base/nowhere')), throwsA(isA<FetchException>().having((e) => e.status, 'status', 302)));
    });
  });
}
