import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../../../app/lib/pdf/index/pdf_index_core.dart';
import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../bin/core_open.dart';
import '../bin/host_load.dart';
import '../bin/index_driver.dart';
import '../bin/pdf_zim_indexer.dart';
import 'fake_native.dart';

Map<String, dynamic> _src(String name) => {'kind': 'zim', 'path': '/docs/$name', 'index_dir': '/idx/$name'};

Map<String, dynamic> _st(String name, {Map<String, dynamic>? index, Map<String, dynamic>? epub, Map<String, dynamic>? captions, Map<String, dynamic>? pdf}) => {
      'id': 'id-$name',
      'kind': 'zim',
      'path': '/docs/$name',
      'title': name,
      'indexed': true,
      'building': false,
      'stale': false,
      'opening': false,
      'updating': false,
      'docs': 1,
      'source_id': 'sid-$name',
      'index': index,
      'epubindex': epub,
      'captionsindex': captions,
      'pdfindex': pdf,
      'error': null,
    };

const _done = '{"state":"done","done":4,"total":4}';

/// The core's PDF calls for the driver: one PDF, listed by [zimPdfs].
class _PdfCore implements PdfIndexCore {
  final List<String> calls = [];
  bool has = true;

  @override
  bool get available => has;
  @override
  Future<bool> prepare() async => has;
  @override
  Future<ZimPdfList> zimPdfs(String zimId) async {
    calls.add('list:$zimId');
    return ZimPdfList(zimUuid: zimId, zimName: 'n', pdfs: zimId == 'id-none.zim' ? const [] : const [ZimPdf(path: 'a.pdf', title: '', size: 4)]);
  }

  @override
  Future<Uint8List> readEntry(String address) async => Uint8List(4);
  @override
  Future<PdfChunks> chunk(List<PdfPageText> pages) async => const PdfChunks(pieces: [{'i': 0, 'text': 'hello'}]);
  @override
  Future<PdfStaging> open({required String indexesDir, required String zimUuid, required String zimName, String? previousZimUuid, String? language}) async {
    calls.add('open:$zimUuid');
    return const PdfStaging(session: 1);
  }

  @override
  Future<PdfReused> reuse(int session, {required String path, required String sha256}) async => const PdfReused(reused: false);
  @override
  Future<PdfAdded> add(int session, {required String path, required String title, required List<Map<String, dynamic>> pieces, List<Map<String, dynamic>>? pages, int? size, String? sha256}) async {
    calls.add('add:$path');
    return const PdfAdded(pieces: 1, committed: 1);
  }

  @override
  Future<void> skip(int session, {required String path, required PdfSkipReason reason, int? size, String? sha256}) async {}
  @override
  Future<void> close(int session) async => calls.add('close');
  @override
  Future<void> discard({required String indexesDir, required String zimUuid}) async {}
  @override
  Future<PdfFinishJob> finish({required String indexesDir, required String zimUuid}) async {
    calls.add('finish');
    return _Job();
  }
}

class _Job implements PdfFinishJob {
  @override
  Future<PdfFinishProgress> progress() async => const PdfFinishProgress(state: PdfFinishState.done);
  @override
  Future<void> cancel() async {}
  @override
  Future<void> free() async {}
}

