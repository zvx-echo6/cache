// Home search's Library part: ZIM pages, PDF passages, words said in videos (caption hits) and EPUB passages, each with
// its row text and where tapping it opens.
import 'dart:convert';
import 'dart:io';

import 'package:cache/search/app_search_providers.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../packages/cache_search/test/engine_test.dart' show FakeNative;
import 'browse/fakes.dart';

const _uuid = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';

// What the core returns for words said in a saved video, a passage of an EPUB book and a passage of a ZIM's PDF.
const _coreHits = <Map<String, dynamic>>[
  {
    'address': 'cap:tube.example.org/0a1b2c3d/captions-en.vtt@12',
    'title': 'Knots every camper should know, at 01:04',
    'snippet': 'It makes a loop that will not slip.',
    'source_id': 'tube.example.org/0a1b2c3d',
    'source_kind': 'video',
    'source_title': 'Knots every camper should know',
    'page': null,
    'link': 'https://tube.example.org/w/0a1b2c3d',
    'time': 64,
    'time_end': 70.5,
    'lang': 'en',
    'quote': 'It makes a loop',
  },
  {
    'address': 'zimepub:$_uuid/Books/guide.epub@7',
    'title': 'Field Guide, Wildfire',
    'snippet': 'Clear a firebreak.',
    'source_id': _uuid,
    'source_kind': 'zim',
    'source_title': 'Survival Library',
    'page': null,
    'link': 'zim:$_uuid/Books/guide.epub!/OEBPS/ch2.xhtml#cache-b12',
    'quote': 'Clear a firebreak around',
  },
  {
    'address': 'zimpdf:$_uuid/Manuals/water.pdf@3',
    'title': 'Water and Shelter Handbook, p. 47',
    'snippet': 'Bring it to a rolling boil.',
    'source_id': _uuid,
    'source_kind': 'zim',
    'source_title': 'Survival Library',
    'page': 47,
    'pdf_page': 49,
    'link': 'zim:$_uuid/Manuals/water.pdf#page=49',
    'quote': 'Bring it to a rolling boil',
  },
];

// Runs inside the core's worker isolate, so it builds its own fake.
CsNative _coreNative() => FakeNative()..replies['search'] = jsonEncode({'results': _coreHits, 'total_estimate': _coreHits.length});

/// Sources whose searches go through a real core: the worker isolate and its dispatcher, over a fake native layer.
class _ThroughCore extends FakeSources {
  _ThroughCore(super.dir, this.core);

  final SearchCore core;

  @override
  bool get coreReady => true;

  @override
  Future<SearchResponse> searchIn(String query, {List<String>? zimIds, int k = 20, int offset = 0}) =>
      core.search(query, k: k, offset: offset, sources: zimIds);
}

/// Sources whose core answers every search with [hits].
class _Searched extends FakeSources {
  _Searched(super.dir, this.hits);

  final List<Map<String, dynamic>> hits;

  @override
  bool get coreReady => true;

