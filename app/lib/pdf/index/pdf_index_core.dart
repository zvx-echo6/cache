import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The search core's calls for making a ZIM's PDFs searchable on this device (interface v2, 2026-11-02): a keyword index, like
/// all other ZIM content (no vectors, no search model). The app drives the loop (it has pdfrx); the core lists the PDFs, chunks
/// the pages (the one cache_chunk the server and the builder share), owns the resumable build in `<zim name>.pdfindex/.build/`
/// and publishes each finished index as an immutable snapshot, `<zim name>.pdfindex/snap/<build-id>/`, which syncs.
///
/// The core-pdf binding implements this once the calls are in the core; until then the app runs on [PdfIndexCoreMissing] (the
/// feature is not offered) and the tests and renders on FakePdfIndexCore.
abstract class PdfIndexCore {
  /// False while the core has none of these calls: nothing about PDF indexing is shown.
  bool get available;

  /// The ZIM's PDF entries (cs_zim_pdfs): mime application/pdf, redirects resolved, no duplicates.
  Future<ZimPdfList> zimPdfs(String zimId);

  /// An entry's bytes, by its `zim:<uuid>/<path>` address (the zim entry read the PDF reader uses, cs_zim_get).
  Future<Uint8List> readEntry(String address);

  /// The pieces of one PDF's pages (cs_pdf_chunk): about 200 words, never across a heading.
  Future<PdfChunks> chunk(List<PdfPageText> pages);

  /// Opens or creates the ZIM's build, `.pdfindex/.build/` (cs_pdfindex_open). A build for another ZIM version, format or
  /// chunker is discarded by the core and started again.
  Future<PdfStaging> open({required String zimPath, required String zimUuid, required String zimName});

  /// Adds one PDF's text pieces, replacing any it had (cs_pdfindex_add). Durable in batches: the core commits about every 20
  /// PDFs or 30 seconds and lists a path as done only after the commit that holds it.
  Future<PdfAdded> add(int session, {required String path, required String title, required List<Map<String, dynamic>> pieces});

  /// Marks a PDF that has nothing to index (cs_pdfindex_skip).
  Future<void> skip(int session, {required String path, required PdfSkipReason reason});

  /// Commits and closes the session; the build stays for a resume (cs_pdfindex_close).
  Future<void> close(int session);

  /// Deletes the build (cs_pdfindex_discard).
  Future<void> discard(String zimPath);

  /// Starts the publish job (cs_job_start "pdfindex_finish"): merge, manifest, then one rename to `snap/<build-id>/`.
  Future<PdfFinishJob> finish(String zimPath);
}

/// What cs_pdfindex_add answers: pieces in the build so far, and PDFs committed (a kill redoes the ones after that).
class PdfAdded {
  const PdfAdded({required this.pieces, required this.committed});

  factory PdfAdded.fromJson(Map<String, dynamic> j) =>
      PdfAdded(pieces: (j['pieces'] as num?)?.toInt() ?? 0, committed: (j['committed'] as num?)?.toInt() ?? 0);

  final int pieces;
  final int committed;
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

/// What cs_pdf_chunk answers. Each piece is kept as the core wrote it and goes back in cs_pdfindex_add unchanged.
class PdfChunks {
  const PdfChunks({required this.pieces, this.emptyPages = const [], this.chunker});

  factory PdfChunks.fromJson(Map<String, dynamic> j) => PdfChunks(
    pieces: [for (final p in (j['pieces'] as List? ?? const [])) (p as Map).cast<String, dynamic>()],
    emptyPages: [for (final i in (j['empty_pages'] as List? ?? const [])) (i as num).toInt()],
    chunker: j['chunker'],
  );

  final List<Map<String, dynamic>> pieces;
  final List<int> emptyPages;

  /// The chunker's version (the build is started again when it changes).
  final Object? chunker;
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

  /// "merge", "manifest" or "publish": cancellable until "publish".
  final String? phase;
  final int done;
  final int total;
  final String? error;

