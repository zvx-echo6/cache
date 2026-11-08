import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The search core's calls for making a ZIM's PDFs searchable on this device (interface v2.1, 2026-11-02): a keyword index, like
/// all other ZIM content (no vectors, no search model). The app drives the loop (it has pdfrx); the core lists the PDFs, chunks
/// the pages (the one cache_chunk the server and the builder share), owns the resumable build in
/// `<indexes_dir>/zim-pdf/<zim uuid>/.build/` and publishes each finished index as an immutable snapshot,
/// `<indexes_dir>/zim-pdf/<zim uuid>/snap/<build-id>/`. The indexes folder is one per device and syncs on its own (the always-on
/// "indexes" share), to every linked device that has the same ZIM.
///
/// The core-pdf binding implements this once the calls are in the core; until then the app runs on [PdfIndexCoreMissing] (the
/// feature is not offered) and the tests and renders on FakePdfIndexCore.
abstract class PdfIndexCore {
  /// False while the core has none of these calls: nothing about PDF indexing is shown.
  bool get available;

  /// Waits until [available] is known (the search core has opened), and says it.
  Future<bool> prepare();

  /// The ZIM's PDF entries (cs_zim_pdfs): mime application/pdf, redirects resolved, no duplicates.
  Future<ZimPdfList> zimPdfs(String zimId);

  /// An entry's bytes, by its `zim:<uuid>/<path>` address (the zim entry read the PDF reader uses, cs_zim_get).
  Future<Uint8List> readEntry(String address);

  /// The pieces of one PDF's pages (cs_pdf_chunk): about 200 words, never across a heading.
  Future<PdfChunks> chunk(List<PdfPageText> pages);

  /// Opens or creates the ZIM's build, `zim-pdf/<zim uuid>/.build/` (cs_pdfindex_open). A build for another format or chunker is
  /// discarded by the core and started again. [previousZimUuid] is an older edition of the same ZIM (the same zim_name) whose
  /// snapshot's PDFs may be reused: the answer lists them ([PdfStaging.reusable]).
  Future<PdfStaging> open({required String indexesDir, required String zimUuid, required String zimName, String? previousZimUuid, String? language});

  /// Takes a PDF's pieces from the previous edition's snapshot when its bytes are the same (cs_pdfindex_reuse, with the sha256 of
  /// the bytes read): reused, or not (then it is extracted as usual).
  Future<PdfReused> reuse(int session, {required String path, required String sha256});

  /// Adds one PDF's text pieces, replacing any it had (cs_pdfindex_add), with the size and sha256 of its bytes (recorded in the
  /// snapshot's pdfs.tsv, for the next edition's reuse). Durable in batches: the core commits about every 20
  /// PDFs or 30 seconds and lists a path as done only after the commit that holds it.
  Future<PdfAdded> add(int session, {required String path, required String title, required List<Map<String, dynamic>> pieces, List<Map<String, dynamic>>? pages, int? size, String? sha256});

  /// Marks a PDF that has nothing to index (cs_pdfindex_skip).
  Future<void> skip(int session, {required String path, required PdfSkipReason reason, int? size, String? sha256});

  /// Commits and closes the session; the build stays for a resume (cs_pdfindex_close).
  Future<void> close(int session);

  /// Deletes the build (cs_pdfindex_discard).
  Future<void> discard({required String indexesDir, required String zimUuid});

  /// Starts the publish job (cs_job_start "pdfindex_finish" with indexes_dir and zim_uuid): merge, manifest, then one rename to
  /// `snap/<build-id>/`.
  Future<PdfFinishJob> finish({required String indexesDir, required String zimUuid});
}

/// What cs_pdfindex_reuse answers.
class PdfReused {
  const PdfReused({required this.reused, this.pieces = 0});

  factory PdfReused.fromJson(Map<String, dynamic> j) => PdfReused(reused: j['reused'] == true, pieces: (j['pieces'] as num?)?.toInt() ?? 0);

  final bool reused;
  final int pieces;
}

/// A PDF the previous edition's snapshot holds (cs_pdfindex_open's "reusable").
class PdfReusable {
  const PdfReusable({required this.path, required this.size, required this.sha256});

  factory PdfReusable.fromJson(Map<String, dynamic> j) =>
      PdfReusable(path: j['path'] as String, size: (j['size'] as num?)?.toInt() ?? -1, sha256: (j['sha256'] as String?) ?? '');

  final String path;
  final int size;
  final String sha256;
}

/// What cs_pdfindex_add answers: pieces in the build so far, and PDFs committed, added and skipped (a kill redoes the ones after
/// that).
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

  Map<String, dynamic> toJson() => {'path': path, 'title': title, 'size': size};

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

  /// As cs_zim_pdfs answers it (the app keeps it per ZIM uuid).
  Map<String, dynamic> toJson() => {'zim_uuid': zimUuid, 'zim_name': zimName, 'pdfs': [for (final p in pdfs) p.toJson()]};

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
  const PdfChunks({required this.pieces, this.emptyPages = const [], this.chunker, this.pages});

  factory PdfChunks.fromJson(Map<String, dynamic> j) => PdfChunks(
    pieces: [for (final p in (j['pieces'] as List? ?? const [])) (p as Map).cast<String, dynamic>()],
    emptyPages: [for (final i in (j['empty_pages'] as List? ?? const [])) (i as num).toInt()],
    chunker: j['chunker'],
    pages: j['pages'] is List ? [for (final p in j['pages'] as List) (p as Map).cast<String, dynamic>()] : null,
  );

  final List<Map<String, dynamic>> pieces;
  final List<int> emptyPages;

  /// The chunker's version (the build is started again when it changes).
  final Object? chunker;

  /// The pages with text, {"pdf_page","label","text"}, handed to cs_pdfindex_add as they are (a citation then lands on its page
  /// and read gives the whole page); null from a chunker that does not give them.
  final List<Map<String, dynamic>>? pages;
}

