import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'engine_test.dart' show FakeNative;

// Runs inside the worker isolate, so it builds its own fake.
CsNative _fake() => FakeNative()
  ..replies['search'] = '{"results":[{"address":"zim:u/A","title":"A","snippet":"s","source_id":"u","source_kind":"zim","source_title":"U"}],"total_estimate":1}'
  ..replies['format'] = '{"tool_message":"[1] A — s","ids":[{"n":1,"address":"zim:u/A","title":"A"}]}'
  ..replies['ids'] = '{"ids":[{"n":1,"address":"zim:u/A","title":"A"}]}'
  ..replies['jobProgress'] = '{"state":"done","done":5,"total":5,"error":null}'
  ..replies['status'] =
      '{"sources":[{"id":"u","kind":"zim","path":"/z/a.zim","title":"U","indexed":true,"building":false,"stale":false,"opening":false,"updating":false,"docs":7,"keyword_source":"own","error":null}]}';

CsNative _failing() => FakeNative()
  ..openResult = 0
  ..error = '{"code":"io","message":"cannot open"}';

void main() {
  test('the worker isolate answers calls with typed results', () async {
    final core = await SearchCore.open(const [SourceConfig.zim(path: '/z/a.zim', indexDir: '/i/a.idx')], native: _fake);
    final r = await core.search('a');
    expect(r.results.single.title, 'A');
    final conv = await core.newConversation();
    final f = await conv.format([r.results.single.toFormatJson()]);
    expect(f.toolMessage, '[1] A — s');
    expect((await conv.ids()).single.n, 1);
    await conv.free();
    final job = await core.startJob('index_zim', {'zim_path': '/z/a.zim', 'index_dir': '/i/a.idx'});
    expect((await job.progress()).state, JobState.done);
    await job.free();
    final status = (await core.status()).single;
    expect(status.docs, 7);
    expect(status.keywordSource, 'own', reason: 'the worker passes where keyword search comes from on to the app');
    await core.close();
    await expectLater(core.status(), throwsA(isA<CacheSearchException>()));
  });

  test('a failing open raises the core error', () async {
    await expectLater(
      SearchCore.open(const [], native: _failing),
      throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'io')),
    );
  });
}
