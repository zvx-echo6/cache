import 'dart:io';

import 'package:cache/browse/opds.dart';
import 'package:flutter_test/flutter_test.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  group('parseEntries (recorded response of /catalog/v2/entries?lang=eng&count=2&q=wikivoyage)', () {
    final page = parseEntries(fixture('kiwix_entries_wikivoyage.xml'));

    test('reads the paging fields', () {
      expect(page.total, 4);
      expect(page.start, 0);
      expect(page.entries.length, 2);
      expect(page.hasMore, isTrue);
      expect(page.next, 2);
    });

    test('reads title, description, language, size, date and variant', () {
      final e = page.entries.first;
      expect(e.title, 'Wikivoyage - Europe');
      expect(e.summary, 'Selection of Europe destinations from Wikivoyage');
      expect(e.language, 'eng');
      expect(e.name, 'wikivoyage_en_europe');
      expect(e.flavour, 'maxi');
      expect(e.flavourText, 'Full');
      expect(e.category, 'wikivoyage');
      expect(e.size, 385267712);
      expect(e.articleCount, 18322);
      expect(e.updated, '2026-09-14');
      expect(e.release, '2026-09');
      expect(e.author, 'Wikivoyage');
      expect(e.id, 'cb7785ec-5255-6f7b-c560-822e9c8cf340');
      expect(page.entries[1].flavourText, 'No pictures');
    });

    test('hides the catalogue\'s internal tags', () {
      expect(page.entries.first.tags, ['wikivoyage']);
    });

    test('the direct .zim address is the catalogue link without .meta4, and the checksums sit next to it', () {
      final e = page.entries.first;
      expect(e.downloadUrl.toString(), 'https://lb.download.kiwix.org/zim/wikivoyage/wikivoyage_en_europe_maxi_2026-09.zim');
      expect(e.sha256Url.toString(), '${e.downloadUrl}.sha256');
      expect(e.md5Url.toString(), '${e.downloadUrl}.md5');
      expect(e.fileName, 'wikivoyage_en_europe_maxi_2026-09.zim');
    });

    test('the icon comes from the catalogue, asked at 96 px', () {
      expect(page.entries.first.iconUrl.toString(),
          'https://opds.library.kiwix.org/catalog/v2/illustration/cb7785ec-5255-6f7b-c560-822e9c8cf340/?size=96');
    });

    test('entries round-trip through json', () {
      final e = page.entries.first;
      final back = CatalogEntry.fromJson(e.toJson());
      expect(back.downloadUrl, e.downloadUrl);
      expect(back.title, e.title);
      expect(back.size, e.size);
    });

    test('something that is not a catalogue is an error in words', () {
      expect(() => parseEntries('<html><body>nope</body></html>'), throwsA(isA<CatalogException>()));
      expect(() => parseEntries('not xml at all <'), throwsA(isA<CatalogException>()));
    });
  });

  test('parseCategories lists the categories with readable labels', () {
    final c = parseCategories(fixture('kiwix_categories.xml'));
    expect(c.length, 16);
    expect(c.map((x) => x.id), containsAll(['wikipedia', 'stack_exchange', 'iFixit', 'gutenberg', 'wikivoyage']));
    expect(c.firstWhere((x) => x.id == 'stack_exchange').label, 'Stack Exchange');
    expect(c.firstWhere((x) => x.id == 'iFixit').label, 'iFixit');
    expect(categoryLabel('something_new'), 'Something new');
  });

  test('parseLanguages reads code, name and count', () {
    final l = parseLanguages(fixture('kiwix_languages.xml'));
    final eng = l.firstWhere((x) => x.code == 'eng');
    expect(eng.name, 'English');
    expect(eng.count, greaterThan(100));
    expect(l.map((x) => x.code), containsAll(['afr', 'fra', 'spa', 'deu']));
  });

  group('KiwixCatalog', () {
    test('builds the documented entries address with the filters', () {
      final c = KiwixCatalog(fetch: (u) async => '');
      final u = c.entriesUrl(query: ' water ', language: 'eng', category: 'stack_exchange', count: 30, start: 60);
      expect(u.scheme, 'https');
      expect(u.host, 'opds.library.kiwix.org');
      expect(u.path, '/catalog/v2/entries');
      expect(u.queryParameters, {'q': 'water', 'lang': 'eng', 'category': 'stack_exchange', 'count': '30', 'start': '60'});
      expect(c.entriesUrl(name: 'wikivoyage_en_europe').queryParameters['name'], 'wikivoyage_en_europe');
      expect(c.entriesUrl(tag: 'medicine').queryParameters['tag'], 'medicine');
      expect(c.categoriesUrl.path, '/catalog/v2/categories');
      expect(c.languagesUrl.path, '/catalog/v2/languages');
    });

    test('reads a page through the fetcher', () async {
      Uri? asked;
      final c = KiwixCatalog(fetch: (u) async {
        asked = u;
        return fixture('kiwix_entries_wikivoyage.xml');
      });
      final p = await c.entries(query: 'wikivoyage', language: 'eng', count: 2);
      expect(p.entries.length, 2);
      expect(asked!.queryParameters['q'], 'wikivoyage');
    });
  });

  group('ZIM identity from the file name', () {
    test('Kiwix naming', () {
      final o = ZimOrigin.fromFileName('wikivoyage_en_europe_nopic_2026-09.zim')!;
      expect(o.name, 'wikivoyage_en_europe');
      expect(o.flavour, 'nopic');
      expect(o.release, '2026-09');
      final p = ZimOrigin.fromFileName('wikipedia_en_100_2026-08.zim')!;
      expect(p.name, 'wikipedia_en_100');
      expect(p.flavour, '');
      expect(ZimOrigin.fromFileName('my-own-file.zim'), isNull);
    });

    test('isOlderThan needs the same name and variant and a later release', () {
      final page = parseEntries(fixture('kiwix_entries_wikivoyage.xml'));
      final maxi = page.entries[0];
      const older = ZimOrigin(name: 'wikivoyage_en_europe', flavour: 'maxi', release: '2026-03');
      const same = ZimOrigin(name: 'wikivoyage_en_europe', flavour: 'maxi', release: '2026-09');
      const otherFlavour = ZimOrigin(name: 'wikivoyage_en_europe', flavour: 'nopic', release: '2026-03');
      const otherName = ZimOrigin(name: 'wikivoyage_en_asia', flavour: 'maxi', release: '2026-03');
      expect(older.isOlderThan(maxi), isTrue);
      expect(same.isOlderThan(maxi), isFalse);
      expect(otherFlavour.isOlderThan(maxi), isFalse);
      expect(otherName.isOlderThan(maxi), isFalse);
    });
  });

  test('the phone language picks the catalogue language, English when unknown', () {
    expect(catalogLanguageFor('fr'), 'fra');
    expect(catalogLanguageFor('EN'), 'eng');
    expect(catalogLanguageFor('xx'), 'eng');
  });
}
