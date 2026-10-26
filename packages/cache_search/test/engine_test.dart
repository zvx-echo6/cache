import 'dart:convert';
import 'dart:typed_data';

import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for the native library: answers from canned JSON and records what it was given.
class FakeNative implements CsNative {
  // The tool, location, places and live calls are not used by these tests.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  final Map<String, String?> replies = {};
  final List<String> calls = [];
  String? error;
  int openResult = 7;
  int setSourcesResult = 0;
  int jobStartResult = 5;
  int jobCancelResult = 0;
  ZimBytes? zim;

  String? _r(String name, [Object? arg]) {
    calls.add(arg == null ? name : '$name:$arg');
    return replies[name];
  }

  @override
  String? layers(int handle, String op, String? arg) {
    calls.add('layers:$op:$arg');
    return replies['layers:$op'];
  }

  @override
  String? video(int handle, String op, String requestJson) {
    calls.add('video:$op:$requestJson');
    return replies['video:$op'];
  }

  @override
  String? version() => _r('version');
  @override
  int open(String configJson) {
    calls.add('open:$configJson');
    return openResult;
  }

  @override
  int setSources(int handle, String configJson) {
    calls.add('setSources:$configJson');
    return setSourcesResult;
  }

  @override
  String? status(int handle) => _r('status');
  @override
  String? lastError(int handle) => error;
  @override
  void close(int handle) => calls.add('close:$handle');
  @override
  String? search(int handle, String query, String optionsJson) {
    calls.add('search:$query:$optionsJson');
    return replies['search'];
  }

  @override
  String? read(int handle, String address, int maxChars) {
    calls.add('read:$address:$maxChars');
    return replies['read'];
  }

  @override
  ZimBytes? zimGet(int handle, String address) => zim;
  @override
  String? zimMainPage(int handle, String zimId) => _r('zimMainPage', zimId);
  @override
  String? suggest(int handle, String prefix, String optionsJson) {
    calls.add('suggest:$prefix:$optionsJson');
    return replies['suggest'];
  }

  @override
  int conversationNew() => 3;
  @override
  String? format(int conv, String resultsJson) {
    calls.add('format:$resultsJson');
    return replies['format'];
  }

  @override
  String? conversationIds(int conv) => _r('ids');
  @override
  void conversationFree(int conv) => calls.add('convFree:$conv');
  @override
  int jobStart(String kind, String paramsJson) {
    calls.add('jobStart:$kind:$paramsJson');
    return jobStartResult;
  }

  @override
  String? jobProgress(int job) => _r('jobProgress');
  @override
  int jobCancel(int job) => jobCancelResult;
  @override
  void jobFree(int job) => calls.add('jobFree:$job');
}

const _zim = SourceConfig.zim(path: '/z/wikimed.zim', indexDir: '/i/wikimed.idx');

