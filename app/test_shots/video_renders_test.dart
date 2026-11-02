// The 1.0.30 video experience (UX-video-30, section 3's render list) for the owner to review, drawn by the app's own widgets with
// sample videos made here (pictures drawn in the test, the project's own caption words, no personal data). Every picture in the
// light and the dark theme; phone, tablet and desktop where the list says.
// flutter test test_shots/video_renders_test.dart --update-goldens  (pictures in test_shots/video/)

import 'dart:io';

import 'package:cache/screens/download_confirm.dart' show openStorageForSpace;
import 'package:cache/screens/videos/instance_sheet.dart';
import 'package:cache/screens/videos/player_screen.dart';
import 'package:cache/screens/videos/video_screen.dart';
import 'package:cache/screens/videos/videos_screen.dart';
import 'package:cache/settings/space.dart';
import 'package:cache/theme.dart';
import 'package:cache/video/caption_search.dart';
import 'package:cache/video/token_store.dart';
import 'package:cache/video/video_prefs.dart';
import 'package:cache/video/video_state.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../test/video_fake.dart';
import '../test/video_player_fakes.dart';
import 'shot_kit.dart';

const _out = 'video';
const Size kPhone = Size(430, 932);
const Size kTablet = Size(1180, 820);
const Size kDesktop = Size(1440, 900);

late Directory _dir;
late String _frame;
final Map<String, String> _thumbs = {};

String _t(CacheThemeId t) => t == CacheThemeId.light ? 'light' : 'dark';

Future<void> _settle(WidgetTester tester, {int n = 8}) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// A picture for a sample video: a sky, a ground and a sun in [hue]'s colours (drawn here, no photo).
String _picture(String name, int r, int g, int b, {int w = 640, int h = 360}) {
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final sky = y < h * 0.62;
      final t = y / h;
      final sun = (x - w * 0.72) * (x - w * 0.72) + (y - h * 0.3) * (y - h * 0.3) < (h * 0.12) * (h * 0.12);
      if (sun) {
        im.setPixelRgb(x, y, 250, 226, 160);
      } else if (sky) {
        im.setPixelRgb(x, y, (r * (1 - t * 0.5)).round(), (g * (1 - t * 0.4)).round(), (b * (1 - t * 0.2)).round());
      } else {
        final hill = (y - h * 0.62) / (h * 0.38);
        im.setPixelRgb(x, y, (60 + 40 * hill).round(), (90 + 30 * hill).round(), (52 + 10 * hill).round());
      }
    }
  }
  final f = File('${_dir.path}/$name.png')..writeAsBytesSync(img.encodePng(im));
  return f.path;
}

Map<String, dynamic> _cap(String lang, String label, {bool auto = false}) => {'language': lang, 'label': label, 'automatic': auto, 'path': '${_dir.path}/captions-$lang.vtt'};

List<Map<String, dynamic>> _library({int extra = 0, bool missing = false}) => [
      savedManifest(uuid: 'knots', title: 'Knots every camper should know', channel: 'Field Skills', at: '2026-10-03T10:00:00Z', durationS: 730, captions: [_cap('en', 'English'), _cap('es', 'Spanish', auto: true)], thumb: _thumbs['knots']),
      savedManifest(uuid: 'fire', title: 'Fire without matches', channel: 'Field Skills', at: '2026-10-01T10:00:00Z', size: 310 * 1024 * 1024, durationS: 580, captions: [_cap('en', 'English')], thumb: _thumbs['fire']),
      savedManifest(
        uuid: 'splint',
        title: 'A splint from a stick',
        channel: 'Medical Basics',
        at: '2026-10-02T10:00:00Z',
        size: 96 * 1024 * 1024,
        durationS: 312,
        captions: [_cap('en', 'English')],
        missing: missing ? [{'language': 'es', 'label': 'Spanish', 'automatic': true}] : const [],
        thumb: _thumbs['splint'],
      ),
      savedManifest(uuid: 'burns', title: 'Treating a burn', channel: 'Medical Basics', at: '2026-09-28T10:00:00Z', size: 140 * 1024 * 1024, durationS: 401, thumb: _thumbs['burns']),
      for (var i = 0; i < extra; i++)
        savedManifest(uuid: 'w$i', title: 'Water filter, part ${i + 1}', channel: 'Water', at: '2026-09-1${i}T10:00:00Z', size: (60 + 10 * i) * 1024 * 1024, durationS: 200 + 30 * i, thumb: _thumbs['water']),
    ];

