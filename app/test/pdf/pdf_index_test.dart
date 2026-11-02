import 'dart:io';

import 'package:cache/pdf/pdf_index.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pdfium_for_tests.dart';
import '../support/sample_pdf.dart';

class _Index implements PdfLibraryIndex {
  final List<({String docId, String title, String link, List<String> pages})> added = [];

  @override
  bool get available => true;

  @override
  Future<void> addPdf({required String docId, required String title, required String link, required List<String> pages}) async =>
      added.add((docId: docId, title: title, link: link, pages: pages));
}

void main() {
  late Directory dir;
  setUpAll(() async {
    await pdfiumForTests();
    dir = Directory.systemTemp.createTempSync('pdf-index');
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  test('every page is read in order (a scanned page is an empty string) and handed to the core', () async {
    final f = File('${dir.path}/handbook.pdf')..writeAsBytesSync(sampleHandbook(count: 5, scanned: {2}));
    final index = _Index();
    final r = await indexPdfFile(f.path, docId: 'doc-1', title: 'Water and Shelter Handbook', link: 'zim:x/handbook.pdf', index: index);
    expect(r.pages, 5);
    expect(r.withText, 4);
    expect(r.added, isTrue);
    expect(index.added.single.docId, 'doc-1');
    final pages = index.added.single.pages;
    expect(pages.length, 5);
    expect(pages[0], contains('Water and Shelter Handbook, page 1'));
    expect(pages[1], isEmpty);
    expect(pages[4], contains('page 5'));
  });

  test('until the core has PDF indexing the stand-in adds nothing, and a scanned PDF is not added', () async {
    final f = File('${dir.path}/two.pdf')..writeAsBytesSync(sampleHandbook(count: 2));
    expect(const PdfIndexStub().available, isFalse);
    final r = await indexPdfFile(f.path, docId: 'd', title: 't', link: 'l');
    expect((r.pages, r.added), (2, false));
    expect(() => const PdfIndexStub().addPdf(docId: 'd', title: 't', link: 'l', pages: const []), throwsUnsupportedError);
    final s = File('${dir.path}/scan.pdf')..writeAsBytesSync(sampleHandbook(count: 3, scanned: {1, 2, 3}));
    final index = _Index();
    final rs = await indexPdfFile(s.path, docId: 'd', title: 't', link: 'l', index: index);
    expect(rs.scanned, isTrue);
    expect(index.added, isEmpty);
  });

  test('a run can be stopped between pages', () async {
    var n = 0;
    final r = await indexPdfFile('x', docId: 'd', title: 't', link: 'l', index: _Index(), read: (p, {password}) => Stream.fromIterable(['a', 'b', 'c']), cancelled: () => ++n > 2);
    expect(r.added, isFalse);
    expect(r.pages, 2);
  });
}
