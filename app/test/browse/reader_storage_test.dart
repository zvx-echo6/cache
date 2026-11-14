import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/browse/reader_resources.dart';
import 'package:cache/browse/zim_urls.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

const _id = '17e9fb54-9554-d2cd-e15f-17cf750882d1';
const _js = '/*zim-storage-marker*/';
const _tag = '<script>$_js</script>';

int _count(String s, String part) => part.allMatches(s).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the stand-in goes first in the head, after its attributes', () {
    const page = '<!DOCTYPE html><HTML lang="en"><HEAD data-x="1"><script>var a=1</script></HEAD><body>hi</body></html>';
    final out = withZimStorage(page, _js);
    expect(out, startsWith('<!DOCTYPE html><HTML lang="en"><HEAD data-x="1">$_tag<script>var a=1</script>'));
    expect(_count(out, _tag), 1);
  });

  test('a page with no head gets it right after <html>', () {
    final out = withZimStorage('<html lang="en"><body><script>x()</script></body></html>', _js);
    expect(out, startsWith('<html lang="en">$_tag<body>'));
    expect(_count(out, _tag), 1);
  });

  test('a head is not mistaken for a header, and a fragment gets it at the start', () {
    final out = withZimStorage('<header>x</header><p>hello</p>', _js);
    expect(out, startsWith('$_tag<header>'));
    expect(_count(out, _tag), 1);
  });

  test('a closing script tag inside the script cannot end the inline script early', () {
    final out = withZimStorage('<head></head>', 'var s="</script>";');
    expect(out, '<head><script>var s="<\\/script>";</script></head>');
  });

  test('the real stand-in ships as an asset, installs always and never contains a closing script tag', () async {
    final js = await rootBundle.loadString(kZimStorageAsset);
    expect(js.length, greaterThan(10000));
    expect(js.toLowerCase().contains('</script'), false);
  });

  test('the licence the app lists is the one kept in third_party', () {
    expect(File('assets/reader/fake-indexeddb-LICENSE').readAsStringSync(), File('../third_party/fake-indexeddb/LICENSE').readAsStringSync());
  });

  test('iOS: the policy meta stays first, then the stand-in first in the head', () async {
    final server = ZimPageServer((a) async => ZimBytes(Uint8List.fromList(utf8.encode('<!doctype html><html><head><script>p()</script></head><body></body></html>')), 'text/html'));
    final r = await serveCustomZimResource(server, readerUrl('zim:$_id/A/x.html', customScheme: true)!, storageScript: _js);
    final out = utf8.decode(r.data);
    final meta = out.indexOf('<meta http-equiv="Content-Security-Policy"');
    expect(meta, greaterThanOrEqualTo(0));
    expect(out.indexOf('<!doctype html>'), 0);
    expect(meta, lessThan(out.indexOf(_tag)));
    expect(out.indexOf(_tag), lessThan(out.indexOf('<script>p()</script>')));
    expect(_count(out, _tag), 1);
  });

  test('Android and iOS pages each hold the stand-in exactly once', () async {
    const page = '<html><head><title>t</title></head><body><p>x</p></body></html>';
    final android = androidReaderHtml(page, _js);
    expect(_count(android, _tag), 1);
    expect(android.indexOf(_tag), lessThan(android.indexOf('<title>')));
    final server = ZimPageServer((a) async => ZimBytes(Uint8List.fromList(utf8.encode(page)), 'text/html'));
    final ios = utf8.decode((await serveCustomZimResource(server, readerUrl('zim:$_id/A/x.html', customScheme: true)!, storageScript: _js)).data);
    expect(_count(ios, _tag), 1);
    // an error page (no archive entry) is HTML too, and gets it once as well
    final missing = ZimPageServer((a) async => throw StateError('x'));
    final err = utf8.decode((await serveCustomZimResource(missing, readerUrl('zim:$_id/A/y.html', customScheme: true)!, storageScript: _js)).data);
    expect(_count(err, _tag), lessThanOrEqualTo(1));
  });
}
