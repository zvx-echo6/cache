import 'package:cache/pdf/pdf_address.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0';

void main() {
  test('a page of a PDF entry is its zim: address with #page=N', () {
    expect(pdfPageOfAddress('zim:$_id/I/FM_21-76.pdf#page=47'), 47);
    expect(pdfPageOfAddress('zim:$_id/I/FM_21-76.pdf'), isNull);
    expect(pdfPageOfAddress('zim:$_id/I/FM_21-76.pdf#page=0'), isNull);
    expect(pdfPageOfAddress('zim:$_id/I/FM_21-76.pdf#zoom=2&page=5'), 5);
    expect(pdfPageOfAddress('zim:$_id/A/Water#section'), isNull);
    // A # in the path is escaped, so the first # starts the fragment.
    expect(pdfPageOfAddress('zim:$_id/I/Notes%23two.pdf#page=3'), 3);
    expect(withoutFragment('zim:$_id/I/Notes%23two.pdf#page=3'), 'zim:$_id/I/Notes%23two.pdf');
    expect(withPdfPage('zim:$_id/I/a.pdf#page=3', 9), 'zim:$_id/I/a.pdf#page=9');
  });

  test('a PDF address: a .pdf path, or any address with a page', () {
    expect(isPdfAddress('zim:$_id/I/FM_21-76.pdf'), isTrue);
    expect(isPdfAddress('zim:$_id/I/FM_21-76.PDF?x=1'), isTrue);
    expect(isPdfAddress('zim:$_id/files/12345#page=2'), isTrue);
    expect(isPdfAddress('zim:$_id/A/Water_purification'), isFalse);
    expect(isPdfAddress('zim:$_id/A/pdf_files'), isFalse);
  });

  test('a PDF is known by its first bytes', () {
    expect(looksLikePdf('%PDF-1.7\n'.codeUnits), isTrue);
    expect(looksLikePdf([...List.filled(100, 32), ...'%PDF-1.4'.codeUnits]), isTrue);
    expect(looksLikePdf('PK\u0003\u0004'.codeUnits), isFalse);
    expect(looksLikePdf(const []), isFalse);
  });

  test('the title is the name without .pdf', () {
    expect(pdfTitleOf('I/FM_21-76_Survival.pdf'), 'FM 21-76 Survival');
    expect(pdfTitleOf('Water%20and%20Shelter.pdf#page=2'), 'Water and Shelter');
    expect(pdfTitleOf(r'C:\docs\Map.PDF'), 'Map');
    expect(pdfTitleOf('.pdf'), 'PDF');
  });
}