  /// When done: {"pdfs","pieces","skipped","bytes","snapshot"}.
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
  Future<PdfStaging> open({required String zimPath, required String zimUuid, required String zimName}) async => _no();
  @override
  Future<PdfAdded> add(int session, {required String path, required String title, required List<Map<String, dynamic>> pieces}) async => _no();
  @override
  Future<void> skip(int session, {required String path, required PdfSkipReason reason}) async => _no();
  @override
  Future<void> close(int session) async {}
  @override
  Future<void> discard(String zimPath) async => _no();
  @override
  Future<PdfFinishJob> finish(String zimPath) async => _no();
}

/// The folders of one ZIM's PDF index, beside the ZIM: `<name>.pdfindex/` holding `.build/` (this device's resumable build,
/// never synced) and `snap/<build-id>/` (published snapshots, which sync). The name is the ZIM's file name without ".zim".
class PdfIndexPaths {
  PdfIndexPaths(this.zimPath);

  final String zimPath;

  String get _stem => zimPath.replaceFirst(RegExp(r'\.zim$', caseSensitive: false), '');

  /// The file name without ".zim": the `zim_name` the app gives cs_pdfindex_open.
  String get name => _stem.split(RegExp(r'[\\/]')).last;

  Directory get root => Directory('$_stem.pdfindex');
  Directory get build => Directory('${root.path}${Platform.pathSeparator}.build');
  Directory get snaps => Directory('${root.path}${Platform.pathSeparator}snap');

  /// Removes it all (the ZIM is gone).
  void deleteAll() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// The complete snapshots here: a manifest, and every file it lists present at its size (a snapshot still arriving by sync
  /// is not one yet; the core checks the sha256 of each file before it uses one).
  List<PdfSnapshot> snapshots() {
    final out = <PdfSnapshot>[];
    try {
      if (!snaps.existsSync()) return out;
      for (final d in snaps.listSync().whereType<Directory>()) {
        final s = PdfSnapshot.read(d);
        if (s != null) out.add(s);
      }
    } catch (_) {}
    return out;
  }

  /// The snapshot every device uses for ZIM version [zimUuid]: the earliest created, then the lowest build id.
  PdfSnapshot? snapshotFor(String zimUuid) {
    final all = snapshots().where((s) => s.zimUuid == zimUuid).toList()
      ..sort((a, b) {
        final c = a.created.compareTo(b.created);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    return all.firstOrNull;
  }
}

/// One published snapshot as this device finds it (its manifest.json).
class PdfSnapshot {
  const PdfSnapshot({required this.id, required this.zimUuid, required this.created, required this.pdfs, required this.skipped, this.pieces = 0});

  /// The build id (the folder's name).
  final String id;
  final String? zimUuid;
  final String created;
  final int pdfs;
  final int skipped;
  final int pieces;

  static PdfSnapshot? read(Directory dir) {
    try {
      final f = File('${dir.path}${Platform.pathSeparator}manifest.json');
      if (!f.existsSync()) return null;
      final j = (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();
      for (final e in (j['files'] as List? ?? const [])) {
        final m = (e as Map).cast<String, dynamic>();
        final file = File('${dir.path}${Platform.pathSeparator}${(m['path'] as String).replaceAll('/', Platform.pathSeparator)}');
        if (!file.existsSync() || file.lengthSync() != (m['size'] as num).toInt()) return null;
      }
      return PdfSnapshot(
        id: dir.path.split(RegExp(r'[\\/]')).last,
        zimUuid: j['zim_uuid'] as String?,
        created: (j['created'] as String?) ?? '',
        pdfs: (j['pdfs'] as num?)?.toInt() ?? 0,
        skipped: (j['skipped'] as num?)?.toInt() ?? 0,
        pieces: (j['pieces'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// What a ZIM folder (the `library` shared folder) holds that never syncs, as sync patterns (see DataKind.notShared): the
/// working folders inside a PDF index (`.build/`, and the publish's temporary folder, which the core names with a leading dot).
/// The published snapshots (`snap/<build-id>/`) sync, following the ZIM's own sync choice (the same shared folder).
const List<String> kZimPdfIndexNotShared = ['*.pdfindex/.*'];

/// Where deletes stay on each device (see DataKind.localDeletes): a snapshot each device cleans up for itself is never deleted
/// on another device by sync.
const List<String> kZimPdfIndexLocalDeletes = ['*.pdfindex/snap'];
