import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a caption hit carries where it opens: link, moment, end, language and first words', () {
    final h = SearchHit.fromJson({
      'address': 'cap:tube.example.org/v1/captions-en.vtt@3',
      'title': 'Flood Safety Basics, at 01:04',
      'snippet': 'sandbag barriers',
      'source_id': 'tube.example.org/v1',
      'source_kind': 'video',
      'source_title': 'Flood Safety Basics',
      'page': null,
      'link': 'https://tube.example.org/w/v1',
      'time': 64,
      'time_end': 70.5,
      'lang': 'en',
      'quote': 'sandbag barriers hold',
    });
    expect((h.link, h.time, h.timeEnd, h.lang, h.quote), ('https://tube.example.org/w/v1', 64.0, 70.5, 'en', 'sandbag barriers hold'));
    expect(h.toFormatJson().keys, ['address', 'title', 'snippet']);
  });

  test('an EPUB hit has a link and first words but no moment; a page hit has none of them', () {
    final e = SearchHit.fromJson({'address': 'zimepub:u/b.epub@1', 'title': 'Guide, Fire', 'link': 'zim:u/b.epub!/c.xhtml#cache-b4', 'quote': 'Clear a'});
    expect((e.link, e.quote, e.time, e.lang), ('zim:u/b.epub!/c.xhtml#cache-b4', 'Clear a', null, null));
    final p = SearchHit.fromJson({'address': 'zim:u/A/Fire', 'title': 'Fire', 'page': null});
    expect((p.link, p.time, p.timeEnd, p.lang, p.quote), (null, null, null, null, null));
  });
}
