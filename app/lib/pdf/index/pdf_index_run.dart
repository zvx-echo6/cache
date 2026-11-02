import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import '../pdf_source.dart' show isNoSpace;
import '../../platform/battery.dart';
import 'pdf_index_core.dart';
import 'pdf_pages.dart';

/// Why a run stopped before the end.
enum PdfRunStop { none, person, battery, cancel, superseded }

/// How a run ended.
enum PdfRunEnd { finished, paused, cancelled, failed, superseded }

enum PdfRunFailureKind { full, other }

class PdfRunFailure {
  const PdfRunFailure(this.kind, [this.message]);

  final PdfRunFailureKind kind;
  final String? message;
}

/// One PDF as the debug timing log records it.
class PdfTimingRow {
  PdfTimingRow(this.path, this.bytes);

  final String path;
  final int bytes;
  int pages = 0;
  int textPages = 0;
  int pieces = 0;
  int readMs = 0;
  int extractMs = 0;
  int chunkMs = 0;
  int addMs = 0;
  PdfSkipReason? skipped;

  int get totalMs => readMs + extractMs + chunkMs + addMs;
}

/// One PDF read, extracted and chunked: its text pieces, or why it is skipped.
class _OnePdf {
  _OnePdf.pieces(this.pieces, {this.size, this.sha256}) : skip = null;
  _OnePdf.skip(this.skip, {this.size, this.sha256}) : pieces = const [];

  final List<Map<String, dynamic>> pieces;
  final PdfSkipReason? skip;

  /// The size and sha256 of the bytes read (none when they could not be read), for the snapshot's pdfs.tsv.
  final int? size;
  final String? sha256;
}

class _Stopped implements Exception {
  const _Stopped();
}

class _Failed implements Exception {
  const _Failed(this.failure);
  final PdfRunFailure failure;
}

