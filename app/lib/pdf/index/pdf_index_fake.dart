import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'pdf_index_core.dart';
import 'pdf_pages.dart';

/// One PDF of a [FakeZim]: its pages' text, or a locked or damaged file.
class FakePdf {
  const FakePdf(this.path, {this.title = '', this.pages = const ['Some words on a page.'], this.locked = false, this.damaged = false});

  final String path;
  final String title;
  final List<String> pages;
  final bool locked;
  final bool damaged;

  /// The bytes [FakePdfIndexCore.readEntry] gives and [readFakePdfPages] reads back.
  Uint8List get bytes => Uint8List.fromList(utf8.encode(locked ? 'LOCKED' : (damaged ? 'DAMAGED' : 'FAKEPDF\n${pages.join('\f')}')));
}

class FakeZim {
  const FakeZim({required this.uuid, required this.name, required this.pdfs});

  final String uuid;
  final String name;
  final List<FakePdf> pdfs;
}

/// Reads the pages of a [FakePdf]'s bytes, as readPdfPagesFromBytes reads a real PDF.
Future<PdfPagesOutcome> readFakePdfPages(Uint8List bytes, String name, {PdfPermit? betweenPages, void Function(String step)? onStep}) async {
  onStep?.call('Opening');
  final s = utf8.decode(bytes, allowMalformed: true);
  if (s == 'LOCKED') return const PdfPagesOutcome.locked();
  if (!s.startsWith('FAKEPDF\n')) return const PdfPagesOutcome.damaged();
  final pages = s.substring(8).split('\f');
  // Page by page, as PDFium reads them, waiting for the throttle between pages.
  for (var i = 1; i < pages.length; i++) {
    await betweenPages?.call();
  }
  // A "TITLE:" first line stands for the document's metadata Title.
  if (pages.isNotEmpty && pages.first.startsWith('TITLE:')) {
    final title = pages.first.substring(6).split('\n').first;
    return PdfPagesOutcome.read([pages.first.substring(6 + title.length).trimLeft(), ...pages.skip(1)], title: title);
  }
  return PdfPagesOutcome.read(pages);
}

/// A stand-in for the core's PDF calls that behaves as interface v2.1 says, on real folders: the build is
/// `<indexes_dir>/zim-pdf/<uuid>/.build/`
/// (meta.json, done.tsv and skipped.tsv), adds are committed in batches of [batch] PDFs (and at close), a path is done only
/// after its commit (committed counts added and skipped), the publish writes `.build/publish-<id>/` with pdfs.tsv and
/// manifest.json last and renames it to `snap/<build-id>/`, and a new edition reuses the PDFs of the previous one's snapshot
/// whose bytes are the same. Used by the tests and the renders until the core has the calls; never by a release build.
class FakePdfIndexCore implements PdfIndexCore {
  FakePdfIndexCore({this.zims = const {}, this.finishSteps = 3, this.stepDelay = Duration.zero, this.failAddWith, this.batch = 20});

  /// By ZIM id.
  final Map<String, FakeZim> zims;

  /// Progress steps the publish takes, each [stepDelay] long.
  final int finishSteps;
  final Duration stepDelay;

  /// When set, cs_pdfindex_add fails with it (a full device: FileSystemException with ENOSPC).
  Object? failAddWith;

  /// PDFs a commit holds.
  final int batch;

  /// Calls, for tests: `open`, `add:PATH`, `skip:PATH:REASON`, `commit`, `close`, `discard`, `finish`.
  final List<String> calls = [];

  /// The title each add was given, by path.
  final Map<String, String> titles = {};

  /// The pages each add was given, by path.
  final Map<String, List<Map<String, dynamic>>?> pagesAdded = {};

  final Map<int, _Session> _sessions = {};
  int _next = 1;
  int _builds = 0;

  @override
  bool get available => true;

  @override
  Future<bool> prepare() async => true;

