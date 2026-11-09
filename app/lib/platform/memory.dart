import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The app's resident memory and swap now, from /proc/self/status (Android and Linux): "RSS 2,346 MB, swap 2,163 MB"; "memory
/// unknown" where the system does not say. For the log, to see what the model and the index work take.
MemoryReading? _lastAppleMemory;

String memoryNow() {
  try {
    if (Platform.isIOS) return _lastAppleMemory?.diagnostics ?? 'memory not read yet';
    if (!(Platform.isAndroid || Platform.isLinux)) return 'memory unknown';
    final status = File('/proc/self/status').readAsLinesSync();
    int? kb(String key) {
      for (final l in status) {
        if (l.startsWith('$key:')) return int.tryParse(l.substring(key.length + 1).trim().split(RegExp(r'\s+')).first);
      }
      return null;
    }

    final rss = kb('VmRSS');
    final swap = kb('VmSwap');
    if (rss == null) return 'memory unknown';
    return 'RSS ${rss ~/ 1024} MB${swap == null ? '' : ', swap ${swap ~/ 1024} MB'}';
  } catch (_) {
    return 'memory unknown';
  }
}

/// The device's memory as the system tells it: what is free now ([avail], what apps can still get without the system killing
/// anything), the total, and the level below which the system starts killing apps ([threshold]); [low] is the system's own
/// "memory is low".
@immutable
class MemoryReading {
  const MemoryReading({
    required this.avail,
    required this.total,
    this.threshold = 0,
    this.low = false,
    this.appScoped = false,
    this.footprint,
    this.resident,
    this.compressed,
  });

  final int avail;
  final int total;
  final int threshold;
  final bool low;

  /// iOS reports room within this app's memory limit, not system-wide free RAM.
  final bool appScoped;
  final int? footprint;
  final int? resident;
  final int? compressed;

  String get diagnostics => [
    if (footprint != null) 'footprint ${footprint! >> 20} MB',
    if (resident != null) 'RSS ${resident! >> 20} MB',
    if (compressed != null) 'compressed ${compressed! >> 20} MB',
    '${appScoped ? 'app room' : 'available'} ${avail >> 20} MB',
    'device ${total >> 20} MB',
  ].join(', ');

  /// What can be used before the system starts killing apps.
  int get room => avail - threshold;

  @override
  String toString() => appScoped ? diagnostics : 'free ${avail >> 20} MB of ${total >> 20} MB (kills below ${threshold >> 20} MB${low ? ', low' : ''})';
}

/// Android's memory channel (MainActivity: ActivityManager.MemoryInfo, and onTrimMemory).
const MethodChannel kMemoryChannel = MethodChannel('co.cache/memory');

MemoryReading? _readingOf(Object? m) {
  if (m is! Map) return null;
  final avail = m['avail'], total = m['total'];
  if (avail is! int || total is! int || total <= 0) return null;
  final t = m['threshold'];
  return MemoryReading(
    avail: avail,
    total: total,
    threshold: t is int ? t : 0,
    low: m['low'] == true,
    appScoped: m['appScoped'] == true,
    footprint: m['footprint'] is int ? m['footprint'] as int : null,
    resident: m['resident'] is int ? m['resident'] as int : null,
    compressed: m['compressed'] is int ? m['compressed'] as int : null,
  );
}

/// The device's memory now: Android from the system (ActivityManager), Linux from /proc/meminfo (MemAvailable); null where it
/// cannot be read (then nothing waits for memory).
Future<MemoryReading?> readMemory() async {
  try {
    if (Platform.isAndroid || Platform.isIOS) {
      final reading = _readingOf(await kMemoryChannel.invokeMethod<Object?>('read'));
      if (Platform.isIOS) _lastAppleMemory = reading;
      return reading;
    }
    if (Platform.isLinux) {
      int? kb(List<String> lines, String key) {
        for (final l in lines) {
          final m = RegExp('^$key:\\s+(\\d+)\\s+kB').firstMatch(l);
          if (m != null) return int.parse(m.group(1)!);
        }
        return null;
      }

      // read at once (a small file): no wait on file I/O
      final lines = File('/proc/meminfo').readAsLinesSync();
      final avail = kb(lines, 'MemAvailable'), total = kb(lines, 'MemTotal');
      if (avail == null || total == null) return null;
      return MemoryReading(avail: avail * 1024, total: total * 1024);
    }
  } catch (_) {}
  return null;
}

/// A fresh sample for diagnostic logs. A slow native probe never holds up indexing.
Future<String> memorySnapshot() async {
  try {
    final reading = await readMemory().timeout(const Duration(seconds: 2));
    if (reading != null && reading.appScoped) return reading.diagnostics;
  } catch (_) {}
  return memoryNow();
}

/// What a chat model of [fileBytes] takes in memory while it answers, by measurement on a phone (a 3.6 GB file: 2.2 GB once
/// loaded, 3.4 GB while answering): about two thirds of the file, plus its working memory.
int modelMemoryNeed(int fileBytes) => (fileBytes * 0.65).round() + (1 << 30);

/// Android's onTrimMemory levels the app acts on.
const int kTrimRunningLow = 10;
const int kTrimUiHidden = 20;

/// Android says memory is short: [level] (onTrimMemory's) and the memory then.
typedef MemoryTrim = void Function(int level, MemoryReading? reading);

/// Calls [onTrim] each time Android sends onTrimMemory (Android only; elsewhere never).
void listenMemoryTrim(MemoryTrim onTrim) {
  kMemoryChannel.setMethodCallHandler((call) async {
    if (call.method != 'trim') return null;
    final m = call.arguments;
    final level = m is Map && m['level'] is int ? m['level'] as int : 0;
    onTrim(level, _readingOf(m));
    return null;
  });
}

/// Whether the model should be let go on this onTrimMemory: Android says memory runs low while Cache is in front (older
/// Androids), or Cache went to the back and what is free is under a gigabyte above where Android starts killing apps.
bool releaseModelOn(int level, MemoryReading? r) {
  if (level >= kTrimRunningLow && level < kTrimUiHidden) return true;
  if (level >= kTrimUiHidden) return r != null && (r.low || r.room < (1 << 30));
  return false;
}
