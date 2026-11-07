import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'app_log.dart';

/// Enabled only by the separate diagnostic APK workflow.
const kAskDiagnostics = bool.fromEnvironment('CACHE_ASK_DIAGNOSTICS');

/// Machine counters only: never questions, answers, or tool results.
class AskDiagnostics {
  AskDiagnostics._(this.round) {
    _sample('start');
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _sample('progress'));
  }
  final int round;
  final Stopwatch _clock = Stopwatch()..start();
  Timer? _timer;
  static AskDiagnostics? start(int round) => kAskDiagnostics ? AskDiagnostics._(round) : null;

  /// Once right after a chat model loads: the native build, llama.cpp's load lines (buffer sizes, REPACK, mmap, KV), and a
  /// memory sample that separates anonymous (RssAnon) from file-backed (RssFile) memory and swap.
  static void modelLoaded({required String engineBuild, required String diagnosticBuild, required List<String> loadLog}) {
    if (!kAskDiagnostics) return;
    try {
      logInfo('Ask diagnostic engine: build=$engineBuild, diagnostic=${diagnosticBuild.isEmpty ? 'none' : diagnosticBuild}');
      for (final line in loadLog) {
        logInfo('Ask diagnostic load: ${line.trim()}');
      }
      logInfo('Ask diagnostic ${jsonEncode(_counters({'round': 0, 'phase': 'loaded'}))}');
    } catch (_) {}
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _sample('end');
    _clock.stop();
  }

  void _sample(String phase) {
    try {
      final counters = _counters({'round': round, 'phase': phase, 'elapsed_ms': _clock.elapsedMilliseconds});
      logInfo('Ask diagnostic ${jsonEncode(counters)}');
    } catch (_) {
      // Diagnostics must never interrupt generation.
    }
  }

  static Map<String, Object?> _counters(Map<String, Object?> head) {
    final counters = <String, Object?>{...head, 'lifecycle': WidgetsBinding.instance.lifecycleState?.name};
    if (Platform.isAndroid || Platform.isLinux) {
      void read(String path, void Function(String) consume) {
        try {
          consume(File(path).readAsStringSync());
        } catch (_) {}
      }

      read('/proc/self/status', (s) => counters.addAll(procMemoryCounters(s)));
      read('/proc/meminfo', (s) => counters.addAll(procMemoryCounters(s)));
      read('/proc/self/stat', (s) => counters.addAll(procProcessCounters(s)));
      read('/proc/pressure/memory', (s) => counters['memory_pressure'] = s.trim());
    }
    return counters;
  }
}

/// Values are the kernel's kB units; allow only these memory counters.
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

/// Fields after the parenthesized command start at field 3; CPU uses raw ticks.
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