  @override
  Future<ZimPdfList> zimPdfs(String zimId) async {
    final z = zims[zimId] ?? (throw StateError('No such ZIM'));
    return ZimPdfList(zimUuid: z.uuid, zimName: z.name, pdfs: [for (final p in z.pdfs) ZimPdf(path: p.path, title: p.title, size: p.bytes.length)]);
  }

  @override
  Future<Uint8List> readEntry(String address) async {
    final rest = address.replaceFirst('zim:', '');
    final slash = rest.indexOf('/');
    final z = zims.values.firstWhere((z) => z.uuid == rest.substring(0, slash));
    return z.pdfs.firstWhere((p) => p.path == rest.substring(slash + 1)).bytes;
  }

  /// The rule, simply: about 200 words a piece, 40 words of overlap, within a page.
  @override
  Future<PdfChunks> chunk(List<PdfPageText> pages) async {
    final pieces = <Map<String, dynamic>>[];
    final empty = <int>[];
    for (final p in pages) {
      final words = p.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
      if (words.isEmpty) {
        empty.add(p.index);
        continue;
      }
      for (var at = 0; at < words.length; at += 160) {
        final end = (at + 200).clamp(0, words.length);
        pieces.add({'i': pieces.length, 'text': words.sublist(at, end).join(' '), 'page': p.label ?? '${p.index + 1}', 'pdf_page': p.index + 1, 'heading_path': const <String>[]});
        if (end == words.length) break;
      }
    }
    return PdfChunks(pieces: pieces, emptyPages: empty, chunker: 1, pages: [
      for (final p in pages)
        if (p.text.trim().isNotEmpty) {'pdf_page': p.index + 1, 'label': p.label ?? '', 'text': p.text},
    ]);
  }

  @override
  Future<PdfStaging> open({required String indexesDir, required String zimUuid, required String zimName, String? previousZimUuid, String? language}) async {
    calls.add('open');
    final paths = PdfIndexPaths(indexesDir, zimUuid);
    final dir = paths.build;
    final meta = File('${dir.path}/meta.json');
    if (dir.existsSync()) {
      try {
        final m = jsonDecode(meta.readAsStringSync()) as Map;
        if (m['zim_uuid'] != zimUuid) dir.deleteSync(recursive: true);
      } catch (_) {
        dir.deleteSync(recursive: true);
      }
    }
    dir.createSync(recursive: true);
    if (!meta.existsSync()) meta.writeAsStringSync(jsonEncode({'zim_uuid': zimUuid, 'zim_name': zimName}));
    final id = _next++;
    final session = _Session(paths);
    _sessions[id] = session;
    final reusable = <PdfReusable>[];
    if (previousZimUuid != null) {
      final prev = PdfIndexPaths(indexesDir, previousZimUuid);
      final snap = prev.current();
      if (snap != null) {
        for (final l in _lines(File('${prev.snaps.path}/${snap.id}/pdfs.tsv'))) {
          final c = l.split('\t');
          if (c.length >= 5 && c[4] == 'added') {
            reusable.add(PdfReusable(path: c[0], size: int.parse(c[1]), sha256: c[2]));
            session.previous[c[0]] = (c[2], int.parse(c[3]));
          }
        }
      }
    }
    final done = _lines(File('${dir.path}/done.tsv'));
    final skipped = _lines(File('${dir.path}/skipped.tsv'));
    return PdfStaging(
      session: id,
      done: {for (final l in done) l.split('\t').first},
      skipped: {for (final l in skipped) l.split('\t').first},
      pieces: _pieces(dir),
      reusable: reusable,
    );
  }

  static List<String> _lines(File f) => f.existsSync() ? [for (final l in f.readAsLinesSync()) if (l.isNotEmpty) l] : const [];

  static int _pieces(Directory dir) => _lines(File('${dir.path}/done.tsv')).fold(0, (s, l) => s + (int.tryParse(l.split('\t').last) ?? 0));

