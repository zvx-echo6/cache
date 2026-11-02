import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The search core's calls for making a ZIM's PDFs searchable on this device (interface v1, 2026-11-02): the app drives the
/// loop (it has pdfrx and the loaded search model), the core lists the PDFs, chunks the pages (the one implementation the
/// server and the builder share) and owns the durable staging and the final atomic publish of `<zim name>.pdfindex/`.
///
/// [CorePdfIndex] binds these to the core's C calls once they are in it (branch core-pdf); until then the app runs on
/// [PdfIndexCoreMissing] (the feature is not offered) and the tests and renders on [FakePdfIndexCore].
abstract class PdfIndexCore {
  /// False while the core has none of these calls: nothing about PDF indexing is shown.
  bool get available;

  /// The ZIM's PDF entries (cs_zim_pdfs): mime application/pdf, redirects resolved, no duplicates.
  Future<ZimPdfList> zimPdfs(String zimId);

  /// An entry's bytes, by its `zim:<uuid>/<path>` address (the zim entry read the PDF reader uses, cs_zim_get).
  Future<Uint8List> readEntry(String address);

  /// The pieces of one PDF's pages (cs_pdf_chunk): about 200 words, never across a heading.
  Future<PdfChunks> chunk(List<PdfPageText> pages);

  /// Opens or creates the ZIM's staging, `<zim dir>/<zim name>.pdfindex.partial/` (cs_pdfindex_open). A partial for another ZIM
  /// version or another model is discarded by the core and started again.
  Future<PdfStaging> open({required String zimPath, required String zimUuid, required String zimName, required String model});

  /// Writes one PDF's pieces, each with its vector, then marks the PDF done (cs_pdfindex_add): all or nothing. The total of
  /// pieces staged so far.
  Future<int> add(int session, {required String path, required String title, required List<Map<String, dynamic>> pieces});

  /// Marks a PDF that has nothing to index (cs_pdfindex_skip).
  Future<void> skip(int session, {required String path, required PdfSkipReason reason});

  /// Closes the session; the partial stays for a resume (cs_pdfindex_close).
  Future<void> close(int session);

  /// Deletes the partial (cs_pdfindex_discard).
  Future<void> discard(String zimPath);

  /// Starts the publish job (cs_job_start "pdfindex_finish"): the partial becomes `<zim name>.pdfindex/` in one step.
  Future<PdfFinishJob> finish(String zimPath);
}

/// One PDF entry of a ZIM.
class ZimPdf {
  const ZimPdf({required this.path, required this.title, required this.size});

  factory ZimPdf.fromJson(Map<String, dynamic> j) =>
      ZimPdf(path: j['path'] as String, title: (j['title'] as String?) ?? '', size: (j['size'] as num?)?.toInt() ?? 0);

  /// The entry's path inside the ZIM.
  final String path;
  final String title;

  /// Bytes; 0 when the core does not know.
  final int size;

  /// The title shown and stored: the entry's title, else its file name without ".pdf".
  String get name {
    if (title.trim().isNotEmpty) return title.trim();
    final file = path.split('/').last;
    return file.toLowerCase().endsWith('.pdf') ? file.substring(0, file.length - 4) : file;
  }
}

/// What cs_zim_pdfs answers.
class ZimPdfList {
  const ZimPdfList({required this.zimUuid, required this.zimName, required this.pdfs});

  factory ZimPdfList.fromJson(Map<String, dynamic> j) => ZimPdfList(
    zimUuid: j['zim_uuid'] as String,
    zimName: (j['zim_name'] as String?) ?? '',
    pdfs: [for (final p in (j['pdfs'] as List? ?? const [])) ZimPdf.fromJson((p as Map).cast<String, dynamic>())],
  );

  final String zimUuid;
  final String zimName;
  final List<ZimPdf> pdfs;

  /// All their bytes.
  int get bytes => pdfs.fold(0, (s, p) => s + p.size);
}

/// One page's text, as the app reads it with pdfrx. [index] is 0-based; pdfrx gives no page labels.
class PdfPageText {
  const PdfPageText(this.index, this.text, {this.label});

  final int index;
  final String text;
  final String? label;

  Map<String, dynamic> toJson() => {'index': index, 'text': text, 'label': ?label};
}

/// What cs_pdf_chunk answers. Each piece is kept as the core wrote it, so what goes back in cs_pdfindex_add is the core's own
/// shape with only "vector" added.
class PdfChunks {
  const PdfChunks({required this.pieces, this.emptyPages = const []});

  factory PdfChunks.fromJson(Map<String, dynamic> j) => PdfChunks(
    pieces: [for (final p in (j['pieces'] as List? ?? const [])) (p as Map).cast<String, dynamic>()],
    emptyPages: [for (final i in (j['empty_pages'] as List? ?? const [])) (i as num).toInt()],
  );

  final List<Map<String, dynamic>> pieces;
  final List<int> emptyPages;
}

/// What cs_pdfindex_open answers: the session and what an earlier run already finished.
class PdfStaging {
  const PdfStaging({required this.session, this.done = const {}, this.skipped = const {}, this.pieces = 0});

  factory PdfStaging.fromJson(Map<String, dynamic> j) => PdfStaging(
    session: (j['session'] as num).toInt(),
    done: {for (final p in (j['done'] as List? ?? const [])) p as String},
    skipped: {for (final p in (j['skipped'] as List? ?? const [])) p as String},
    pieces: (j['pieces'] as num?)?.toInt() ?? 0,
  );

  final int session;
  final Set<String> done;
  final Set<String> skipped;
  final int pieces;
}

/// Why a PDF has nothing to index. Not an error: it is counted ("12 could not be read") and the run moves on.
enum PdfSkipReason {
  noText('no_text'),
  locked('locked'),
  damaged('damaged');

