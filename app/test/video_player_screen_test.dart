import 'dart:async';
import 'dart:io';

import 'package:cache/screens/videos/player_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';

// No platform playback or codecs: this controller records the screen's contract.
class RecordingController extends VideoPlayerController {
  RecordingController({this.pending}) : super.file(File('offline.mp4'));
  final Completer<void>? pending;
  final calls = <String>[];
  ClosedCaptionFile? captions;
  bool disposed = false;

  @override
  Future<void> initialize() async {
    calls.add('initialize');
    await pending?.future;
    if (!disposed) {
      value = value.copyWith(
        isInitialized: true,
        duration: const Duration(seconds: 60),
        size: const Size(640, 360),
      );
    }
  }

  @override
  Future<void> seekTo(Duration position) async {
    calls.add('seek:${position.inMilliseconds}');
    value = value.copyWith(position: position);
  }

  @override
  Future<void> play() async {
    calls.add('play');
    if (!disposed) value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> setClosedCaptionFile(Future<ClosedCaptionFile>? file) async {
    captions = await file;
    value = value.copyWith(caption: captions!.captions.first);
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    disposed = true;
    // No platform resources were created; release ChangeNotifier listeners.
    await super.dispose();
  }
}

class NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('Offline player attempted HTTP');
  }
}

VideoTarget target({
  bool local = true,
  double offset = 12.345,
  List<DownloadedCaption> captions = const [],
}) => VideoTarget(
  isLocal: local,
  uuid: 'test-video',
  title: 'Saved video',
  offsetS: offset,
  durationS: 60,
  location: local ? 'offline.mp4' : 'https://video.example.test/video.mp4',
  captions: captions,
);

Future<void> open(
  WidgetTester tester,
  RecordingController c,
  VideoTarget t,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: PlayerScreen(
        target: t,
        controllerFactory: (received) {
          expect(identical(received, t), isTrue);
          return c;
        },
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final local in [true, false]) {
    testWidgets(
      '${local ? 'Downloaded' : 'Stream'} citation initializes, seeks exact offset, then plays',
      (tester) async {
        final c = RecordingController();
        await open(tester, c, target(local: local));
        expect(c.calls, ['initialize', 'seek:12345', 'play']);
        expect(find.byTooltip('Pause'), findsOneWidget);
        expect(find.text('Streaming'), local ? findsNothing : findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        expect(c.calls.last, 'dispose');
      },
    );
  }

  testWidgets('Zero offset plays without an unnecessary seek', (tester) async {
    final c = RecordingController();
    await open(tester, c, target(offset: 0));
    expect(c.calls, ['initialize', 'play']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Downloaded WebVTT captions parse locally and toggle without HTTP',
    (tester) async {
      final network = NoNetwork();
      final previous = HttpOverrides.current;
      HttpOverrides.global = network;
      addTearDown(() => HttpOverrides.global = previous);
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('cache-player-'),
      );
      addTearDown(() => dir!.deleteSync(recursive: true));
      final file = File('${dir!.path}/captions.vtt');
      file.writeAsStringSync(
        'WEBVTT\n\n00:00:10.000 --> 00:00:15.000\nLocal caption\n\n00:00:20.000 --> 00:00:25.000\nSecond cue\n',
      );
      final c = RecordingController();
      await open(
        tester,
        c,
        target(
          captions: [
            DownloadedCaption(
              language: 'en',
              label: 'English',
              path: file.path,
            ),
          ],
        ),
      );
      expect(find.text('Local caption'), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Show captions'));
        for (var i = 0; i < 50 && c.captions == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
      expect(c.captions!.captions, hasLength(2));
      expect(c.captions!.captions.first.start, const Duration(seconds: 10));
      expect(c.captions!.captions.first.end, const Duration(seconds: 15));
      expect(c.captions!.captions.last.text, 'Second cue');
      expect(find.text('Local caption'), findsOneWidget);
      await tester.tap(find.byTooltip('Hide captions'));
      await tester.pump();
      expect(find.text('Local caption'), findsNothing);
      expect(find.byTooltip('Show captions (English)'), findsOneWidget);
      expect(network.attempts, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Skips clamp to zero and duration', (tester) async {
    final c = RecordingController();
    await open(tester, c, target(offset: 3));
    await tester.tap(find.byTooltip('Back 10 seconds'));
    await tester.pump();
    expect(c.calls.last, 'seek:0');
    c.value = c.value.copyWith(position: const Duration(seconds: 57));
    await tester.pump();
    await tester.tap(find.byTooltip('Forward 10 seconds'));
    await tester.pump();
    expect(c.calls.last, 'seek:60000');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Unmount during initialization disposes and never seeks or plays',
    (tester) async {
      final pending = Completer<void>();
      final c = RecordingController(pending: pending);
      await open(tester, c, target());
      expect(c.calls, ['initialize']);
      await tester.pumpWidget(const SizedBox());
      expect(c.calls, ['initialize', 'dispose']);
      pending.complete();
      await tester.pump();
      expect(c.calls, ['initialize', 'dispose']);
      expect(tester.takeException(), isNull);
    },
  );
}
