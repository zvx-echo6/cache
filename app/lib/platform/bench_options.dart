import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:flutter/services.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show clearAmbientCache;

/// What the bench sets from the launch intent (`am start ... --ei cache_preread_mbps 40 --ez cache_drop_caches true`). Only the
/// test APK reads the extras (MainActivity, BuildConfig.TEST_APK); every other build answers [off], so nothing here changes a
/// released app.
@immutable
class BenchOptions {
  const BenchOptions({this.prereadMbps = 0, this.dropCaches = false});

  /// The native gentle pre-read's rate in MB/s (0: off).
  final int prereadMbps;

  /// Drop the image and tile caches as Ask starts answering.
  final bool dropCaches;

  static const BenchOptions off = BenchOptions();

  @override
  String toString() => 'preread_mbps=$prereadMbps, drop_caches=$dropCaches';
}

const MethodChannel kBenchChannel = MethodChannel('cache/bench');

/// The bench's options now (read on every model load, so a new launch intent counts); [BenchOptions.off] off Android or when the
/// channel does not answer. [android] is a test hook.
Future<BenchOptions> readBenchOptions({MethodChannel channel = kBenchChannel, bool? android}) async {
  if (!(android ?? (!kIsWeb && Platform.isAndroid))) return BenchOptions.off;
  try {
    final m = await channel.invokeMethod<Object?>('get');
    if (m is! Map) return BenchOptions.off;
    final mbps = m['preread_mbps'];
    return BenchOptions(prereadMbps: mbps is int && mbps > 0 ? mbps : 0, dropCaches: m['drop_caches'] == true);
  } catch (_) {
    return BenchOptions.off;
  }
}

/// Test APK only (the bench option drop_caches): empties Flutter's image cache and the map's tile cache (maplibre_gl's
/// clearAmbientCache) and says what it did, for the log.
Future<String> dropBenchCaches() async {
  final images = PaintingBinding.instance.imageCache;
  final before = images.currentSizeBytes;
  images.clear();
  images.clearLiveImages();
  final mb = (before / 1048576).toStringAsFixed(1);
  try {
    await clearAmbientCache();
    return 'dropped image cache $mb MB and tile cache';
  } catch (_) {
    return 'dropped image cache $mb MB and tile cache (the map library did not clear its cache)';
  }
}
