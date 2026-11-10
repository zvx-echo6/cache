import 'engine.dart';

/// One `needs_ocr` batch read: the `cs_ingest_ocr` call to make, each page's result, and the pages that could not be read.
class OcrBatch {
  const OcrBatch({required this.job, required this.engine, required this.version, required this.pages, required this.failed});

  final int job;
  final String engine;
  final String version;

  /// Every page of the batch, in the order asked. A page in [failed] is here with empty text and confidence 0.
  final List<OcrPageText> pages;

  /// Pages the engine could not read even on a second try (their errors). They are handed back as blank so the job goes on
  /// (the core asks for the same batch until every page is answered); they still count as OCR'd, so a later engine redoes them.
  final Map<int, OcrException> failed;

  /// The parameters of `cs_ingest_ocr`: `{job, engine, version, pages: [{page, text, confidence}]}`.
  Map<String, dynamic> get ingestParams => {'job': job, 'engine': engine, 'version': version, 'pages': [for (final p in pages) p.toIngestJson()]};
}

/// Waits until the work may go on (the app's throttle: rests, a warm phone, the person using the app).
typedef OcrPermit = Future<void> Function();

/// The entry point for Add PDF: reads one `needs_ocr` batch of the ingest job [job] with [engine] and returns what to pass to
/// `cs_ingest_ocr`. [needsOcr] is the status's `needs_ocr` list as decoded JSON. [betweenPages] is awaited before every page
/// after the first; [onPage] hears each page as it is done (for progress).
///
/// Pages are read one at a time, never in parallel: one 300 dpi page image is about 34 MB decoded (US Letter, 2550 x 3300, 4
/// bytes a pixel as the engines hold it), and on a mid-range phone one at a time is what keeps memory flat.
Future<OcrBatch> ocrForIngest(int job, List<Object?> needsOcr, OcrEngine engine, {OcrPermit? betweenPages, void Function(OcrPageText page)? onPage}) async {
  final images = [for (final e in needsOcr) OcrPageImage.fromJson((e as Map).cast<String, dynamic>())];
  final pages = <OcrPageText>[];
  final failed = <int, OcrException>{};
  for (final image in images) {
    if (pages.isNotEmpty) await betweenPages?.call();
    OcrPageText? got;
    OcrException? error;
    for (var attempt = 0; attempt < 2 && got == null; attempt++) {
      try {
        got = await engine.recognize(image);
      } on OcrException catch (e) {
        error = e;
        // a missing or unreadable file will not read on a second try
        if (e.code == 'no_file' || e.code == 'bad_image') break;
      }
    }
    if (got == null) {
      failed[image.page] = error ?? const OcrException('engine', 'no result');
      got = OcrPageText(page: image.page, text: '', confidence: 0);
    }
    pages.add(got);
    onPage?.call(got);
  }
  return OcrBatch(job: job, engine: engine.engine, version: engine.version, pages: pages, failed: failed);
}

/// Joins recognised lines into a page's text: lines in reading order joined by `\n`, each trimmed, empty ones dropped.
String joinOcrLines(Iterable<String> lines) => lines.map((l) => l.trim()).where((l) => l.isNotEmpty).join('\n');

/// A page's confidence from its lines' (text, confidence) pairs: the average weighted by each line's length; 0 with no text.
double pageConfidence(Iterable<(String, double)> lines) {
  var weight = 0;
  var sum = 0.0;
  for (final (text, c) in lines) {
    final n = text.trim().length;
    if (n == 0) continue;
    weight += n;
    sum += c.clamp(0.0, 1.0) * n;
  }
  return weight == 0 ? 0 : sum / weight;
}