  @override
  Future<SearchResponse> searchIn(String query, {List<String>? zimIds, int k = 20, int offset = 0}) async =>
      SearchResponse.fromJson({'results': hits, 'total_estimate': hits.length});
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('library-search'));
  tearDown(() => dir.deleteSync(recursive: true));

  final page = {
    'address': 'zim:$_uuid/A/Water_purification',
    'title': 'Water purification',
    'snippet': 'Boil it.',
    'source_id': _uuid,
    'source_kind': 'zim',
    'source_title': 'Wikipedia Medicine',
    'page': null,
  };
  final pdf = {
    'address': 'zimpdf:$_uuid/Manuals/water.pdf@3',
    'title': 'Water and Shelter Handbook, p. 47',
    'snippet': 'Bring it to a rolling boil.',
    'source_id': _uuid,
    'source_kind': 'zim',
    'source_title': 'Survival Library',
    'page': 47,
    'pdf_page': 49,
  };
  final savedCaption = {
    'address': 'cap:tube.example.org/0a1b2c3d/captions-en.vtt@12',
    'title': 'Knots every camper should know, at 01:04',
    'snippet': 'It makes a loop that will not slip.',
    'source_id': 'tube.example.org/0a1b2c3d',
    'source_kind': 'video',
    'source_title': 'Knots every camper should know',
    'page': null,
    'link': 'https://tube.example.org/w/0a1b2c3d',
    'time': 64,
    'time_end': 70.5,
    'lang': 'en',
    'quote': 'It makes a loop',
  };
  final zimCaption = {
    'address': 'zimcap:$_uuid/Media/knots_en.srt@4',
    'title': 'Knots, at 00:12',
    'snippet': 'A loop that will not slip.',
    'source_id': _uuid,
    'source_kind': 'zim',
    'source_title': 'Field Skills Videos',
    'page': null,
    'link': 'zim:$_uuid/Media/knots.mp4',
    'time': 12,
    'lang': 'en',
    'quote': 'A loop that',
  };
  final epub = {
    'address': 'zimepub:$_uuid/Books/guide.epub@7',
    'title': 'Field Guide, Wildfire',
    'snippet': 'Clear a firebreak.',
    'source_id': _uuid,
    'source_kind': 'zim',
    'source_title': 'Survival Library',
    'page': null,
    'link': 'zim:$_uuid/Books/guide.epub!/OEBPS/ch2.xhtml#cache-b12',
    'quote': 'Clear a firebreak around',
  };

  test('every kind of hit is a row with plain text: the page once, the collection as the second line', () async {
    final p = LibrarySearchProvider(
      sources: _Searched(dir, [page, pdf, savedCaption, zimCaption, epub]),
      openZim: (_) {},
      openAddress: (_) {},
      openVideo: (_, _, _) {},
      openPassage: (_, _) {},
    );
    final rows = await p.search('water');
    expect([for (final r in rows) (r.title, r.detail)], [
      ('Water purification', 'Wikipedia Medicine'),
      ('Water and Shelter Handbook, p. 47', 'Survival Library'),
      // a saved video's name begins its title: not said twice
      ('Knots every camper should know, at 01:04', ''),
      ('Knots, at 00:12', 'Field Skills Videos'),
      ('Field Guide, Wildfire', 'Survival Library'),
    ]);
    expect(rows.every((r) => r.module == 'Library'), isTrue);
  });

  test('a PDF passage with its link and words opens as a citation: the page, with the passage marked', () async {
    final marked = <(String, String)>[];
    final p = LibrarySearchProvider(
      sources: _Searched(dir, [
        {...pdf, 'link': 'zim:$_uuid/Manuals/water.pdf#page=49', 'quote': 'Bring it to a rolling boil'},
      ]),
      openZim: (_) {},
      openAddress: (_) => fail('a PDF passage with its words opens marked'),
      openPassage: (a, q) => marked.add((a, q)),
    );
    (await p.search('boil')).single.open();
    expect(marked, [('zim:$_uuid/Manuals/water.pdf#page=49', 'Bring it to a rolling boil')]);
  });

  test('built library passages remain visible and open unchanged', () async {
    final opened = <String>[];
    final libraryHit = <String, dynamic>{
      'address': 'lib:field-library/6ba7b810-9dad-11d1-80b4-00c04fd430c8',
      'title': 'Field Manual, p. 47',
      'snippet': 'Boil it.',
      'source_id': 'field-library',
      'source_kind': 'library',
      'source_title': 'Field library',
      'page': 47,
    };
    final unsupported = {...libraryHit, 'address': 'unsupported://abc'};
    final p = LibrarySearchProvider(sources: _Searched(dir, [libraryHit, unsupported]), openZim: (_) {}, openAddress: opened.add);
    final rows = await p.search('water');
    expect(rows.length, 1);
    expect(rows.single.title, 'Field Manual, p. 47');
    expect(rows.single.detail, 'Field library');
    rows.single.open();
    expect(opened, [libraryHit['address']]);
  });

  test('a page opens in the reader, a PDF passage at its real PDF page', () async {
    final opened = <String>[];
    final p = LibrarySearchProvider(sources: _Searched(dir, [page, pdf]), openZim: (_) {}, openAddress: opened.add);
    for (final r in await p.search('water')) {
      r.open();
    }
    expect(opened, ['zim:$_uuid/A/Water_purification', 'zim:$_uuid/Manuals/water.pdf#page=49']);
  });

  test('a caption hit opens the video at its moment, in its language (a saved video and a ZIM video)', () async {
    final played = <(String, double, String?)>[];
    final p = LibrarySearchProvider(
      sources: _Searched(dir, [savedCaption, zimCaption]),
      openZim: (_) {},
      openAddress: (_) => fail('a caption hit is not a reader page'),
      openVideo: (link, time, lang) => played.add((link, time, lang)),
      openPassage: (_, _) => fail('a caption hit is not a passage'),
    );
    for (final r in await p.search('loop')) {
      r.open();
    }
    expect(played, [('https://tube.example.org/w/0a1b2c3d', 64.0, 'en'), ('zim:$_uuid/Media/knots.mp4', 12.0, 'en')]);
  });

  test('an EPUB hit opens its chapter at the passage, with the passage marked', () async {
    final passages = <(String, String)>[];
    final p = LibrarySearchProvider(
      sources: _Searched(dir, [epub]),
      openZim: (_) {},
      openAddress: (_) => fail('an EPUB hit opens as a passage'),
      openVideo: (_, _, _) => fail('an EPUB hit is not a video'),
      openPassage: (a, q) => passages.add((a, q)),
    );
    final rows = await p.search('firebreak');
    rows.single.open();
    expect(passages, [('zim:$_uuid/Books/guide.epub!/OEBPS/ch2.xhtml#cache-b12', 'Clear a firebreak around')]);
  });

  test('caption, EPUB and ZIM PDF hits that came through the core worker are all listed and open where they should', () async {
    final core = await SearchCore.open(const [], native: _coreNative);
    try {
      final played = <(String, double, String?)>[];
      final marked = <(String, String)>[];
      final p = LibrarySearchProvider(
        sources: _ThroughCore(dir, core),
        openZim: (_) {},
        openAddress: (_) => fail('each of these opens as a video moment or a marked passage'),
        openVideo: (link, time, lang) => played.add((link, time, lang)),
        openPassage: (a, q) => marked.add((a, q)),
      );
      final rows = await p.search('loop');
      expect([for (final r in rows) r.title], ['Knots every camper should know, at 01:04', 'Field Guide, Wildfire', 'Water and Shelter Handbook, p. 47']);
      for (final r in rows) {
        r.open();
      }
      expect(played, [('https://tube.example.org/w/0a1b2c3d', 64.0, 'en')]);
      expect(marked, [
        ('zim:$_uuid/Books/guide.epub!/OEBPS/ch2.xhtml#cache-b12', 'Clear a firebreak around'),
        ('zim:$_uuid/Manuals/water.pdf#page=49', 'Bring it to a rolling boil'),
      ]);
    } finally {
      await core.close();
    }
  });

  test('caption and EPUB hits are left out where they cannot be opened (no opener, or an older core with no link)', () async {
    final noLink = {...epub}..remove('link');
    final p = LibrarySearchProvider(sources: _Searched(dir, [page, savedCaption, noLink]), openZim: (_) {}, openAddress: (_) {});
    expect([for (final r in await p.search('x')) r.title], ['Water purification']);
    final q = LibrarySearchProvider(sources: _Searched(dir, [noLink]), openZim: (_) {}, openAddress: (_) {}, openPassage: (_, _) {});
    expect(await q.search('x'), isEmpty);
  });
}
