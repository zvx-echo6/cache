import 'package:flutter_test/flutter_test.dart';

import 'package:cache/browse/web/reader_frame_base.dart';

void main() {
  test('a page report with string fields is read', () {
    final m = parseZimFrameMessage({'cacheZim': 'page', 'href': '/zim/t/a', 'title': 'A'});
    expect(m, isA<ZimFramePage>());
    expect((m as ZimFramePage).href, '/zim/t/a');
    expect(m.title, 'A');
  });

  test('an external link with a string url is read', () {
    final m = parseZimFrameMessage({'cacheZim': 'external', 'url': 'https://example.org/'});
    expect((m as ZimFrameExternal).url, 'https://example.org/');
  });

  test('anything else is ignored', () {
    expect(parseZimFrameMessage(null), isNull);
    expect(parseZimFrameMessage('page'), isNull);
    expect(parseZimFrameMessage([1]), isNull);
    expect(parseZimFrameMessage({'cacheZim': 'eval', 'url': 'x'}), isNull);
    expect(parseZimFrameMessage({'cacheZim': 'page', 'href': 1, 'title': 'A'}), isNull);
    expect(parseZimFrameMessage({'cacheZim': 'page', 'href': '/a'}), isNull);
    expect(parseZimFrameMessage({'cacheZim': 'external', 'url': {'a': 1}}), isNull);
    expect(parseZimFrameMessage({'url': 'https://example.org/'}), isNull);
  });

  test('only http, https and mailto are openable', () {
    expect(isOpenableExternalUrl('https://example.org/'), isTrue);
    expect(isOpenableExternalUrl('http://example.org/'), isTrue);
    expect(isOpenableExternalUrl('mailto:a@b.c'), isTrue);
    expect(isOpenableExternalUrl('javascript:alert(1)'), isFalse);
    expect(isOpenableExternalUrl('data:text/html,x'), isFalse);
    expect(isOpenableExternalUrl('blob:https://x/y'), isFalse);
    expect(isOpenableExternalUrl('//example.org/'), isFalse);
    expect(isOpenableExternalUrl('/zim/a'), isFalse);
    expect(isOpenableExternalUrl(''), isFalse);
  });
}
