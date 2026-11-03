import 'dart:io';

/// The app's resident memory and swap now, from /proc/self/status (Android and Linux): "RSS 2,346 MB, swap 2,163 MB"; "memory
/// unknown" where the system does not say. For the log, to see what the model and the index work take.
String memoryNow() {
  try {
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
