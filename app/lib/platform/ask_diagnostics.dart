import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'app_log.dart';
import 'memory.dart';

/// Memory samples while the model answers one Ask round, written only at the Detailed log level: at the start, every 10
/// seconds, and at the end, as one JSON line each ("Ask diagnostic {...}"). Machine counters only: never questions, answers,
/// or tool results. Logging only: nothing here changes what the model or the app does.
class AskDiagnostics {
  AskDiagnostics._(this.round) {
    _sample('start');
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _sample('progress'));
  }

  final int round;
  final Stopwatch _clock = Stopwatch()..start();
  Timer? _timer;

  /// Starts sampling round [round]; null (nothing sampled) below the Detailed level.
  static AskDiagnostics? start(int round) => appLog.writes(LogLevel.detailed) ? AskDiagnostics._(round) : null;

  void stop() {
    _timer?.cancel();
    _timer = null;
    _sample('end');
    _clock.stop();
  }

  void _sample(String phase) {
    try {
      logDetail('Ask diagnostic ${jsonEncode(_counters({'round': round, 'phase': phase, 'elapsed_ms': _clock.elapsedMilliseconds}))}');
    } catch (_) {
      // Diagnostics must never interrupt generation.
    }
  }

  static Map<String, Object?> _counters(Map<String, Object?> head) {
    final counters = <String, Object?>{...head};
    try {
      counters['lifecycle'] = WidgetsBinding.instance.lifecycleState?.name;
    } catch (_) {}
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
