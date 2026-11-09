import 'dart:typed_data';

import 'package:test/test.dart';

import '../../../app/lib/pdf/index/pdf_chunk.dart';
import '../../../app/lib/pdf/index/pdf_index_core.dart';
import '../bin/pdf_zim_indexer.dart';

/// A stand-in for the core's PDF index calls that records what the run asked of it.
class FakeCore implements PdfIndexCore {
  final List<String> calls = [];
  final Map<String, Uint8List> entries = {};
  final Set<String> failRead = {};
  Set<String> doneBefore = {};
  List<PdfReusable> reusable = [];
  Set<String> reusableHit = {};
  String? previous;
  List<Map<String, dynamic>> added = [];
  Map<String, dynamic>? addedPages;
  String? addedTitle;
  PdfFinishState finish = PdfFinishState.done;
  void Function()? onAdd;

  @override
  bool get available => true;
  @override
  Future<bool> prepare() async => true;
  @override
  Future<ZimPdfList> zimPdfs(String zimId) async => throw UnimplementedError();
  @override
  Future<Uint8List> readEntry(String address) async {
    calls.add('read:$address');
    if (failRead.contains(address)) throw StateError('unreadable');
    return entries[address] ?? Uint8List(0);
  }

  // The same rule the app falls back to, so the pieces are real.
  @override
  Future<PdfChunks> chunk(List<PdfPageText> pages) async => chunkPdfPages(pages);
  @override
  Future<PdfStaging> open({required String indexesDir, required String zimUuid, required String zimName, String? previousZimUuid, String? language}) async {
    calls.add('open:$indexesDir:$zimUuid:$zimName:${previousZimUuid ?? '-'}:${language ?? '-'}');
    return PdfStaging(session: 5, done: doneBefore, reusable: reusable);
  }

  @override
  Future<PdfReused> reuse(int session, {required String path, required String sha256}) async {
    calls.add('reuse:$path:$sha256');
    return PdfReused(reused: reusableHit.contains(path), pieces: 3);
  }

  @override
  Future<PdfAdded> add(int session, {required String path, required String title, required List<Map<String, dynamic>> pieces, List<Map<String, dynamic>>? pages, int? size, String? sha256}) async {
    calls.add('add:$path:$title:${pieces.length}:${pages?.length}:$size:$sha256');
    onAdd?.call();
    return PdfAdded(pieces: pieces.length, committed: 1);
  }

  @override
  Future<void> skip(int session, {required String path, required PdfSkipReason reason, int? size, String? sha256}) async => calls.add('skip:$path:${reason.code}:$size:$sha256');
  @override
  Future<void> close(int session) async => calls.add('close:$session');
  @override
  Future<void> discard({required String indexesDir, required String zimUuid}) async => calls.add('discard');
  @override
  Future<PdfFinishJob> finish({required String indexesDir, required String zimUuid}) async {
    calls.add('finish:$indexesDir:$zimUuid');
    return _Job(finish);
  }
}

class _Job implements PdfFinishJob {
  _Job(this.state);
  final PdfFinishState state;
  @override
  Future<PdfFinishProgress> progress() async => PdfFinishProgress(state: state, result: {'pdfs': 1}, error: state == PdfFinishState.failed ? 'no room' : null);
  @override
  Future<void> cancel() async {}
  @override
  Future<void> free() async {}
}

ZimPdfList _list(List<String> paths, {String name = 'wiki'}) => ZimPdfList(zimUuid: 'u1', zimName: name, pdfs: [for (final p in paths) ZimPdf(path: p, title: '', size: 100)]);

String _words(int n) => List.generate(n, (i) => 'w$i').join(' ');

