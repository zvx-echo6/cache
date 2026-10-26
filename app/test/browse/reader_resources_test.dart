import 'dart:convert';
import 'dart:typed_data';

import 'package:cache/browse/reader_resources.dart';
import 'package:cache/browse/zim_urls.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

const id = '17e9fb54-9554-d2cd-e15f-17cf750882d1';

void main() {
  test('iOS registers the scheme and blocks other resource protocols', () {
    final settings = readerSettings(customScheme: true);
    expect(settings.resourceCustomSchemes, [zimReaderScheme]);
    expect(settings.useShouldInterceptRequest, false);
    final rules = settings.contentBlockers!;
    expect(rules.first.action.type, ContentBlockerActionType.BLOCK);
    expect(
      rules.last.action.type,
      ContentBlockerActionType.IGNORE_PREVIOUS_RULES,
    );
    bool blocked(String url) {
      var result = false;
      for (final rule in rules) {
        if (RegExp(rule.trigger.urlFilter).hasMatch(url)) {
          result = rule.action.type == ContentBlockerActionType.BLOCK;
        }
      }
      return result;
    }

    for (final url in [
      'https://example.org/a.png',
      'http://zim.invalid/a',
      'wss://example.org/socket',
      'file:///private/file',
      'ftp://example.org/a',
    ]) {
      expect(blocked(url), true, reason: url);
    }
    for (final url in [
      'cache-zim://zim.invalid/$id/A/page',
      'data:image/png;base64,AA==',
      'blob:local',
    ]) {
      expect(blocked(url), false, reason: url);
    }
  });

  test(
    'Android keeps its HTTPS interception and network/file restrictions',
    () {
      final settings = readerSettings(customScheme: false);
      expect(settings.resourceCustomSchemes, isEmpty);
      expect(settings.contentBlockers, isEmpty);
      expect(settings.useShouldInterceptRequest, true);
      expect(settings.blockNetworkLoads, true);
      expect(settings.allowFileAccess, false);
      expect(settings.useShouldOverrideUrlLoading, true);
    },
  );

  test(
    'iOS links, assets, queries and shortcuts round-trip canonical addresses',
    () async {
      final asked = <String>[];
      final server = ZimPageServer((address) async {
        asked.add(address);
        return ZimBytes(Uint8List.fromList([0, 127, 255]), 'image/png');
      });
      final page = readerUrl('zim:$id/A/Caf\u00e9%25%23', customScheme: true)!;
      expect(page.scheme, zimReaderScheme);
      expect(addressOfUrl(page), 'zim:$id/A/Caf%C3%A9%25%23');
      for (final link in [
        'Other#section',
        '../-/style.css',
        '../I/picture.png',
        '?q=water',
      ]) {
        final url = page.resolve(link);
        expect(isReaderUrl(url, customScheme: true), true);
        final response = await serveCustomZimResource(server, url);
        expect(response.data, [0, 127, 255]);
        expect(response.contentType, 'image/png');
        expect(asked.last, addressOfUrl(url));
      }
      expect(addressOfUrl(page.resolve('#section')), addressOfUrl(page));
      expect(readerUrl(addressOfUrl(page)!)!.scheme, 'https');
    },
  );

  test('external and disguised reader URLs never reach the archive', () async {
    final server = ZimPageServer(
      (address) async => fail('unexpected archive read'),
    );
    for (final url in [
      'https://example.org/a',
      'file://zim.invalid/$id/A/a',
      'cache-zim://user@zim.invalid/$id/A/a',
      'cache-zim://zim.invalid:123/$id/A/a',
      'cache-zim://zim.invalid/not-a-uuid/A/a',
      'cache-zim://zim.invalid/$id/',
    ]) {
      final uri = Uri.parse(url);
      expect(addressOfUrl(uri), isNull);
      final response = await serveCustomZimResource(server, uri);
      expect(
        utf8.decode(response.data),
        contains('not in the offline archive'),
      );
    }
    expect(isReaderUrl(readerUrl('zim:$id/A/a')!, customScheme: true), false);
  });

  test('CSS and binary assets retain their exact bytes and MIME', () async {
    for (final mime in [
      'text/css; charset=utf-8',
      'image/png',
      'font/woff2',
      'application/javascript',
    ]) {
      final bytes = Uint8List.fromList([0, 1, 127, 128, 255]);
      final server = ZimPageServer((a) async => ZimBytes(bytes, mime));
      final response = await serveCustomZimResource(
        server,
        readerUrl('zim:$id/-/asset', customScheme: true)!,
      );
      expect(response.contentType, mime.split(';').first);
      expect(response.data, bytes);
    }
  });

  test(
    'offline policy precedes archive scripts and keeps markup and Unicode',
    () async {
      for (final html in [
        '<!doctype html><html><head><script>start()</script></head><body>caf\u00e9</body></html>',
        '<script>start()</script><p>caf\u00e9</p>',
        '<!-- <head> --><script>start()</script>caf\u00e9',
      ]) {
        final server = ZimPageServer(
          (a) async => ZimBytes(
            Uint8List.fromList(utf8.encode(html)),
            'text/html; charset=utf-8',
          ),
        );
        final response = await serveCustomZimResource(
          server,
          readerUrl('zim:$id/A/a', customScheme: true)!,
        );
        final body = utf8.decode(response.data);
        expect(response.contentType, 'text/html');
        expect(
          body.indexOf('Content-Security-Policy'),
          lessThan(body.indexOf('<script>')),
        );
        expect(body, contains('connect-src cache-zim:'));
        expect(body, contains("object-src 'none'"));
        expect(body, contains('caf\u00e9'));
        if (html.startsWith('<!doctype')) {
          expect(body.startsWith('<!doctype html>'), true);
        }
      }
    },
  );

  test(
    'missing entries and core errors complete with local readable responses',
    () async {
      for (final code in ['not_found', 'io']) {
        final server = ZimPageServer(
          (a) async =>
              throw CacheSearchException(code, 'private native details'),
        );
        final response = await serveCustomZimResource(
          server,
          readerUrl('zim:$id/A/a', customScheme: true)!,
        );
        final body = utf8.decode(response.data);
        expect(
          body,
          contains(
            code == 'not_found'
                ? 'not in the offline archive'
                : 'could not be read',
          ),
        );
        expect(body, isNot(contains('private native details')));
        expect(body, contains('Content-Security-Policy'));
      }
    },
  );
}
