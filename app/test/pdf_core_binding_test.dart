import 'package:cache/chat/tool.dart';
import 'package:cache/pdf/index/pdf_chunk.dart';
import 'package:cache/pdf/index/pdf_index_core.dart';
import 'package:cache/pdf/pdf_address.dart';
import 'package:flutter_test/flutter_test.dart';

String _w(int n, String w) => List.filled(n, w).join(' ');

void main() {
  test('pieces: about 200 words with 40 of overlap, across pages, naming the pages they start and end on', () {
    final c = chunkPdfPages([
      PdfPageText(0, _w(150, 'a')),
      const PdfPageText(1, '   '),
      PdfPageText(2, _w(150, 'b'), label: 'iii'),
    ]);
    expect(c.emptyPages, [1]);
    expect(c.pieces, hasLength(2));
    final p0 = c.pieces[0];
    expect((p0['text'] as String).split(' '), hasLength(200));
    expect(p0['page'], '1');
    expect(p0['pdf_page'], 1);
    expect(p0['pdf_page_end'], 3);
    final p1 = c.pieces[1];
    // 300 words in all: the second piece starts 160 words in (40 shared) and takes the rest.
    expect((p1['text'] as String).split(' '), hasLength(140));
    expect(p1['page'], 'iii');
    expect(p1['pdf_page'], 3);
    expect(p1.containsKey('pdf_page_end'), isFalse);
    expect(p1['heading_path'], isEmpty);
    expect(chunkPdfPages([const PdfPageText(0, '')]).pieces, isEmpty);
  });

  test("a hit in a ZIM's PDF index opens its PDF; a citation opens the core's link (with its page)", () {
    const id = '17e9fb54-9554-d2cd-e15f-17cf750882d1';
    expect(pdfEntryOfIndexHit('zimpdf:$id/I/FM_21-76.pdf@12'), 'zim:$id/I/FM_21-76.pdf');
    expect(pdfEntryOfIndexHit('zim:$id/A/Water'), isNull);
    const cite = SourceResult(
      title: 'FM 21-76, p. 47',
      snippet: '',
      address: 'zimpdf:$id/I/FM_21-76.pdf@12',
      link: 'zim:$id/I/FM_21-76.pdf#page=47',
      pdfPage: 47,
      quote: 'Boil water',
    );
    expect(cite.openAddress, 'zim:$id/I/FM_21-76.pdf#page=47');
    expect(isPdfAddress(cite.openAddress), isTrue);
    expect(pdfPageOfAddress(cite.openAddress), 47);
    // A video moment still opens its link at its time, and a plain PDF entry at its page.
    const pdf = SourceResult(title: 't', snippet: '', address: 'zim:$id/I/a.pdf', pdfPage: 3);
    expect(pdf.openAddress, 'zim:$id/I/a.pdf#page=3');
  });

  test("the core's open answer: done and skipped (skipped as {path, reason})", () {
    final s = PdfStaging.fromJson({
      'session': 7,
      'done': ['a.pdf'],
      'skipped': [
        {'path': 'b.pdf', 'reason': 'locked'},
      ],
      'pieces': 3,
    });
    expect(s.session, 7);
    expect(s.done, {'a.pdf'});
    expect(s.skipped, {'b.pdf'});
    expect(s.pieces, 3);
  });
}
