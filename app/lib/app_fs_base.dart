import 'dart:typed_data';

/// The two folders the app keeps its files in. On a phone they are the app's support folder and its documents folder (the
/// external-storage folder on Android); in a browser they are the same two folders on Cache Server.
enum AppRoot { support, docs }

/// One file or folder, as [AppFs.list] and [AppFs.stat] report it.
class AppFsEntry {
  const AppFsEntry({required this.name, required this.isDir, required this.size, required this.mtime});

  final String name;
  final bool isDir;
  final int size;
  final DateTime mtime;
}

/// How the app reaches its own files. A file is addressed as ([AppRoot], relative path): the path is relative to the root, uses
/// '/' and has no '..'; the empty path is the root itself. On a phone this is plain dart:io (app_fs_io.dart); in a browser it is
/// Cache Server's fs.* operations (app_fs_web.dart). A file that is not there reads as null, [exists] is false and [delete] does
/// nothing; any other failure is thrown, as dart:io throws it.
abstract class AppFs {
  Future<String?> readString(AppRoot root, String path);
  Future<Uint8List?> readBytes(AppRoot root, String path);

  /// Writes the whole file or none of it (a hidden temp file renamed over it).
  Future<void> writeStringAtomic(AppRoot root, String path, String text);
  Future<void> writeBytesAtomic(AppRoot root, String path, List<int> bytes);

  /// The write older code did by hand: the text into `<path>.tmp`, flushed, then renamed over the file. On a phone it is exactly
  /// that (so the temp file keeps its name); in a browser it is [writeStringAtomic]. Use [writeStringAtomic] in new code.
  Future<void> writeStringViaTmp(AppRoot root, String path, String text);

  /// Copies the file to [to] (nothing happens when it is missing). On a phone it is File.copySync.
  Future<void> copy(AppRoot root, String from, String to);

  /// [writeStringAtomic] for a caller that cannot wait (a setter that saves). On a phone it is the synchronous write, done
  /// before this returns; in a browser it is queued behind the earlier writes of this [AppFs] and its errors are dropped. The
  /// root must have been used before ([mkdir], or any read or write), or this throws.
  void writeStringAtomicSync(AppRoot root, String path, String text);

  Future<bool> exists(AppRoot root, String path);

  /// What is directly inside the folder (empty when there is no such folder).
  Future<List<AppFsEntry>> list(AppRoot root, String path);

  /// Null when there is nothing at [path].
  Future<AppFsEntry?> stat(AppRoot root, String path);

  Future<void> delete(AppRoot root, String path, {bool recursive = false});

  /// Creates the folder and the folders above it. The empty path (the root) is only made sure of.
  Future<void> mkdir(AppRoot root, String path);
}
