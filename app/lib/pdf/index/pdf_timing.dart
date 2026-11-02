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
  const PdfTimingResult({required this.log, required this.rows, required this.elapsed, required this.totalPdfs, required this.totalBytes});

  final File log;
  final List<PdfTimingRow> rows;
  final Duration elapsed;
  final int totalPdfs;
  final int totalBytes;

  int get pages => rows.fold(0, (s, r) => s + r.pages);
  int get pieces => rows.fold(0, (s, r) => s + r.pieces);
  int get bytes => rows.fold(0, (s, r) => s + r.bytes);
  List<int> get embedMs => [for (final r in rows) ...r.embedMs]..sort();

  double get _secs => elapsed.inMilliseconds / 1000;
  double get pagesPerSecond => _secs == 0 ? 0 : pages / _secs;
  double get piecesPerSecond => _secs == 0 ? 0 : pieces / _secs;
  double get embedMsPerPiece => embedMs.isEmpty ? 0 : embedMs.fold(0, (s, v) => s + v) / embedMs.length;

  /// The whole ZIM's time at this speed, by bytes (by PDF count when the sizes are not known).
  Duration get extrapolated {
    if (rows.isEmpty) return Duration.zero;
    final ms = elapsed.inMilliseconds;
    final f = bytes > 0 && totalBytes > 0 ? totalBytes / bytes : totalPdfs / rows.length;
    return Duration(milliseconds: (ms * f).round());
  }
}

int _pct(List<int> sorted, double q) => sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * q).round()];

/// Indexes the first [count] PDFs of a ZIM the way a real run does (read, extract, chunk, embed), staging nothing, and writes a
/// log to [logDir]: one tab-separated line a PDF, then pages/s, pieces/s, embed ms per piece and the whole ZIM extrapolated.
/// The developer pulls the file from the device (adb pull on Android; the app's folder elsewhere).
Future<PdfTimingResult> runPdfTiming({
  required PdfIndexCore core,
  required PdfEmbed? embed,
  required String model,
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
  final log = File('${logDir.path}${Platform.pathSeparator}pdf-timing-${PdfIndexPaths(zimPath).name}-$stamp.tsv');
  final out = StringBuffer()
    ..writeln('# Cache PDF index timing, ${started.toUtc().toIso8601String()}')
    ..writeln('# zim\t${PdfIndexPaths(zimPath).name}\tuuid\t${list.zimUuid}\tpdfs\t${list.pdfs.length}\tbytes\t${list.bytes}\tmodel\t$model')
    ..writeln('path\tbytes\tpages\ttext_pages\tpieces\tread_ms\textract_ms\tchunk_ms\tembed_ms\tembed_ms_per_piece\tskipped');
  // The model loads before the clock starts.
  await embed?.call('warm up');
  final rows = <PdfTimingRow>[];
  final sw = Stopwatch()..start();
  final run = PdfIndexRun(
    core: core,
    embed: embed,
    model: model,
    zimPath: zimPath,
    list: list,
    readPages: readPages,
    stage: false,
    limit: count,
    onTiming: rows.add,
    clock: clock,
  );
  await run.run();
  sw.stop();
  for (final r in rows) {
    final e = r.embedMs.fold(0, (s, v) => s + v);
    out.writeln([
      r.path, r.bytes, r.pages, r.textPages, r.pieces, r.readMs, r.extractMs, r.chunkMs, e,
      r.pieces == 0 ? '' : (e / r.pieces).toStringAsFixed(1), r.skipped?.code ?? '',
    ].join('\t'));
  }
  final res = PdfTimingResult(log: log, rows: rows, elapsed: sw.elapsed, totalPdfs: list.pdfs.length, totalBytes: list.bytes);
  final em = res.embedMs;
  out
    ..writeln('# pdfs\t${rows.length}\tseconds\t${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}')
    ..writeln('# pages_per_s\t${res.pagesPerSecond.toStringAsFixed(2)}')
    ..writeln('# pieces_per_s\t${res.piecesPerSecond.toStringAsFixed(2)}')
    ..writeln('# embed_ms_per_piece\tmean\t${res.embedMsPerPiece.toStringAsFixed(1)}\tp50\t${_pct(em, 0.5)}\tp95\t${_pct(em, 0.95)}')
    ..writeln('# whole_zim_extrapolated_hours\t${(res.extrapolated.inSeconds / 3600).toStringAsFixed(2)}')
    ..writeln('# not timed: cs_pdfindex_add and the pdfindex_finish job (nothing is staged)');
  if (run.failure != null) out.writeln('# stopped\t${run.failure!.kind.name}\t${run.failure!.message ?? ''}');
  await log.writeAsString(out.toString(), flush: true);
  return res;
}