  _Session _session(int id) => _sessions[id] ?? (throw StateError('Session closed'));

  void _commit(_Session s) {
    if (s.pending.isEmpty && s.pendingSkips.isEmpty) return;
    calls.add('commit');
    final dir = s.paths.build;
    File('${dir.path}/done.tsv').writeAsStringSync(s.pending.map((l) => '$l\n').join(), mode: FileMode.append, flush: true);
    File('${dir.path}/skipped.tsv').writeAsStringSync(s.pendingSkips.map((l) => '$l\n').join(), mode: FileMode.append, flush: true);
    s.pending.clear();
    s.pendingSkips.clear();
  }

  @override
  Future<PdfAdded> add(int session, {required String path, required String title, required List<Map<String, dynamic>> pieces, List<Map<String, dynamic>>? pages, int? size, String? sha256}) async {
    calls.add('add:$path');
    titles[path] = title;
    pagesAdded[path] = pages;
    final err = failAddWith;
    if (err != null) throw err;
    for (final p in pieces) {
      if (p['text'] is! String || p.containsKey('vector')) throw ArgumentError('A piece is text only');
    }
    final s = _session(session);
    s.pending.add('$path\t${pieces.length}');
    s.since++;
    if (s.since >= batch) {
      s.since = 0;
      _commit(s);
    }
    return _added(s);
  }

  PdfAdded _added(_Session s) {
    final dir = s.paths.build;
    final pending = s.pending.fold(0, (n, l) => n + (int.tryParse(l.split('\t').last) ?? 0));
    return PdfAdded(pieces: _pieces(dir) + pending, committed: _lines(File('${dir.path}/done.tsv')).length + _lines(File('${dir.path}/skipped.tsv')).length);
  }

  @override
  Future<PdfReused> reuse(int session, {required String path, required String sha256}) async {
    calls.add('reuse:$path');
    final s = _session(session);
    final prev = s.previous[path];
    if (prev == null || prev.$1 != sha256) return const PdfReused(reused: false);
    s.pending.add('$path\t${prev.$2}');
    s.since++;
    if (s.since >= batch) {
      s.since = 0;
      _commit(s);
    }
    return PdfReused(reused: true, pieces: prev.$2);
  }

  /// The size and sha256 of a PDF of the ZIM [uuid], for pdfs.tsv.
  (int, String)? _fileOf(String uuid, String path) {
    for (final z in zims.values) {
      if (z.uuid != uuid) continue;
      for (final p in z.pdfs) {
        if (p.path == path) return (p.bytes.length, sha256.convert(p.bytes).toString());
      }
    }
    return null;
  }

  @override
  Future<void> skip(int session, {required String path, required PdfSkipReason reason, int? size, String? sha256}) async {
    calls.add('skip:$path:${reason.code}');
    _session(session).pendingSkips.add('$path\t${reason.code}');
  }

  @override
  Future<void> close(int session) async {
    final s = _sessions.remove(session);
    if (s != null) _commit(s);
    calls.add('close');
  }

  /// A kill: the session goes without its last commit.
  void kill(int session) => _sessions.remove(session);

  @override
  Future<void> discard({required String indexesDir, required String zimUuid}) async {
    calls.add('discard');
    final d = PdfIndexPaths(indexesDir, zimUuid).build;
    if (d.existsSync()) d.deleteSync(recursive: true);
  }

  @override
  Future<PdfFinishJob> finish({required String indexesDir, required String zimUuid}) async {
    calls.add('finish');
    return _FakeFinish(this, PdfIndexPaths(indexesDir, zimUuid), 'b${DateTime.now().microsecondsSinceEpoch}-${_builds++}');
  }
}

class _Session {
  _Session(this.paths);

  final PdfIndexPaths paths;
  final List<String> pending = [];
  final List<String> pendingSkips = [];
  int since = 0;