void main() {
  group('open and sources', () {
    test('cs_open gets the sources as the config JSON', () {
      final n = FakeNative();
      SearchEngine.open(n, [_zim]);
      final sent = jsonDecode(n.calls.first.substring('open:'.length)) as Map;
      expect(sent, {
        'sources': [
          {'kind': 'zim', 'path': '/z/wikimed.zim', 'index_dir': '/i/wikimed.idx'},
        ],
      });
    });

    test('a library carries its settings object', () {
      final j = const SourceConfig.library(path: '/l', indexDir: '/li', settings: {'library_id': 'recon', 'format': 1}).toJson();
      expect(j['kind'], 'library');
      expect(j['settings'], {'library_id': 'recon', 'format': 1});
    });

    test('a failed cs_open raises the thread error', () {
      final n = FakeNative()
        ..openResult = 0
        ..error = '{"code":"bad_json","message":"sources missing"}';
      expect(
        () => SearchEngine.open(n, []),
        throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'bad_json').having((e) => e.message, 'message', 'sources missing')),
      );
    });

    test('setSources raises on a negative result', () {
      final n = FakeNative();
      final e = SearchEngine.open(n, [_zim]);
      n
        ..setSourcesResult = -1
        ..error = '{"code":"io","message":"no such file"}';
      expect(() => e.setSources([_zim]), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'io')));
    });

    test('status parses sources, a failed ZIM keeps its error', () {
      final n = FakeNative()
        ..replies['status'] = jsonEncode({
          'sources': [
            {'id': 'u1', 'kind': 'zim', 'path': '/z/a.zim', 'title': 'A', 'indexed': true, 'building': false, 'stale': false, 'opening': false, 'updating': false, 'docs': 12, 'error': null},
            {'id': null, 'kind': 'zim', 'path': '/z/b.zim', 'title': '', 'indexed': false, 'error': {'code': 'io', 'message': 'gone'}},
          ],
        });
      final s = SearchEngine.open(n, [_zim]).status();
      expect(s[0].searchable, isTrue);
      expect(s[0].docs, 12);
      expect(s[1].id, isNull);
      expect(s[1].searchable, isFalse);
      expect(s[1].error!.code, 'io');
    });
  });

  group('search and read', () {
    test('search sends the options and parses the hits', () {
      final n = FakeNative()
        ..replies['search'] = jsonEncode({
          'results': [
            {'address': 'zim:u1/Burn', 'title': 'WikiMed: Burn', 'snippet': 'Cool it.', 'source_id': 'u1', 'source_kind': 'zim', 'source_title': 'WikiMed', 'page': null},
          ],
          'total_estimate': 41,
          'vector_sources': [],
          'keyword_only_sources': ['u1'],
        });
      final e = SearchEngine.open(n, [_zim]);
      final r = e.search('burn', k: 3, sources: ['u1'], queryVector: const QueryVector('bge', [0.5, 1.0]));
      expect(r.results.single.title, 'WikiMed: Burn');
      expect(r.results.single.page, isNull);
      expect(r.totalEstimate, 41);
      expect(r.keywordOnlySources, ['u1']);
      final opts = jsonDecode(n.calls.last.split(':').skip(2).join(':')) as Map;
      expect(opts, {'k': 3, 'offset': 0, 'sources': ['u1'], 'query_vector': {'model': 'bge', 'vector': [0.5, 1.0]}});
    });

    test('search without a vector sends nulls', () {
      final n = FakeNative()..replies['search'] = '{"results":[],"total_estimate":0}';
      SearchEngine.open(n, [_zim]).search('x');
      final opts = jsonDecode(n.calls.last.substring('search:x:'.length)) as Map;
      expect(opts['sources'], isNull);
      expect(opts['query_vector'], isNull);
    });

    test('a null reply raises the handle error', () {
      final n = FakeNative()..error = '{"code":"index_missing","message":"no index for wikimed"}';
      final e = SearchEngine.open(n, [_zim]);
      expect(() => e.search('x'), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'index_missing')));
    });

    test('an error that is not JSON still raises', () {
      final n = FakeNative()..error = 'boom';
      final e = SearchEngine.open(n, [_zim]);
      expect(() => e.read('zim:u1/x'), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'internal').having((x) => x.message, 'message', 'boom')));
    });

    test('read parses a ZIM article and a library page', () {
      final n = FakeNative()
        ..replies['read'] = '{"address":"lib:recon/9","title":"Tourniquets","text":"Apply...","truncated":true,"author":"Army","page":42,"source_type":"book"}';
      final r = SearchEngine.open(n, [_zim]).read('lib:recon/9', maxChars: 1000);
      expect(n.calls.last, 'read:lib:recon/9:1000');
      expect(r.truncated, isTrue);
      expect(r.author, 'Army');
      expect(r.page, 42);
      n.replies['read'] = '{"address":"zim:u1/A","title":"A","text":"t","truncated":false,"author":null,"page":null,"source_type":null}';
      final z = SearchEngine.open(n, [_zim]).read('zim:u1/A');
      expect(z.author, isNull);
    });

    test('zimGet returns the bytes and mime, or the error', () {
      final n = FakeNative()..zim = ZimBytes(Uint8List.fromList([1, 2, 3]), 'text/html');
      final e = SearchEngine.open(n, [_zim]);
      expect(e.zimGet('zim:u1/x').bytes, [1, 2, 3]);
      n
        ..zim = null
        ..error = '{"code":"not_found","message":"no entry"}';
      expect(() => e.zimGet('zim:u1/y'), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'not_found')));
    });

    test('suggest and main page', () {
      final n = FakeNative()
        ..replies['suggest'] = '{"suggestions":[{"title":"Burn","address":"zim:u1/Burn","source_id":"u1"}]}'
        ..replies['zimMainPage'] = '{"address":"zim:u1/Main"}';
      final e = SearchEngine.open(n, [_zim]);
      expect(e.suggest('bu').single.address, 'zim:u1/Burn');
      expect(e.zimMainPage('u1'), 'zim:u1/Main');
    });

    test('a closed engine raises, and close is safe twice', () {
      final n = FakeNative();
      final e = SearchEngine.open(n, [_zim])..close();
      e.close();
      expect(n.calls.where((c) => c.startsWith('close')).length, 1);
      expect(() => e.status(), throwsA(isA<CacheSearchException>()));
    });
  });

  group('numbering', () {
    test('format passes the results through and parses the tool message and ids', () {
      final n = FakeNative()
        ..replies['format'] = jsonEncode({
          'tool_message': '[1] Burn — Cool it.\n[2] Water — Boil it.',
          'ids': [
            {'n': 1, 'address': 'zim:u1/Burn', 'title': 'Burn'},
            {'n': 2, 'address': 'zim:u1/Water', 'title': 'Water'},
          ],
        })
        ..replies['ids'] = '{"ids":[{"n":1,"address":"zim:u1/Burn","title":"Burn"}]}';
      final c = ConversationNumbers.create(n);
      final f = c.format([
        const SearchHit(address: 'zim:u1/Burn', title: 'Burn', snippet: 'Cool it.', sourceId: 'u1', sourceKind: 'zim', sourceTitle: 'W').toFormatJson(),
      ]);
      expect(jsonDecode(n.calls.last.substring('format:'.length)), [
        {'address': 'zim:u1/Burn', 'title': 'Burn', 'snippet': 'Cool it.'},
      ]);
      expect(f.toolMessage, '[1] Burn — Cool it.\n[2] Water — Boil it.');
      expect([for (final i in f.ids) i.n], [1, 2]);
      expect(c.ids().single.address, 'zim:u1/Burn');
      c.free();
      c.free();
      expect(n.calls.where((x) => x.startsWith('convFree')).length, 1);
      expect(() => c.ids(), throwsA(isA<CacheSearchException>()));
    });

    test('a failed format raises', () {
      final n = FakeNative()..error = '{"code":"bad_json","message":"results"}';
      expect(() => ConversationNumbers.create(n).format([]), throwsA(isA<CacheSearchException>()));
    });
  });

  group('jobs', () {
    test('start sends the params; progress parses state, steps and errors', () {
      final n = FakeNative();
      final j = CoreJob.start(n, 'index_zim', {'zim_path': '/z/a.zim', 'index_dir': '/i/a.idx', 'heap_mb': 200});
      expect(n.calls.last, 'jobStart:index_zim:{"zim_path":"/z/a.zim","index_dir":"/i/a.idx","heap_mb":200}');
      n.replies['jobProgress'] = '{"state":"running","done":25,"total":100,"error":null}';
      var p = j.progress();
      expect(p.state, JobState.running);
      expect(p.fraction, 0.25);
      expect(p.isFinished, isFalse);
      n.replies['jobProgress'] = '{"state":"failed","done":3,"total":0,"error":{"code":"no_space","message":"full"}}';
      p = j.progress();
      expect(p.isFinished, isTrue);
      expect(p.fraction, isNull);
      expect(p.errorCode, 'no_space');
      j.free();
      j.free();
      expect(n.calls.where((x) => x.startsWith('jobFree')).length, 1);
    });

    test('a job that cannot start raises the thread error', () {
      final n = FakeNative()
        ..jobStartResult = 0
        ..error = '{"code":"busy","message":"index is being built"}';
      expect(() => CoreJob.start(n, 'index_zim', {}), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'busy')));
    });

    test('cancel raises on failure', () {
      final n = FakeNative();
      final j = CoreJob.start(n, 'index_zim', {});
      n.jobCancelResult = -1;
      n.error = '{"code":"internal","message":"x"}';
      expect(() => j.cancel(), throwsA(isA<CacheSearchException>()));
    });
  });

  group('layers', () {
    test('every call passes its one string, or null, and parses the object', () {
      final n = FakeNative()
        ..replies['layers:list'] = '{"layers":[],"online":true}'
        ..replies['layers:plan'] = '{"tiles":10,"ok_to_start":true}'
        ..replies['layers:server'] = '{"port":4321,"base_url":"http://127.0.0.1:4321"}';
      final e = SearchEngine.open(n, [_zim]);
      expect(e.layers('list')['online'], true);
      expect(e.layers('plan', '{"layer":"basemap"}')['tiles'], 10);
      expect(e.layers('server')['port'], 4321);
      expect(n.calls, containsAll(['layers:list:null', 'layers:plan:{"layer":"basemap"}', 'layers:server:null']));
    });

    test('a failed call raises the handle error', () {
      final n = FakeNative()..error = '{"code":"not_configured","message":"no layers section"}';
      final e = SearchEngine.open(n, [_zim]);
      expect(() => e.layers('list'), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'not_configured')));
    });
  });
}
