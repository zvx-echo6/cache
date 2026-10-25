import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'engine_test.dart' show FakeNative;

// Runs inside the worker isolate, so it builds its own fake.
CsNative _fake() => FakeNative()
  ..replies['video:instances'] = '{"instances":[{"id":"tube.example.org","url":"https://tube.example.org","name":"Tube","version":"8.2.4","added_at":"x"}]}'
  ..replies['video:login'] = '{"instance":"tube.example.org","token_type":"Bearer","access_token":"A","refresh_token":"R","expires_in":10,"refresh_token_expires_in":20}'
  ..replies['video:get'] = '''{"instance":"tube.example.org","uuid":"u1","title":"T","description":null,"duration_s":65,"channel":{"name":"c","display_name":"C","handle":"c","host":"tube.example.org","avatar":null},
    "download_enabled":true,"captions":[],"options":[{"key":"480","label":"480p","kind":"video","size":1000,"source":"web"},{"key":"audio","label":"Audio only","kind":"audio","size":null,"source":"hls"}],
    "stream":{"hls":"https://tube.example.org/m.m3u8","mp4":null,"needs_auth":false},"downloaded":{"kind":"video","resolution":"480","size":1000,"downloaded_at":"x"}}'''
  ..replies['video:resolve'] = '{"kind":"stream","instance":"tube.example.org","uuid":"u1","title":"T","url":"https://tube.example.org/m.m3u8","format":"hls","offset_s":12.5,"duration_s":65,"needs_auth":false,"thumbnail":null}'
  ..replies['jobProgress'] = '{"state":"running","done":10,"total":40,"error":null}';

CsNative _failing() => FakeNative()
  ..openResult = 0
  ..error = '{"code":"not_configured","message":"no video section"}';

void main() {
  test('the video worker isolate answers typed calls and runs a download job', () async {
    final core = await VideoCore.open('/v', native: _fake);
    final i = (await core.instances()).single;
    expect((i.id, i.name, i.host), ('tube.example.org', 'Tube', 'tube.example.org'));
    final t = await core.login('tube.example.org', 'alice', 'pw', otp: '123456');
    expect((t.accessToken, t.refreshToken), ('A', 'R'));
    final d = await core.get('tube.example.org', 'u1', token: 'A');
    expect(d.options.map((o) => (o.key, o.isAudio, o.size)), [('480', false, 1000), ('audio', true, null)]);
    expect(d.canStream, isTrue);
    expect(d.downloadedResolution, '480');
    final target = await core.resolve('u1', offsetS: 12.5);
    expect((target.isLocal, target.isHls, target.offsetS), (false, true, 12.5));
    final job = await core.startDownload('tube.example.org', 'u1', choice: '480', token: 'A');
    expect((await job.progress()).fraction, 0.25);
    await job.cancel();
    await job.free();
    await core.close();
    await expectLater(core.instances(), throwsA(isA<CacheSearchException>()));
  });

  test('a failing open raises the core error', () async {
    await expectLater(
      VideoCore.open('/v', native: _failing),
      throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'not_configured')),
    );
  });
}
