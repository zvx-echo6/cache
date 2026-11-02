import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../files.dart';

/// The folder the core reads live source definitions from (`live.sources_dir`). The app keeps in it exactly the definitions of the
/// sources that are switched on (the core lists every definition it finds to the assistant, so a source that is off is not there).
/// The app notes which files are its own (`.managed`), so a definition someone put there by hand is never touched.
class LiveFolder {
  LiveFolder(this.dir);

  final Directory dir;

  File get _manifest => File('${dir.path}/.managed');

  /// Makes the folder hold [desired] (source id to definition text) among the app's files. [formerly] are the ids earlier versions of
  /// the app wrote, used the first time to clear the ones that are no longer wanted.
  void apply(Map<String, String> desired, {Iterable<String> formerly = const []}) {
    dir.createSync(recursive: true);
    var managed = <String>{};
    try {
      managed = (jsonDecode(_manifest.readAsStringSync()) as List).cast<String>().toSet();
    } catch (_) {
      managed = formerly.toSet();
    }
    // One file that cannot be written or removed (somebody else's permissions) does not stop the others.
    final kept = <String>{};
    for (final e in desired.entries) {
      try {
        final f = File('${dir.path}/${e.key}.json');
        // Whole or not at all: the core reads every definition it finds here.
        if (!f.existsSync() || f.readAsStringSync() != e.value) writeStringAtomicSync(f, e.value);
        kept.add(e.key);
      } on FileSystemException catch (x) {
        debugPrint('Live source ${e.key}: ${x.message}');
      }
    }
    for (final id in managed.difference(desired.keys.toSet())) {
      try {
        final f = File('${dir.path}/$id.json');
        if (f.existsSync()) f.deleteSync();
      } on FileSystemException catch (x) {
        debugPrint('Live source $id: ${x.message}');
        kept.add(id);
      }
    }
    try {
      writeStringAtomicSync(_manifest, jsonEncode(kept.toList()..sort()));
    } on FileSystemException catch (x) {
      debugPrint('Live sources manifest: ${x.message}');
    }
  }
}
