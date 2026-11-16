import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import '../pdfium_init.dart';
import 'pdf_meta.dart';
import '../../platform/app_log.dart';

export 'pdf_meta.dart' show readPdfMeta, openPdfForIndexing;
export 'pdf_title.dart' show cleanPdfTitle;

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

/// Waits until the work may go on (the index scheduler's throttle: rests, a warm phone, the person using the app).
typedef PdfPermit = Future<void> Function();

/// Reads a PDF's pages from its bytes; [name] identifies it to the engine; [betweenPages] is awaited before each page after the
/// first, so a long PDF is throttled like the rest.
/// [onStep] hears each step as it starts ("Opening", "Reading title", "Reading page 12 of 300"): the queue shows it, and a
/// step that never ends is named by it.
typedef PdfBytesReader = Future<PdfPagesOutcome> Function(Uint8List bytes, String name, {PdfPermit? betweenPages, void Function(String step)? onStep});

/// The longest one step of reading a PDF may take (opening it, or one page): past it the PDF is skipped as one that could not be
/// read, and the queue moves on.
const Duration kPdfStepTimeout = Duration(minutes: 2);

/// How much longer than [kPdfStepTimeout] a step may take now: the throttle's slowing (a third of the speed: three times as
/// long). Set by the app; 1 by default.
double Function() pdfStepScale = () => 1;

Duration get _stepTimeout => Duration(microseconds: (kPdfStepTimeout.inMicroseconds * pdfStepScale().clamp(1.0, 20.0)).round());

/// Reads every page's text with PDFium (pdfrx), one page at a time. A PDF that needs a password is locked (the indexer has no
/// password to give); one PDFium cannot open is damaged.
Future<PdfPagesOutcome> readPdfPagesFromBytes(Uint8List bytes, String name, {PdfPermit? betweenPages, void Function(String step)? onStep}) async {
  onStep?.call('Preparing PDF reader');
  await initPdfium();
  final PdfDocument doc;
  Future<void> Function() removeFile = () async {};
  try {
    final opened = await openPdfForIndexing(bytes, name, onStep: onStep).timeout(_stepTimeout);
    doc = opened.$1;
    removeFile = opened.$2;
  } on PdfPasswordException {
    return const PdfPagesOutcome.locked();
  } on TimeoutException {
    logError('A PDF took over ${_stepTimeout.inMinutes} min to open; skipped as unreadable', detail: name);
    return const PdfPagesOutcome.damaged();
  } catch (_) {
    return const PdfPagesOutcome.damaged();
  }
  try {
    // The Title and the page labels, which pdfrx does not wrap: PDFium's own calls on the document, made in pdfrx's worker isolate
    // (PDFium is not thread-safe). A PDF that says neither gives null; one that takes too long gives null too.
    ({String? title, List<String?>? labels}) meta = (title: null, labels: null);
    try {
      // the handle only (no PDFium call here); the calls themselves run in pdfrx's worker isolate (see readPdfMeta)
      onStep?.call('Reading title');
      final handle = await doc.useNativeDocumentHandle((h) => h);
      meta = await readPdfMeta(handle, doc.pages.length).timeout(_stepTimeout);
    } catch (_) {}
    final pages = <String>[];
    final count = doc.pages.length;
    for (final page in doc.pages) {
      if (pages.isNotEmpty) await betweenPages?.call();
      onStep?.call('Reading page ${pages.length + 1} of $count');
      try {
        // each page within its time: one PDFium cannot read in that time is not waited on for ever (the PDF is skipped)
        final t = await page.ensureLoaded().then((p) => p.loadStructuredText()).timeout(_stepTimeout);
        pages.add(t.fullText);
      } on TimeoutException {
        rethrow;
      } catch (_) {
        // One page that does not read keeps its place, empty.
        pages.add('');
      }
    }
    return PdfPagesOutcome.read(pages, title: meta.title, labels: meta.labels);
  } on TimeoutException {
    logError('A PDF page took over ${_stepTimeout.inMinutes} min; skipped as unreadable', detail: name);
    return const PdfPagesOutcome.damaged();
  } catch (_) {
    return const PdfPagesOutcome.damaged();
  } finally {
    try {
      await doc.dispose().timeout(const Duration(seconds: 10));
    } catch (_) {}
    await removeFile();
  }
}
