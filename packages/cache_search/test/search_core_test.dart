import 'dart:convert';

import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'engine_test.dart' show FakeNative;

// What cs_search returns for words said in a saved video, a passage of an EPUB in a ZIM and a passage of a ZIM's PDF.
const _caption = <String, dynamic>{
  'address': 'cap:tube.example.org/v1/captions-en.vtt@3',
  'title': 'Flood Safety Basics, at 01:04',
  'snippet': 'sandbag barriers',
  'source_id': 'tube.example.org/v1',
  'source_kind': 'video',
  'source_title': 'Flood Safety Basics',
  'page': null,
  'link': 'https://tube.example.org/w/v1',
  'time': 64.0,
  'time_end': 70.5,
  'lang': 'en',
  'quote': 'sandbag barriers hold',
};
const _epub = <String, dynamic>{
  'address': 'zimepub:u/Books/guide.epub@7',
  'title': 'Field Guide, Wildfire',
  'snippet': 'Clear a firebreak.',
  'source_id': 'u',
  'source_kind': 'zim',
  'source_title': 'Survival Library',
  'page': null,
  'link': 'zim:u/Books/guide.epub!/OEBPS/ch2.xhtml#cache-b12',
  'quote': 'Clear a firebreak around',
};
const _pdf = <String, dynamic>{
  'address': 'zimpdf:u/Manuals/water.pdf@3',
  'title': 'Water and Shelter Handbook, p. 47',
  'snippet': 'Bring it to a rolling boil.',
  'source_id': 'u',
  'source_kind': 'zim',
  'source_title': 'Survival Library',
  'page': 47,
  'pdf_page': 49,
  'link': 'zim:u/Manuals/water.pdf#page=49',
  'quote': 'Bring it to a rolling boil',
};

CsNative _kinds() => FakeNative()
  ..replies['search'] = jsonEncode({
    'results': [_caption, _epub, _pdf],
    'total_estimate': 3,
    'vector_sources': ['field-library'],
    'keyword_only_sources': ['u'],
  });

// Runs inside the worker isolate, so it builds its own fake.
CsNative _fake() => FakeNative()
  ..replies['search'] = '{"results":[{"address":"zim:u/A","title":"A","snippet":"s","source_id":"u","source_kind":"zim","source_title":"U"}],"total_estimate":1}'
  ..replies['format'] = '{"tool_message":"[1] A — s","ids":[{"n":1,"address":"zim:u/A","title":"A"}]}'
  ..replies['ids'] = '{"ids":[{"n":1,"address":"zim:u/A","title":"A"}]}'
  ..replies['jobProgress'] = '{"state":"done","done":5,"total":5,"error":null}'
  ..replies['status'] =
      '{"sources":[{"id":"u","kind":"zim","path":"/z/a.zim","title":"U","indexed":true,"building":false,"stale":false,"opening":false,"updating":false,"docs":7,"keyword_source":"own","embedding_model":"bge-m3-Q8_0.gguf","source_id":"u","index":{"kind":"zim","location":"/i/a.idx","snapshot":null,"format":3},"error":null}]}';

// The page cs_read gives for each address: a printed label that is text, a number, or none.
const _pages = <String, Object?>{'lib:field/roman': 'iv', 'lib:field/section': 'A-3', 'lib:field/number': 47, 'lib:field/none': null};

/// Answers cs_read with a passage on the page [_pages] has for the address.
class _PagesNative extends FakeNative {
  @override
  String? read(int handle, String address, int maxChars) =>
      jsonEncode({'address': address, 'title': 'Field Manual', 'text': 'Boil it.', 'truncated': false, 'author': null, 'page': _pages[address], 'source_type': 'pdf'});
}

CsNative _pagesNative() => _PagesNative();

CsNative _failing() => FakeNative()
  ..openResult = 0
  ..error = '{"code":"io","message":"cannot open"}';

