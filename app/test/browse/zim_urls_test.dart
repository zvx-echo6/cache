import 'dart:convert';
import 'dart:typed_data';

import 'package:cache/browse/zim_urls.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

const id = '17e9fb54-9554-d2cd-e15f-17cf750882d1';

void main() {
  test('a zim address becomes a page address and back', () {
    final u = readerUrl('zim:$id/A/Water_purification')!;
    expect(u.toString(), 'https://zim.invalid/$id/A/Water_purification');
    expect(addressOfUrl(u), 'zim:$id/A/Water_purification');
  });

  test('spaces and non-ASCII are encoded; the address\'s own escapes stay', () {
    final u = readerUrl('zim:$id/Café au lait%25%23')!;
    expect(u.path, '/$id/Caf%C3%A9%20au%20lait%25%23');
    // The core percent-decodes the path itself.
    expect(addressOfUrl(u), 'zim:$id/Caf%C3%A9%20au%20lait%25%23');
  });

  test('a fragment is dropped and a query is kept', () {
    expect(readerUrl('zim:$id/Page#section')!.toString(), 'https://zim.invalid/$id/Page');
    final u = Uri.parse('https://zim.invalid/$id/search?q=a');
    expect(addressOfUrl(u), 'zim:$id/search?q=a');
  });

  test('other hosts and non-addresses are refused', () {
    expect(readerUrl('https://en.wikipedia.org/wiki/Water'), isNull);
    expect(readerUrl('zim:not-a-uuid/x'), isNull);
    expect(addressOfUrl(Uri.parse('https://example.com/x')), isNull);
    expect(isZimAddress('zim:$id/x'), isTrue);
    expect(isZimAddress('lib:abc/1'), isFalse);
    expect(zimIdOfAddress('zim:${id.toUpperCase()}/x'), id);
  });

  group('ZimPageServer', () {
    test('serves an entry with its type', () async {
      final asked = <String>[];
      final s = ZimPageServer((a) async {
        asked.add(a);
        return ZimBytes(Uint8List.fromList(utf8.encode('<p>hi</p>')), 'text/html');
      });
      final r = await s.serve(Uri.parse('https://zim.invalid/$id/A/Water'));
      expect(r.status, 200);
      expect(r.mime, 'text/html');
      expect(utf8.decode(r.bytes), '<p>hi</p>');
      expect(asked, ['zim:$id/A/Water']);
    });

    test('a missing entry is a 404 and anything off the fake host never reaches the ZIM', () async {
      final s = ZimPageServer((a) async => throw const CacheSearchException('not_found', 'no entry'));
      expect((await s.serve(Uri.parse('https://zim.invalid/$id/missing'))).status, 404);
      expect((await s.serve(Uri.parse('https://example.com/x.png'))).status, 404);
    });

    test('a core failure is a 500 with the reason', () async {
      final s = ZimPageServer((a) async => throw const CacheSearchException('io', 'disk gone'));
      final r = await s.serve(Uri.parse('https://zim.invalid/$id/x'));
      expect(r.status, 500);
      expect(utf8.decode(r.bytes), 'disk gone');
    });
  });
}
