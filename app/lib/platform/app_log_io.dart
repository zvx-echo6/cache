import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../browse/zim_download.dart' show freeBytesOnDisk;
import '../maps/ui/format.dart' show formatBytes;
import '../version.dart';
import 'app_log.dart';
import 'memory.dart';

/// Opens the app's log in the app's own folder and writes what happened since the last start: Cache stopped while it was
/// open (it crashed or was killed: the "running" mark is still there), and on Android the system's own reasons the last
/// times the app ended (a crash, a native crash, low memory). Dart errors are written as they happen.
Future<void> openAppLog() async {
  try {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/logs');
    await appLog.open(dir);
    final running = File('${dir.path}/running');
    if (running.existsSync()) logError('Cache stopped unexpectedly the last time it was open');
    _mark(running, true);
    AppLifecycleListener(
      onResume: () => _mark(running, true),
      onPause: () => _mark(running, false),
      onDetach: () => _mark(running, false),
    );
    logInfo('Cache $kAppVersion ($kAppBuild) starts; log level ${logLevelTitle(appLog.level)}; ${memoryNow()}');
    await _exitReasons(dir);
  } catch (e) {
    debugPrint('The log could not be opened: $e');
  }
}

/// Dart errors (framework and asynchronous) go to the log; the framework's own report stays.
void logDartErrors() {
  final before = FlutterError.onError;
  FlutterError.onError = (d) {
    logError('App error', error: d.exception, stack: d.stack);
    before?.call(d);
  };
  PlatformDispatcher.instance.onError = (e, s) {
    logError('App error', error: e, stack: s);
    return true;
  };
}

void _mark(File running, bool on) {
  try {
    if (on) {
      running.writeAsStringSync(DateTime.now().toIso8601String());
    } else if (running.existsSync()) {
      running.deleteSync();
    }
  } catch (_) {}
}

const MethodChannel _memory = kMemoryChannel;

/// Android 11 and later: why the app's process ended, the times since the last start (crash, native crash, low memory).
Future<void> _exitReasons(Directory dir) async {
  if (!Platform.isAndroid) return;
  final seenFile = File('${dir.path}/exits-seen');
  var seen = 0;
  try {
    seen = int.parse(seenFile.readAsStringSync().trim());
  } catch (_) {}
  try {
    final list = await _memory.invokeListMethod<Object?>('exits');
    var newest = seen;
    for (final e in list ?? const []) {
      if (e is! Map) continue;
      final t = (e['time'] as num?)?.toInt() ?? 0;
      if (t <= seen) continue;
      if (t > newest) newest = t;
      final when = DateTime.fromMillisecondsSinceEpoch(t).toIso8601String();
      final reason = e['reason'] as String? ?? 'unknown';
      final line = 'Cache ended at $when: $reason';
      if (reason == 'crash' || reason == 'native crash' || reason == 'not responding' || reason == 'low memory') {
        logError(line, detail: e['description'] as String?);
      } else {
        logInfo(line);
      }
    }
    if (newest > seen) seenFile.writeAsStringSync('$newest');
  } catch (_) {}
}

/// The phone's model ("Google Pixel 8", "iPhone17,1"); null when it cannot be read.
Future<String?> deviceModel() async {
  try {
    return await _memory.invokeMethod<String>('device');
  } catch (_) {
    return null;
  }
}

/// Shares the log files through the system share sheet, with a short header (version and build, device, OS, level, free
/// memory and storage). With Everything on it first warns that the log holds personal content.
Future<void> shareAppLog(BuildContext context) async {
  if (appLog.level == LogLevel.everything) {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Share the log?'),
        content: const Text('The log level is Everything: the log holds what you searched, asked and wrote, and places. Share it only with someone you trust.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Share')),
        ],
      ),
    );
    if (go != true) return;
  }
  await appLog.flush();
  final dir = appLog.dir;
  if (dir == null) return;
  final mem = await readMemory();
  final free = dir.existsSync() ? freeBytesOnDisk(dir.path) : null;
  final header = File('${dir.path}/about.txt');
  await header.writeAsString([
    'Cache $kAppVersion (build $kAppBuild)',
    'Device: ${await deviceModel() ?? 'unknown'}',
    'System: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    'Log level: ${logLevelTitle(appLog.level)}',
    'Memory: ${mem ?? 'unknown'}; this app: ${memoryNow()}',
    'Storage free: ${free == null ? 'unknown' : formatBytes(free)}',
    'Written: ${DateTime.now().toIso8601String()}',
  ].join('\n'));
  await SharePlus.instance.share(ShareParams(
    files: [XFile(header.path, mimeType: 'text/plain'), for (final f in appLog.logFiles) XFile(f.path, mimeType: 'text/plain')],
    subject: 'Cache log',
  ));
}

/// Shown at the top of every screen while the level is Everything.
class LogEverythingBanner extends StatelessWidget {
  const LogEverythingBanner({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appLog,
        builder: (context, _) {
          final until = appLog.everythingUntil;
          if (until == null) return const SizedBox.shrink();
          final scheme = Theme.of(context).colorScheme;
          final at = TimeOfDay.fromDateTime(until).format(context);
          return Material(
            color: scheme.errorContainer,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('The log keeps everything, also what you type, until $at',
                          key: const ValueKey('log-everything-banner'), style: TextStyle(fontSize: 13, color: scheme.onErrorContainer)),
                    ),
                    TextButton(onPressed: appLog.endEverything, child: const Text('Turn off')),
                  ],
                ),
              ),
            ),
          );
        },
      );
}

/// The log's size for Settings ("1.2 MB").
String appLogSize() {
  try {
    return formatBytes(appLog.bytes);
  } catch (_) {
    return '';
  }
}
