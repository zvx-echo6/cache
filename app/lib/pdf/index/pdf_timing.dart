import 'dart:io';

import 'package:flutter/foundation.dart';

import 'pdf_index_core.dart';
import 'pdf_index_run.dart';
import 'pdf_pages.dart';

/// The debug timing switch is offered only in debug builds and developer builds (built with --dart-define=CACHE_DEVELOPER=true);
/// a normal build never shows it.
const bool kPdfTimingSwitch = kDebugMode || bool.fromEnvironment('CACHE_DEVELOPER');

/// PDFs the timing run indexes.
const int kPdfTimingCount = 20;

/// What the timing run measured, and the log it wrote.
class PdfTimingResult {
  const PdfTimingResult({required this.log, required this.rows, required this.elapsed, required this.totalPdfs, required this.totalBytes, required this.staged});

  final File log;
  final List<PdfTimingRow> rows;
  final Duration elapsed;
  final int totalPdfs;
  final int totalBytes;

  /// cs_pdfindex_add was timed (false when this device has a build in progress, which the timing run leaves alone).
  final bool staged;

  int get pages => rows.fold(0, (s, r) => s + r.pages);
  int get pieces => rows.fold(0, (s, r) => s + r.pieces);
  int get bytes => rows.fold(0, (s, r) => s + r.bytes);

  double get _secs => elapsed.inMilliseconds / 1000;
  double get pagesPerSecond => _secs == 0 ? 0 : pages / _secs;

  double _mean(int Function(PdfTimingRow r) f) => rows.isEmpty ? 0 : rows.fold(0, (s, r) => s + f(r)) / rows.length;

  /// Milliseconds a PDF, on average.
  double get extractMsPerPdf => _mean((r) => r.extractMs);
  double get chunkMsPerPdf => _mean((r) => r.chunkMs);
  double get addMsPerPdf => _mean((r) => r.addMs);
  double get readMsPerPdf => _mean((r) => r.readMs);

  /// The whole ZIM's time at this speed, by bytes (by PDF count when the sizes are not known).
  Duration get extrapolated {
    if (rows.isEmpty) return Duration.zero;
    final ms = elapsed.inMilliseconds;
    final f = bytes > 0 && totalBytes > 0 ? totalBytes / bytes : totalPdfs / rows.length;
    return Duration(milliseconds: (ms * f).round());
  }
}

/// Indexes the first [count] PDFs of a ZIM the way a real run does (read, extract, chunk, add) and writes a log to [logDir]: one
/// tab-separated line a PDF, then pages/s, ms a PDF for extract, chunk and add, and the whole ZIM extrapolated. The PDFs are
/// staged in a build of their own that is discarded afterwards (publish nothing); when this device already has a build in
/// progress, it is left alone and add is not timed. The developer pulls the file from the device.
Future<PdfTimingResult> runPdfTiming({
  required PdfIndexCore core,
  required String zimPath,
  required ZimPdfList list,
  required Directory logDir,
  PdfBytesReader readPages = readPdfPagesFromBytes,
  int count = kPdfTimingCount,
  DateTime Function() clock = DateTime.now,
}) async {
  await logDir.create(recursive: true);
  final started = clock();
  final stamp = started.toUtc().toIso8601String().replaceAll(':', '').split('.').first;
  final paths = PdfIndexPaths(zimPath);
  final log = File('${logDir.path}${Platform.pathSeparator}pdf-timing-${paths.name}-$stamp.tsv');
  final stage = !paths.build.existsSync();
  final out = StringBuffer()
    ..writeln('# Cache PDF index timing, ${started.toUtc().toIso8601String()}')
    ..writeln('# zim\t${paths.name}\tuuid\t${list.zimUuid}\tpdfs\t${list.pdfs.length}\tbytes\t${list.bytes}')
    ..writeln('path\tbytes\tpages\ttext_pages\tpieces\tread_ms\textract_ms\tchunk_ms\tadd_ms\tskipped');
  final rows = <PdfTimingRow>[];
  final sw = Stopwatch()..start();
  final run = PdfIndexRun(
    core: core,
    zimPath: zimPath,
    list: list,
    readPages: readPages,
    stage: stage,
    publish: false,
    limit: count,
    onTiming: rows.add,
    clock: clock,
  );
  await run.run();
  sw.stop();
  if (stage) {
    try {
      await core.discard(zimPath);
    } catch (_) {}
  }
  for (final r in rows) {
    out.writeln([r.path, r.bytes, r.pages, r.textPages, r.pieces, r.readMs, r.extractMs, r.chunkMs, stage ? r.addMs : '', r.skipped?.code ?? ''].join('\t'));
  }
  final res = PdfTimingResult(log: log, rows: rows, elapsed: sw.elapsed, totalPdfs: list.pdfs.length, totalBytes: list.bytes, staged: stage);
  out
    ..writeln('# pdfs\t${rows.length}\tseconds\t${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}')
    ..writeln('# pages_per_s\t${res.pagesPerSecond.toStringAsFixed(2)}')
    ..writeln('# ms_per_pdf\tread\t${res.readMsPerPdf.toStringAsFixed(0)}\textract\t${res.extractMsPerPdf.toStringAsFixed(0)}\tchunk\t${res.chunkMsPerPdf.toStringAsFixed(0)}\tadd\t${stage ? res.addMsPerPdf.toStringAsFixed(0) : 'not timed'}')
    ..writeln('# whole_zim_extrapolated_hours\t${(res.extrapolated.inSeconds / 3600).toStringAsFixed(2)}')
    ..writeln(stage ? '# staged in a throwaway build (discarded); the publish job is not timed' : '# a build is in progress on this device: add not timed, nothing staged');
  if (run.failure != null) out.writeln('# stopped\t${run.failure!.kind.name}\t${run.failure!.message ?? ''}');
  await log.writeAsString(out.toString(), flush: true);
  return res;
}
