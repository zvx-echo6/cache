import 'dart:io';

// Small helpers for putting a file in place whole. A file is written under a hidden name next to its real one and renamed
// over it once complete, so nothing reads half of it, and the sync (which skips names that start with '.') never sends half
// of it to the other devices.

/// Renames [from] over the file at [to]. Windows can refuse to rename over a file that exists, or that another write is
/// renaming at that moment; then the file there is dropped and the rename tried again, a few times, a little later each time.
/// [from] must be in the same folder (or file system) as [to].
Future<File> renameOver(File from, String to) async {
  for (var i = 0;; i++) {
    try {
      return await from.rename(to);
    } on FileSystemException {
      if (!Platform.isWindows || i >= 20) rethrow;
      try {
        await File(to).delete();
      } on FileSystemException catch (_) {}
      await Future<void>.delayed(Duration(milliseconds: 5 * (i + 1)));
    }
  }
}

/// [renameOver], synchronously.
File renameOverSync(File from, String to) {
  for (var i = 0;; i++) {
    try {
      return from.renameSync(to);
    } on FileSystemException {
      if (!Platform.isWindows || i >= 20) rethrow;
      try {
        File(to).deleteSync();
      } on FileSystemException catch (_) {}
      sleep(Duration(milliseconds: 5 * (i + 1)));
    }
  }
}

var _temps = 0;

/// A hidden temp file next to [target] (same folder, so finishing it is a rename). The time and count keep two writes of
/// one file, from this isolate or another, from sharing a temp.
File hiddenTempFor(File target) {
  final name = target.path.split(RegExp(r'[\\/]')).last;
  return File('${target.parent.path}${Platform.pathSeparator}.$name.${DateTime.now().microsecondsSinceEpoch}-${++_temps}.tmp');
}

/// Writes [bytes] to [file] whole: into a hidden temp next to it, flushed to the disk, then renamed over it.
Future<void> writeBytesAtomic(File file, List<int> bytes) async {
  final tmp = hiddenTempFor(file);
  try {
    await tmp.writeAsBytes(bytes, flush: true);
    await renameOver(tmp, file.path);
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    rethrow;
  }
}

/// [writeBytesAtomic] for text (UTF-8).
Future<void> writeStringAtomic(File file, String text) async {
  final tmp = hiddenTempFor(file);
  try {
    await tmp.writeAsString(text, flush: true);
    await renameOver(tmp, file.path);
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    rethrow;
  }
}

/// [writeStringAtomic], synchronously.
void writeStringAtomicSync(File file, String text) {
  final tmp = hiddenTempFor(file);
  try {
    tmp.writeAsStringSync(text, flush: true);
    renameOverSync(tmp, file.path);
  } catch (_) {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
    rethrow;
  }
}
