import 'dart:io';
import 'dart:typed_data';

import 'package:cache/history/conversation_store.dart' show StoredCitation;
import 'package:cache/screens/videos/player_screen.dart';
import 'package:cache/screens/videos/video_screen.dart';
import 'package:cache/screens/videos/videos_screen.dart';
import 'package:cache/settings/space.dart';
import 'package:cache/theme.dart';
import 'package:cache/video/caption_search.dart';
import 'package:cache/video/token_store.dart';
import 'package:cache/video/video_prefs.dart';
import 'package:cache/video/video_state.dart';
import 'package:cache/video/zim_video.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'video_fake.dart';

/// Lets the background isolate answer and the screen rebuild; spinners never settle, so pumpAndSettle is not used.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const Map<String, dynamic> _en = {'language': 'en', 'label': 'English', 'automatic': false, 'path': '/data/c-en.vtt'};
const Map<String, dynamic> _es = {'language': 'es', 'label': 'Spanish', 'automatic': true};

List<Map<String, dynamic>> _library({int extra = 0}) => [
      savedManifest(uuid: 'knots', title: 'Knots every camper should know', channel: 'Field Skills', at: '2026-10-03T10:00:00Z', captions: [_en]),
      savedManifest(uuid: 'fire', title: 'Fire without matches', channel: 'Field Skills', at: '2026-10-01T10:00:00Z', size: 310 * 1024 * 1024),
      savedManifest(uuid: 'splint', title: 'A splint from a stick', channel: 'Medical Basics', at: '2026-10-02T10:00:00Z', captions: [_en], missing: [_es]),
      for (var i = 0; i < extra; i++) savedManifest(uuid: 'x$i', title: 'Water filter part $i', channel: 'Medical Basics', at: '2026-09-0${i + 1}T10:00:00Z'),
    ];

Future<VideoState> _state(WidgetTester tester, List<Map<String, dynamic>> saved, {CaptionSearch? search, bool captionFetchFails = false, Space? space, bool private = false}) async {
  final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('video-ui')))!;
  addTearDown(() => dir.deleteSync(recursive: true));
  final v = VideoState(
    dirOverride: dir,
    nativeFactory: seededVideoNative(saved, captionFetchFails: captionFetchFails, private: private),
    tokens: MemoryTokenStore(),
    prefs: VideoPrefs(),
    captionSearch: search ?? const CaptionSearchMissing(),
    spaceOf: space == null ? null : () => space,
  );
  await tester.runAsync(v.init);
  addTearDown(v.dispose);
  return v;
}

Future<void> _show(WidgetTester tester, Widget w, {Size size = const Size(430, 932)}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: w));
  await settle(tester);
}

