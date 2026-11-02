import 'dart:async';
import 'dart:io';

import 'package:cache/screens/videos/player_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache/video/captions.dart';
import 'package:cache/video/video_prefs.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'video_player_fakes.dart';

const Size _phone = Size(430, 932);
const Size _tablet = Size(1180, 820);
const Size _shortWide = Size(1180, 560);

void _size(WidgetTester tester, Size s) {
  tester.view.physicalSize = s * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

Future<void> open(
  WidgetTester tester,
  RecordingController c,
  VideoTarget t, {
  VideoPrefs? prefs,
  bool cited = false,
  String? citedLang,
  Size size = _phone,
  VoidCallback? onRedownload,
  VoidCallback? onPlaySaved,
  bool? mobile,
}) async {
  _size(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: PlayerScreen(
        target: t,
        prefs: prefs,
        cited: cited,
        citedLang: citedLang,
        onRedownload: onRedownload,
        onPlaySaved: onPlaySaved,
        mobileOverride: mobile ?? false,
        controllerFactory: (received) {
          expect(identical(received, t), isTrue);
          return c;
        },
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('cache-player-'));
  tearDown(() => dir.deleteSync(recursive: true));

  List<DownloadedCaption> english() => [writeCaption(dir, 'en', 'English', kKnotCues)];
  List<DownloadedCaption> two() => [writeCaption(dir, 'en', 'English', kKnotCues), writeCaption(dir, 'es', 'Spanish', kKnotCuesEs, automatic: true)];

  group('player states', () {
    for (final local in [true, false]) {
      testWidgets('${local ? 'Saved' : 'Stream'}: loading, then playing, then paused; the line under the title says where it plays', (tester) async {
        final pending = Completer<void>();
        final c = RecordingController(pending: pending);
        await open(tester, c, playerTarget(local: local));
        expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'loading');
        pending.complete();
        await tester.pump();
        await tester.pump();
        expect(c.calls, ['initialize', 'play']);
        expect(find.byTooltip('Pause'), findsOneWidget, reason: 'playing');
        expect(find.text(local ? '1:00 · On this device' : '1:00 · Streaming'), findsOneWidget);
        await tester.tap(find.byTooltip('Pause'));
        await tester.pump();
        expect(find.byTooltip('Play'), findsOneWidget, reason: 'paused');
        expect(find.byTooltip('Settings'), findsOneWidget);
        expect(find.byTooltip('Full screen'), findsOneWidget);
        expect(find.text('0:00 / 1:00'), findsOneWidget);
        expect(find.byKey(const ValueKey('player-captions')), findsNothing, reason: 'no captions: no CC button');
        await close(tester);
        expect(c.calls.last, 'dispose');
      });
    }

    testWidgets('A stream that cannot play says so with Try again (and Saved copy when there is one); Try again starts it again', (tester) async {
      final c = RecordingController(fail: true);
      var saved = 0;
      _size(tester, _phone);
      var made = 0;
      final t = playerTarget(local: false);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.dark),
        home: PlayerScreen(
          target: t,
          onPlaySaved: () => saved++,
          mobileOverride: false,
          controllerFactory: (_) {
            made++;
            return made == 1 ? c : RecordingController();
          },
        ),
      ));
      await tester.pump();
      await tester.pump();
      expect(find.text("This video can't be played."), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-saved-copy')));
      expect(saved, 1);
      await tester.tap(find.byKey(const ValueKey('player-retry')));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(made, 2);
      expect(find.text("This video can't be played."), findsNothing);
      expect(find.byTooltip('Pause'), findsOneWidget);
      await close(tester);
    });

    testWidgets('A saved file that cannot play offers "Delete it and download again"', (tester) async {
      var again = 0;
      await open(tester, RecordingController(fail: true), playerTarget(), onRedownload: () => again++);
      expect(find.text("This file can't be played."), findsOneWidget);
      await tester.tap(find.text('Delete it and download again'));
      expect(again, 1);
      await close(tester);
    });

    testWidgets('The controls hide after 3 s of playback, never while paused; a tap brings them back', (tester) async {
      final c = RecordingController();
      await open(tester, c, playerTarget());
      expect(find.byKey(const ValueKey('player-play')), findsOneWidget);
      await tester.pump(kControlsHide + const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('player-play')), findsNothing, reason: 'playing: hidden');
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('player-surface'))));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('player-play')), findsOneWidget);
      await tester.tap(find.byTooltip('Pause'));
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(const ValueKey('player-play')), findsOneWidget, reason: 'paused: they stay');
      await close(tester);
    });

    testWidgets('A double tap on the right half skips forward 10 s, on the left back 10 s, with a brief +10 s / -10 s', (tester) async {
      final c = RecordingController();
      await open(tester, c, playerTarget());
      c.at(const Duration(seconds: 20));
      await tester.pump();
      final box = tester.getRect(find.byKey(const ValueKey('player-surface')));
      Future<void> doubleTap(Offset p) async {
        await tester.tapAt(p);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tapAt(p);
        await tester.pump();
      }

      await doubleTap(Offset(box.right - 12, box.center.dy));
      expect(c.calls.last, 'seek:30000');
      expect(find.text('+10 s'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('+10 s'), findsNothing);
      await doubleTap(Offset(box.left + 12, box.center.dy));
      expect(c.calls.last, 'seek:20000');
      expect(find.text('−10 s'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 800));
      await close(tester);
    });

    testWidgets('Skips clamp to zero and duration', (tester) async {
      final c = RecordingController();
      await open(tester, c, playerTarget(offset: 3));
      await tester.tap(find.byTooltip('Back 10 seconds'));
      await tester.pump();
      expect(c.calls.last, 'seek:0');
      c.at(const Duration(seconds: 57));
      await tester.pump();
      await tester.tap(find.byTooltip('Forward 10 seconds'));
      await tester.pump();
      expect(c.calls.last, 'seek:60000');
      await close(tester);
    });

    testWidgets('Speed from the gear, and true full screen: title and Back on the picture, controls on a tap; Back leaves it', (tester) async {
      final c = RecordingController();
      await open(tester, c, playerTarget());
      await tester.tap(find.byKey(const ValueKey('player-settings')));
      await tester.pumpAndSettle();
      expect(find.text('Speed'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-speed')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('speed-1.5')));
      await tester.pumpAndSettle();
      expect(c.calls.last, 'speed:1.5');
      await tester.tap(find.byKey(const ValueKey('player-settings')));
      await tester.pumpAndSettle();
      expect(find.text('1.5x'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-fullscreen')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-full')), findsOneWidget);
      expect(find.byType(AppBar), findsNothing, reason: 'the video alone');
      expect(find.byKey(const ValueKey('player-full-back')), findsOneWidget, reason: 'the controls show at first');
      expect(find.descendant(of: find.byKey(const ValueKey('player-full')), matching: find.text('Saved video')), findsOneWidget, reason: 'the title on the picture');
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('player-surface'))) + const Offset(0, 150));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('player-full-back')), findsNothing, reason: 'a tap hides them');
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      await nav.maybePop();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-full')), findsNothing);
      expect(find.byType(AppBar), findsOneWidget);
      await close(tester);
    });

    testWidgets('A phone turned sideways on a wide video goes full screen', (tester) async {
      final c = RecordingController();
      await open(tester, c, playerTarget(), size: const Size(860, 400), mobile: true);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-full')), findsOneWidget);
      await close(tester);
    });

    testWidgets('Keys: Space plays and pauses, Right and Left move 5 seconds, F full screen, Esc leaves it', (tester) async {
      final c = RecordingController();
      await open(tester, c, playerTarget(), size: const Size(1440, 900));
      c.at(const Duration(seconds: 20));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(c.calls.last, 'pause');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(c.calls.last, 'seek:25000');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(c.calls.last, 'seek:20000');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-full')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-full')), findsNothing);
      await close(tester);
    });

    testWidgets('Unmount during initialization disposes and never seeks or plays', (tester) async {
      final pending = Completer<void>();
      final c = RecordingController(pending: pending);
      await open(tester, c, playerTarget(offset: 12.3));
      await close(tester);
      pending.complete();
      await tester.pump();
      expect(c.calls, ['initialize', 'dispose']);
    });
  });

  group('resume', () {
    testWidgets('Opens where it was left, says so for 5 seconds with Start over, and keeps the new place', (tester) async {
      final prefs = VideoPrefs();
      final key = VideoPrefs.keyOf(instance: 'example.org', uuid: 'test-video');
      prefs.setPosition(key, const Duration(seconds: 42), const Duration(seconds: 60));
      final c = RecordingController();
      await open(tester, c, playerTarget(), prefs: prefs);
      expect(c.calls, ['initialize', 'seek:42000', 'play']);
      expect(find.text('Resumed at 0:42'), findsOneWidget);
      expect(find.text('Start over'), findsOneWidget);
      await tester.pump(kResumedNotice + const Duration(milliseconds: 100));
      expect(find.text('Resumed at 0:42'), findsNothing, reason: 'gone after 5 seconds');
      c.at(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 5));
      expect(prefs.positionOf(key), const Duration(seconds: 30), reason: 'kept while it plays');
      await close(tester);
    });

    testWidgets('Start over goes back to the beginning and forgets the place', (tester) async {
      final prefs = VideoPrefs();
      final key = VideoPrefs.keyOf(instance: 'example.org', uuid: 'test-video');
      prefs.setPosition(key, const Duration(seconds: 42), const Duration(seconds: 60));
      final c = RecordingController();
      await open(tester, c, playerTarget(), prefs: prefs);
      await tester.tap(find.text('Start over'));
      await tester.pump();
      expect(c.calls.last, 'seek:0');
      expect(find.text('Resumed at 0:42'), findsNothing);
      expect(prefs.positionOf(key), isNull);
      await close(tester);
    });

    testWidgets('The place is cleared in the last 10 seconds, and kept on leaving', (tester) async {
      final prefs = VideoPrefs();
      final key = VideoPrefs.keyOf(instance: 'example.org', uuid: 'test-video');
      final c = RecordingController();
      await open(tester, c, playerTarget(), prefs: prefs);
      expect(find.textContaining('Resumed'), findsNothing, reason: 'nothing kept yet: from the start');
      c.at(const Duration(seconds: 25));
      await close(tester);
      expect(prefs.positionOf(key), const Duration(seconds: 25), reason: 'leaving keeps the place');

      final c2 = RecordingController();
      await open(tester, c2, playerTarget(), prefs: prefs);
      c2.at(const Duration(seconds: 55));
      await tester.pump(const Duration(seconds: 5));
      expect(prefs.positionOf(key), isNull, reason: 'the last 10 seconds: watched');
      await close(tester);
    });

    testWidgets('A citation overrides the kept place', (tester) async {
      final prefs = VideoPrefs();
      prefs.setPosition(VideoPrefs.keyOf(instance: 'example.org', uuid: 'test-video'), const Duration(seconds: 42), const Duration(seconds: 60));
      final c = RecordingController();
      await open(tester, c, playerTarget(offset: 12.345), prefs: prefs, cited: true);
      expect(c.calls, ['initialize', 'seek:12345', 'play']);
      expect(find.textContaining('Resumed'), findsNothing);
      await close(tester);
    });

    test('Kept on this device in its own file, read back; damaged reads as empty', () async {
      final f = File('${dir.path}/video-prefs.json');
      final a = VideoPrefs(file: f);
      await a.load();
      a.setPosition('pt:x/1', const Duration(seconds: 90), const Duration(minutes: 40));
      a.captions = 'es';
      await a.flush();
      final b = VideoPrefs(file: f);
      await b.load();
      expect(b.positionOf('pt:x/1'), const Duration(seconds: 90));
      expect(b.captions, 'es');
      f.writeAsStringSync('{not json');
      final c = VideoPrefs(file: f);
      await c.load();
      expect(c.positionOf('pt:x/1'), isNull);
      expect(c.captions, isNull);
    });
  });

  group('captions', () {
    testWidgets('One language: Captions turns on and off (no sheet); the caption is on the picture; the choice is kept, and the next video starts with it', (tester) async {
      final network = NoNetwork();
      final previous = HttpOverrides.current;
      HttpOverrides.global = network;
      addTearDown(() => HttpOverrides.global = previous);
      final prefs = VideoPrefs();
      final c = RecordingController();
      await open(tester, c, playerTarget(captions: english()), prefs: prefs);
      expect(find.byTooltip('Captions: Off'), findsOneWidget, reason: 'off the first time');
      c.at(const Duration(seconds: 13));
      await tester.pump();
      expect(find.text('It makes a loop that will not slip or jam.'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('player-captions')));
      await tester.pump();
      expect(find.byTooltip('Captions: English'), findsOneWidget);
      expect(find.byKey(const ValueKey('captions-off')), findsNothing, reason: 'CC toggles: no sheet');
      expect(find.descendant(of: find.byKey(const ValueKey('caption-band')), matching: find.text('It makes a loop that will not slip or jam.')), findsOneWidget);
      expect(prefs.captions, 'en');
      expect(find.byKey(const ValueKey('player-transcript')), findsNothing, reason: 'a phone has no transcript');
      await close(tester);

      final c2 = RecordingController();
      await open(tester, c2, playerTarget(captions: english(), uuid: 'other'), prefs: prefs);
      expect(find.byTooltip('Captions: English'), findsOneWidget, reason: 'the kept choice');
      await tester.tap(find.byKey(const ValueKey('player-captions')));
      await tester.pump();
      expect(find.byTooltip('Captions: Off'), findsOneWidget);
      expect(prefs.captions, 'off');
      expect(network.attempts, 0);
      await close(tester);
    });

    testWidgets('Two languages: a long press on CC (or Captions in the gear) opens Off and each language; kept by language', (tester) async {
      final prefs = VideoPrefs();
      final c = RecordingController();
      await open(tester, c, playerTarget(captions: two()), prefs: prefs);
      await tester.tap(find.byKey(const ValueKey('player-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-captions')), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const ValueKey('player-captions')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('captions-off')), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Spanish (automatic)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('captions-es')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Captions: Spanish (automatic)'), findsOneWidget);
      expect(prefs.captions, 'es');
      c.at(const Duration(seconds: 7));
      await tester.pump();
      expect(find.text('Primero, el as de guía. Hace un lazo fijo.'), findsOneWidget);
      await close(tester);

      // a video without the kept language starts with its first one
      final c2 = RecordingController();
      await open(tester, c2, playerTarget(captions: english(), uuid: 'other'), prefs: prefs);
      expect(find.byTooltip('Captions: English'), findsOneWidget);
      await close(tester);
    });

    test('WebVTT and SubRip cues parse in time order; the cue at a time and the cited cue', () {
      final vtt = parseCues('WEBVTT\n\n00:00:05.000 --> 00:00:08.000\nSecond\n\n00:00:01.000 --> 00:00:04.000\nFirst\n');
      expect([for (final c in vtt) c.text], ['First', 'Second']);
      final srt = parseCues('1\n00:00:01,000 --> 00:00:04,000\nUno\n\n2\n00:00:05,000 --> 00:00:08,000\nDos\n');
      expect([for (final c in srt) c.text], ['Uno', 'Dos']);
      expect(cueAt(vtt, const Duration(seconds: 2)), 0);
      expect(cueAt(vtt, const Duration(milliseconds: 4500)), -1);
      expect(citedCue(vtt, const Duration(milliseconds: 4500)), 1, reason: 'a moment just before a cue finds it');
      expect(citedCue(vtt, const Duration(seconds: 30)), 1);
    });
  });

  group('transcript and the cited moment', () {
    testWidgets('Tablet: the transcript sits beside the video, follows playback, and a tap on a line seeks there', (tester) async {
      final c = RecordingController();
      await open(tester, c, playerTarget(captions: english()), size: _tablet);
      expect(find.byKey(const ValueKey('player-transcript')), findsOneWidget);
      expect(find.text('First, the bowline. It makes a fixed loop.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cue-3')));
      await tester.pump();
      expect(c.calls.last, 'seek:18000');
      await close(tester);
    });

    testWidgets('Tablet, cited: opens at the cue start with Match on it in the transcript; it clears once playback moves past', (tester) async {
      final c = RecordingController();
      await open(tester, c, playerTarget(captions: english(), offset: 12.4), size: _tablet, cited: true);
      await tester.pump();
      expect(c.calls, ['initialize', 'seek:12000', 'play'], reason: 'the cue start');
      final match = find.byKey(const ValueKey('transcript-match'));
      expect(match, findsOneWidget);
      expect(find.ancestor(of: match, matching: find.byKey(const ValueKey('cue-2'))), findsOneWidget);
      c.at(const Duration(seconds: 19));
      await tester.pump();
      expect(match, findsNothing);
      await close(tester);
    });

    testWidgets('Tablet, cited: tapping another line clears Match', (tester) async {
      final c = RecordingController();
      await open(tester, c, playerTarget(captions: english(), offset: 12), size: _tablet, cited: true);
      expect(find.byKey(const ValueKey('transcript-match')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cue-5')));
      await tester.pump();
      expect(find.byKey(const ValueKey('transcript-match')), findsNothing);
      await close(tester);
    });

    testWidgets('Phone, cited: captions show with the cited line marked Match on the picture; the kept choice is not changed', (tester) async {
      final prefs = VideoPrefs();
      final c = RecordingController();
      await open(tester, c, playerTarget(captions: english(), offset: 12), prefs: prefs, cited: true);
      expect(find.byKey(const ValueKey('player-transcript')), findsNothing);
      expect(find.byKey(const ValueKey('caption-match')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('caption-band')), matching: find.text('It makes a loop that will not slip or jam.')), findsOneWidget);
      expect(prefs.captions, isNull);
      c.at(const Duration(seconds: 19));
      await tester.pump();
      expect(find.byKey(const ValueKey('caption-match')), findsNothing);
      await close(tester);
    });

    testWidgets('Cited in Spanish (the citation\'s lang): the Spanish line is on the picture, marked; on a tablet the transcript is Spanish', (tester) async {
      final c = RecordingController();
      await open(tester, c, playerTarget(captions: two(), offset: 12), cited: true, citedLang: 'es');
      expect(find.byKey(const ValueKey('caption-match')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('caption-band')), matching: find.text('Hace un lazo que no se suelta ni se traba.')), findsOneWidget);
      await close(tester);
      final c2 = RecordingController();
      await open(tester, c2, playerTarget(captions: two(), offset: 12), cited: true, citedLang: 'es', size: _tablet);
      expect(find.text('TRANSCRIPT · Spanish (automatic)'), findsOneWidget);
      expect(find.ancestor(of: find.byKey(const ValueKey('transcript-match')), matching: find.byKey(const ValueKey('cue-2'))), findsOneWidget);
      await close(tester);
    });

    testWidgets('A wide window too short for the transcript beside: the gear has Transcript', (tester) async {
      final c = RecordingController();
      await open(tester, c, playerTarget(captions: english()), size: _shortWide);
      expect(find.byKey(const ValueKey('player-transcript')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('player-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('captions-transcript')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-transcript')), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await close(tester);
    });
  });
}