void main() {
  late FakeCore core;
  late Map<int, PdfTextResult> byLength;

  setUp(() {
    core = FakeCore();
    byLength = {};
  });

  // The reader answers by the PDF's size, so each PDF's entry bytes pick what "MuPDF" gave.
  Future<PdfTextResult> read(Uint8List b, {required bool hashOnly}) async {
    final r = byLength[b.length] ?? const PdfTextResult.damaged();
    return hashOnly ? PdfTextResult(status: 'ok', size: b.length, sha256: r.sha256) : r;
  }

  ZimPdfIndexer indexer({Future<void> Function()? permit}) => ZimPdfIndexer(core: core, read: read, indexesDir: '/idx', permit: permit);

  test('each PDF is read, chunked by the core rule and added with its cleaned title, page labels and hash; then the index is published', () async {
    core.entries['zim:u1/a.pdf'] = Uint8List(10);
    byLength[10] = PdfTextResult(status: 'ok', size: 10, sha256: 'aa', title: 'Microsoft Word - a.doc', labels: const ['i', '2'], pages: [_words(250), _words(10)]);
    core.entries['zim:u1/b.pdf'] = Uint8List(11);
    byLength[11] = const PdfTextResult(status: 'ok', size: 11, sha256: 'bb', title: ' Food  and Water ', labels: ['1'], pages: ['some text here']);
    final ix = indexer();
    expect(await ix.run(_list(['a.pdf', 'b.pdf'])), ZimPdfEnd.finished);
    expect(core.calls.first, 'open:/idx:u1:wiki:-:-');
    // 260 words make two pieces (200 with 40 overlap, then the rest); the title that is a file name is dropped
    expect(core.calls, contains('add:a.pdf::2:2:10:aa'));
    expect(core.calls, contains('add:b.pdf:Food and Water:1:1:11:bb'));
    expect(core.calls.indexOf('close:5'), lessThan(core.calls.indexWhere((c) => c.startsWith('finish:'))));
    expect(ix.done, 2);
    expect(ix.skipped, 0);
    expect(ix.result, {'pdfs': 1});
  });

  test('a PDF with no text, a locked one, a damaged one and an entry that cannot be read are skipped, and the run goes on', () async {
    core.entries['zim:u1/none.pdf'] = Uint8List(1);
    byLength[1] = const PdfTextResult(status: 'ok', size: 1, sha256: 'h1', pages: ['  ', '']);
    core.entries['zim:u1/locked.pdf'] = Uint8List(2);
    byLength[2] = const PdfTextResult(status: 'locked', size: 2, sha256: 'h2');
    core.entries['zim:u1/bad.pdf'] = Uint8List(3);
    byLength[3] = const PdfTextResult.damaged(size: 3, sha256: 'h3');
    core.failRead.add('zim:u1/gone.pdf');
    core.entries['zim:u1/ok.pdf'] = Uint8List(4);
    byLength[4] = const PdfTextResult(status: 'ok', size: 4, sha256: 'h4', pages: ['hello world']);
    final ix = indexer();
    expect(await ix.run(_list(['none.pdf', 'locked.pdf', 'bad.pdf', 'gone.pdf', 'ok.pdf'])), ZimPdfEnd.finished);
    expect(core.calls, containsAll(['skip:none.pdf:no_text:1:h1', 'skip:locked.pdf:locked:2:h2', 'skip:bad.pdf:damaged:3:h3', 'skip:gone.pdf:damaged:null:null']));
    expect(core.calls.where((c) => c.startsWith('add:')), hasLength(1));
    expect(ix.skipped, 4);
    expect(ix.done, 1);
  });

  test('PDFs an earlier run finished are not read again', () async {
    core.doneBefore = {'a.pdf'};
    core.entries['zim:u1/b.pdf'] = Uint8List(4);
    byLength[4] = const PdfTextResult(status: 'ok', size: 4, sha256: 'h', pages: ['hello world']);
    final ix = indexer();
    await ix.run(_list(['a.pdf', 'b.pdf']));
    expect(core.calls.where((c) => c.startsWith('read:')), ['read:zim:u1/b.pdf']);
    expect(ix.done, 2);
  });

  test('a PDF the older edition has at the same size is taken from it when its bytes are the same, else read as usual', () async {
    core.reusable = const [PdfReusable(path: 'same.pdf', size: 100, sha256: 'x'), PdfReusable(path: 'changed.pdf', size: 100, sha256: 'y')];
    core.reusableHit = {'same.pdf'};
    core.entries['zim:u1/same.pdf'] = Uint8List(100);
    core.entries['zim:u1/changed.pdf'] = Uint8List(100);
    byLength[100] = const PdfTextResult(status: 'ok', size: 100, sha256: 'hash100', pages: ['hello world']);
    final ix = indexer();
    await ix.run(_list(['same.pdf', 'changed.pdf']));
    expect(core.calls, contains('reuse:same.pdf:hash100'));
    expect(core.calls.where((c) => c.startsWith('add:')), ['add:changed.pdf::1:1:100:hash100']);
    expect(ix.reused, 1);
    expect(ix.done, 2);
  });

  test('cancel stops before the next PDF, closes the session and keeps the build (no finish, no discard)', () async {
    core.entries['zim:u1/a.pdf'] = Uint8List(4);
    core.entries['zim:u1/b.pdf'] = Uint8List(4);
    byLength[4] = const PdfTextResult(status: 'ok', size: 4, sha256: 'h', pages: ['hello world']);
    final ix = indexer();
    core.onAdd = ix.cancel;
    expect(await ix.run(_list(['a.pdf', 'b.pdf'])), ZimPdfEnd.paused);
    expect(core.calls.where((c) => c.startsWith('add:')), hasLength(1));
    expect(core.calls, contains('close:5'));
    expect(core.calls.any((c) => c.startsWith('finish:') || c == 'discard'), isFalse);
  });

  test('the permit is awaited before each PDF', () async {
    var n = 0;
    core.entries['zim:u1/a.pdf'] = Uint8List(4);
    core.entries['zim:u1/b.pdf'] = Uint8List(4);
    byLength[4] = const PdfTextResult(status: 'ok', size: 4, sha256: 'h', pages: ['hello world']);
    await indexer(permit: () async => n++).run(_list(['a.pdf', 'b.pdf']));
    expect(n, 2);
  });

  test('a publish that fails fails the run with its reason; the build stays', () async {
    core.finish = PdfFinishState.failed;
    core.entries['zim:u1/a.pdf'] = Uint8List(4);
    byLength[4] = const PdfTextResult(status: 'ok', size: 4, sha256: 'h', pages: ['hello world']);
    final ix = indexer();
    expect(await ix.run(_list(['a.pdf'])), ZimPdfEnd.failed);
    expect(ix.error, 'no room');
    expect(core.calls, isNot(contains('discard')));
  });

  test('the results of the child are read: pages, labels, title and the hash', () {
    final r = PdfTextResult.fromJson({'status': 'ok', 'size': 5, 'sha256': 'ab', 'title': 'T', 'labels': ['1', 'ii'], 'pages': ['x', 'y']});
    expect(r.pages, ['x', 'y']);
    expect(r.labels, ['1', 'ii']);
    expect(r.damaged, isFalse);
    expect(PdfTextResult.fromJson({'status': 'locked'}).locked, isTrue);
    expect(PdfTextResult.fromJson({'status': 'nonsense'}).damaged, isTrue);
  });
}