/// The app side of indexing one ZIM's PDFs (interface v2, keyword only): cs_pdfindex_open, then for each PDF not done yet read
/// its bytes (the zim entry read), extract the pages (pdfrx), cs_pdf_chunk, cs_pdfindex_add with the text pieces (or
/// cs_pdfindex_skip for no text, locked or damaged), then cs_pdfindex_close and the pdfindex_finish job. The core commits in
/// batches, so a kill redoes at most the uncommitted batch: the next run starts from cs_pdfindex_open's done list. [stop] pauses
/// (the build stays) or cancels (the build is discarded).
class PdfIndexRun extends ChangeNotifier {
  PdfIndexRun({
    required this.core,
    required this.paths,
    required this.zimName,
    this.previousZimUuid,
    this.language,
    this.attemptFile,
    this.spaceOk,
    required this.list,
    this.readPages = readPdfPagesFromBytes,
    this.battery,
    this.batteryEvery = const Duration(minutes: 1),
    this.limit,
    this.stage = true,
    this.publish = true,
    this.onTiming,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final PdfIndexCore core;
  /// Where the ZIM's index is built and published (its uuid's folder in the device's indexes folder).
  final PdfIndexPaths paths;

  /// The ZIM's metadata Name, given to cs_pdfindex_open.
  final String zimName;

  /// An older edition of this ZIM with a snapshot: its unchanged PDFs are reused, not read again.
  final String? previousZimUuid;

  /// The ZIM's Language metadata (it picks the stemmer; the core takes English when there is none).
  final String? language;

  /// Where the PDF being extracted is written down first (flushed), and removed once its extraction returned. A malformed PDF
  /// can crash PDFium natively, which ends the whole app; the next run finds the note and skips that PDF as damaged instead of
  /// crashing on it again. Null keeps no note (the timing run, the estimate's sample).
  final File? attemptFile;

  /// Notes [path] as being extracted, durably.
  void _noteAttempt(String path) {
    final f = attemptFile;
    if (f == null) return;
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode({'zim_uuid': list.zimUuid, 'path': path}), flush: true);
  }

  void _clearAttempt() {
    final f = attemptFile;
    try {
      if (f != null && f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// The PDF an earlier run was extracting when the app ended (a native crash), for this ZIM; null when none.
  String? _crashedOn() {
    final f = attemptFile;
    try {
      if (f == null || !f.existsSync()) return null;
      final j = jsonDecode(f.readAsStringSync());
      return j is Map && j['zim_uuid'] == list.zimUuid && j['path'] is String ? j['path'] as String : null;
    } catch (_) {
      return null;
    }
  }

  /// False when the device is low on storage (under the reserve): the run stops with "this device is full" (checked with the
  /// battery).
  final bool Function()? spaceOk;

  /// PDFs taken from the previous edition.
  int reused = 0;
  final ZimPdfList list;
  final PdfBytesReader readPages;
  final BatteryReader? battery;
  final Duration batteryEvery;

  /// Index at most this many PDFs (the debug timing run).
  final int? limit;

  /// False for a timing run that stages nothing: every step but open, add and the publish.
  final bool stage;

  /// False for the timing run that stages its PDFs (to time cs_pdfindex_add) but publishes nothing.
  final bool publish;
  final void Function(PdfTimingRow row)? onTiming;
  final DateTime Function() clock;

  int done = 0;
  int skipped = 0;
  int pieces = 0;

  /// PDFs the core has committed, added and skipped (cs_pdfindex_add's "committed"): what a kill keeps.
  int committed = 0;

  /// The previous edition's PDFs by path, with their size (cs_pdfindex_open's "reusable").
  final Map<String, int> reusable = {};
  int bytesDone = 0;

  /// What this run did itself (a resume counts from where it starts), for the speed.
  int _bytesThisRun = 0;
  int _pdfsThisRun = 0;
  DateTime? startedAt;

  /// Starting: open and the first PDF are not done yet.
  bool get starting => _pdfsThisRun == 0 && !finishing;

  /// The publish job is running.
  bool finishing = false;
  double? finishFraction;
  bool _finishCancellable = false;
  PdfFinishJob? _job;

  PdfRunStop _stop = PdfRunStop.none;
  PdfRunStop get stopped => _stop;
  PdfRunFailure? failure;
  Map<String, dynamic>? result;

  int get total => list.pdfs.length;
  int get handled => done + skipped;
  double get fraction => total == 0 ? 1 : (handled / total).clamp(0.0, 1.0);

  /// Time since this run started.
  Duration get elapsed => startedAt == null ? Duration.zero : clock().difference(startedAt!);

  /// The time left from this run's own speed (bytes of PDF a second, or PDFs a second when the sizes are not known), once it
  /// has 5 seconds of data; null before.
  Duration? get timeLeft {
    final secs = elapsed.inMilliseconds / 1000;
    if (secs < 5 || _pdfsThisRun == 0) return null;
    final bytes = list.bytes;
    if (bytes > 0 && _bytesThisRun > 0) {
      final rate = _bytesThisRun / secs;
      return Duration(seconds: ((bytes - bytesDone).clamp(0, bytes) / rate).round());
    }
    final rate = _pdfsThisRun / secs;
    return Duration(seconds: ((total - handled).clamp(0, total) / rate).round());
  }

  /// Pauses ([PdfRunStop.person], [PdfRunStop.battery]), cancels or gives way to an index from another device. Takes effect at
  /// the next piece; the PDF in hand is dropped (it is redone on resume). The publish can be cancelled until its "publish" step.
  void stop(PdfRunStop why) {
    if (_stop != PdfRunStop.none || why == PdfRunStop.none) return;
    if (finishing && (why == PdfRunStop.person || why == PdfRunStop.battery)) return;
    _stop = why;
    if (finishing && _finishCancellable) unawaited(_job?.cancel());
    notifyListeners();
  }

  DateTime? _batteryAt;

  Future<void> _checkBattery() async {
    final b = battery;
    if (b == null) return;
    final now = clock();
    if (_batteryAt != null && now.difference(_batteryAt!) < batteryEvery) return;
    _batteryAt = now;
    final r = await b();
    if (r != null && r.low) stop(PdfRunStop.battery);
  }

  void _checkSpace() {
    if (spaceOk != null && !spaceOk!()) throw const _Failed(PdfRunFailure(PdfRunFailureKind.full));
  }

  void _checkStop() {
    if (_stop != PdfRunStop.none) throw const _Stopped();
  }

  Future<PdfRunEnd> run() async {
    startedAt = clock();
    notifyListeners();
    int? session;
    try {
      var doneSet = <String>{};
      if (stage) {
        final s = await core.open(indexesDir: paths.indexesDir, zimUuid: paths.zimUuid, zimName: zimName, previousZimUuid: previousZimUuid, language: language);
        for (final r in s.reusable) {
          reusable[r.path] = r.size;
        }
        session = s.session;
        doneSet = {...s.done, ...s.skipped};
        pieces = s.pieces;
        committed = s.done.length + s.skipped.length;
        // The app ended while PDFium read this PDF (a native crash): it is skipped as damaged, never tried again.
        final crashed = _crashedOn();
        if (crashed != null && !doneSet.contains(crashed) && list.pdfs.any((p) => p.path == crashed)) {
          await core.skip(session, path: crashed, reason: PdfSkipReason.damaged);
          doneSet.add(crashed);
          skipped++;
          bytesDone += list.pdfs.firstWhere((p) => p.path == crashed).size;
        }
        _clearAttempt();
        for (final p in list.pdfs) {
          if (s.done.contains(p.path)) {
            done++;
            bytesDone += p.size;
          } else if (s.skipped.contains(p.path)) {
            skipped++;
            bytesDone += p.size;
          }
        }
        notifyListeners();
      }
      var failedReads = 0;
      var count = 0;
      for (final pdf in list.pdfs) {
        if (doneSet.contains(pdf.path)) continue;
        if (limit != null && count >= limit!) break;
        count++;
        await _checkBattery();
        _checkStop();
        _checkSpace();
        final row = PdfTimingRow(pdf.path, pdf.size);
        // The previous edition has this PDF at this size: when its bytes are the same, its pieces are taken as they are.
        Uint8List? read;
        if (session != null && reusable[pdf.path] == pdf.size && pdf.size > 0) {
          try {
            read = await core.readEntry('zim:${list.zimUuid}/${pdf.path}');
            final r = await core.reuse(session, path: pdf.path, sha256: crypto.sha256.convert(read).toString());
            if (r.reused) {
              done++;
              reused++;
              pieces += r.pieces;
              bytesDone += pdf.size;
              _bytesThisRun += pdf.size;
              _pdfsThisRun++;
              notifyListeners();
              continue;
            }
          } catch (e) {
            if (_isFull(e)) rethrow;
            read = null;
          }
        }
        final one = await _indexOne(pdf, row, bytes: read);
        if (one.skip == PdfSkipReason.damaged && row.readMs < 0) {
          // The entry read itself failed. One is a damaged entry; several in a row mean the core cannot read the ZIM now.
          failedReads++;
          if (failedReads >= 5) throw const _Failed(PdfRunFailure(PdfRunFailureKind.other, 'The library could not be read.'));
        } else {
          failedReads = 0;
        }
        _checkStop();
        final sw = Stopwatch()..start();
        if (one.skip != null) {
          if (session != null) await core.skip(session, path: pdf.path, reason: one.skip!, size: one.size, sha256: one.sha256);
          skipped++;
        } else {
          if (session != null) {
            final a = await core.add(session, path: pdf.path, title: pdf.name, pieces: one.pieces, size: one.size, sha256: one.sha256);
            pieces = a.pieces;
            committed = a.committed;
          } else {
            pieces += one.pieces.length;
          }
          done++;
        }
        row.addMs = sw.elapsedMilliseconds;
        if (row.readMs < 0) row.readMs = 0;
        bytesDone += pdf.size;
        _bytesThisRun += pdf.size;
        _pdfsThisRun++;
        onTiming?.call(row);
        notifyListeners();
      }
      if (session != null) {
        await core.close(session);
        session = null;
      }
      if (!stage || !publish) return PdfRunEnd.finished;
      _checkStop();
      return await _finish();
    } on _Stopped {
      return _end(session);
    } on _Failed catch (e) {
      failure = e.failure;
      await _close(session);
      return PdfRunEnd.failed;
    } catch (e) {
      failure = _failureOf(e);
      await _close(session);
      return PdfRunEnd.failed;
    } finally {
      notifyListeners();
    }
  }

  Future<void> _close(int? session) async {
    if (session == null) return;
    try {
      await core.close(session);
    } catch (_) {}
  }

  Future<PdfRunEnd> _end(int? session) async {
    await _close(session);
    switch (_stop) {
      case PdfRunStop.cancel:
      case PdfRunStop.superseded:
        if (stage) {
          try {
            await core.discard(indexesDir: paths.indexesDir, zimUuid: paths.zimUuid);
          } catch (_) {}
        }
        return _stop == PdfRunStop.cancel ? PdfRunEnd.cancelled : PdfRunEnd.superseded;
      default:
        return PdfRunEnd.paused;
    }
  }

  Future<PdfRunEnd> _finish() async {
    finishing = true;
    notifyListeners();
    final job = _job = await core.finish(indexesDir: paths.indexesDir, zimUuid: paths.zimUuid);
    try {
      while (true) {
        final p = await job.progress();
        _finishCancellable = p.cancellable;
        finishFraction = p.fraction;
        notifyListeners();
        switch (p.state) {
          case PdfFinishState.running:
            await Future<void>.delayed(const Duration(milliseconds: 250));
          case PdfFinishState.done:
            result = p.result;
            return PdfRunEnd.finished;
          case PdfFinishState.cancelled:
            // The partial is still there: a pause keeps it, a cancel removes it.
            return _end(null);
          case PdfFinishState.failed:
            failure = _failureOf(p.error ?? 'The index could not be finished.');
            return PdfRunEnd.failed;
        }
      }
    } finally {
      finishing = false;
      try {
        await job.free();
      } catch (_) {}
    }
  }

  Future<_OnePdf> _indexOne(ZimPdf pdf, PdfTimingRow row, {Uint8List? bytes}) async {
    final sw = Stopwatch()..start();
    final Uint8List data;
    try {
      data = bytes ?? await core.readEntry('zim:${list.zimUuid}/${pdf.path}');
    } catch (e) {
      if (_isFull(e)) rethrow;
      row.readMs = -1;
      row.skipped = PdfSkipReason.damaged;
      return _OnePdf.skip(PdfSkipReason.damaged);
    }
    row.readMs = sw.elapsedMilliseconds;
    final size = data.length;
    final sha = stage ? crypto.sha256.convert(data).toString() : null;
    _checkStop();
    sw.reset();
    _noteAttempt(pdf.path);
    final PdfPagesOutcome pages;
    try {
      pages = await readPages(data, pdf.path);
    } finally {
      // Extraction returned (or threw): no native crash on this PDF, whatever comes next.
      _clearAttempt();
    }
    row.extractMs = sw.elapsedMilliseconds;
    row.pages = pages.pages.length;
    row.textPages = pages.pages.where((p) => p.trim().isNotEmpty).length;
    final reason = pages.locked ? PdfSkipReason.locked : (pages.damaged ? PdfSkipReason.damaged : (pages.noText ? PdfSkipReason.noText : null));
    if (reason != null) {
      row.skipped = reason;
      return _OnePdf.skip(reason, size: size, sha256: sha);
    }
    _checkStop();
    sw.reset();
    final chunks = await core.chunk([for (var i = 0; i < pages.pages.length; i++) PdfPageText(i, pages.pages[i])]);
    row.chunkMs = sw.elapsedMilliseconds;
    if (chunks.pieces.isEmpty) {
      row.skipped = PdfSkipReason.noText;
      return _OnePdf.skip(PdfSkipReason.noText, size: size, sha256: sha);
    }
    row.pieces = chunks.pieces.length;
    return _OnePdf.pieces(chunks.pieces, size: size, sha256: sha);
  }
}

bool _isFull(Object e) {
  if (e is FileSystemException && isNoSpace(e)) return true;
  final s = '$e'.toLowerCase();
  return s.contains('no_space') || s.contains('no space') || s.contains('disk full') || s.contains('enospc') || s.contains('device is full');
}

PdfRunFailure _failureOf(Object e) {
  if (_isFull(e)) return const PdfRunFailure(PdfRunFailureKind.full);
  return PdfRunFailure(PdfRunFailureKind.other, '$e'.replaceFirst('Bad state: ', '').replaceFirst('Exception: ', ''));
}
