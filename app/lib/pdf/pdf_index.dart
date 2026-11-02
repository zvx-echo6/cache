import 'dart:async';

import 'package:pdfrx/pdfrx.dart';

/// Search in PDFs on the device: the app reads each page's text (PDFium, through pdfrx) and hands the pages to the search core,
/// which indexes them as a library document. Page n of the document is `pages[n - 1]`; a page with no text (a scanned picture)
/// is an empty string, so page numbers stay right. The core's call (cs_library_add_pdf) is being added by the training work;
/// until it is in the core, [PdfIndexStub] stands in and says it is not there. Nothing calls this from the screens yet.
abstract class PdfLibraryIndex {
  /// False while the core has no PDF indexing.
  bool get available;

  /// Adds (or replaces) the document [docId]: its [title], the [link] a result opens (with `#page=N` added per page by the
  /// core), and its pages' text in order.
  Future<void> addPdf({required String docId, required String title, required String link, required List<String> pages});
}

/// The stand-in until the core has cs_library_add_pdf.
class PdfIndexStub implements PdfLibraryIndex {
  const PdfIndexStub();

  @override
  bool get available => false;

  @override
  Future<void> addPdf({required String docId, required String title, required String link, required List<String> pages}) =>
      Future.error(UnsupportedError('The search core cannot index PDFs yet (cs_library_add_pdf).'));
}

/// What [indexPdfFile] did.
class PdfIndexResult {
  const PdfIndexResult({required this.pages, required this.withText, required this.added});

  /// Pages in the file, and how many had text.
  final int pages;
  final int withText;

  /// False when the core has no PDF indexing (nothing was added) or the run was stopped.
  final bool added;

  /// True when no page had text: a scanned PDF, which search cannot read (text recognition is not in this version).
  bool get scanned => pages > 0 && withText == 0;
}

/// Reads the text of every page of a PDF, in order (an empty string for a page with none).
typedef PdfPagesReader = Stream<String> Function(String path, {String? password});

/// The text of each page of the PDF at [path], read with PDFium (one page at a time, in reading order).
Stream<String> readPdfPages(String path, {String? password}) async* {
  await pdfrxFlutterInitialize();
  final doc = await PdfDocument.openFile(path, passwordProvider: password == null ? null : createSimplePasswordProvider(password));
  try {
    for (final page in doc.pages) {
      final p = await page.ensureLoaded();
      final t = await p.loadStructuredText();
      yield t.fullText;
    }
  } finally {
    await doc.dispose();
  }
}

/// Reads the pages of the PDF at [path] and adds them to [index] as document [docId]. [cancelled] is asked between pages.
/// When [index] is not available the pages are still read (so the caller learns whether the file is scanned) but nothing is
/// added.
Future<PdfIndexResult> indexPdfFile(
  String path, {
  required String docId,
  required String title,
  required String link,
  PdfLibraryIndex index = const PdfIndexStub(),
  PdfPagesReader read = readPdfPages,
  bool Function()? cancelled,
  String? password,
}) async {
  final pages = <String>[];
  await for (final text in read(path, password: password)) {
    if (cancelled?.call() ?? false) return PdfIndexResult(pages: pages.length, withText: _withText(pages), added: false);
    pages.add(text);
  }
  final withText = _withText(pages);
  if (!index.available || withText == 0) return PdfIndexResult(pages: pages.length, withText: withText, added: false);
  await index.addPdf(docId: docId, title: title, link: link, pages: pages);
  return PdfIndexResult(pages: pages.length, withText: withText, added: true);
}

int _withText(List<String> pages) => pages.where((p) => p.trim().isNotEmpty).length;
