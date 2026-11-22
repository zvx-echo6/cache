import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import '../net/fetch.dart';
import '../platform.dart' as plat;
import 'video_media.dart';

/// One caption line with its time, as the player and the transcript show it.
class Cue {
  const Cue(this.start, this.end, this.text);

  final Duration start;
  final Duration end;
  final String text;

  bool covers(Duration at) => at >= start && at < end;
}

/// The cues of a WebVTT or SubRip file (the video_player package's own parsers), in time order, with empty cues left out.
List<Cue> parseCues(String text) {
  final t = text.startsWith('﻿') ? text.substring(1) : text;
  final ClosedCaptionFile f = t.trimLeft().startsWith('WEBVTT') ? WebVTTCaptionFile(t) : SubRipCaptionFile(t);
  final cues = [
    for (final c in f.captions)
      if (c.text.trim().isNotEmpty) Cue(c.start, c.end, c.text.trim()),
  ]..sort((a, b) => a.start.compareTo(b.start));
  return cues;
}

/// The index of the cue showing at [at], or -1.
int cueAt(List<Cue> cues, Duration at) {
  var lo = 0;
  var hi = cues.length - 1;
  var best = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (cues[mid].start <= at) {
      best = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return best >= 0 && cues[best].covers(at) ? best : -1;
}

/// The cue a cited moment [at] points at: the one showing then, else the next one to start (a citation starts at a cue, so
/// a moment a fraction before it still finds it), else the last one before it. -1 when there are none.
int citedCue(List<Cue> cues, Duration at) {
  if (cues.isEmpty) return -1;
  final i = cueAt(cues, at);
  if (i >= 0) return i;
  for (var n = 0; n < cues.length; n++) {
    if (cues[n].start >= at) return n;
  }
  return cues.length - 1;
}

/// A caption track a video has: saved beside the video, inside a ZIM (extracted to a file), or an address to fetch (streaming).
class CaptionTrack {
  const CaptionTrack({required this.language, required this.label, this.automatic = false, this.path, this.url});

  final String language;
  final String label;
  final bool automatic;
  final String? path;
  final String? url;

  /// "English", or "Spanish (automatic)" for captions the site's speech recognition made.
  String get name => automatic ? '$label (automatic)' : label;

  /// Test hook: the client a browser reads captions with.
  static http.Client? webClient;

  Future<List<Cue>> load() async {
    // A caption file is small (at most 5 MB): read at once, so the first cue is there when playback starts.
    // A browser reads the same files through the server (a page may not read a video site, and the saved files are on the server).
    if (plat.isWeb && (path != null || url != null)) {
      final address = path != null ? VideoMedia.file(path!) : VideoMedia.remote(url!);
      final res = await (webClient ?? http.Client()).get(VideoMedia.resolve(address));
      if (res.statusCode != 200) throw StateError('captions: HTTP ${res.statusCode}');
      return parseCues(utf8.decode(res.bodyBytes, allowMalformed: true));
    }
    if (path != null) return parseCues(File(path!).readAsStringSync());
    if (url != null) return parseCues(await fetchText(Uri.parse(url!), httpsOnly: false, scope: FetchScope.video));
    return const [];
  }
}

/// "English, Spanish": the languages of [names] for a "Captions: ..." line.
String captionLanguages(Iterable<String> names) => names.join(', ');