  const PdfSkipReason(this.code);
  final String code;
}

/// Where the publish job stands.
class PdfFinishProgress {
  const PdfFinishProgress({required this.state, this.phase, this.done = 0, this.total = 0, this.error, this.result});

  final PdfFinishState state;

  /// "optimize", "write" or "publish": cancellable until "publish".
  final String? phase;
  final int done;
  final int total;
  final String? error;

  /// When done: {"pdfs","pieces","skipped","bytes"}.
  final Map<String, dynamic>? result;

  bool get cancellable => state == PdfFinishState.running && phase != 'publish';
  double? get fraction => total > 0 ? (done / total).clamp(0.0, 1.0) : null;
}

enum PdfFinishState { running, done, cancelled, failed }

abstract class PdfFinishJob {
  Future<PdfFinishProgress> progress();
  Future<void> cancel();
  Future<void> free();
}

/// The core has no PDF indexing (until core-pdf lands): the feature is not offered.
class PdfIndexCoreMissing implements PdfIndexCore {
  const PdfIndexCoreMissing();

  static Never _no() => throw UnsupportedError('The search core cannot index PDFs yet.');

  @override
  bool get available => false;
  @override
  Future<ZimPdfList> zimPdfs(String zimId) async => _no();
  @override
  Future<Uint8List> readEntry(String address) async => _no();
  @override
  Future<PdfChunks> chunk(List<PdfPageText> pages) async => _no();
  @override
  Future<PdfStaging> open({required String zimPath, required String zimUuid, required String zimName, required String model}) async => _no();
  @override
  Future<int> add(int session, {required String path, required String title, required List<Map<String, dynamic>> pieces}) async => _no();
  @override
  Future<void> skip(int session, {required String path, required PdfSkipReason reason}) async => _no();
  @override
  Future<void> close(int session) async {}
  @override
  Future<void> discard(String zimPath) async => _no();
  @override
  Future<PdfFinishJob> finish(String zimPath) async => _no();
}

/// The folders of one ZIM's PDF index, beside the ZIM: `<name>.pdfindex/` (the published index, which syncs),
/// `<name>.pdfindex.partial/` (this device's staging) and `<name>.pdfindex.tmp/` (the publish in progress). The name is the ZIM's
/// file name without ".zim".
class PdfIndexPaths {
  PdfIndexPaths(this.zimPath);

  final String zimPath;

  String get _stem => zimPath.replaceFirst(RegExp(r'\.zim$', caseSensitive: false), '');

  /// The file name without ".zim": the `zim_name` the app gives cs_pdfindex_open.
  String get name => _stem.split(RegExp(r'[\\/]')).last;

  Directory get index => Directory('$_stem.pdfindex');
  Directory get partial => Directory('$_stem.pdfindex.partial');
  Directory get tmp => Directory('$_stem.pdfindex.tmp');

  /// Removes all three (the ZIM is gone).
  void deleteAll() {
    for (final d in [index, partial, tmp]) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

/// The published index as this device finds it: which ZIM version it is for, how many PDFs it holds and skipped, and a
/// fingerprint of its files (SHA256SUMS), by which the app tells an index it built from one that came from another device.
class PdfIndexManifest {
  const PdfIndexManifest({required this.zimUuid, required this.pdfs, required this.skipped, required this.fingerprint, this.paths = const {}});

  final String? zimUuid;
  final int pdfs;
  final int skipped;
  final String fingerprint;

  /// The PDFs it holds or skipped (documents.tsv and skipped.tsv), for "22 new".
  final Set<String> paths;

  /// Reads [dir]; null when there is no finished index there (no cache-library.json or no SHA256SUMS: a half-synced copy).
  static PdfIndexManifest? read(Directory dir) {
    try {
      final lib = File('${dir.path}/cache-library.json');
      final sums = File('${dir.path}/SHA256SUMS');
      if (!lib.existsSync() || !sums.existsSync()) return null;
      final j = (jsonDecode(lib.readAsStringSync()) as Map).cast<String, dynamic>();
      final docs = _firstColumn(File('${dir.path}/documents.tsv'));
      final skipped = _firstColumn(File('${dir.path}/skipped.tsv'));
      final s = sums.readAsStringSync();
      return PdfIndexManifest(
        zimUuid: (j['zim_uuid'] ?? (j['zim'] is Map ? (j['zim'] as Map)['uuid'] : null)) as String?,
        pdfs: (j['pdfs'] as num?)?.toInt() ?? docs.length,
        skipped: (j['skipped'] as num?)?.toInt() ?? skipped.length,
        fingerprint: sha256.convert(utf8.encode(s)).toString(),
        paths: {...docs, ...skipped},
      );
    } catch (_) {
      return null;
    }
  }

  static Set<String> _firstColumn(File f) {
    if (!f.existsSync()) return const {};
    return {
      for (final line in const LineSplitter().convert(f.readAsStringSync()))
        if (line.trim().isNotEmpty && !line.startsWith('#')) line.split('\t').first,
    };
  }
}

/// What a ZIM folder (the `library` shared folder) holds that never syncs, as sync patterns (see DataKind.notShared). The
/// published `<name>.pdfindex/` syncs: it holds the vectors, the expensive part, so a ZIM's PDFs are indexed once, on any device.
/// Left out:
/// - `*.pdfindex.partial`: this device's staging (a resume point only this device can use).
/// - `*.pdfindex.tmp`: a publish in progress, renamed to `.pdfindex/` in one step when it is whole.
/// - `*.pdfindex/index`: a keyword index the core may build inside the published index for itself, built on each device as a
///   library's `index/` is.
const List<String> kZimPdfIndexNotShared = ['*.pdfindex.partial', '*.pdfindex.tmp', '*.pdfindex/index'];