void main() {
  test('the worker isolate answers calls with typed results', () async {
    final core = await SearchCore.open(const [SourceConfig.zim(path: '/z/a.zim', indexDir: '/i/a.idx')], native: _fake);
    final r = await core.search('a');
    expect(r.results.single.title, 'A');
    final conv = await core.newConversation();
    final f = await conv.format([r.results.single.toFormatJson()]);
    expect(f.toolMessage, '[1] A — s');
    expect((await conv.ids()).single.n, 1);
    await conv.free();
    final job = await core.startJob('index_zim', {'zim_path': '/z/a.zim', 'index_dir': '/i/a.idx'});
    expect((await job.progress()).state, JobState.done);
    await job.free();
    final status = (await core.status()).single;
    expect(status.docs, 7);
    expect(status.keywordSource, 'own', reason: 'the worker passes where keyword search comes from on to the app');
    expect(status.embeddingModel, 'bge-m3-Q8_0.gguf', reason: 'and the embedding model a library names');
    expect(status.sourceId, 'u', reason: 'and the id sync filters the indexes by');
    expect(status.index?.kind, 'zim');
    expect(status.index?.format, 3);
    await core.close();
    await expectLater(core.status(), throwsA(isA<CacheSearchException>()));
  });

  test('a caption, an EPUB and a ZIM PDF hit reach the app through the worker with every field', () async {
    final core = await SearchCore.open(const [], native: _kinds);
    final r = await core.search('boil');
    expect(r.results.length, 3);
    final (caption, epub, pdf) = (r.results[0], r.results[1], r.results[2]);
    expect((caption.link, caption.time, caption.timeEnd, caption.lang, caption.quote), ('https://tube.example.org/w/v1', 64.0, 70.5, 'en', 'sandbag barriers hold'));
    expect((epub.link, epub.quote), ('zim:u/Books/guide.epub!/OEBPS/ch2.xhtml#cache-b12', 'Clear a firebreak around'));
    expect((pdf.page, pdf.pdfPage, pdf.link, pdf.quote), (47, 49, 'zim:u/Manuals/water.pdf#page=49', 'Bring it to a rolling boil'));
    // the whole hit, field for field, as the core sent it
    expect([for (final h in r.results) h.toJson()], [_caption, _epub, _pdf]);
    expect(r.totalEstimate, 3);
    expect(r.vectorSources, ['field-library']);
    expect(r.keywordOnlySources, ['u']);
    await core.close();
  });

  test('a passage is read whatever its page is: a label that is text, a number, or none', () async {
    final core = await SearchCore.open(const [], native: _pagesNative);
    final pages = <(int?, String?)>[];
    for (final address in _pages.keys) {
      final r = await core.read(address);
      expect((r.address, r.title, r.text, r.sourceType), (address, 'Field Manual', 'Boil it.', 'pdf'));
      pages.add((r.page, r.pageLabel));
    }
    expect(pages, [(null, 'iv'), (null, 'A-3'), (47, '47'), (null, null)]);
    await core.close();
  });

  test('a read result written out and read again keeps its page: the number, or the label', () {
    Map<String, dynamic> read(Object? page) => {'address': 'lib:field/p', 'title': 'Field Manual', 'text': 'Boil it.', 'truncated': true, 'author': 'A. Writer', 'page': page, 'source_type': 'pdf'};
    for (final page in ['iv', 'A-3', 47, null]) {
      expect(ReadResult.fromJson(read(page)).toJson(), read(page));
    }
    // a whole number sent as 47.0 is page 47; a blank label is no page
    expect((ReadResult.fromJson(read(47.0)).page, ReadResult.fromJson(read(47.0)).pageLabel), (47, '47'));
    expect((ReadResult.fromJson(read(' ')).page, ReadResult.fromJson(read(' ')).pageLabel), (null, null));
  });

  test('a failing open raises the core error', () async {
    await expectLater(
      SearchCore.open(const [], native: _failing),
      throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'io')),
    );
  });
}
