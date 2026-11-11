import 'dart:io';

import 'package:cache_llama/cache_llama.dart' show kDefaultPrereadMbps;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the bench sets from the launch intent (`am start ... --ei cache_preread_mbps 40`). Only the test APK reads the extra
/// (MainActivity, BuildConfig.TEST_APK); every other build answers nothing, so the app's default applies.
@immutable
class BenchOptions {
  const BenchOptions({this.prereadMbps = kDefaultPrereadMbps, this.dateOffsetDays = 0, this.ubatch = 0, this.embedThreads = 0, this.poolPause = false, this.poolPoll = -1, this.deferSearchLoad = false});

  /// The native gentle pre-read's rate in MB/s: [kDefaultPrereadMbps] unless the extra was given; 0 turns it off.
  final int prereadMbps;

  /// `--ei cache_date_offset_days N`: shifts the date line of the chat's system prompt by N days (so a phone check sees a new
  /// day's prompt start). Nothing else changes. 0: no shift.
  final int dateOffsetDays;

  /// `--ei cache_ubatch N`: the chat context's n_ubatch for a measurement; 0: llama.cpp's default.
  final int ubatch;

  /// `--ei cache_embed_threads N`: the search model's thread count for a measurement; 0: the default (4).
  final int embedThreads;

  /// `--ez cache_pool_pause true`: the chat threadpool rests while nothing decodes (an A/B measurement of contention with the
  /// embedder). False: as always.
  final bool poolPause;

  /// `--ei cache_pool_poll N` (0 to 100): the chat threadpool's poll level; -1: ggml's default.
  final int poolPoll;

  /// `--ez cache_defer_search_load true`: opening Ask loads the search model only after the prompt read ahead has finished, been
  /// skipped or stopped (a search before then loads it at once). False: as always.
  final bool deferSearchLoad;

  static const BenchOptions off = BenchOptions();

  @override
  String toString() => 'preread_mbps=$prereadMbps${dateOffsetDays != 0 ? ', date_offset_days=$dateOffsetDays' : ''}${ubatch != 0 ? ', cache_ubatch=$ubatch' : ''}${embedThreads != 0 ? ', embed_threads=$embedThreads' : ''}${poolPause ? ', pool_pause=true' : ''}${poolPoll >= 0 ? ', pool_poll=$poolPoll' : ''}${deferSearchLoad ? ', defer_search_load=true' : ''}';
}

const MethodChannel kBenchChannel = MethodChannel('cache/bench');

/// The bench's options now (read on every model load, so a new launch intent counts). The default when the extra is absent, the
/// build is not Android, or the channel does not answer. [android] is a test hook.
Future<BenchOptions> readBenchOptions({MethodChannel channel = kBenchChannel, bool? android}) async {
  if (!(android ?? (!kIsWeb && Platform.isAndroid))) return BenchOptions.off;
  try {
    final m = await channel.invokeMethod<Object?>('get');
    if (m is! Map) return BenchOptions.off;
    final mbps = m['preread_mbps'];
    // The two measurement extras count only when the build says it is the test APK (the release build never sends them).
    final test = m['testApk'] == true;
    final days = m['date_offset_days'];
    final ub = m['cache_ubatch'];
    final et = m['cache_embed_threads'];
    final pp = m['cache_pool_pause'];
    final pl = m['cache_pool_poll'];
    final ds = m['cache_defer_search_load'];
    return BenchOptions(
      prereadMbps: mbps is int && mbps >= 0 ? mbps : kDefaultPrereadMbps,
      dateOffsetDays: test && days is int ? days : 0,
      ubatch: test && ub is int && ub > 0 ? ub : 0,
      embedThreads: test && et is int && et > 0 ? et : 0,
      poolPause: test && pp == true,
      deferSearchLoad: test && ds == true,
      poolPoll: test && pl is int && pl >= 0 ? (pl > 100 ? 100 : pl) : -1,
    );
  } catch (_) {
    return BenchOptions.off;
  }
}

/// The date shift of the chat's system prompt now (see [BenchOptions.dateOffsetDays]), set when the bench options are read at a model
/// load. Always 0 outside the test APK.
int benchDateOffsetDays = 0;

/// The search model's thread count from the bench ([BenchOptions.embedThreads]); 0: the default. Always 0 outside the test APK.
int benchEmbedThreads = 0;

/// [BenchOptions.deferSearchLoad] now. Read at the app's start (before Ask can open) and at every model load. Always false outside the test APK.
bool benchDeferSearchLoad = false;
