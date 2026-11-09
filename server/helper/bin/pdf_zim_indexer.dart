import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../app/lib/pdf/index/pdf_chunk.dart';
import '../../../app/lib/pdf/index/pdf_index_core.dart';
import '../../../app/lib/pdf/index/pdf_title.dart';
import '../../../packages/cache_search/lib/src/core_dispatch.dart';

/// Making the PDFs inside ZIMs searchable on the server, with no browser open. The phone does it in app/lib/pdf/index/
/// (PdfIndexRun): the core lists the PDFs, the app reads each one's pages with pdfrx and hands them back to the core, which chunks
/// them (cs_pdf_chunk) and writes the keyword index (cs_pdfindex_*, then the pdfindex_finish job). pdfrx needs Flutter, so here
/// the pages come from MuPDF, in a child process of the server program (`cache pdf-text`, server/builder/src/pdf_text.rs); every
/// other call is the phone's own, so the chunks, the records and the snapshot are the same format and the indexes are compatible.
/// The words come out of a different PDF reader (the text of a page may differ slightly between PDFium and MuPDF).

/// What reading one PDF gave (the child's answer): its pages, or why it could not be read.
class PdfTextResult {
  const PdfTextResult({required this.status, this.size, this.sha256, this.title, this.labels = const [], this.pages = const []});

  const PdfTextResult.damaged({this.size, this.sha256}) : status = 'damaged', title = null, labels = const [], pages = const [];

  factory PdfTextResult.fromJson(Map<String, dynamic> j) => PdfTextResult(
        status: (j['status'] as String?) ?? 'damaged',
        size: (j['size'] as num?)?.toInt(),
        sha256: j['sha256'] as String?,
        title: j['title'] as String?,
        labels: [for (final l in (j['labels'] as List? ?? const [])) '$l'],
        pages: [for (final p in (j['pages'] as List? ?? const [])) '$p'],
      );

  /// "ok", "locked" or "damaged".
  final String status;
  final int? size;
  final String? sha256;
  final String? title;
  final List<String> labels;
  final List<String> pages;

  bool get locked => status == 'locked';
  bool get damaged => status != 'ok' && status != 'locked';
}

/// Reads a PDF's bytes: its pages, or (with [hashOnly]) only its size and sha256.
typedef PdfTextRead = Future<PdfTextResult> Function(Uint8List bytes, {required bool hashOnly});

/// [PdfTextRead] over the server program run as `pdf-text` (one process for each PDF: a PDF that crashes MuPDF, runs past its
/// time or wants more memory than it may have is damaged, and the server goes on). The time is 2 minutes and 15 seconds for each
/// MB, at most an hour; the address space is 2 GiB and 64 times the PDF, at most 8 GiB (the library builder's limits).
class PdfTextProcess {
  PdfTextProcess(this.exe, this.tmp);

  final String exe;
  final String tmp;

