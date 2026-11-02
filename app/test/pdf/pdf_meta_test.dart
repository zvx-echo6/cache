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

  test('a PDF with no page labels gives none; a file-name Title is not a title', () async {
    final r = await readPdfPagesFromBytes(samplePdf([sampleTextPage(1), sampleTextPage(2)], title: 'Microsoft Word - plan.doc'), 'plan.pdf');
    expect(r.labels, isNull);
    expect(r.title, 'Microsoft Word - plan.doc');
    expect(cleanPdfTitle(r.title), '');
  });
}
