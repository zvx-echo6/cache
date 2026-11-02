import 'dart:typed_data';

import 'package:cache_search/cache_search.dart';

import '../../sources/sources_state.dart';
import 'pdf_chunk.dart';
import 'pdf_index_core.dart';

/// The search core's PDF index calls (core-pdf): cs_zim_pdfs, cs_pdf_chunk (the shared cache_chunk), the handle-less
/// cs_pdfindex_* session keyed by {indexes_dir, zim_uuid} with reuse across editions, and the pdfindex_finish job, through the
/// app's search core. A core without cs_pdf_chunk chunks here with the same rule ([chunkPdfPages]).
class CorePdfIndex implements PdfIndexCore {
  CorePdfIndex(this.sources);

  final SourcesState sources;
  bool _has = false;

  SearchCore get _core => sources.core ?? (throw StateError(sources.unavailable ?? 'Search is not ready yet'));

  @override
  bool get available => _has;

  @override
  Future<bool> prepare() async {
    final c = await sources.whenCoreOpen();
    try {
      _has = await c.hasPdfIndex();
    } catch (_) {
      _has = false;
    }
    return _has;
  }

  @override
  Future<ZimPdfList> zimPdfs(String zimId) async => ZimPdfList.fromJson(await _core.zimPdfs(zimId));

  @override
  Future<Uint8List> readEntry(String address) async => (await sources.zimGet(address)).bytes;

  @override
  Future<PdfChunks> chunk(List<PdfPageText> pages) async {
    try {
      return PdfChunks.fromJson(await _core.pdfIndex('chunk', args: {
        'pages': [for (final p in pages) {'index': p.index, 'label': p.label ?? '', 'text': p.text}],
      }));
    } on CacheSearchException catch (e) {
      // A core without cs_pdf_chunk answers nothing for it: the same rule here.
      if (e.code == 'internal' || e.code == 'unsupported') return chunkPdfPages(pages);
      rethrow;
    }
  }

  @override
  Future<PdfStaging> open({required String indexesDir, required String zimUuid, required String zimName, String? previousZimUuid, String? language}) async =>
      PdfStaging.fromJson(await _core.pdfIndex('open', args: {
        'indexes_dir': indexesDir,
        'zim_uuid': zimUuid,
        'zim_name': zimName,
        'language': ?language,
        if (previousZimUuid != null) 'previous': {'zim_uuid': previousZimUuid},
      }));

  @override
  Future<PdfReused> reuse(int session, {required String path, required String sha256}) async =>
      PdfReused.fromJson(await _core.pdfIndex('reuse', session: session, args: {'path': path, 'sha256': sha256}));

  @override
  Future<PdfAdded> add(int session, {required String path, required String title, required List<Map<String, dynamic>> pieces, List<Map<String, dynamic>>? pages, int? size, String? sha256}) async =>
      PdfAdded.fromJson(await _core.pdfIndex('add', session: session, args: {'path': path, 'title': title, 'pieces': pieces, 'pages': ?pages, 'size': ?size, 'sha256': ?sha256}));

  @override
  Future<void> skip(int session, {required String path, required PdfSkipReason reason, int? size, String? sha256}) =>
      _core.pdfIndex('skip', session: session, args: {'path': path, 'reason': reason.code, 'size': ?size, 'sha256': ?sha256});

  @override
  Future<void> close(int session) => _core.pdfIndex('close', session: session);

  @override
  Future<void> discard({required String indexesDir, required String zimUuid}) =>
      _core.pdfIndex('discard', args: {'indexes_dir': indexesDir, 'zim_uuid': zimUuid});

  @override
  Future<PdfFinishJob> finish({required String indexesDir, required String zimUuid}) async =>
      _CoreFinish(await _core.startJob('pdfindex_finish', {'indexes_dir': indexesDir, 'zim_uuid': zimUuid}));
}

class _CoreFinish implements PdfFinishJob {
  _CoreFinish(this.job);

  final CoreJobHandle job;

  @override
  Future<PdfFinishProgress> progress() async {
    final p = await job.progress();
    return PdfFinishProgress(
      state: switch (p.state) {
        JobState.running => PdfFinishState.running,
        JobState.done => PdfFinishState.done,
        JobState.cancelled => PdfFinishState.cancelled,
        JobState.failed => PdfFinishState.failed,
      },
      phase: p.phase,
      done: p.done,
      total: p.total,
      error: p.errorMessage ?? p.errorCode,
      result: p.result,
    );
  }

  @override
  Future<void> cancel() => job.cancel();

  @override
  Future<void> free() => job.free();
}
