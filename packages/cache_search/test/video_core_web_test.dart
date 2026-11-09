import 'dart:convert';

import 'package:cache_search/cache_search.dart';
import 'package:cache_search/src/video_core_web.dart' as web;
import 'package:flutter_test/flutter_test.dart';

/// Answers the helper's video.* ops from canned JSON and records what was asked.
class FakeTransport implements CoreTransport {
  final List<(String, Map<String, dynamic>)> calls = [];
  final Map<String, String> videoReplies = {};
  Object? jobsReply = const [];
  bool closed = false;

  @override
  Future<dynamic> call(String op, Map<String, dynamic> args) async {
    calls.add((op, args));
    switch (op) {
      case 'video.info':
        return {'dir': '/data/app/docs/videos'};
      case 'video.call':
        final r = videoReplies[args['op']];
        if (r == null) throw const CacheSearchException('not_found', 'no such video');
        return r;
      case 'video.jobStart':
        return {'job': 7};
      case 'video.jobProgress':
        return {'state': 'running', 'done': 10, 'total': 40, 'error': null};
      case 'video.jobs':
        return jobsReply;
      case 'video.jobCancel':
      case 'video.jobFree':
        return null;
    }
    throw StateError(op);
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  test('the web VideoCore sends typed calls as video.call and reads the server folder', () async {
    final t = FakeTransport()
      ..videoReplies['instances'] = '{"instances":[{"id":"tube.example.org","url":"https://tube.example.org","name":"Tube","version":"8"}]}'
      ..videoReplies['list'] = '{"total":0,"start":0,"videos":[]}';
    final core = await web.VideoCore.open('ignored', transport: t);
    expect(core.dir, '/data/app/docs/videos');
    expect((await core.instances()).single.id, 'tube.example.org');
    await core.list('tube.example.org', channel: 'c', token: 'T');
    final call = t.calls.last;
    expect(call.$1, 'video.call');
    expect(call.$2['op'], 'list');
    expect(jsonDecode(call.$2['request'] as String), {'instance': 'tube.example.org', 'channel': 'c', 'start': 0, 'count': 20, 'token': 'T'});
    await expectLater(core.downloads(), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'not_found')));
  });

  test('a download is a server job: start with what the tab knows, poll, cancel, free; jobs() finds them again', () async {
    final t = FakeTransport();
    final core = await web.VideoCore.open('', transport: t);
    final job = await core.startDownload('a.example', 'u1', choice: '480', token: 'T', title: 'Title', label: '480p');
    expect(t.calls.last, ('video.jobStart', {'instance': 'a.example', 'video': 'u1', 'choice': '480', 'token': 'T', 'title': 'Title', 'label': '480p'}));
    expect((await job.progress()).fraction, 0.25);
    await job.cancel();
    expect(t.calls.last, ('video.jobCancel', {'job': 7}));
    await job.free();
    await job.free();
    expect(t.calls.where((c) => c.$1 == 'video.jobFree'), hasLength(1));
    t.jobsReply = [
      {'job': 3, 'instance': 'a.example', 'video': 'u2', 'choice': 'audio', 'title': 'Two', 'label': 'Audio only', 'state': 'done', 'done': 5, 'total': 5, 'error': null},
      {'job': 4, 'instance': 'a.example', 'video': 'u3', 'choice': '720', 'title': 'Three', 'label': '720p', 'state': 'failed', 'done': 0, 'total': 0, 'error': {'code': 'no_space', 'message': 'full'}},
    ];
    final jobs = await core.jobs();
    expect(jobs.map((j) => (j.info.video, j.info.title, j.info.state, j.info.errorCode)), [('u2', 'Two', 'done', null), ('u3', 'Three', 'failed', 'no_space')]);
    await jobs.first.job.cancel();
    expect(t.calls.last, ('video.jobCancel', {'job': 3}));
    await core.close();
    expect(t.closed, isTrue);
    await expectLater(core.instances(), throwsA(isA<CacheSearchException>()));
  });
}
