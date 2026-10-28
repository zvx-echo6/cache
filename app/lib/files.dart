import 'dart:io';

/// Small helpers for putting a file in place whole. A file is written under a hidden name next to its real one and renamed
/// over it once complete, so nothing reads half of it, and the sync (which skips names that start with '.') never sends half
/// of it to the other devices.

/// Renames [from] over the file at [to]. Windows can refuse to rename over a file that exists; then that file is deleted
/// right before the rename is tried again. [from] must be in the same folder (or file system) as [to].
Future<File> renameOver(File from, String to) async {
  try {
    return await from.rename(to);
  } on FileSystemException {
    final old = File(to);
    if (!Platform.isWindows || !await old.exists()) rethrow;
    await old.delete();
    return from.rename(to);
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
