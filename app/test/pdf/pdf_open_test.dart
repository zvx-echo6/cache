import 'dart:io';

import 'package:cache/browse/reader_screen.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:cache/pdf/pdf_reader_screen.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart' show ConversationId;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse/fakes.dart';

const _id = '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0';

void main() {
  testWidgets('a PDF entry of a ZIM opens in the PDF reader, at its page, with the quote', (tester) async {
    final dir = Directory.systemTemp.createTempSync('zim-pdf');
    addTearDown(() => dir.deleteSync(recursive: true));
    final sources = FakeSources(dir);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.light),
      home: ZimReaderScreen(sources: sources, zim: ZimFile(path: '${dir.path}/army.zim', size: 1), address: 'zim:$_id/I/FM_21-76.pdf#page=47', quote: 'Water'),
    ));
    final r = tester.widget<PdfReaderScreen>(find.byType(PdfReaderScreen));
    expect(r.initialPage, 47);
    expect(r.quote, 'Water');
    expect(r.source.title, 'FM 21-76');
  });

  test('a citation carries its PDF page and passage when the core gives them, and works without them', () {
    final with_ = ConversationId.fromJson({'n': 3, 'address': 'zim:$_id/I/a.pdf', 'title': 'a', 'pdf_page': 12, 'quote': 'Boil water'});
    expect((with_.pdfPage, with_.quote), (12, 'Boil water'));
    expect(with_.toJson()['pdf_page'], 12);
    final without = ConversationId.fromJson({'n': 4, 'address': 'zim:$_id/A/Water', 'title': 'w'});
    expect((without.pdfPage, without.quote), (null, null));
    expect(without.toJson().containsKey('pdf_page'), isFalse);
    expect(without.toJson().containsKey('quote'), isFalse);

    const r = SourceResult(title: 'a', snippet: '', address: 'zim:$_id/I/a.pdf', pdfPage: 12, quote: 'Boil water');
    expect(r.openAddress, 'zim:$_id/I/a.pdf#page=12');
    const own = SourceResult(title: 'a', snippet: '', address: 'zim:$_id/I/a.pdf#page=5', pdfPage: 12);
    expect(own.openAddress, 'zim:$_id/I/a.pdf#page=5');
    const plain = SourceResult(title: 'w', snippet: '', address: 'zim:$_id/A/Water');
    expect(plain.openAddress, 'zim:$_id/A/Water');

    final stored = StoredCitation.fromJson(const StoredCitation(n: 1, title: 'a', snippet: '', address: 'zim:x/a.pdf', pdfPage: 2, quote: 'q').toJson());
    expect((stored.pdfPage, stored.quote), (2, 'q'));
    expect(const StoredCitation(n: 1, title: 'a', snippet: '', address: 'zim:x/a').toJson().keys, ['n', 'title', 'snippet', 'address']);
  });
}
