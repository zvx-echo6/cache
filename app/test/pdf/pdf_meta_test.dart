import 'package:cache/pdf/index/pdf_pages.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pdfium_for_tests.dart';
import '../support/sample_pdf.dart';

void main() {
  setUpAll(pdfiumForTests);

  test("PDFium's own calls: the document's metadata Title and each page's printed label", () async {
    final bytes = samplePdf(
      [for (var n = 1; n <= 4; n++) sampleTextPage(n)],
      title: 'Are You Ready? An In-depth Guide',
      pageLabels: '0 << /S /r >> 2 << /S /D >>',
    );
    final r = await readPdfPagesFromBytes(bytes, 'ready.pdf');
    expect(r.pages, hasLength(4));
    expect(r.title, 'Are You Ready? An In-depth Guide');
    expect(r.labels, ['i', 'ii', '1', '2']);
    expect(cleanPdfTitle(r.title), 'Are You Ready? An In-depth Guide');
  });

  test('a PDF over 1 MB (pdfrx reads it through its worker isolate\'s callback): the Title and labels read, no crash', () async {
    // Build 32 aborted here: PDFium's calls for the Title and labels ran in the app's isolate, and on a PDF over 1 MB PDFium reads
    // the file through a callback that belongs to pdfrx's worker isolate ("Cannot invoke native callback from a different
    // isolate"). The calls now run in that worker isolate.
    final line = 'Boil water for one minute; at altitude boil it for three minutes, then let it cool in a covered pot. ' * 2;
    final bytes = samplePdf(
      [for (var n = 1; n <= 40; n++) SamplePage(heading: 'Water and Shelter Handbook, page $n', lines: [for (var i = 0; i < 160; i++) line])],
      title: 'Water Treatment Manual',
      pageLabels: '0 << /S /r >> 2 << /S /D >>',
    );
    expect(bytes.length, greaterThan(1024 * 1024), reason: 'over pdfrx\'s 1 MB in-memory limit');
    final r = await readPdfPagesFromBytes(bytes, 'big.pdf');
    expect(r.pages, hasLength(40));
    expect(r.title, 'Water Treatment Manual');
    expect(r.labels!.take(4), ['i', 'ii', '1', '2']);
    expect(r.pages.first, contains('Boil water'));
  });

  test('a PDF with no page labels gives none; a file-name Title is not a title', () async {
    final r = await readPdfPagesFromBytes(samplePdf([sampleTextPage(1), sampleTextPage(2)], title: 'Microsoft Word - plan.doc'), 'plan.pdf');
    expect(r.labels, isNull);
    expect(r.title, 'Microsoft Word - plan.doc');
    expect(cleanPdfTitle(r.title), '');
  });
}