  Future<PdfTextResult> read(Uint8List bytes, {required bool hashOnly}) async {
    Directory(tmp).createSync(recursive: true);
    final dir = await Directory(tmp).createTemp('pdf-text-');
    try {
      final input = '${dir.path}/in.pdf', output = '${dir.path}/out.json';
      await File(input).writeAsBytes(bytes, flush: true);
      final mem = math.min(8 << 30, (2 << 30) + 64 * bytes.length);
      final p = await Process.start(exe, ['pdf-text', input, output, if (hashOnly) 'hash'], environment: {'CACHE_PDF_TEXT_MEM': '$mem'});
      unawaited(p.stdout.drain<void>());
      unawaited(p.stderr.drain<void>());
      final limit = Duration(seconds: math.min(3600, 120 + 15 * (bytes.length >> 20)));
      final code = await p.exitCode.timeout(limit, onTimeout: () {
        p.kill(ProcessSignal.sigkill);
        return -1;
      });
      final out = File(output);
      if (code != 0 || !out.existsSync()) return const PdfTextResult.damaged();
      return PdfTextResult.fromJson((jsonDecode(await out.readAsString()) as Map).cast<String, dynamic>());
    } catch (_) {
      return const PdfTextResult.damaged();
    } finally {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

/// [PdfIndexCore] over the helper's dispatcher: the same calls as the app's CorePdfIndex (app/lib/pdf/index/pdf_index_binding.dart),
/// made on the dispatcher instead of the search core.
class DispatcherPdfCore implements PdfIndexCore {
  DispatcherPdfCore(this.d, {this.poll = const Duration(milliseconds: 100)});

  final CoreDispatcher d;
  final Duration poll;

  Map<String, dynamic> _map(Object? o) => (o as Map).cast<String, dynamic>();

  Map<String, dynamic> _pdf(String op, {int session = 0, Map<String, dynamic>? args}) =>
      _map(d.handle('pdfIndex', {'op': op, 'session': session, 'args': args}));

  @override
  bool get available {
    try {
      return d.handle('hasPdfIndex', const {}) == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> prepare() async => available;

  /// The list is made by the core's `zim_pdfs` job (a pass over every entry of a large ZIM is long), as the app does it; a core
  /// older than the job lists in the call itself.
  @override
  Future<ZimPdfList> zimPdfs(String zimId) async {
    String? path;
    try {
      for (final s in (d.handle('status', const {}) as List)) {
        if ((s as Map)['id'] == zimId) path = s['path'] as String?;
      }
    } catch (_) {}
    if (path != null) {
      int? job;
      try {
        job = d.handle('jobStart', {'kind': 'zim_pdfs', 'params': {'zim_path': path}}) as int;
      } catch (e) {
        if (!'$e'.contains('unknown job kind')) rethrow;
      }
      if (job != null) {
        try {
          while (true) {
            final p = _map(d.handle('jobProgress', {'job': job}));
            switch (p['state']) {
              case 'running':
                await Future<void>.delayed(poll);
              case 'done':
                return ZimPdfList.fromJson(_map(p['result'] ?? (throw StateError('The PDF list gave no answer'))));
              default:
                final e = p['error'];
                throw StateError(e is Map ? '${e['message']}' : 'The PDF list stopped');
            }
          }
        } finally {
          try {
            d.handle('jobFree', {'job': job});
          } catch (_) {}
        }
      }
    }
    return ZimPdfList.fromJson(_map(d.handle('zimPdfs', {'zimId': zimId})));
  }

  @override
  Future<Uint8List> readEntry(String address) async => (d.handle('zimGet', {'address': address}) as List)[0] as Uint8List;

  @override
  Future<PdfChunks> chunk(List<PdfPageText> pages) async {
    try {
      return PdfChunks.fromJson(_pdf('chunk', args: {
        'pages': [for (final p in pages) {'index': p.index, 'label': p.label ?? '', 'text': p.text}],
      }));
    } catch (e) {
      // A core without cs_pdf_chunk: the same rule here (as the app does).
      if ('$e'.contains('internal') || '$e'.contains('unsupported')) return chunkPdfPages(pages);
      rethrow;
    }
  }

  @override
  Future<PdfStaging> open({required String indexesDir, required String zimUuid, required String zimName, String? previousZimUuid, String? language}) async =>
      PdfStaging.fromJson(_pdf('open', args: {
        'indexes_dir': indexesDir,
        'zim_uuid': zimUuid,
        'zim_name': zimName,
        'language': ?language,
        if (previousZimUuid != null) 'previous': {'zim_uuid': previousZimUuid},
      }));

  @override
  Future<PdfReused> reuse(int session, {required String path, required String sha256}) async =>
      PdfReused.fromJson(_pdf('reuse', session: session, args: {'path': path, 'sha256': sha256}));

  @override
  Future<PdfAdded> add(int session, {required String path, required String title, required List<Map<String, dynamic>> pieces, List<Map<String, dynamic>>? pages, int? size, String? sha256}) async =>
      PdfAdded.fromJson(_pdf('add', session: session, args: {'path': path, 'title': title, 'pieces': pieces, 'pages': ?pages, 'size': ?size, 'sha256': ?sha256}));

  @override
  Future<void> skip(int session, {required String path, required PdfSkipReason reason, int? size, String? sha256}) async {
    _pdf('skip', session: session, args: {'path': path, 'reason': reason.code, 'size': ?size, 'sha256': ?sha256});
  }

  @override
  Future<void> close(int session) async {
    _pdf('close', session: session);
  }

  @override
  Future<void> discard({required String indexesDir, required String zimUuid}) async {
    _pdf('discard', args: {'indexes_dir': indexesDir, 'zim_uuid': zimUuid});
  }

  @override
  Future<PdfFinishJob> finish({required String indexesDir, required String zimUuid}) async =>
      _Finish(d, d.handle('jobStart', {'kind': 'pdfindex_finish', 'params': {'indexes_dir': indexesDir, 'zim_uuid': zimUuid}}) as int);
}

class _Finish implements PdfFinishJob {
  _Finish(this.d, this.job);

  final CoreDispatcher d;
  final int job;

  @override
  Future<PdfFinishProgress> progress() async {
    final p = (d.handle('jobProgress', {'job': job}) as Map).cast<String, dynamic>();
    final e = p['error'];
    return PdfFinishProgress(
      state: switch (p['state']) {
        'running' => PdfFinishState.running,
        'done' => PdfFinishState.done,
        'cancelled' => PdfFinishState.cancelled,
        _ => PdfFinishState.failed,
      },
      phase: p['phase'] as String?,
      done: (p['done'] as num?)?.toInt() ?? 0,
      total: (p['total'] as num?)?.toInt() ?? 0,
      error: e is Map ? '${e['message'] ?? e['code']}' : null,
      result: p['result'] is Map ? (p['result'] as Map).cast<String, dynamic>() : null,
    );
  }

  @override
  Future<void> cancel() async {
    d.handle('jobCancel', {'job': job});
  }

  @override
  Future<void> free() async {
    d.handle('jobFree', {'job': job});
  }
}

/// How a ZIM's PDF run ended: [finished] (the index is published), [paused] (stopped by [ZimPdfIndexer.cancel]; the build stays
/// for the next run) or [failed] ([ZimPdfIndexer.error] says why).
enum ZimPdfEnd { finished, paused, failed }

/// What the helper needs to index ZIMs' PDFs: the core's calls, the PDF reader and the device's indexes folder.
class PdfWork {
  PdfWork({required this.core, required this.read, required this.indexesDir});

  final PdfIndexCore core;
  final PdfTextRead read;
  final String indexesDir;
}

/// One ZIM's PDF run (PdfIndexRun on the phone, without its screens, battery, crash note and timing): cs_pdfindex_open, then for
/// each PDF not done yet its bytes (the entry read), the pages, cs_pdf_chunk and cs_pdfindex_add (or cs_pdfindex_skip for none,
/// locked or damaged), then cs_pdfindex_close and the pdfindex_finish job. The core commits in batches, so a stop (or a kill)
/// redoes at most the uncommitted batch. [permit] is awaited before each PDF, as the phone awaits its throttle; [cancel] stops at
/// the next PDF and keeps the build.
class ZimPdfIndexer {
  ZimPdfIndexer({required this.core, required this.read, required this.indexesDir, this.permit, this.log});

  final PdfIndexCore core;
  final PdfTextRead read;
  final String indexesDir;
  final Future<void> Function()? permit;
  final void Function(String message)? log;

  bool _cancelled = false;

  /// PDFs made searchable (this run and earlier ones), skipped (no text, locked, damaged) and all of the ZIM's.
  int done = 0;
  int skipped = 0;
  int total = 0;

  /// PDFs taken from the previous edition.
  int reused = 0;

  /// 0..1 through the PDFs, then the publish.
  double? get fraction => total == 0 ? null : ((done + skipped) / total).clamp(0.0, 1.0).toDouble();

  /// Why a run failed.
  String? error;

  /// The publish job's result when it finished: {"pdfs","pieces","skipped","bytes","snapshot"}.
  Map<String, dynamic>? result;

  void cancel() {
    _cancelled = true;
  }

  /// An older edition of the ZIM (the same metadata Name, another uuid) with a snapshot here: its PDFs are reused (the phone's
  /// PdfIndexState._previous).
  String? previousEdition(String zimUuid, String zimName) {
    if (zimName.isEmpty) return null;
    PdfSnapshot? best;
    String? uuid;
    for (final u in pdfIndexUuids(indexesDir)) {
      if (u == zimUuid) continue;
      final s = PdfIndexPaths(indexesDir, u).current();
      if (s == null || s.zimName != zimName) continue;
      if (best == null || s.created.compareTo(best.created) > 0) {
        best = s;
        uuid = u;
      }
    }
    return uuid;
  }

  Future<ZimPdfEnd> run(ZimPdfList list) async {
    total = list.pdfs.length;
    int? session;
    try {
      // The ZIM's metadata Name; the language is not known here (the phone gives the catalogue's, and a browser's ZIM has only its
      // file name, so none), and the core takes English.
      final zimName = list.zimName;
      final s = await core.open(indexesDir: indexesDir, zimUuid: list.zimUuid, zimName: zimName, previousZimUuid: previousEdition(list.zimUuid, zimName));
      session = s.session;
      final doneSet = {...s.done, ...s.skipped};
      final reusable = {for (final r in s.reusable) r.path: r.size};
      for (final p in list.pdfs) {
        if (s.done.contains(p.path)) {
          done++;
        } else if (s.skipped.contains(p.path)) {
          skipped++;
        }
      }
      var failedReads = 0;
      for (final pdf in list.pdfs) {
        if (doneSet.contains(pdf.path)) continue;
        await permit?.call();
        if (_cancelled) return await _stopped(session);
        final address = 'zim:${list.zimUuid}/${pdf.path}';
        Uint8List? bytes;
        // The previous edition has this PDF at this size: when its bytes are the same, its pieces are taken as they are.
        if (reusable[pdf.path] == pdf.size && pdf.size > 0) {
          try {
            bytes = await core.readEntry(address);
            final h = await read(bytes, hashOnly: true);
            final sha = h.sha256;
            if (sha != null && (await core.reuse(session, path: pdf.path, sha256: sha)).reused) {
              done++;
              reused++;
              continue;
            }
          } catch (_) {
            bytes = null;
          }
        }
        final data = bytes ?? await _entry(address, pdf.path);
        if (data == null) {
          await core.skip(session, path: pdf.path, reason: PdfSkipReason.damaged);
          skipped++;
          // One is a damaged entry; several in a row mean the core cannot read the ZIM now.
          if (++failedReads >= 5) throw StateError('The library could not be read.');
          continue;
        }
        failedReads = 0;
        if (_cancelled) return await _stopped(session);
        await _one(session, pdf, data);
      }
      await core.close(session);
      session = null;
      if (_cancelled) return ZimPdfEnd.paused;
      return await _finish(list);
    } catch (e) {
      error = '$e'.replaceFirst('Bad state: ', '').replaceFirst('Exception: ', '');
      if (session != null) {
        try {
          await core.close(session);
        } catch (_) {}
      }
      return ZimPdfEnd.failed;
    }
  }

  Future<Uint8List?> _entry(String address, String path) async {
    try {
      return await core.readEntry(address);
    } catch (e) {
      log?.call('PDF entry read failed ($path): $e');
      return null;
    }
  }

  Future<ZimPdfEnd> _stopped(int session) async {
    try {
      await core.close(session);
    } catch (_) {}
    return ZimPdfEnd.paused;
  }

  Future<void> _one(int session, ZimPdf pdf, Uint8List bytes) async {
    final r = await read(bytes, hashOnly: false);
    final size = r.size ?? bytes.length;
    final reason = r.locked
        ? PdfSkipReason.locked
        : r.damaged
            ? PdfSkipReason.damaged
            : r.pages.every((p) => p.trim().isEmpty)
                ? PdfSkipReason.noText
                : null;
    if (reason != null) {
      await core.skip(session, path: pdf.path, reason: reason, size: size, sha256: r.sha256);
      skipped++;
      return;
    }
    final chunks = await core.chunk([
      for (var i = 0; i < r.pages.length; i++) PdfPageText(i, r.pages[i], label: i < r.labels.length ? r.labels[i] : null),
    ]);
    if (chunks.pieces.isEmpty) {
      await core.skip(session, path: pdf.path, reason: PdfSkipReason.noText, size: size, sha256: r.sha256);
      skipped++;
      return;
    }
    // The PDF's own Title when it has a real one, else "" (the core names it from its file name).
    await core.add(session, path: pdf.path, title: cleanPdfTitle(r.title), pieces: chunks.pieces, pages: chunks.pages, size: size, sha256: r.sha256);
    done++;
  }

  Future<ZimPdfEnd> _finish(ZimPdfList list) async {
    final job = await core.finish(indexesDir: indexesDir, zimUuid: list.zimUuid);
    var cancelSent = false;
    try {
      while (true) {
        final p = await job.progress();
        if (_cancelled && !cancelSent && p.cancellable) {
          cancelSent = true;
          await job.cancel();
        }
        switch (p.state) {
          case PdfFinishState.running:
            await Future<void>.delayed(const Duration(milliseconds: 250));
          case PdfFinishState.done:
            result = p.result;
            return ZimPdfEnd.finished;
          case PdfFinishState.cancelled:
            return ZimPdfEnd.paused;
          case PdfFinishState.failed:
            error = p.error ?? 'The index could not be finished.';
            return ZimPdfEnd.failed;
        }
      }
    } finally {
      try {
        await job.free();
      } catch (_) {}
    }
  }
}
