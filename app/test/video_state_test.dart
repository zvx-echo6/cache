import 'dart:io';

import 'package:cache/video/token_store.dart';
import 'package:cache/video/video_state.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'video_fake.dart';

void main() {
  late Directory dir;
  late MemoryTokenStore tokens;
  late VideoState v;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('video-state');
    tokens = MemoryTokenStore();
    v = VideoState(dirOverride: dir, nativeFactory: fakeVideoNative, tokens: tokens);
    await v.init();
  });

  tearDown(() async {
    v.dispose();
    await dir.delete(recursive: true);
  });

  test('adding and removing an instance', () async {
    expect(v.ready, isTrue);
    expect(v.instances, isEmpty);
    final i = await v.addInstance('tube.example.org');
    expect(i.name, 'Example PeerTube');
    expect(v.instances.single.host, 'tube.example.org');
    await expectLater(v.addInstance('nope.example'), throwsA(isA<CacheSearchException>()));
    await v.removeInstance(i.id);
    expect(v.instances, isEmpty);
  });

  test('login keeps tokens in the secure store, not the core, and logout forgets them', () async {
    final i = await v.addInstance('tube.example.org');
    await expectLater(v.login(i.id, 'alice', 'wrong'), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'auth_failed')));
    expect(tokens.values, isEmpty);
    await v.login(i.id, 'alice', 'right');
    expect(v.userOf(i.id), 'alice');
    expect(tokens.values['video.${i.id}.access'], 'A1');
    expect(tokens.values['video.${i.id}.refresh'], 'R1');
    expect(tokens.values.values.any((x) => x == 'right'), isFalse, reason: 'the password is never stored');
    await v.logout(i.id);
    expect(tokens.values, isEmpty);
    expect(v.userOf(i.id), isNull);
  });

  test('an expired access token is refreshed once and the call repeated', () async {
    final i = await v.addInstance('tube.example.org');
    await v.login(i.id, 'alice', 'right');
    final calls = <String?>[];
    var first = true;
    final out = await v.withToken<String>(i.id, (t) async {
      calls.add(t);
      if (first) {
        first = false;
        throw const CacheSearchException('auth_failed', 'expired');
      }
      return 'ok';
    });
    expect(out, 'ok');
    expect(calls, ['A1', 'A2'], reason: 'the second try uses the refreshed token');
    expect(tokens.values['video.${i.id}.access'], 'A2');
    expect(tokens.values['video.${i.id}.refresh'], 'R2');
  });

  test('a failed refresh drops the login', () async {
    final i = await v.addInstance('tube.example.org');
    await v.login(i.id, 'alice', 'right');
    tokens.values['video.${i.id}.refresh'] = 'R1';
    // the call is refused again after the refresh: the login is dropped
    await expectLater(
      v.withToken<String>(i.id, (t) async => throw const CacheSearchException('auth_failed', 'expired')),
      throwsA(isA<CacheSearchException>()),
    );
    expect(v.userOf(i.id), isNull, reason: 'still refused after the refresh: signed out');
    expect(tokens.values, isEmpty);
  });

  test('browse calls go through to the core', () async {
    final i = await v.addInstance('tube.example.org');
    final p = await v.list(i.id);
    expect(p.videos.single.title, 'Merry Christmas');
    expect((await v.channels(i.id)).channels.single.handle, 'big-clive');
    final d = await v.details(i.id, VideoFakeNative.uuid);
    expect(d.options.map((o) => o.key), ['720', '360', 'audio']);
    expect(d.options.first.size, 9000000);
    expect(d.downloadEnabled, isTrue);
    expect(d.captions.single.language, 'en');
  });

  test('a download shows progress, ends in the saved list, and resolves to the file', () async {
    final i = await v.addInstance('tube.example.org');
    final d = await v.details(i.id, VideoFakeNative.uuid);
    final task = await v.download(d, d.options[1]);
    expect(task.isActive, isTrue);
    await v.pollOnce();
    expect(task.done, 1000000);
    expect(task.fraction, closeTo(1 / 3, 0.001));
    await v.pollOnce();
    expect(task.phase, DownloadPhase.done);
    expect(v.saved.single.resolutionLabel, '360p');
    expect(v.savedBytes, 3000000);
    final t = await v.resolve(VideoFakeNative.uuid, instance: i.id, offsetS: 5);
    expect(t.isLocal, isTrue);
    expect(t.location, '/data/video.mp4');
    expect(t.offsetS, 5);
    await v.deleteSaved(v.saved.single);
    expect(v.saved, isEmpty);
    final s = await v.resolve('https://example.org/w/1TesHJPJ33Jz5TUP7TA7cu?start=1m', offsetS: 7);
    expect(s.isLocal, isFalse);
    expect(s.location, 'https://example.org/v.mp4');
  });

  test('error texts are for people', () {
    expect(videoErrorText(const CacheSearchException('fetch_failed', 'x')), contains("Can't reach"));
    expect(videoErrorText(const CacheSearchException('no_space', 'x')), contains('free space'));
    expect(videoErrorText(const CacheSearchException('unsupported', 'turned downloads off')), 'turned downloads off');
  });
}