/// What cs_pdfindex_open answers: the session and what an earlier run already finished.
class PdfStaging {
  const PdfStaging({required this.session, this.done = const {}, this.skipped = const {}, this.pieces = 0, this.reusable = const []});

  factory PdfStaging.fromJson(Map<String, dynamic> j) => PdfStaging(
    session: (j['session'] as num).toInt(),
    done: {for (final p in (j['done'] as List? ?? const [])) p as String},
    // The core lists skipped PDFs as {"path","reason"}; a plain path is read too.
    skipped: {for (final p in (j['skipped'] as List? ?? const [])) p is Map ? p['path'] as String : p as String},
    pieces: (j['pieces'] as num?)?.toInt() ?? 0,
    reusable: [for (final r in (j['reusable'] as List? ?? const [])) PdfReusable.fromJson((r as Map).cast<String, dynamic>())],
  );

  final int session;
  final Set<String> done;
  final Set<String> skipped;
  final int pieces;

  /// The previous edition's PDFs that may be reused (asked for with "previous").
  final List<PdfReusable> reusable;
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
  Future<bool> prepare() async => false;
  @override
  Future<ZimPdfList> zimPdfs(String zimId) async => _no();
  @override
  Future<Uint8List> readEntry(String address) async => _no();
  @override
  Future<PdfChunks> chunk(List<PdfPageText> pages) async => _no();
  @override
  Future<PdfStaging> open({required String indexesDir, required String zimUuid, required String zimName, String? previousZimUuid, String? language}) async => _no();
  @override
  Future<PdfReused> reuse(int session, {required String path, required String sha256}) async => _no();
  @override
  Future<PdfAdded> add(int session, {required String path, required String title, required List<Map<String, dynamic>> pieces, List<Map<String, dynamic>>? pages, int? size, String? sha256}) async => _no();
  @override
  Future<void> skip(int session, {required String path, required PdfSkipReason reason, int? size, String? sha256}) async => _no();
  @override
  Future<void> close(int session) async {}
  @override
  Future<void> discard({required String indexesDir, required String zimUuid}) async => _no();
  @override
  Future<PdfFinishJob> finish({required String indexesDir, required String zimUuid}) async => _no();
}

/// The folders of one ZIM's PDF index in the device's indexes folder: `zim-pdf/<zim uuid>/` holding `.build/` (this device's
/// resumable build, never synced) and `snap/<build-id>/` (published snapshots, which sync).
class PdfIndexPaths {
  PdfIndexPaths(this.indexesDir, this.zimUuid);

  final String indexesDir;
  final String zimUuid;

  static String get _sep => Platform.pathSeparator;

  Directory get root => Directory('$indexesDir${_sep}zim-pdf$_sep$zimUuid');
  Directory get build => Directory('${root.path}$_sep.build');
  Directory get snaps => Directory('${root.path}${_sep}snap');

  /// Removes it all on this device (the ZIM is gone; a snapshot delete never syncs).
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
        if (s != null && (s.zimUuid == null || s.zimUuid == zimUuid)) out.add(s);
      }
    } catch (_) {}
    return out;
  }

  /// The snapshot every device uses: the earliest created, then the lowest build id.
  PdfSnapshot? current() {
    final all = snapshots()
      ..sort((a, b) {
        final c = a.created.compareTo(b.created);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    return all.firstOrNull;
  }
}

/// Every ZIM uuid with a PDF index folder in [indexesDir].
List<String> pdfIndexUuids(String indexesDir) {
  try {
    final d = Directory('$indexesDir${Platform.pathSeparator}zim-pdf');
    if (!d.existsSync()) return const [];
    return [for (final e in d.listSync().whereType<Directory>()) e.path.split(RegExp(r'[\\/]')).last];
  } catch (_) {
    return const [];
  }
}

/// The zim-pdf snapshot format this version reads (the core's pdfindex.rs FORMAT). A snapshot of another format is not one here:
/// the ZIM's PDFs are made searchable again, without a word about the old one.
const int kPdfIndexFormat = 2;

/// One published snapshot as this device finds it (its manifest.json).
class PdfSnapshot {
  const PdfSnapshot({required this.id, required this.zimUuid, required this.created, required this.pdfs, required this.skipped, this.pieces = 0, this.zimName});

  /// The build id (the folder's name).
  final String id;
  final String? zimUuid;
  final String created;
  final int pdfs;
  final int skipped;
  final int pieces;

  /// The ZIM's metadata Name, the same for every edition (a new edition reuses an older one's PDFs).
  final String? zimName;

  static PdfSnapshot? read(Directory dir) {
    try {
      final f = File('${dir.path}${Platform.pathSeparator}manifest.json');
      if (!f.existsSync()) return null;
      final j = (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();
      if ((j['format'] as num?)?.toInt() != kPdfIndexFormat) return null;
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
        zimName: j['zim_name'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
