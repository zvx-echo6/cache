import 'dart:async';
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

/// What reading a PDF's pages gave: each page's text in order (an empty string for a page with none, so page numbers stay
/// right), or why it could not be read.
class PdfPagesOutcome {
  const PdfPagesOutcome.read(this.pages) : locked = false, damaged = false;
  const PdfPagesOutcome.locked() : pages = const [], locked = true, damaged = false;
  const PdfPagesOutcome.damaged() : pages = const [], locked = false, damaged = true;

  final List<String> pages;
  final bool locked;
  final bool damaged;

  /// No page has any text (a scanned PDF: text recognition is not in this version).
  bool get noText => !locked && !damaged && pages.every((p) => p.trim().isEmpty);
}

/// Reads a PDF's pages from its bytes; [name] identifies it to the engine.
typedef PdfBytesReader = Future<PdfPagesOutcome> Function(Uint8List bytes, String name);

/// Reads every page's text with PDFium (pdfrx), one page at a time. A PDF that needs a password is locked (the indexer has no
/// password to give); one PDFium cannot open is damaged.
Future<PdfPagesOutcome> readPdfPagesFromBytes(Uint8List bytes, String name) async {
  await pdfrxFlutterInitialize();
  final PdfDocument doc;
  try {
    doc = await PdfDocument.openData(bytes, sourceName: 'pdfindex:$name', firstAttemptByEmptyPassword: true);
  } on PdfPasswordException {
    return const PdfPagesOutcome.locked();
  } catch (_) {
    return const PdfPagesOutcome.damaged();
  }
  try {
    final pages = <String>[];
    for (final page in doc.pages) {
      try {
        final p = await page.ensureLoaded();
        final t = await p.loadStructuredText();
        pages.add(t.fullText);
      } catch (_) {
        // One page that does not read keeps its place, empty.
        pages.add('');
      }
    }
    return PdfPagesOutcome.read(pages);
  } catch (_) {
    return const PdfPagesOutcome.damaged();
  } finally {
    await doc.dispose();
  }
}
