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
