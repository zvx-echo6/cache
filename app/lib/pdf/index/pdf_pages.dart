import 'dart:async';
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import 'pdf_meta.dart';

export 'pdf_meta.dart' show readPdfMeta;

/// What reading a PDF's pages gave: each page's text in order (an empty string for a page with none, so page numbers stay
/// right), or why it could not be read.
class PdfPagesOutcome {
  const PdfPagesOutcome.read(this.pages, {this.title, this.labels}) : locked = false, damaged = false;
  const PdfPagesOutcome.locked() : pages = const [], locked = true, damaged = false, title = null, labels = null;
  const PdfPagesOutcome.damaged() : pages = const [], locked = false, damaged = true, title = null, labels = null;

  final List<String> pages;

  /// The document's own Title (its metadata, PDFium's FPDF_GetMetaText), or null when it has none.
  final String? title;

  /// Each page's printed label ("iv", "A-3"; PDFium's FPDF_GetPageLabel), null for a page with none; null when not read.
  final List<String?>? labels;
  final bool locked;
  final bool damaged;

  /// No page has any text (a scanned PDF: text recognition is not in this version).
  bool get noText => !locked && !damaged && pages.every((p) => p.trim().isEmpty);
}

/// A PDF's metadata Title as cs_pdfindex_add's "title": trimmed, or "" when it is empty or is plainly a file name rather than a
/// title (an office program's "Microsoft Word - report.doc", or a name ending in a document extension); the core then makes a
/// readable name from the entry's file name.
String cleanPdfTitle(String? title) {
  var t = (title ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return '';
  if (RegExp(r'^microsoft (word|powerpoint|excel)\s*-', caseSensitive: false).hasMatch(t)) return '';
  if (RegExp(r'\.(docx?|pptx?|xlsx?|pdf|indd|rtf|odt|txt|qxd|pub|wpd)$', caseSensitive: false).hasMatch(t)) return '';
  if (!RegExp(r'[A-Za-z]').hasMatch(t)) return '';
  return t;
}

/// Waits until the work may go on (the index scheduler's throttle: rests, a warm phone, the person using the app).
typedef PdfPermit = Future<void> Function();

/// Reads a PDF's pages from its bytes; [name] identifies it to the engine; [betweenPages] is awaited before each page after the
/// first, so a long PDF is throttled like the rest.
typedef PdfBytesReader = Future<PdfPagesOutcome> Function(Uint8List bytes, String name, {PdfPermit? betweenPages});

/// Reads every page's text with PDFium (pdfrx), one page at a time. A PDF that needs a password is locked (the indexer has no
/// password to give); one PDFium cannot open is damaged.
Future<PdfPagesOutcome> readPdfPagesFromBytes(Uint8List bytes, String name, {PdfPermit? betweenPages}) async {
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
    // The Title and the page labels, which pdfrx does not wrap: PDFium's own calls on the document, while pdfrx's worker is held
    // (PDFium is not thread-safe). A PDF that says neither gives null.
    ({String? title, List<String?>? labels}) meta = (title: null, labels: null);
    try {
      meta = await doc.useNativeDocumentHandle((handle) => readPdfMeta(handle, doc.pages.length));
    } catch (_) {}
    final pages = <String>[];
    for (final page in doc.pages) {
      if (pages.isNotEmpty) await betweenPages?.call();
      try {
        final p = await page.ensureLoaded();
        final t = await p.loadStructuredText();
        pages.add(t.fullText);
      } catch (_) {
        // One page that does not read keeps its place, empty.
        pages.add('');
      }
    }
    return PdfPagesOutcome.read(pages, title: meta.title, labels: meta.labels);
  } catch (_) {
    return const PdfPagesOutcome.damaged();
  } finally {
    await doc.dispose();
  }
}
