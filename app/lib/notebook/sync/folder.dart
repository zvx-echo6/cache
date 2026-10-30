import 'dart:io';
import 'dart:typed_data';

/// A file of a connected folder: its path inside the folder (with `/`), when it last changed and its size.
class FolderFile {
  const FolderFile(this.path, this.mtime, this.size);

  final String path;
  final int mtime;
  final int size;
}

/// A folder Cache keeps notebooks in (an Obsidian vault, a Logseq graph, or the folder notebook sync shares between devices).
/// Paths are inside the folder, with `/`. Writes go to a temporary file in the same folder that is then renamed over the
/// target, so a failure leaves the old file.
abstract class SyncFolder {
  /// A short name of the folder for status lines.
  String get display;

  /// Whether the folder can be reached now.
  Future<bool> reachable();

  /// The files under [dir] (all levels), `.md` and others.
  Future<List<FolderFile>> list(String dir);
  Future<String?> readText(String path);
  Future<Uint8List?> readBytes(String path);
  Future<void> writeText(String path, String text);
  Future<void> writeBytes(String path, Uint8List bytes);
  Future<void> delete(String path);
  Future<bool> exists(String path);
}

/// A folder on the file system (desktop, and folders the phone lets Cache read and write directly).
class IoFolder implements SyncFolder {
  IoFolder(this.root);

  final String root;

  @override
  String get display => root.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).lastOrNull ?? root;

  File _f(String path) => File('$root/$path');

  @override
  Future<bool> reachable() => Directory(root).exists();

  @override
  Future<List<FolderFile>> list(String dir) async {
    final d = Directory(dir.isEmpty ? root : '$root/$dir');
    if (!await d.exists()) return const [];
    final out = <FolderFile>[];
    final base = Directory(root).absolute.path.replaceAll('\\', '/');
    await for (final e in d.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = e.absolute.path.replaceAll('\\', '/').substring(base.length).replaceFirst(RegExp(r'^/'), '');
      if (rel.split('/').any((p) => p.startsWith('.') && p != '.cache')) continue;
      final st = await e.stat();
      out.add(FolderFile(rel, st.modified.millisecondsSinceEpoch, st.size));
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  @override
  Future<String?> readText(String path) async {
    final f = _f(path);
    if (!await f.exists()) return null;
    return (await f.readAsString()).replaceAll('\r\n', '\n');
  }

  @override
  Future<Uint8List?> readBytes(String path) async {
    final f = _f(path);
    return await f.exists() ? f.readAsBytes() : null;
  }

  Future<void> _atomic(String path, Future<void> Function(File tmp) write) async {
    final f = _f(path);
    await f.parent.create(recursive: true);
    final name = path.split('/').last;
    final tmp = File('${f.parent.path}/.$name.cache-tmp');
    await write(tmp);
    await tmp.rename(f.path);
  }

  @override
  Future<void> writeText(String path, String text) => _atomic(path, (t) => t.writeAsString(text, flush: true));

  @override
  Future<void> writeBytes(String path, Uint8List bytes) => _atomic(path, (t) => t.writeAsBytes(bytes, flush: true));

  @override
  Future<void> delete(String path) async {
    final f = _f(path);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<bool> exists(String path) => _f(path).exists();
}
