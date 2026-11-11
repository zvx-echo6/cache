import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The app's resident memory and swap now, from /proc/self/status (Android and Linux): "RSS 2346 MB (anon 1200 MB, file
/// 1146 MB), swap 2163 MB"; "memory unknown" where the system does not say. iOS gives its last native reading (phys_footprint
/// and resident size). For the log, to see what the model and the index work take.
MemoryReading? _lastAppleMemory;

String memoryNow() {
  try {
    if (Platform.isIOS) return _lastAppleMemory?.diagnostics ?? 'memory not read yet';
    if (!(Platform.isAndroid || Platform.isLinux)) return 'memory unknown';
    return procStatusSummary(File('/proc/self/status').readAsStringSync());
  } catch (_) {
    return 'memory unknown';
  }
}

/// The log text for a /proc/self/status [source]: RSS with its anonymous (RssAnon) and file-backed (RssFile) parts, and swap.
String procStatusSummary(String source) {
  final c = procMemoryCounters(source);
  final rss = c['VmRSS_kb'];
  if (rss == null) return 'memory unknown';
  final anon = c['RssAnon_kb'], file = c['RssFile_kb'], swap = c['VmSwap_kb'];
  final parts = [if (anon != null) 'anon ${anon ~/ 1024} MB', if (file != null) 'file ${file ~/ 1024} MB'];
  return 'RSS ${rss ~/ 1024} MB${parts.isEmpty ? '' : ' (${parts.join(', ')})'}${swap == null ? '' : ', swap ${swap ~/ 1024} MB'}';
}

/// The memory counters of /proc/self/status or /proc/meminfo [source], in the kernel's kB, keyed by name plus "_kb"; only these
/// names are taken, and a line whose value is not a number is left out.
Map<String, int> procMemoryCounters(String source) {
  const keys = {'VmRSS', 'VmSwap', 'RssAnon', 'RssFile', 'MemAvailable', 'SwapFree'};
  final values = <String, int>{};
  for (final line in source.split('\n')) {
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final key = line.substring(0, colon);
    if (!keys.contains(key)) continue;
    final number = int.tryParse(line.substring(colon + 1).trim().split(RegExp(r'\s+')).first);
    if (number != null) values['${key}_kb'] = number;
  }
  return values;
}

/// Fault and CPU counters of /proc/self/stat [source]. Fields after the parenthesized command start at field 3; CPU is in
/// raw ticks.
Map<String, int> procProcessCounters(String source) {
  final end = source.lastIndexOf(')');
  if (end < 0) return {};
  final fields = source.substring(end + 1).trim().split(RegExp(r'\s+'));
  final result = <String, int>{};
  for (final field in const {10: 'minor_faults', 12: 'major_faults', 14: 'user_ticks', 15: 'system_ticks'}.entries) {
    final index = field.key - 3;
    if (index >= fields.length) continue;
    final value = int.tryParse(fields[index]);
    if (value != null) result[field.value] = value;
  }
  return result;
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

/// Calls [onTrim] each time Android sends onTrimMemory (Android only; elsewhere never), and [onWarning] each time iOS sends a
/// memory warning (iOS only).
void listenMemoryTrim(MemoryTrim onTrim, {void Function()? onWarning}) {
  kMemoryChannel.setMethodCallHandler((call) async {
    if (call.method == 'memoryWarning') {
      onWarning?.call();
      return null;
    }
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