Future<VideoState> _state(WidgetTester tester, List<Map<String, dynamic>> saved, {CaptionSearch? search, Space? space, bool noCaptions = false, bool site = true, bool private = false, String auth = 'local'}) async {
  final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('video-shot')))!;
  addTearDown(() => dir.deleteSync(recursive: true));
  final v = VideoState(
    dirOverride: dir,
    nativeFactory: seededVideoNative(saved, noCaptions: noCaptions, private: private, auth: auth),
    tokens: MemoryTokenStore(),
    prefs: VideoPrefs(),
    captionSearch: search ?? const CaptionSearchMissing(),
    spaceOf: () => space ?? const Space(free: 40 * 1024 * 1024 * 1024, reserve: 0),
  );
  await tester.runAsync(v.init);
  if (site) await tester.runAsync(() => v.addInstance('tube.example.org'));
  addTearDown(v.dispose);
  return v;
}

DownloadTask _downloading({String uuid = 'water', String title = 'Purifying water in the field', String instance = 'example.org'}) =>
    DownloadTask(instance: instance, uuid: uuid, title: title, choice: '480', label: '480p', expectedSize: 412 * 1024 * 1024)
      ..done = 160 * 1024 * 1024
      ..total = 412 * 1024 * 1024;

Future<void> _show(WidgetTester tester, Widget page, CacheThemeId theme, {Size size = kPhone}) async {
  phone(tester, size: size, ratio: size == kPhone ? 3 : 2);
  await tester.pumpWidget(shotApp(page, theme: theme, insets: size == kPhone ? null : EdgeInsets.zero));
  await _settle(tester);
  // the sample pictures, read once (an image file loads outside the test's clock)
  final ctx = tester.element(find.byType(Scaffold).first);
  await tester.runAsync(() async {
    for (final p in [..._thumbs.values, _frame]) {
      await precacheImage(FileImage(File(p)), ctx);
    }
  });
  await tester.pump();
}

Future<void> _snap(WidgetTester tester, String name, CacheThemeId theme) => snap(tester, _out, '$name-${_t(theme)}');

PlayerScreen _player(
  RecordingController c, {
  bool two = true,
  double offset = 0,
  bool cited = false,
  VideoPrefs? prefs,
  String title = 'Knots every camper should know',
  String channel = 'Field Skills',
  String? instance = 'example.org',
  String uuid = 'knots',
  List<DownloadedCaption>? captions,
  VoidCallback? onRedownload,
  String? where,
}) =>
    PlayerScreen(
      target: VideoTarget(
        isLocal: true,
        uuid: uuid,
        title: title,
        offsetS: offset,
        durationS: 730,
        location: 'offline.mp4',
        instance: instance,
        captions: captions ??
            [
              writeCaption(_dir, 'en', 'English', kKnotCues),
              if (two) writeCaption(_dir, 'es', 'Spanish', kKnotCuesEs, automatic: true),
            ],
      ),
      prefs: prefs ?? VideoPrefs(),
      cited: cited,
      channel: channel,
      where: where,
      onRedownload: onRedownload,
      mobileOverride: false,
      savedQuality: instance == null ? null : '480p',
      frame: Image.file(File(_frame), fit: BoxFit.cover),
      controllerFactory: (_) => c,
    );

