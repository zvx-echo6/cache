import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../bin/core_open.dart';
import '../bin/index_driver.dart';
import 'fake_native.dart';

Map<String, dynamic> _src(String name, {String kind = 'zim', Map<String, dynamic>? settings}) => {
      'kind': kind,
      'path': '/docs/$name',
      'index_dir': '/idx/$name',
      'settings': ?settings,
    };

Map<String, dynamic> _st(String name, {bool indexed = false, bool building = false, bool stale = false, String kind = 'zim', Object? error}) => {
      'id': 'id-$name',
      'kind': kind,
      'path': '/docs/$name',
      'title': name,
      'indexed': indexed,
      'building': building,
      'stale': stale,
      'opening': false,
      'updating': false,
      'docs': 1,
      'error': error,
    };

String _running(int done) => '{"state":"running","done":$done,"total":4}';
const _done = '{"state":"done","done":4,"total":4}';
const _failed = '{"state":"failed","done":1,"total":4,"error":{"code":"internal","message":"disk full"}}';

void main() {
  late FakeNative fake;
  late CoreDispatcher d;
  late IndexDriver driver;
  late Map<String, Map<String, dynamic>> status;

  setUp(() {
    status = {};
    fake = FakeNative()..statusFn = () => jsonEncode({'sources': status.values.toList()});
    d = CoreDispatcher(() => fake);
    d.handle('open', {'sources': <Object>[], 'extra': null});
    driver = IndexDriver(d, every: const Duration(hours: 1));
  });
  tearDown(() => driver.stop());

  List<String> jobs() => fake.calls.where((c) => c.startsWith('jobStart:')).toList();

  test('a ZIM that is not indexed gets an index_zim job, with its progress; when it ends the core gets the list again', () {
    status['a.zim'] = _st('a.zim');
    fake.progressScript.addAll([_running(1), _done]);
    driver.useSources([_src('a.zim')]);
    driver.tick();
    expect(jobs(), hasLength(1));
    expect(jobs().single, startsWith('jobStart:index_zim:'));
    final params = jsonDecode(jobs().single.substring('jobStart:index_zim:'.length)) as Map;
    expect(params, {'zim_path': '/docs/a.zim', 'index_dir': '/idx/a.zim', 'heap_mb': 200});
    expect(d.handle('status', const {}), isNotEmpty);

    driver.tick();
    expect(driver.progress['/docs/a.zim'], 0.25);
    expect(driver.busy, isTrue);

    status['a.zim'] = _st('a.zim', indexed: true);
    final before = fake.calls.where((c) => c.startsWith('setSources:')).length;
    driver.tick();
    expect(driver.busy, isFalse);
    expect(driver.progress, isEmpty);
    expect(fake.calls, contains('jobFree:100'));
    expect(fake.calls.where((c) => c.startsWith('setSources:')).length, before + 1);
    driver.tick();
    expect(jobs(), hasLength(1), reason: 'a ready ZIM is not indexed again');
  });

  test('one job at a time: the second ZIM starts after the first ends; a ready ZIM and one with an error are skipped', () {
    status['a.zim'] = _st('a.zim');
    status['b.zim'] = _st('b.zim');
    status['ready.zim'] = _st('ready.zim', indexed: true);
    status['bad.zim'] = _st('bad.zim', error: {'code': 'x', 'message': 'broken'});
    fake.progressScript.addAll([_running(1), _done]);
    driver.useSources([_src('bad.zim'), _src('ready.zim'), _src('a.zim'), _src('b.zim')]);
    driver.tick();
    expect(jobs(), hasLength(1));
    expect(jobs().single, contains('/docs/a.zim'));
    driver.tick();
    expect(jobs(), hasLength(1), reason: 'the first is still running');
    fake.progressScript
      ..clear()
      ..add(_done);
    status['a.zim'] = _st('a.zim', indexed: true);
    driver.tick();
    expect(jobs(), hasLength(2), reason: 'the first ended, so the next one starts');
    expect(jobs().last, contains('/docs/b.zim'));
  });

  test('a source being built is left alone; a stale ZIM is indexed again', () {
    status['a.zim'] = _st('a.zim', building: true);
    status['s.zim'] = _st('s.zim', indexed: true, stale: true);
    fake.progressScript.add(_done);
    driver.useSources([_src('a.zim'), _src('s.zim')]);
    driver.tick();
    expect(jobs(), hasLength(1));
    expect(jobs().single, contains('/docs/s.zim'));
  });

  test('a failed job is kept (index.state says why), is not started again, and is tried once more after a rescan', () {
    status['a.zim'] = _st('a.zim');
    fake.progressScript.add(_failed);
    driver.useSources([_src('a.zim')]);
    driver.tick();
    driver.tick();
    expect(driver.failures['/docs/a.zim'], 'disk full');
    final op = IndexStateOp(driver);
    expect(op.handle('index.state', const {}), {
      '/docs/a.zim': {'fraction': null, 'error': 'disk full'},
    });
    driver.tick();
    driver.tick();
    expect(jobs(), hasLength(1));
    driver.useSources([_src('a.zim')]);
    driver.tick();
    expect(jobs(), hasLength(2));
  });

  test('a busy answer is not a failure', () {
    status['a.zim'] = _st('a.zim');
    fake.startError = '{"code":"busy","message":"another job is building it"}';
    driver.useSources([_src('a.zim')]);
    driver.tick();
    expect(driver.failures, isEmpty);
    expect(driver.busy, isFalse);
  });

  test('a library that is not indexed gets index_library with its settings; keyword_index off and an indexed one are skipped', () {
    status['l1'] = _st('l1', kind: 'library');
    status['l2'] = _st('l2', kind: 'library');
    status['l3'] = _st('l3', kind: 'library', indexed: true);
    fake.progressScript.add(_done);
    driver.useSources([
      _src('l2', kind: 'library', settings: {'keyword_index': 'off'}),
      _src('l3', kind: 'library'),
      _src('l1', kind: 'library', settings: {'keyword_index': 'auto'}),
    ]);
    driver.tick();
    expect(jobs(), hasLength(1));
    expect(jobs().single, startsWith('jobStart:index_library:'));
    final params = jsonDecode(jobs().single.substring('jobStart:index_library:'.length)) as Map;
    expect(params['library_path'], '/docs/l1');
    expect(params['index_dir'], '/idx/l1');
    expect(params['settings'], {'keyword_index': 'auto'});
  });

  test('a library still opening on the first tick is indexed once it is ready (the timer keeps running)', () async {
    var opening = true;
    status['l1'] = _st('l1', kind: 'library');
    fake.statusFn = () => jsonEncode({
          'sources': [
            {..._st('l1', kind: 'library'), 'opening': opening, 'id': opening ? null : 'id-l1'},
          ],
        });
    fake.progressScript.add(_done);
    final fast = IndexDriver(d, every: const Duration(milliseconds: 20));
    addTearDown(fast.stop);
    fast.useSources([_src('l1', kind: 'library')]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(jobs(), isEmpty, reason: 'still opening');
    opening = false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(jobs(), hasLength(1));
    expect(jobs().single, startsWith('jobStart:index_library:'));
  });

  test('a ZIM still opening on the first tick is indexed once it is ready', () async {
    var opening = true;
    fake.statusFn = () => jsonEncode({
          'sources': [
            {..._st('a.zim'), 'opening': opening, 'id': opening ? null : 'id-a.zim'},
          ],
        });
    fake.progressScript.add(_done);
    final fast = IndexDriver(d, every: const Duration(milliseconds: 20));
    addTearDown(fast.stop);
    fast.useSources([_src('a.zim')]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(jobs(), isEmpty);
    opening = false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(jobs(), hasLength(1));
    expect(jobs().single, startsWith('jobStart:index_zim:'));
  });

  test('the tick stops once every source is settled and indexed', () {
    status['a.zim'] = _st('a.zim', indexed: true);
    driver.useSources([_src('a.zim')]);
    driver.tick();
    expect(driver.running, isFalse);
  });

  test('open and sources.rescan hand the list to the driver', () {
    status['a.zim'] = _st('a.zim');
    fake.progressScript.add(_done);
    final op = RescanOp(AppDirs(Directory('/nonexistent/support'), Directory('/nonexistent/docs')), d, indexer: driver);
    op.handle('sources.rescan', {'sources': [_src('a.zim')]});
    driver.tick();
    expect(jobs(), hasLength(1));
  });
}
