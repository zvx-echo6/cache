import 'dart:io';
import 'dart:typed_data';

import 'package:cache/app_fs.dart';
import 'package:cache/screens/videos/external_sign_in.dart';
import 'package:cache/theme.dart';
import 'package:cache/video/video_media.dart';
import 'package:cache/video/video_prefs.dart';
import 'package:cache/video/video_state.dart';
import 'package:cache/video/zim_video.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the browser build of Videos does, as far as it can be tried off the web: the server addresses, the prefs kept through AppFs, a
/// server download read back as a task, the ZIM video and the pasted external sign-in.
void main() {
  tearDown(() => VideoMedia.root = null);

  group('addresses on the server', () {
    test('a saved file is its path under the videos folder, each name encoded', () {
      VideoMedia.root = '/srv/cache/app/docs/videos';
      expect(VideoMedia.file('/srv/cache/app/docs/videos/tube.example.org/abc-123/video 480.mp4'), '/api/video/media/tube.example.org/abc-123/video%20480.mp4');
      expect(VideoMedia.file('/srv/cache/app/docs/videos/tube.example.org_9000/u/thumb.jpg'), '/api/video/media/tube.example.org_9000/u/thumb.jpg');
    });

    test('without the folder known, the part after /videos/ is used; a server address stays as it is', () {
      expect(VideoMedia.file('/data/app/docs/videos/a/b/c.vtt'), '/api/video/media/a/b/c.vtt');
      expect(VideoMedia.file('/api/video/zim/x/y.vtt'), '/api/video/zim/x/y.vtt');
    });

    test('a ZIM entry and a remote stream', () {
      expect(VideoMedia.zimEntry('zim:0f1e2d3c-0000-4000-8000-123456789abc/videos/My Clip.mp4'), '/api/video/zim/0f1e2d3c-0000-4000-8000-123456789abc/videos/My%20Clip.mp4');
      expect(VideoMedia.stream('https://tube.example.org/a b.mp4?x=1&y=2'), '/api/video/stream?u=https%3A%2F%2Ftube.example.org%2Fa+b.mp4%3Fx%3D1%26y%3D2');
      // off the web an address is left alone
      expect(VideoMedia.remote('https://tube.example.org/a.mp4'), 'https://tube.example.org/a.mp4');
    });
  });

  group('video prefs through AppFs', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('video-prefs-fs'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('positions, captions and quality are kept in video-prefs.json of the support folder and read back', () async {
      final support = Directory('${tmp.path}/support')..createSync();
      final fs = createAppFs(supportOverride: support, docsOverride: Directory('${tmp.path}/docs'));
      final a = VideoPrefs(fs: fs);
      await a.load();
      a.setPosition('pt:a/u', const Duration(minutes: 3), const Duration(minutes: 10));
      a.captions = 'en';
      a.quality = '720';
      await a.flush();
      expect(File('${support.path}/video-prefs.json').existsSync(), isTrue);
      final b = VideoPrefs(fs: fs);
      await b.load();
      expect(b.positionOf('pt:a/u'), const Duration(minutes: 3));
      expect((b.captions, b.quality), ('en', '720'));
    });

    test('a missing file is an empty record', () async {
      final p = VideoPrefs(fs: createAppFs(supportOverride: Directory('${tmp.path}/none'), docsOverride: tmp));
      await p.load();
      expect(p.captions, isNull);
    });
  });

  group('server downloads read back as tasks', () {
    VideoJobInfo info(String state, {String? code}) =>
        VideoJobInfo(instance: 'tube.example.org', video: 'u1', choice: '480', title: 'Title', label: '480p', state: state, done: 5, total: 20, errorCode: code, errorMessage: code == null ? null : 'full');

    test('running, done, paused (cancelled) and failed', () {
      final running = VideoState.taskFromServerJob(info('running'));
      expect((running.phase, running.done, running.total, running.title, running.label, running.choice), (DownloadPhase.running, 5, 20, 'Title', '480p', '480'));
      expect(VideoState.taskFromServerJob(info('done')).phase, DownloadPhase.done);
      expect(VideoState.taskFromServerJob(info('cancelled')).phase, DownloadPhase.cancelled);
      final failed = VideoState.taskFromServerJob(info('failed', code: 'no_space'));
      expect(failed.phase, DownloadPhase.failed);
      expect(failed.error, 'Not enough free space on this device.');
    });
  });

  group('a ZIM video in the browser', () {
    const id = '0f1e2d3c-0000-4000-8000-123456789abc';
    Future<ZimBytes> read(String a) async {
      if (a.endsWith('_en.vtt')) return ZimBytes(Uint8List.fromList([1, 2, 3]), 'text/vtt');
      throw const CacheSearchException('not_found', 'no');
    }

    test('plays from the server route, with the caption entry found beside it', () async {
      final v = await openZimVideoWeb(address: 'zim:$id/v/FEMA_clip.mp4#t=3', read: read, zimTitle: 'FEMA', offsetS: 12, headStatus: (_) async => 200);
      expect(v.zimTitle, 'FEMA');
      final t = v.target;
      expect((t.isLocal, t.isAudio, t.offsetS, t.uuid), (true, false, 12.0, 'zim:$id/v/FEMA_clip.mp4'));
      expect(t.location, '/api/video/zim/$id/v/FEMA_clip.mp4');
      expect(t.title, 'FEMA clip');
      expect(t.captions.single.path, '/api/video/zim/$id/v/FEMA_clip_en.vtt');
      expect(t.captions.single.language, 'en');
    });

    test('a sound entry is audio; a missing entry is not_found; a page is not a video', () async {
      final a = await openZimVideoWeb(address: 'zim:$id/a/talk.mp3', read: read, zimTitle: 'Z', headStatus: (_) async => 200);
      expect(a.target.isAudio, isTrue);
      await expectLater(openZimVideoWeb(address: 'zim:$id/v/x.mp4', read: read, zimTitle: 'Z', headStatus: (_) async => 404), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'not_found')));
      await expectLater(openZimVideoWeb(address: 'zim:$id/A/page', read: read, zimTitle: 'Z', headStatus: (_) async => 200), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'unsupported')));
    });
  });

  group('sign in with a site plugin, in a browser', () {
    Future<ExternalSignIn?> run(WidgetTester tester, String pasted) async {
      ExternalSignIn? result;
      var done = false;
      final opened = <String>[];
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.dark),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<ExternalSignIn>(
                context: context,
                builder: (_) => ExternalSignInPasteDialog(
                  auth: const VideoExternalAuth(authName: 'gitlab', displayName: 'GitLab', url: 'https://tube.example.org/plugins/auth/gitlab'),
                  returnPrefix: 'https://tube.example.org/login',
                  open: opened.add,
                ),
              );
              done = true;
            },
            child: const Text('go'),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('external-open')));
      expect(opened, ['https://tube.example.org/plugins/auth/gitlab']);
      await tester.enterText(find.byKey(const ValueKey('external-paste')), pasted);
      await tester.tap(find.byKey(const ValueKey('external-done')));
      await tester.pumpAndSettle();
      if (!done) {
        // the dialog is still open (the address was not the one) and says so: close it
        expect(find.textContaining('not the address'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
      return result;
    }

    testWidgets('the address the site ends on gives the one-time token and the user', (tester) async {
      final r = await run(tester, 'https://tube.example.org/login?externalAuthToken=TOK&username=alice');
      expect(r, isA<ExternalSignInDone>());
      expect((r! as ExternalSignInDone).username, 'alice');
      expect((r as ExternalSignInDone).token, 'TOK');
    });

    testWidgets('any other address says so and stays open', (tester) async {
      final r = await run(tester, 'https://elsewhere.example/login');
      expect(r, isNull);
    });
  });
}