void main() {
  setUpAll(() async {
    await loadShotFonts();
    _dir = Directory.systemTemp.createTempSync('video-shots');
    _frame = _picture('frame', 120, 170, 220, w: 1280, h: 720);
    _thumbs['knots'] = _picture('knots', 110, 160, 210);
    _thumbs['fire'] = _picture('fire', 210, 130, 90);
    _thumbs['splint'] = _picture('splint', 150, 190, 170);
    _thumbs['burns'] = _picture('burns', 190, 160, 200);
    _thumbs['water'] = _picture('water', 90, 170, 200);
    // caption files the saved records point at
    writeCaption(_dir, 'en', 'English', kKnotCues);
    writeCaption(_dir, 'es', 'Spanish', kKnotCuesEs, automatic: true);
    openStorageForSpace = (_) {};
  });

  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    final n = _t(theme);

    testWidgets('1: the Videos list ($n)', (tester) async {
      var v = await _state(tester, _library());
      v.tasks.add(_downloading());
      await _show(tester, VideosScreen(video: v), theme);
      await _snap(tester, '1a-list-downloading-grouped', theme);

      v = await _state(tester, const [], site: false);
      await _show(tester, VideosScreen(video: v), theme);
      await _snap(tester, '1b-list-empty', theme);

      final search = FakeCaptionSearch([
        FakeCaptionVideo(host: 'example.org', uuid: 'knots', title: 'Knots every camper should know', cues: [for (final c in kKnotCues) (c.$1 + 60, c.$2 + 60, c.$3)]),
        const FakeCaptionVideo(host: 'example.org', uuid: 'splint', title: 'A splint from a stick', cues: [(95, 101, 'Tie the splint above and below the break with a loop.')]),
      ]);
      v = await _state(tester, _library(extra: 5), search: search);
      await _show(tester, VideosScreen(video: v), theme);
      await tester.enterText(find.byKey(const ValueKey('videos-search')), 'loop');
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await _snap(tester, '1c-list-search-caption-match', theme);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('2-5: the player ($n)', (tester) async {
      var c = RecordingController(duration: const Duration(seconds: 730), size: const Size(1280, 720));
      final prefs = VideoPrefs()..captions = 'en';
      await _show(tester, _player(c, prefs: prefs), theme);
      c.at(const Duration(seconds: 14));
      await tester.pump();
      await _snap(tester, '2a-player-captions-on', theme);
      await tester.longPress(find.byKey(const ValueKey('player-captions')));
      await tester.pumpAndSettle();
      await _snap(tester, '2b-captions-sheet', theme);
      await tester.tapAt(const Offset(200, 120));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-settings')));
      await tester.pumpAndSettle();
      await _snap(tester, '2d-settings-sheet', theme);
      await tester.tap(find.byKey(const ValueKey('settings-speed')));
      await tester.pumpAndSettle();
      await _snap(tester, '2c-speed-sheet', theme);
      await tester.pumpWidget(const SizedBox());

      // a stream from a video site: the gear's Quality, then its choices
      c = RecordingController(duration: const Duration(seconds: 730), size: const Size(1280, 720));
      await _show(
        tester,
        PlayerScreen(
          target: playerTarget(local: false, title: 'Knots every camper should know'),
          qualities: const [
            VideoQuality(key: '1080', label: '1080p', url: 'https://tube.example.org/v-1080.mp4'),
            VideoQuality(key: '720', label: '720p', url: 'https://tube.example.org/v-720.mp4'),
            VideoQuality(key: '480', label: '480p', url: 'https://tube.example.org/v-480.mp4'),
            VideoQuality(key: '360', label: '360p', url: 'https://tube.example.org/v-360.mp4'),
          ],
          captionUrls: const [],
          prefs: VideoPrefs(),
          channel: 'Field Skills',
          mobileOverride: false,
          frame: Image.file(File(_frame), fit: BoxFit.cover),
          controllerFactory: (_) => c,
        ),
        theme,
      );
      await tester.tap(find.byKey(const ValueKey('player-settings')));
      await tester.pumpAndSettle();
      await _snap(tester, '2e-settings-quality-stream', theme);
      await tester.tap(find.byKey(const ValueKey('settings-quality')));
      await tester.pumpAndSettle();
      await _snap(tester, '2f-quality-sheet-stream', theme);
      await tester.pumpWidget(const SizedBox());

      c = RecordingController(duration: const Duration(seconds: 730), size: const Size(1280, 720));
      await _show(tester, _player(c, offset: 12, cited: true), theme);
      await _snap(tester, '3a-player-cited-match', theme);
      await tester.pumpWidget(const SizedBox());

      c = RecordingController(duration: const Duration(seconds: 730), size: const Size(1280, 720));
      final kept = VideoPrefs()..setPosition(VideoPrefs.keyOf(instance: 'example.org', uuid: 'knots'), const Duration(minutes: 3, seconds: 42), const Duration(seconds: 730));
      await _show(tester, _player(c, prefs: kept), theme);
      await _snap(tester, '4a-player-resumed', theme);
      await tester.pumpWidget(const SizedBox());

      c = RecordingController(fail: true);
      await _show(tester, PlayerScreen(target: playerTarget(local: false, title: 'Knots every camper should know'), mobileOverride: false, controllerFactory: (_) => c), theme);
      await _snap(tester, '4b-player-error-try-again', theme);
      await tester.pumpWidget(const SizedBox());

      c = RecordingController(fail: true);
      await _show(tester, _player(c, onRedownload: () {}), theme);
      await _snap(tester, '4c-player-file-error-download-again', theme);
      await tester.pumpWidget(const SizedBox());

      c = RecordingController(duration: const Duration(seconds: 730), size: const Size(1280, 720));
      await _show(tester, _player(c, prefs: VideoPrefs()..captions = 'en'), theme, size: const Size(932, 430));
      c.at(const Duration(seconds: 14));
      await tester.tap(find.byKey(const ValueKey('player-fullscreen')));
      await tester.pumpAndSettle();
      await _snap(tester, '5a-full-screen-captions-controls', theme);
      await tester.tapAt(const Offset(466, 130));
      await tester.pump(const Duration(milliseconds: 400));
      await _snap(tester, '5b-full-screen-captions', theme);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('6-7: the video page and the download sheet ($n)', (tester) async {
      var v = await _state(tester, const []);
      await _show(tester, VideoScreen(video: v, instanceId: 'tube.example.org', uuid: VideoFakeNative.uuid, title: 'Merry Christmas'), theme);
      await _snap(tester, '6a-page-not-saved', theme);
      await tester.tap(find.byKey(const ValueKey('video-download')));
      await tester.pumpAndSettle();
      await _snap(tester, '7a-download-sheet-captions', theme);
      await tester.pumpWidget(const SizedBox());

      v = await _state(tester, const []);
      v.tasks.add(_downloading(uuid: VideoFakeNative.uuid, title: 'Merry Christmas', instance: 'tube.example.org'));
      await _show(tester, VideoScreen(video: v, instanceId: 'tube.example.org', uuid: VideoFakeNative.uuid, title: 'Merry Christmas'), theme);
      await _snap(tester, '6b-page-downloading', theme);
      await tester.pumpWidget(const SizedBox());

      v = await _state(tester, _library(), site: false);
      await _show(tester, VideoScreen(video: v, instanceId: 'example.org', uuid: 'knots', title: 'Knots every camper should know'), theme);
      await _snap(tester, '6c-page-saved', theme);
      await tester.tap(find.byKey(const ValueKey('video-delete')));
      await tester.pumpAndSettle();
      await _snap(tester, '6e-delete-confirm', theme);
      await tester.pumpWidget(const SizedBox());

      v = await _state(tester, _library(missing: true), site: false);
      await _show(tester, VideoScreen(video: v, instanceId: 'example.org', uuid: 'splint', title: 'A splint from a stick'), theme);
      await _snap(tester, '6d-page-saved-missing-caption', theme);
      await tester.pumpWidget(const SizedBox());

      v = await _state(tester, const [], noCaptions: true);
      await _show(tester, VideoScreen(video: v, instanceId: 'tube.example.org', uuid: VideoFakeNative.uuid, title: 'Merry Christmas'), theme);
      await tester.tap(find.byKey(const ValueKey('video-download')));
      await tester.pumpAndSettle();
      await _snap(tester, '7b-download-sheet-no-captions', theme);
      await tester.pumpWidget(const SizedBox());

      v = await _state(tester, const [], private: true);
      await _show(tester, VideoScreen(video: v, instanceId: 'tube.example.org', uuid: VideoFakeNative.uuid, title: 'Merry Christmas'), theme);
      await _snap(tester, '6f-page-private-log-in', theme);
      await tester.pumpWidget(const SizedBox());

      v = await _state(tester, const [], space: const Space(free: 1024 * 1024, reserve: 0));
      await _show(tester, VideoScreen(video: v, instanceId: 'tube.example.org', uuid: VideoFakeNative.uuid, title: 'Merry Christmas'), theme);
      await tester.tap(find.byKey(const ValueKey('video-download')));
      await tester.pumpAndSettle();
      await _snap(tester, '7c-download-sheet-no-room', theme);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('8: a ZIM video in the same player ($n)', (tester) async {
      final c = RecordingController(duration: const Duration(seconds: 730), size: const Size(1280, 720));
      final prefs = VideoPrefs()..captions = 'en';
      await _show(
        tester,
        _player(
          c,
          prefs: prefs,
          title: 'FEMA UHA video01',
          channel: 'In FEMA Preparedness',
          where: 'On this device',
          instance: null,
          uuid: 'zim:b1c2/videos/FEMA_UHA_video01.mp4',
          captions: [writeCaption(_dir, 'zim', 'On', kKnotCues)],
        ),
        theme,
      );
      c.at(const Duration(seconds: 20));
      await tester.pump();
      await _snap(tester, '8-zim-video-player', theme);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('10: the sign-in sheet as the site offers it ($n)', (tester) async {
      for (final (name, auth) in [('10a-sign-in-local-only', 'local'), ('10b-sign-in-external-only', 'external'), ('10c-sign-in-both', 'both')]) {
        final v = await _state(tester, const [], auth: auth);
        await _show(
          tester,
          Builder(
            builder: (context) => Scaffold(
              appBar: AppBar(title: const Text('Example PeerTube')),
              body: Center(child: TextButton(onPressed: () => showInstanceSheet(context, video: v, instance: v.instances.single), child: const Text('open'))),
            ),
          ),
          theme,
        );
        await tester.tap(find.text('open'));
        await _settle(tester);
        await tester.pumpAndSettle();
        await _snap(tester, name, theme);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('9: tablet and desktop ($n)', (tester) async {
      for (final (name, size) in [('9a-tablet-landscape-player', kTablet), ('9b-desktop-player', kDesktop)]) {
        final c = RecordingController(duration: const Duration(seconds: 730), size: const Size(1280, 720));
        await _show(tester, _player(c, prefs: VideoPrefs()..captions = 'en'), theme, size: size);
        c.at(const Duration(seconds: 14));
        await tester.pump();
        await _snap(tester, name, theme);
        await tester.pumpWidget(const SizedBox());
      }
      final c = RecordingController(duration: const Duration(seconds: 730), size: const Size(1280, 720));
      await _show(tester, _player(c, offset: 30, cited: true), theme, size: kTablet);
      await _snap(tester, '9c-tablet-cited-match', theme);
      await tester.pumpWidget(const SizedBox());

      for (final (name, size) in [('9d-tablet-list', kTablet), ('9e-desktop-list', kDesktop)]) {
        final v = await _state(tester, _library(extra: 5));
        v.tasks.add(_downloading());
        await _show(tester, VideosScreen(video: v), theme, size: size);
        await _snap(tester, name, theme);
        await tester.pumpWidget(const SizedBox());
      }
      final v = await _state(tester, _library(), site: false);
      await _show(tester, VideoScreen(video: v, instanceId: 'example.org', uuid: 'knots', title: 'Knots every camper should know'), theme, size: kTablet);
      await _snap(tester, '9f-tablet-video-page', theme);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