void main() {
  test('Saved videos group by channel at two or more channels, newest first; one channel has no heading', () {
    final v = VideoState(tokens: MemoryTokenStore(), prefs: VideoPrefs());
    final list = [for (final m in _library()) DownloadedVideo.fromJson(m)];
    final g = v.savedGroups(list);
    expect([for (final x in g) x.heading], ['Field Skills', 'Medical Basics'], reason: 'the group with the newest video first');
    expect([for (final d in g.first.videos) d.uuid], ['knots', 'fire']);
    final one = v.savedGroups(list.where((d) => d.channelName == 'Field Skills').toList());
    expect(one.single.heading, isNull);
    expect(v.savedGroups(const []), isEmpty);
  });

  test('A caption citation keeps time_end and lang from the core to the stored chat', () {
    final id = ConversationId.fromJson({
      'n': 3, 'address': 'cap:tube.example.org/knots/4', 'title': 'Knots, at 0:12', 'link': 'https://tube.example.org/w/knots',
      'time': 12, 'time_end': 18.5, 'quote': 'It makes a loop', 'lang': 'es',
    });
    expect((id.time, id.timeEnd, id.lang), (12.0, 18.5, 'es'));
    final stored = StoredCitation(n: 3, title: id.title, snippet: '', address: id.address, link: id.link, time: id.time, quote: id.quote, timeEnd: id.timeEnd, lang: id.lang);
    final back = StoredCitation.fromJson(stored.toJson());
    expect((back.time, back.timeEnd, back.lang, back.link), (12.0, 18.5, 'es', 'https://tube.example.org/w/knots'));
  });

  test('cs_captions_search answers parse as the interface gives them', () {
    final r = parseCaptionSearch({
      'videos': [
        {
          'source_id': 'tube.example.org/knots',
          'link': 'https://tube.example.org/w/knots',
          'title': 'Knots',
          'host': 'tube.example.org',
          'saved': true,
          'hits': [
            {'start_s': 12.0, 'end_s': 18.5, 'text': 'It makes a loop', 'lang': 'en'},
          ],
        },
        {'source_id': 'b1c2', 'link': 'zim:b1c2/videos/fema_01.mp4', 'title': 'FEMA', 'host': '', 'saved': true, 'hits': []},
      ],
    });
    expect((r.first.uuid, r.first.hits.single.startS, r.first.hits.single.endS, r.first.isZim), ('knots', 12.0, 18.5, false));
    expect((r.last.isZim, r.last.uuid), (true, null));
  });

  testWidgets('Empty: the line says how to get videos; Add a video site opens the site', timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    final v = await _state(tester, const []);
    await _show(tester, VideosScreen(video: v));
    expect(find.text('Nothing on this device yet. Find a video on a site and choose Download.'), findsOneWidget);
    expect(find.text('Saved on this device'), findsNothing, reason: 'Saved is merged into Videos');
    expect(find.text('VIDEO SITES'), findsOneWidget);
    await tester.tap(find.text('Add a video site'));
    await tester.pumpAndSettle();
    expect(find.text('The address of a PeerTube site.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'tube.example.org');
    await tester.tap(find.text('Add'));
    await settle(tester);
    expect(find.text('Search this site'), findsOneWidget);
    expect(find.text('Latest'), findsOneWidget);
  });

  testWidgets('The list: downloading rows first (Pause), then the saved videos under their channels, then the sites', timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    final v = await _state(tester, _library());
    await tester.runAsync(() => v.addInstance('tube.example.org'));
    v.tasks.add(DownloadTask(instance: 'example.org', uuid: 'water', title: 'Purifying water in the field', choice: '480', label: '480p', expectedSize: 412 * 1024 * 1024)
      ..done = 160 * 1024 * 1024
      ..total = 412 * 1024 * 1024);
    await _show(tester, VideosScreen(video: v));
    expect(find.text('DOWNLOADING'), findsOneWidget);
    expect(find.text('Purifying water in the field'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('ON THIS DEVICE · 3 videos · 770 MB'), findsOneWidget);
    double y(String s) => tester.getTopLeft(find.text(s)).dy;
    expect(y('Field Skills') < y('Knots every camper should know'), isTrue);
    expect(y('Knots every camper should know') < y('Fire without matches'), isTrue);
    expect(y('Fire without matches') < y('Medical Basics'), isTrue);
    expect(y('Medical Basics') < y('A splint from a stick'), isTrue);
    expect(find.text('480p · 230 MB · Captions'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('videos-search')), findsNothing, reason: 'search from 8 videos');
    await tester.scrollUntilVisible(find.text('Example PeerTube'), 200);
    expect(find.text('Find videos on a site'), findsOneWidget);
    expect(find.text('Add a video site'), findsNothing, reason: 'a site exists: only the quiet Add at the heading');
    expect(find.byKey(const ValueKey('videos-add-site')), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('Search from 8 videos: a caption match shows its line and time and opens the player there with the line marked', timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    final search = FakeCaptionSearch([
      const FakeCaptionVideo(host: 'example.org', uuid: 'knots', title: 'Knots every camper should know', cues: [(64, 70, 'It makes a loop that will not slip.'), (90, 96, 'Pull it tight.')]),
    ]);
    final v = await _state(tester, _library(extra: 5), search: search);
    await _show(tester, VideosScreen(video: v));
    expect(find.byKey(const ValueKey('videos-search')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('videos-search')), 'loop');
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(search.queries, ['loop']);
    expect(find.textContaining('It makes a loop that will not slip.', findRichText: true), findsOneWidget);
    expect(find.textContaining('1:04', findRichText: true), findsOneWidget);
    expect(find.text('Fire without matches'), findsNothing);
    await tester.tap(find.text('Knots every camper should know'));
    await settle(tester);
    final player = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
    expect(player.cited, isTrue);
    expect(player.target.offsetS, 64);
  });

  testWidgets('Search matches titles and channels without the captions index', timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    final v = await _state(tester, _library(extra: 5));
    await _show(tester, VideosScreen(video: v));
    await tester.enterText(find.byKey(const ValueKey('videos-search')), 'medical');
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(find.text('A splint from a stick'), findsOneWidget);
    expect(find.text('Knots every camper should know'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('videos-search')), 'zzz');
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(find.text('No saved video matches "zzz".'), findsOneWidget);
  });

  testWidgets('Video page of a saved video: no connection needed, one way to play (the picture), Delete asks first', timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    final v = await _state(tester, _library());
    await _show(tester, VideosScreen(video: v));
    await tester.tap(find.text('Knots every camper should know'));
    await settle(tester);
    expect(find.byType(VideoScreen), findsOneWidget);
    expect(find.text('On this device · 480p · 230 MB'), findsOneWidget);
    expect(find.text('Captions: English'), findsOneWidget);
    expect(find.text('Field Skills · 4:12 · 14 Mar 2026'), findsOneWidget);
    expect(find.text('Play'), findsNothing, reason: 'no Play button: the picture plays');
    await tester.tap(find.text('Delete from this device'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this video?'), findsOneWidget);
    expect(find.text('It is deleted from this device (230 MB). You can download it again later.'), findsOneWidget);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(v.saved, hasLength(3));
    await tester.tap(find.text('Delete from this device'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-delete-yes')));
    await settle(tester);
    await settle(tester);
    await tester.pumpAndSettle();
    expect(v.saved, hasLength(2));
    expect(find.byType(VideoScreen), findsNothing, reason: 'its site is not on the list: nothing is left to show, back to the list');
    expect(find.text('Knots every camper should know'), findsNothing);
  });

  testWidgets('A caption that did not save is said with Try again, which fetches only the captions', timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    final v = await _state(tester, _library());
    await _show(tester, VideoScreen(video: v, instanceId: 'example.org', uuid: 'splint', title: 'A splint from a stick'));
    expect(find.text('Spanish captions did not save.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('video-captions-retry')));
    await settle(tester);
    expect(find.text('Spanish captions did not save.'), findsNothing);
    expect(find.text('Captions: English, Spanish (automatic)'), findsOneWidget);
    expect(v.savedFor('example.org', 'splint')!.size, 230 * 1024 * 1024, reason: 'the video was not fetched again');
  });

  testWidgets('Try again that still fails says so and keeps the line', timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    final v = await _state(tester, _library(), captionFetchFails: true);
    await _show(tester, VideoScreen(video: v, instanceId: 'example.org', uuid: 'splint', title: 'A splint from a stick'));
    await tester.tap(find.byKey(const ValueKey('video-captions-retry')));
    await settle(tester);
    expect(find.text('Spanish captions did not save.'), findsOneWidget);
    expect(find.text('Spanish captions did not save. Check the connection and try again.'), findsOneWidget);
  });

  testWidgets('A site video: Not on this device; the download sheet names sizes and captions; the smallest is picked', timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    final v = await _state(tester, const [], space: const Space(free: 100 * 1024 * 1024 * 1024, reserve: 0));
    await tester.runAsync(() => v.addInstance('tube.example.org'));
    await _show(tester, VideoScreen(video: v, instanceId: 'tube.example.org', uuid: VideoFakeNative.uuid, title: 'Merry Christmas'));
    expect(find.text('Not on this device'), findsOneWidget);
    expect(find.text('Captions: English (automatic)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('video-download')));
    await tester.pumpAndSettle();
    expect(find.text('Smaller sizes use less space on this device.'), findsOneWidget);
    expect(find.text('Best 720p'), findsOneWidget);
    expect(find.text('Smaller 360p'), findsOneWidget);
    expect(find.text('Audio only'), findsOneWidget);
    expect(find.text('Captions come with it: English (automatic).'), findsOneWidget);
    expect(find.text('Download 360p · 2.9 MB'), findsOneWidget, reason: 'the smallest video size is picked first');
  });

  testWidgets('A private video, not logged in: "Log in to <site> to play this video" and Log in; after it, it plays with its qualities', timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    final v = await _state(tester, const [], private: true);
    await tester.runAsync(() => v.addInstance('tube.example.org'));
    await _show(tester, VideoScreen(video: v, instanceId: 'tube.example.org', uuid: VideoFakeNative.uuid, title: 'Merry Christmas'));
    expect(find.text('Log in to Example PeerTube to play this video'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsNothing, reason: 'the picture does not play yet');
    await tester.tap(find.byKey(const ValueKey('video-login')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'User name'), 'alice');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'right');
    await tester.tap(find.widgetWithText(FilledButton, 'Log in').last);
    await settle(tester);
    expect(find.text('Logged in as alice'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.text('Log in to Example PeerTube to play this video'), findsNothing);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    final d = await tester.runAsync(() => v.details('tube.example.org', VideoFakeNative.uuid));
    expect(d!.qualities.first.url, 'https://example.org/v-720.mp4?videoFileToken=FT1');
    expect(d.qualitiesExpire, DateTime.utc(2026, 11, 2, 12));
  });

  testWidgets('Not enough room: the sheet says so with Open Storage in place of Download', timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    final v = await _state(tester, const [], space: const Space(free: 1024 * 1024, reserve: 0));
    await tester.runAsync(() => v.addInstance('tube.example.org'));
    await _show(tester, VideoScreen(video: v, instanceId: 'tube.example.org', uuid: VideoFakeNative.uuid, title: 'Merry Christmas'));
    await tester.tap(find.byKey(const ValueKey('video-download')));
    await tester.pumpAndSettle();
    expect(find.text('Not enough room on this device.'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-sheet-download')), findsNothing);
  });

  test('A ZIM video entry: its caption entry beside it is found by name; the entry is copied to a file to play', () async {
    expect(zimCaptionCandidates('zim:u/videos/FEMA_UHA_video01.mp4').take(4), [
      'zim:u/videos/FEMA_UHA_video01.vtt',
      'zim:u/videos/FEMA_UHA_video01.srt',
      'zim:u/videos/FEMA_UHA_video01_en.vtt',
      'zim:u/videos/FEMA_UHA_video01_en.srt',
    ]);
    expect(isZimMediaAddress('zim:u/videos/a.webm#t=3'), isTrue);
    expect(isZimMediaAddress('zim:u/videos/a_en.srt'), isFalse);
    final dir = Directory.systemTemp.createTempSync('zim-video');
    addTearDown(() => dir.deleteSync(recursive: true));
    final reads = <String>[];
    Future<ZimBytes> read(String a) async {
      reads.add(a);
      if (a == 'zim:u/videos/FEMA_UHA_video01.mp4') return ZimBytes(Uint8List.fromList(List.filled(1000, 7)), 'video/mp4');
      if (a == 'zim:u/videos/FEMA_UHA_video01_en.srt') return ZimBytes(Uint8List.fromList('1\n00:00:01,000 --> 00:00:03,000\nShelter first\n'.codeUnits), 'text/plain');
      throw const CacheSearchException('not_found', 'no entry');
    }

    final z = await openZimVideo(address: 'zim:u/videos/FEMA_UHA_video01.mp4', read: read, cacheDir: dir, zimTitle: 'FEMA', offsetS: 12);
    expect(File(z.target.location).lengthSync(), 1000);
    expect(z.target.isLocal, isTrue);
    expect(z.target.offsetS, 12);
    expect(z.target.captions.single.language, 'en');
    expect(File(z.target.captions.single.path).readAsStringSync(), contains('Shelter first'));
    expect(z.target.title, 'FEMA UHA video01');
    await expectLater(
      openZimVideo(address: 'zim:u/A/Page', read: (a) async => ZimBytes(Uint8List(3), 'text/html'), cacheDir: dir, zimTitle: 'FEMA'),
      throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'unsupported')),
    );
  });
}
