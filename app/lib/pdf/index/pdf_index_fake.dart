import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  /// The bytes [readEntry] gives and [readFakePdfPages] reads back.
  Uint8List get bytes => Uint8List.fromList(utf8.encode(locked ? 'LOCKED' : (damaged ? 'DAMAGED' : 'FAKEPDF\n${pages.join('\f')}')));
}

class FakeZim {
  const FakeZim({required this.uuid, required this.name, required this.pdfs});

  final String uuid;
  final String name;
  final List<FakePdf> pdfs;
}

/// Reads the pages of a [FakePdf]'s bytes, as [readPdfPages] reads a real PDF.
Future<PdfPagesOutcome> readFakePdfPages(Uint8List bytes, String name) async {
  final s = utf8.decode(bytes, allowMalformed: true);
  if (s == 'LOCKED') return const PdfPagesOutcome.locked();
  if (!s.startsWith('FAKEPDF\n')) return const PdfPagesOutcome.damaged();
  return PdfPagesOutcome.read(s.substring(8).split('\f'));
}

/// A stand-in for the core's PDF calls that behaves as interface v1 says, on real folders: the staging is
/// `<name>.pdfindex.partial/` with done.tsv and skipped.tsv, and the publish writes `<name>.pdfindex.tmp/` and renames it to
/// `<name>.pdfindex/` (cache-library.json, documents.tsv, skipped.tsv, SHA256SUMS). Used by the tests and the renders until the
/// core has the calls, and by nothing in a release build.
class FakePdfIndexCore implements PdfIndexCore {
  FakePdfIndexCore({this.zims = const {}, this.finishSteps = 3, this.stepDelay = Duration.zero, this.failAddWith, this.vectors = true});

  /// Every piece must carry a vector (v1); false for a keyword-only index.
  final bool vectors;

  /// By ZIM id.
  final Map<String, FakeZim> zims;

  /// Progress steps the publish takes, each [stepDelay] long.
  final int finishSteps;
  final Duration stepDelay;

  /// When set, cs_pdfindex_add fails with it (a full device: FileSystemException with ENOSPC).
  Object? failAddWith;

  /// Calls, for tests: `open`, `add:PATH`, `skip:PATH:REASON`, `close`, `discard`, `finish`.
  final List<String> calls = [];

  final Map<int, ({String zimPath, String uuid, String model})> _sessions = {};
  int _next = 1;

  @override
  bool get available => true;

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

