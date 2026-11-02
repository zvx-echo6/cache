import 'dart:convert';
import 'dart:typed_data';

import 'package:cache/browse/epub_address.dart';
import 'package:cache/browse/zim_urls.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

const id = '17e9fb54-9554-d2cd-e15f-17cf750882d1';

void main() {
  test("an EPUB citation keeps its !/ and its block anchor through the reader's address mapping", () {
    const cite = 'zim:$id/I/Field Guide.epub!/OEBPS/Text/ch03.xhtml#cache-b12';
    final u = readerUrl(cite)!;
    expect(u.toString(), 'https://zim.invalid/$id/I/Field%20Guide.epub!/OEBPS/Text/ch03.xhtml#cache-b12');
    expect(u.fragment, 'cache-b12');
    // Back to the address: the core is asked for the file inside the EPUB.
    expect(addressOfUrl(u), 'zim:$id/I/Field%20Guide.epub!/OEBPS/Text/ch03.xhtml');
    // A link in the chapter resolves inside the EPUB.
    final next = u.resolve('ch04.xhtml');
    expect(addressOfUrl(next), 'zim:$id/I/Field%20Guide.epub!/OEBPS/Text/ch04.xhtml');
    expect(addressOfUrl(u.resolve('../Styles/book.css')), 'zim:$id/I/Field%20Guide.epub!/OEBPS/Styles/book.css');
    // On iOS the same through the reader's own scheme.
    expect(readerUrl(cite, customScheme: true).toString(), startsWith('cache-zim://zim.invalid/$id/I/Field%20Guide.epub!/OEBPS/'));
    // Other pages still open at the top.
    expect(readerUrl('zim:$id/A/Water#History')!.hasFragment, isFalse);
  });

  test('what an address is', () {
    expect(isEpubEntryAddress('zim:$id/I/book.epub'), isTrue);
    expect(isEpubEntryAddress('zim:$id/I/BOOK.EPUB?x=1'), isTrue);
    expect(isEpubEntryAddress('zim:$id/I/book.epub!/ch1.xhtml'), isFalse);
    expect(isEpubEntryAddress('zim:$id/A/Water'), isFalse);
    expect(isEpubInnerAddress('zim:$id/I/book.epub!/ch1.xhtml#cache-b3'), isTrue);
    expect(isEpubInnerAddress('zim:$id/I/book.epub'), isFalse);
    expect(epubBlockOfAddress('zim:$id/I/book.epub!/ch1.xhtml#cache-b3'), 3);
    expect(epubBlockOfAddress('zim:$id/I/book.epub!/ch1.xhtml#intro'), isNull);
    expect(resolveEpubPath('OEBPS/content.opf', 'Text/ch1.xhtml'), 'OEBPS/Text/ch1.xhtml');
    expect(resolveEpubPath('OEBPS/Text/ch1.xhtml', '../Images/a.png#x'), 'OEBPS/Images/a.png');
    expect(resolveEpubPath('content.opf', 'ch1.xhtml'), 'ch1.xhtml');
    expect(quoteProbe('  Boil   water for one full minute before drinking it, and longer at altitude. '), 'Boil water for one full minute before drinking');
  });

  group('tapping an EPUB entry opens its first chapter', () {
    Future<ZimBytes> Function(String) served(Map<String, String> files) => (a) async {
      final f = files[a];
      if (f == null) throw const CacheSearchException('not_found', 'no such entry');
      return ZimBytes(Uint8List.fromList(utf8.encode(f)), 'application/xml');
    };
    const epub = 'zim:$id/I/book.epub';
    const container = '<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>';
    const opf = '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><manifest>'
        '<item id="cover" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>'
        '<item id="c1" href="Text/ch01.xhtml" media-type="application/xhtml+xml"/>'
        '<item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/></manifest>'
        '<spine><itemref idref="cover" linear="no"/><itemref idref="c1"/></spine></package>';

    test('the spine in reading order: the first linear item', () async {
      final get = served({'$epub!/META-INF/container.xml': container, '$epub!/OEBPS/content.opf': opf});
      expect(await epubFirstChapter(epub, get), '$epub!/OEBPS/Text/ch01.xhtml');
      // From an address with a fragment too.
      expect(await epubFirstChapter('$epub#x', get), '$epub!/OEBPS/Text/ch01.xhtml');
    });

    test('an EPUB that does not say (no container, a broken package): null, so the reader says it could not open it', () async {
      expect(await epubFirstChapter(epub, served({})), isNull);
      expect(await epubFirstChapter(epub, served({'$epub!/META-INF/container.xml': container, '$epub!/OEBPS/content.opf': '<package'})), isNull);
    });
  });
}
