import 'dart:convert';
import 'dart:io';

import '../platform/app_log.dart';
import 'weather_files.dart';

/// The folder the core reads live source definitions from (`live.sources_dir`). The app keeps in it exactly the definitions of the
/// sources that are switched on (the core lists every definition it finds to the assistant, so a source that is off is not there).
/// The app notes which files are its own (`.managed`), so a definition someone put there by hand is never touched.
class LiveFolder {
  LiveFolder(Directory dir) : files = IoFiles(dir), _dir = dir;

  /// The folder in a browser: on Cache Server, reached through [WeatherFiles].
  LiveFolder.files(this.files) : _dir = null;

  final WeatherFiles files;
  final Directory? _dir;

  /// The folder on a phone; null in a browser (the core's folder is on the server).
  Directory? get dir => _dir;

  static const String _manifest = '.managed';

  /// Makes the folder hold [desired] (source id to definition text) among the app's files. [formerly] are the ids earlier versions of
  /// the app wrote, used the first time to clear the ones that are no longer wanted.
  void apply(Map<String, String> desired, {Iterable<String> formerly = const []}) {
    files.makeFolder('');
    var managed = <String>{};
    try {
      managed = (jsonDecode(files.read(_manifest)!) as List).cast<String>().toSet();
    } catch (_) {
      managed = formerly.toSet();
    }
    // One file that cannot be written or removed (somebody else's permissions) does not stop the others.
    final kept = <String>{};
    for (final e in desired.entries) {
      try {
        // Whole or not at all: the core reads every definition it finds here.
        if (files.read('${e.key}.json') != e.value) files.write('${e.key}.json', e.value);
        kept.add(e.key);
      } on FileSystemException catch (x) {
        logError('Live source', error: x.message, detail: e.key);
      }
    }
    for (final id in managed.difference(desired.keys.toSet())) {
      try {
        files.delete('$id.json');
      } on FileSystemException catch (x) {
        logError('Live source', error: x.message, detail: id);
        kept.add(id);
      }
    }
    try {
      files.write(_manifest, jsonEncode(kept.toList()..sort()));
    } on FileSystemException catch (x) {
      logError('Live sources manifest', error: x.message);
    }
  }
}
