// ignore_for_file: avoid_print
// Temporary: checks PDFium loads in CI. Removed in the next commit.
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import 'support/pdfium_for_tests.dart';
import 'support/sample_pdf.dart';

void main() {
  test('probe', () async {
    await pdfiumForTests();
    print('MODULE ${Pdfrx.pdfiumModulePath}');
    final doc = await PdfDocument.openData(sampleHandbook(count: 4, scanned: {2}), sourceName: 'probe.pdf');
    print('PAGES ${doc.pages.length}');
    for (final p in doc.pages) {
      final t = await p.loadStructuredText();
      print('PAGE ${p.pageNumber} ${p.width}x${p.height} chars=${t.fullText.length} :: ${t.fullText.substring(0, t.fullText.length.clamp(0, 400)).replaceAll('\n', '|')}');
    }
    await doc.dispose();
  });
}
