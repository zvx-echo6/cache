import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../packages/cache_search/lib/src/errors.dart';
import '../bin/core_open.dart';
import '../bin/keystore.dart';
import '../bin/video_ops.dart';
import 'fake_native.dart';

/// The fake with the video calls: answers `videoReplies[op]` (null: the core's error).
class VideoFake extends FakeNative {
  final Map<String, String?> videoReplies = {};
  final List<String> videoCalls = [];

  @override
  String? video(int handle, String op, String requestJson) {
    videoCalls.add('$op:$requestJson');
    return videoReplies[op];
  }
}

void main() {
  late Directory tmp, support, docs;
  late VideoFake fake;
  late VideoOps ops;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('video_ops_test');
    support = Directory('${tmp.path}/support')..createSync();
    docs = Directory('${tmp.path}/docs')..createSync();
    fake = VideoFake();
    ops = VideoOps(AppDirs(support, docs), () => fake);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String running(int done, int total) => jsonEncode({'state': 'running', 'done': done, 'total': total});

  test('the core handle is opened on <docs>/videos with the indexes folder, once', () {
    expect(ops.handles('video.call'), isTrue);
    expect(ops.handles('fs.read'), isFalse);
    expect(ops.handle('video.info', {}), {'dir': '${docs.path}/videos'});
    ops.handle('video.info', {});
    final opens = fake.calls.where((c) => c.startsWith('open:')).toList();
    expect(opens, hasLength(1));
    final cfg = jsonDecode(opens.single.substring(5)) as Map;
    expect(cfg['sources'], isEmpty);
    expect(cfg['video'], {'dir': '${docs.path}/videos'});
    expect(cfg['indexes_dir'], '${support.path}/indexes');
  });

  test('video.call passes the op and request to cs_video_<op> and returns its JSON; a core error is thrown', () {
    fake.videoReplies['instances'] = '{"instances":[]}';
    expect(ops.handle('video.call', {'op': 'instances', 'request': ''}), '{"instances":[]}');
    fake.videoReplies['list'] = null;
    fake.error = '{"code":"fetch_failed","message":"no route"}';
    expect(
      () => ops.handle('video.call', {'op': 'list', 'request': '{"instance":"x"}'}),
      throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'fetch_failed')),
    );
    expect(fake.videoCalls.last, 'list:{"instance":"x"}');
  });

  test('a download is a core job in the videos folder; it is listed with what the tab told, so another tab can show it', () {
    fake.progressScript.add(running(10, 100));
    final r = ops.handle('video.jobStart', {'instance': 'a.example', 'video': 'u1', 'choice': '480', 'token': 't', 'title': 'T', 'label': '480p'}) as Map;
    final start = fake.calls.firstWhere((c) => c.startsWith('jobStart:video_download:'));
    final params = jsonDecode(start.substring('jobStart:video_download:'.length)) as Map;
    expect(params, {'dir': '${docs.path}/videos', 'instance': 'a.example', 'video': 'u1', 'choice': '480', 'token': 't'});
    final list = ops.handle('video.jobs', {}) as List;
    expect(list, hasLength(1));
    expect(list.single, {
      'job': r['job'],
      'instance': 'a.example',
      'video': 'u1',
      'choice': '480',
      'title': 'T',
      'label': '480p',
      'state': 'running',
      'done': 10,
      'total': 100,
      'error': null,
    });
  });

  test('the same video started again while it runs is the running job; after a stop it starts a new one', () {
    fake.progressScript.add(running(1, 2));
    final a = ops.handle('video.jobStart', {'instance': 'a', 'video': 'u'}) as Map;
    final b = ops.handle('video.jobStart', {'instance': 'a', 'video': 'u'}) as Map;
    expect(b['job'], a['job']);
    expect(fake.calls.where((c) => c.startsWith('jobStart:')), hasLength(1));
    fake.progressScript
      ..clear()
      ..add(jsonEncode({'state': 'cancelled', 'done': 1, 'total': 2}));
    ops.handle('video.jobCancel', {'job': a['job']});
    final c = ops.handle('video.jobStart', {'instance': 'a', 'video': 'u'}) as Map;
    expect(c['job'], isNot(a['job']));
    expect(fake.calls, contains('jobFree:100'));
    expect(fake.calls.where((c) => c.startsWith('jobStart:')), hasLength(2));
  });

  test('progress carries the failure, and a freed job is gone', () {
    fake.progressScript.add(jsonEncode({'state': 'failed', 'done': 0, 'total': 0, 'error': {'code': 'no_space', 'message': 'full'}}));
    final a = ops.handle('video.jobStart', {'instance': 'a', 'video': 'u'}) as Map;
    expect((ops.handle('video.jobProgress', {'job': a['job']}) as Map)['error'], {'code': 'no_space', 'message': 'full'});
    ops.handle('video.jobFree', {'job': a['job']});
    expect(ops.handle('video.jobs', {}), isEmpty);
    expect(() => ops.handle('video.jobProgress', {'job': a['job']}), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'not_found')));
  });

  test('an unknown video op is an error', () {
    expect(() => ops.handle('video.nope', {}), throwsA(isA<CacheSearchException>()));
  });

  test('a keystore reference in a video op reaches the instance as the real token; the browser never gets the value', () {
    final keys = KeyStore(File('${tmp.path}/keystore.json'));
    keys.set('video.a.example.access', 'REAL-ACCESS');
    keys.set('video.a.example.refresh', 'REAL-REFRESH');
    final o = VideoOps(AppDirs(support, docs), () => fake, resolve: keys.resolve);
    fake.videoReplies['list'] = '{"items":[]}';
    final reply = o.handle('video.call', {
      'op': 'list',
      'request': jsonEncode({'instance': 'a.example', 'token': KeyStore.refOf('video.a.example.access'), 'refresh': KeyStore.refOf('video.a.example.refresh'), 'n': 3}),
    });
    expect(reply, '{"items":[]}');
    final sent = jsonDecode(fake.videoCalls.single.substring('list:'.length)) as Map;
    expect(sent, {'instance': 'a.example', 'token': 'REAL-ACCESS', 'refresh': 'REAL-REFRESH', 'n': 3});
    expect(reply, isNot(contains('REAL')));
    fake.progressScript.add(running(1, 2));
    o.handle('video.jobStart', {'instance': 'a.example', 'video': 'u1', 'token': KeyStore.refOf('video.a.example.access')});
    final start = fake.calls.firstWhere((c) => c.startsWith('jobStart:video_download:'));
    expect((jsonDecode(start.substring('jobStart:video_download:'.length)) as Map)['token'], 'REAL-ACCESS');
    // a request that is not JSON, or has no reference, goes on as it is; a reference to nothing is an error
    fake.videoReplies['x'] = '{}';
    o.handle('video.call', {'op': 'x', 'request': 'not json keystore://x'});
    expect(fake.videoCalls.last, 'x:not json keystore://x');
    expect(
      () => o.handle('video.call', {'op': 'list', 'request': jsonEncode({'token': KeyStore.refOf('video.gone')})}),
      throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'not_found')),
    );
  });
}