  /// The v1 rule, simply: about 200 words a piece, at most 300, 40 words of overlap, within a page.
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
    return PdfChunks(pieces: pieces, emptyPages: empty);
  }

  @override
  Future<PdfStaging> open({required String zimPath, required String zimUuid, required String zimName, required String model}) async {
    calls.add('open');
    final dir = PdfIndexPaths(zimPath).partial;
    final meta = File('${dir.path}/meta.json');
    if (dir.existsSync()) {
      try {
        final m = jsonDecode(meta.readAsStringSync()) as Map;
        if (m['zim_uuid'] != zimUuid || m['model'] != model) dir.deleteSync(recursive: true);
      } catch (_) {
        dir.deleteSync(recursive: true);
      }
    }
    dir.createSync(recursive: true);
    if (!meta.existsSync()) meta.writeAsStringSync(jsonEncode({'zim_uuid': zimUuid, 'model': model}));
    final id = _next++;
    _sessions[id] = (zimPath: zimPath, uuid: zimUuid, model: model);
    final done = _lines(File('${dir.path}/done.tsv'));
    final skipped = _lines(File('${dir.path}/skipped.tsv'));
    return PdfStaging(session: id, done: {for (final l in done) l.split('\t').first}, skipped: {for (final l in skipped) l.split('\t').first}, pieces: _pieces(dir));
  }

  static List<String> _lines(File f) => f.existsSync() ? [for (final l in f.readAsLinesSync()) if (l.isNotEmpty) l] : const [];

  static int _pieces(Directory dir) => _lines(File('${dir.path}/done.tsv')).fold(0, (s, l) => s + (int.tryParse(l.split('\t').last) ?? 0));

  Directory _dir(int session) => PdfIndexPaths((_sessions[session] ?? (throw StateError('Session closed'))).zimPath).partial;

  @override
  Future<int> add(int session, {required String path, required String title, required List<Map<String, dynamic>> pieces}) async {
    calls.add('add:$path');
    final err = failAddWith;
    if (err != null) throw err;
    for (final p in pieces) {
      final v = p['vector'];
      if (vectors && (v is! List || v.isEmpty)) throw ArgumentError('A piece has no vector');
    }
    final dir = _dir(session);
    File('${dir.path}/done.tsv').writeAsStringSync('$path\t${pieces.length}\n', mode: FileMode.append, flush: true);
    return _pieces(dir);
  }

  @override
  Future<void> skip(int session, {required String path, required PdfSkipReason reason}) async {
    calls.add('skip:$path:${reason.code}');
    File('${_dir(session).path}/skipped.tsv').writeAsStringSync('$path\t${reason.code}\n', mode: FileMode.append, flush: true);
  }

  @override
  Future<void> close(int session) async {
    calls.add('close');
    _sessions.remove(session);
  }

  @override
  Future<void> discard(String zimPath) async {
    calls.add('discard');
    final d = PdfIndexPaths(zimPath).partial;
    if (d.existsSync()) d.deleteSync(recursive: true);
  }

  @override
  Future<PdfFinishJob> finish(String zimPath) async {
    calls.add('finish');
    return _FakeFinish(this, PdfIndexPaths(zimPath));
  }
}

class _FakeFinish implements PdfFinishJob {
  _FakeFinish(this.core, this.paths) {
    unawaited(_run());
  }

  final FakePdfIndexCore core;
  final PdfIndexPaths paths;
  PdfFinishProgress _p = const PdfFinishProgress(state: PdfFinishState.running, phase: 'optimize');
  bool _cancel = false;

  Future<void> _run() async {
    try {
      for (var i = 0; i < core.finishSteps; i++) {
        if (_cancel) {
          _p = const PdfFinishProgress(state: PdfFinishState.cancelled);
          return;
        }
        _p = PdfFinishProgress(state: PdfFinishState.running, phase: i == core.finishSteps - 1 ? 'publish' : 'optimize', done: i, total: core.finishSteps);
        await Future<void>.delayed(core.stepDelay);
      }
      final part = paths.partial;
      final meta = (jsonDecode(File('${part.path}/meta.json').readAsStringSync()) as Map).cast<String, dynamic>();
      final done = FakePdfIndexCore._lines(File('${part.path}/done.tsv'));
      final skipped = FakePdfIndexCore._lines(File('${part.path}/skipped.tsv'));
      final tmp = paths.tmp;
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      tmp.createSync(recursive: true);
      File('${tmp.path}/cache-library.json').writeAsStringSync(jsonEncode({'zim_uuid': meta['zim_uuid'], 'model': meta['model'], 'pdfs': done.length, 'skipped': skipped.length}));
      File('${tmp.path}/documents.tsv').writeAsStringSync(done.map((l) => '$l\n').join());
      File('${tmp.path}/skipped.tsv').writeAsStringSync(skipped.map((l) => '$l\n').join());
      File('${tmp.path}/SHA256SUMS').writeAsStringSync('fake ${DateTime.now().microsecondsSinceEpoch}\n');
      if (paths.index.existsSync()) paths.index.deleteSync(recursive: true);
      tmp.renameSync(paths.index.path);
      part.deleteSync(recursive: true);
      final pieces = done.fold(0, (s, l) => s + (int.tryParse(l.split('\t').last) ?? 0));
      _p = PdfFinishProgress(
        state: PdfFinishState.done,
        phase: 'publish',
        done: core.finishSteps,
        total: core.finishSteps,
        result: {'pdfs': done.length, 'pieces': pieces, 'skipped': skipped.length, 'bytes': 0},
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
