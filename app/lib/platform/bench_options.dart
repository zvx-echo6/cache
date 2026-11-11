import 'dart:io';

import 'package:cache_llama/cache_llama.dart' show kDefaultPrereadMbps;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the bench sets from the launch intent (`am start ... --ei cache_preread_mbps 40`). Only the test APK reads the extra
/// (MainActivity, BuildConfig.TEST_APK); every other build answers nothing, so the app's default applies.
@immutable
class BenchOptions {
  const BenchOptions({this.prereadMbps = kDefaultPrereadMbps});

  /// The native gentle pre-read's rate in MB/s: [kDefaultPrereadMbps] unless the extra was given; 0 turns it off.
  final int prereadMbps;

  static const BenchOptions off = BenchOptions();

  @override
  String toString() => 'preread_mbps=$prereadMbps';
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
    return mbps is int && mbps >= 0 ? BenchOptions(prereadMbps: mbps) : BenchOptions.off;
  } catch (_) {
    return BenchOptions.off;
  }
}
