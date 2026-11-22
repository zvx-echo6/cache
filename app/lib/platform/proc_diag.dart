import 'dart:io';

import 'package:flutter/widgets.dart';

import 'app_log.dart';
import 'battery.dart';

/// Diagnostic only (no behaviour): what the process is using and how the system holds it, for finding why background work is
/// slower than work in front. Linux and Android only; elsewhere every call says nothing.

/// CPU seconds this process has used (user + system, all threads), from /proc/self/stat; null where it cannot be read.
double? processCpuSeconds() {
  try {
    if (!Platform.isAndroid && !Platform.isLinux) return null;
    final s = File('/proc/self/stat').readAsStringSync();
    // fields after the command name (which is in brackets and may hold spaces): 12 = utime, 13 = stime (0-based, after "comm")
    final rest = s.substring(s.lastIndexOf(')') + 2).split(' ');
    final ticks = int.parse(rest[11]) + int.parse(rest[12]);
    return ticks / 100.0; // CLK_TCK is 100 on Android
  } catch (_) {
    return null;
  }
}

String _lifecycle() {
  try {
    return WidgetsBinding.instance.lifecycleState?.name ?? 'unknown';
  } catch (_) {
    return 'no-binding';
  }
}

/// A stopwatch of wall time and process CPU time for one step.
class StepClock {
  StepClock() : _wall = Stopwatch()..start(), _cpu = processCpuSeconds();
  final Stopwatch _wall;
  final double? _cpu;

  /// "wall 4.2 s, cpu 3.9 s (93%), app resumed".
  String took() {
    final w = _wall.elapsedMilliseconds / 1000.0;
    final c = processCpuSeconds();
    final cpu = (c == null || _cpu == null) ? null : c - _cpu;
    final pct = cpu == null || w <= 0 ? '' : ' (${(100 * cpu / w).round()}%)';
    return 'wall ${w.toStringAsFixed(1)} s, cpu ${cpu == null ? 'unknown' : '${cpu.toStringAsFixed(1)} s'}$pct, app ${_lifecycle()}';
  }
}

String _read(String path, {int max = 400}) {
  try {
    final t = File(path).readAsStringSync().trim().replaceAll('\n', ' | ');
    return t.length > max ? t.substring(0, max) : t;
  } catch (e) {
    return 'unreadable';
  }
}

String _status(String key) {
  try {
    for (final l in File('/proc/self/status').readAsLinesSync()) {
      if (l.startsWith('$key:')) return l.substring(key.length + 1).trim();
    }
  } catch (_) {}
  return 'unreadable';
}

/// One log line: the process's cgroup and cpuset, the cores it may run on, its scheduling, and the system's thermal reading.
Future<void> logProcessDiag(String why) async {
  if (!Platform.isAndroid && !Platform.isLinux) return;
  BatteryReading? b;
  try {
    b = await readBattery();
  } catch (_) {}
  logInfo(
    'Process diag ($why): app ${_lifecycle()}, cgroup ${_read('/proc/self/cgroup')}, cpuset ${_read('/proc/self/cpuset', max: 80)}, '
    'cpus_allowed ${_status('Cpus_allowed_list')}, threads ${_status('Threads')}, nice/sched ${_read('/proc/self/sched', max: 120)}, '
    'thermal ${b?.thermal.name ?? 'unknown'}, headroom ${b?.headroom?.toStringAsFixed(2) ?? 'unknown'}, '
    'battery ${b == null ? 'unknown' : '${b.percent}% ${b.charging ? 'charging' : 'not charging'}'}',
  );
}
