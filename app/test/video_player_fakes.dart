import 'dart:async';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

// No platform playback or codecs: this controller records the screen's contract.
class RecordingController extends VideoPlayerController {
  RecordingController({this.pending, this.duration = const Duration(seconds: 60), this.fail = false, this.size = const Size(640, 360)}) : super.file(File('offline.mp4'));
  final Completer<void>? pending;
  final Duration duration;
  final Size size;

  /// initialize() throws, as a file the platform cannot play does.
  bool fail;
  final calls = <String>[];
  bool disposed = false;

  @override
  Future<void> initialize() async {
    calls.add('initialize');
    await pending?.future;
    if (fail) throw PlatformExceptionLike();
    if (!disposed) {
      value = value.copyWith(isInitialized: true, duration: duration, size: size);
    }
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    calls.add('speed:$speed');
    value = value.copyWith(playbackSpeed: speed);
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
  Future<void> pause() async {
    calls.add('pause');
    if (!disposed) value = value.copyWith(isPlaying: false);
  }

  /// Playback reached [at].
  void at(Duration at) => value = value.copyWith(position: at);

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    disposed = true;
    // No platform resources were created; release ChangeNotifier listeners.
    await super.dispose();
  }
}

class PlatformExceptionLike implements Exception {}

class NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('Offline player attempted HTTP');
  }
}

VideoTarget playerTarget({
  bool local = true,
  double offset = 0,
  List<DownloadedCaption> captions = const [],
  String title = 'Saved video',
  String? instance = 'example.org',
  String uuid = 'test-video',
}) =>
    VideoTarget(
      isLocal: local,
      uuid: uuid,
      title: title,
      offsetS: offset,
      durationS: 60,
      location: local ? 'offline.mp4' : 'https://video.example.test/video.mp4',
      captions: captions,
      instance: instance,
    );

/// Writes WebVTT [cues] (start s, end s, text) to a file in [dir] and gives it as a saved caption track.
DownloadedCaption writeCaption(Directory dir, String language, String label, List<(double, double, String)> cues, {bool automatic = false}) {
  String ts(double s) {
    final ms = (s * 1000).round();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:${two(ms ~/ 1000 % 60)}.${(ms % 1000).toString().padLeft(3, '0')}';
  }

  final f = File('${dir.path}/captions-$language.vtt');
  f.writeAsStringSync('WEBVTT\n\n${[for (final c in cues) '${ts(c.$1)} --> ${ts(c.$2)}\n${c.$3}\n'].join('\n')}');
  return DownloadedCaption(language: language, label: label, path: f.path, automatic: automatic);
}

/// The knots video's English cues (renders and tests).
const List<(double, double, String)> kKnotCues = [
  (2, 6, 'Three knots cover most of what you need at camp.'),
  (6, 12, 'First, the bowline. It makes a fixed loop.'),
  (12, 18, 'It makes a loop that will not slip or jam.'),
  (18, 24, 'Now the sheet bend, for joining two ropes.'),
  (24, 30, 'Pass the end up through the bight.'),
  (30, 36, 'Then the taut-line hitch, for tent guy lines.'),
  (36, 42, 'Slide it to tighten the line.'),
  (42, 50, 'Practise each one until you can tie it in the dark.'),
];

const List<(double, double, String)> kKnotCuesEs = [
  (2, 6, 'Tres nudos cubren casi todo en el campamento.'),
  (6, 12, 'Primero, el as de guía. Hace un lazo fijo.'),
  (12, 18, 'Hace un lazo que no se suelta ni se traba.'),
  (18, 24, 'Ahora el nudo de escota, para unir dos cuerdas.'),
];