  /// The previous edition's PDFs: path to (sha256, pieces).
  final Map<String, (String, int)> previous = {};
}

class _FakeFinish implements PdfFinishJob {
  _FakeFinish(this.core, this.paths, this.buildId) {
    unawaited(_run());
  }

  final FakePdfIndexCore core;
  final PdfIndexPaths paths;
  final String buildId;
  PdfFinishProgress _p = const PdfFinishProgress(state: PdfFinishState.running, phase: 'merge');
  bool _cancel = false;

  Future<void> _run() async {
    try {
      for (var i = 0; i < core.finishSteps; i++) {
        if (_cancel) {
          _p = const PdfFinishProgress(state: PdfFinishState.cancelled);
          return;
        }
        final phase = i == core.finishSteps - 1 ? 'publish' : (i == 0 ? 'merge' : 'manifest');
        _p = PdfFinishProgress(state: PdfFinishState.running, phase: phase, done: i, total: core.finishSteps);
        await Future<void>.delayed(core.stepDelay);
      }
      final build = paths.build;
      final meta = (jsonDecode(File('${build.path}/meta.json').readAsStringSync()) as Map).cast<String, dynamic>();
      final done = FakePdfIndexCore._lines(File('${build.path}/done.tsv'));
      final skipped = FakePdfIndexCore._lines(File('${build.path}/skipped.tsv'));
      final pieces = done.fold(0, (s, l) => s + (int.tryParse(l.split('\t').last) ?? 0));
      final tmp = Directory('${build.path}/publish-$buildId')..createSync(recursive: true);
      final rows = StringBuffer();
      for (final l in done) {
        final c = l.split('\t');
        final f = core._fileOf(paths.zimUuid, c[0]);
        rows.writeln([c[0], f?.$1 ?? 0, f?.$2 ?? '', c.last, 'added'].join('\t'));
      }
      for (final l in skipped) {
        final c = l.split('\t');
        final f = core._fileOf(paths.zimUuid, c[0]);
        rows.writeln([c[0], f?.$1 ?? 0, f?.$2 ?? '', 0, 'skipped:${c.last}'].join('\t'));
      }
      File('${tmp.path}/pdfs.tsv').writeAsStringSync(rows.toString());
      final seg = File('${tmp.path}/segment.bin')..writeAsStringSync(done.join('\n'));
      final segBytes = seg.lengthSync();
      File('${tmp.path}/manifest.json').writeAsStringSync(jsonEncode({
        'kind': 'zim-pdf',
        'zim_uuid': meta['zim_uuid'],
        'zim_name': meta['zim_name'],
        'format': kPdfIndexFormat,
        'chunker': 1,
        'created': DateTime.now().toUtc().toIso8601String(),
        'pdfs': done.length,
        'pieces': pieces,
        'skipped': skipped.length,
        'files': [
          {'path': 'segment.bin', 'size': segBytes, 'sha256': 'fake'},
          {'path': 'pdfs.tsv', 'size': File('${tmp.path}/pdfs.tsv').lengthSync(), 'sha256': 'fake'},
        ],
      }));
      paths.snaps.createSync(recursive: true);
      tmp.renameSync('${paths.snaps.path}/$buildId');
      build.deleteSync(recursive: true);
      _p = PdfFinishProgress(
        state: PdfFinishState.done,
        phase: 'publish',
        done: core.finishSteps,
        total: core.finishSteps,
        result: {'pdfs': done.length, 'pieces': pieces, 'skipped': skipped.length, 'bytes': segBytes, 'snapshot': buildId},
      );
    } catch (e) {
      _p = PdfFinishProgress(state: PdfFinishState.failed, error: '$e');
    }
  }

  @override
  Future<PdfFinishProgress> progress() async => _p;

  @override
  Future<void> cancel() async {
    if (_p.cancellable) _cancel = true;
  }

  @override
  Future<void> free() async {}
}