void main() {
  late FakeNative fake;
  late CoreDispatcher d;
  late Map<String, Map<String, dynamic>> status;
  late _PdfCore pdfCore;

  setUp(() {
    status = {};
    pdfCore = _PdfCore();
    fake = FakeNative()
      ..statusFn = (() => jsonEncode({'sources': status.values.toList()}))
      ..progressScript.add(_done);
    d = CoreDispatcher(() => fake);
    d.handle('open', {'sources': <Object>[], 'extra': null});
  });

  List<String> jobs() => fake.calls.where((c) => c.startsWith('jobStart:')).toList();
  Map<String, dynamic> params(String call, String kind) => jsonDecode(call.substring('jobStart:$kind:'.length)) as Map<String, dynamic>;

  IndexDriver make({HostLoad? load, bool withPdf = false}) => IndexDriver(
        d,
        every: const Duration(hours: 1),
        extra: {'indexes_dir': '/indexes'},
        load: load,
        pdf: withPdf ? PdfWork(core: pdfCore, read: (b, {required hashOnly}) async => PdfTextResult(status: 'ok', size: b.length, sha256: 'h', pages: const ['hello world']), indexesDir: '/indexes') : null,
      );

  test('an index built before snapshots is sealed (index_seal), with the phone\'s parameters; it is not tried again', () {
    status['a.zim'] = _st('a.zim', index: {'location': 'old', 'kind': 'zim', 'dir': '/idx/a.zim', 'needs_seal': true});
    final driver = make()..useSources([_src('a.zim')]);
    addTearDown(driver.stop);
    driver.tick();
    expect(jobs(), hasLength(1));
    expect(params(jobs().single, 'index_seal'), {'indexes_dir': '/indexes', 'kind': 'zim', 'source_id': 'sid-a.zim', 'index_dir': '/idx/a.zim'});
    expect(driver.progress.keys, ['seal:zim/sid-a.zim']);
    driver.tick();
    expect(driver.busy, isFalse);
    driver.tick();
    expect(jobs(), hasLength(1));
  });

  test('the EPUBs and the caption files of a ZIM are indexed with index_source, after the seals', () {
    status['a.zim'] = _st(
      'a.zim',
      index: {'location': 'new', 'kind': 'zim', 'needs_seal': true, 'dir': '/idx/a.zim'},
      epub: {'state': 'none', 'kind': 'zim-epub', 'source_id': 'sid-a.zim', 'needs_build': true},
      captions: {'state': 'none', 'kind': 'zim-captions', 'needs_build': true},
    );
    final driver = make()..useSources([_src('a.zim')]);
    addTearDown(driver.stop);
    driver.tick();
    expect(jobs().single, startsWith('jobStart:index_seal:'));
    driver.tick(); // the seal is done: the captions start
    expect(jobs(), hasLength(2));
    expect(params(jobs().last, 'index_source'), {'indexes_dir': '/indexes', 'kind': 'zim-captions', 'source_id': 'sid-a.zim'}, reason: 'the source id falls back to the ZIM\'s');
    driver.tick(); // the captions are done: the EPUBs start
    expect(jobs(), hasLength(3));
    expect(params(jobs().last, 'index_source'), {'indexes_dir': '/indexes', 'kind': 'zim-epub', 'source_id': 'sid-a.zim'});
    driver.tick();
    driver.tick();
    expect(jobs(), hasLength(3));
  });

  test('without an indexes folder there are no seals or index_source jobs', () {
    status['a.zim'] = _st('a.zim', epub: {'state': 'none', 'kind': 'zim-epub', 'needs_build': true});
    final driver = IndexDriver(d, every: const Duration(hours: 1))..useSources([_src('a.zim')]);
    addTearDown(driver.stop);
    driver.tick();
    expect(jobs(), isEmpty);
  });

  test('a job that takes a duty gets the host\'s at the start and again through cs_job_set when it changes', () {
    var temp = 40.0;
    final load = HostLoad(readTempC: () => temp, readMemory: () => null, every: Duration.zero);
    status['a.zim'] = _st('a.zim', epub: {'state': 'none', 'kind': 'zim-epub', 'source_id': 's', 'needs_build': true});
    fake.progressScript
      ..clear()
      ..add('{"state":"running","done":1,"total":4}');
    final driver = make(load: load)..useSources([_src('a.zim')]);
    addTearDown(driver.stop);
    driver.tick();
    expect(params(jobs().single, 'index_source')['duty'], {'work_ms': 2000, 'idle_ms': 250});
    driver.tick();
    expect(fake.calls.where((c) => c.startsWith('jobSet')), isEmpty, reason: 'the duty did not change');
    temp = 82; // warm: slower
    driver.tick();
    final set = fake.calls.singleWhere((c) => c.startsWith('jobSet'));
    final pace = jsonDecode(set.substring(set.indexOf('{'))) as Map;
    expect(pace['paused'], isFalse);
    expect(pace['idle_ms'], greaterThan(250));
  });

  test('a hot or memory-starved host starts nothing new, and the timer keeps looking', () {
    var temp = 100.0;
    final load = HostLoad(readTempC: () => temp, readMemory: () => null, every: Duration.zero);
    status['a.zim'] = _st('a.zim', index: {'location': 'old', 'kind': 'zim', 'dir': '/i', 'needs_seal': true});
    final driver = make(load: load)..useSources([_src('a.zim')]);
    addTearDown(driver.stop);
    driver.tick();
    expect(jobs(), isEmpty);
    expect(driver.running, isTrue);
    temp = 20; // heat eases off by halves: below the resume level on the next reading
    driver.tick();
    expect(jobs(), hasLength(1));
  });

  test('a hold is logged once when it starts and once when it ends, and index.state says why', () {
    var temp = 100.0;
    final load = HostLoad(readTempC: () => temp, readMemory: () => null, every: Duration.zero);
    status['a.zim'] = _st('a.zim', index: {'location': 'old', 'kind': 'zim', 'dir': '/i', 'needs_seal': true});
    final lines = <String>[];
    final driver = IndexDriver(d, every: const Duration(hours: 1), extra: {'indexes_dir': '/indexes'}, load: load, log: lines.add)..useSources([_src('a.zim')]);
    addTearDown(driver.stop);
    final op = IndexStateOp(driver);
    expect((op.handle('index.state', const {}) as Map).containsKey('hold'), isFalse);
    driver.tick();
    driver.tick();
    expect(lines.where((l) => l.startsWith('index work is held')), ['index work is held: the host is too hot']);
    expect(driver.hold, 'heat');
    expect((op.handle('index.state', const {}) as Map)['hold'], {'fraction': null, 'error': null, 'hold': 'heat'});
    temp = 20; // each reading halves the heat: 0.5 is under the level where work goes on
    driver.tick();
    driver.tick();
    expect(lines.where((l) => l.startsWith('index work goes on')), hasLength(1));
    expect(driver.hold, isNull);
    expect((op.handle('index.state', const {}) as Map).containsKey('hold'), isFalse);
  });

  test('a host short of memory holds index work, and the hold says memory', () {
    final load = HostLoad(readTempC: () => null, readMemory: () => (available: 100 << 20, total: 8 << 30), every: Duration.zero);
    status['a.zim'] = _st('a.zim', index: {'location': 'old', 'kind': 'zim', 'dir': '/i', 'needs_seal': true});
    final lines = <String>[];
    final driver = IndexDriver(d, every: const Duration(hours: 1), extra: {'indexes_dir': '/indexes'}, load: load, log: lines.add)..useSources([_src('a.zim')]);
    addTearDown(driver.stop);
    driver.tick();
    expect(jobs(), isEmpty);
    expect(driver.hold, 'memory');
    expect(lines, contains('index work is held: the host is short of memory'));
  });

  test('the PDFs of a ZIM whose PDF index is not ready are indexed, once; the core gets the list again when the index is published', () async {
    status['a.zim'] = _st('a.zim', pdf: {'state': 'none'});
    final driver = make(withPdf: true)..useSources([_src('a.zim')]);
    addTearDown(driver.stop);
    final before = fake.calls.where((c) => c.startsWith('setSources:')).length;
    driver.tick();
    expect(driver.busy, isTrue);
    expect(driver.running, isTrue);
    await pumpEventQueue();
    expect(pdfCore.calls, ['list:id-a.zim', 'open:id-a.zim', 'add:a.pdf', 'close', 'finish']);
    expect(driver.busy, isFalse);
    expect(driver.failures, isEmpty);
    expect(driver.progress, isEmpty);
    expect(fake.calls.where((c) => c.startsWith('setSources:')).length, before + 1);
    driver.tick();
    await pumpEventQueue();
    expect(pdfCore.calls, hasLength(5), reason: 'tried once for each open or rescan');
  });

  test('a ZIM whose PDF index is ready, or that has no PDFs, is left alone', () async {
    status['ready.zim'] = _st('ready.zim', pdf: {'state': 'ready', 'snapshot': 's'});
    status['none.zim'] = _st('none.zim', pdf: {'state': 'none'});
    final driver = make(withPdf: true)..useSources([_src('ready.zim'), _src('none.zim')]);
    addTearDown(driver.stop);
    driver.tick();
    await pumpEventQueue();
    expect(pdfCore.calls, ['list:id-none.zim']);
    driver.useSources([_src('ready.zim'), _src('none.zim')]);
    driver.tick();
    await pumpEventQueue();
    expect(pdfCore.calls, ['list:id-none.zim'], reason: 'a ZIM with no PDFs is not listed again');
  });

  test('a core with no PDF index calls indexes no PDFs, and the tick can stop', () async {
    pdfCore.has = false;
    status['a.zim'] = _st('a.zim', pdf: {'state': 'none'});
    final driver = make(withPdf: true)..useSources([_src('a.zim')]);
    addTearDown(driver.stop);
    driver.tick();
    expect(driver.running, isFalse);
    expect(pdfCore.calls, isEmpty);
  });
}
