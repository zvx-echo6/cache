import 'dart:io' show Directory;
import 'dart:typed_data';

import 'package:cache_search/cache_search.dart' show CacheSearchException, CoreTransport, HttpTransport;

import 'app_fs_base.dart';

AppFs createAppFs({Directory? supportOverride, Directory? docsOverride}) => WebAppFs();

// One transport for every WebAppFs: the same /api/core endpoint (same origin, so the session cookie goes along) that SearchCore uses.
final CoreTransport _transport = HttpTransport();

/// The browser side: the files are on Cache Server, reached by its fs.* operations through /api/core. Each operation takes
/// {root: "support"|"docs", path: relative, '/'-separated}. A missing file comes back as not_found, which reads here the way a
/// missing file reads on a phone (null, false, nothing to delete); bad_path and io_error are thrown as CacheSearchException.
class WebAppFs implements AppFs {
  WebAppFs();

  Future<void> _queue = Future.value();

  Future<dynamic> _call(String op, AppRoot root, String path, [Map<String, dynamic> more = const {}]) =>
      _transport.call(op, {'root': root.name, 'path': path, ...more});

  static bool _missing(Object e) => e is CacheSearchException && e.code == 'not_found';

  @override
  Future<String?> readString(AppRoot root, String path) async {
    try {
      return (await _call('fs.readString', root, path)) as String?;
    } catch (e) {
      if (_missing(e)) return null;
      rethrow;
    }
  }

  @override
  Future<Uint8List?> readBytes(AppRoot root, String path) async {
    try {
      final v = await _call('fs.read', root, path);
      return v is Uint8List ? v : (v is List ? Uint8List.fromList(v.cast<int>()) : null);
    } catch (e) {
      if (_missing(e)) return null;
      rethrow;
    }
  }

  @override
  Future<void> writeStringAtomic(AppRoot root, String path, String text) async {
    await _call('fs.write', root, path, {'string': text});
  }

  @override
  Future<void> writeBytesAtomic(AppRoot root, String path, List<int> bytes) async {
    await _call('fs.write', root, path, {'bytes': bytes is Uint8List ? bytes : Uint8List.fromList(bytes)});
  }

  @override
  Future<void> writeString(AppRoot root, String path, String text) => writeStringAtomic(root, path, text);

  @override
  Future<void> writeStringViaTmp(AppRoot root, String path, String text) => writeStringAtomic(root, path, text);

  @override
  Future<void> copy(AppRoot root, String from, String to) async {
    final bytes = await readBytes(root, from);
    if (bytes != null) await writeBytesAtomic(root, to, bytes);
  }

  @override
  void writeStringAtomicSync(AppRoot root, String path, String text) {
    _queue = _queue.then((_) => writeStringAtomic(root, path, text)).catchError((Object _) {});
  }

  @override
  Future<bool> exists(AppRoot root, String path) async {
    try {
      return (await _call('fs.exists', root, path)) == true;
    } catch (e) {
      if (_missing(e)) return false;
      rethrow;
    }
  }

  @override
  Future<List<AppFsEntry>> list(AppRoot root, String path) async {
    try {
      final v = await _call('fs.list', root, path);
      return [for (final e in v as List) _entry((e as Map).cast<String, dynamic>())];
    } catch (e) {
      if (_missing(e)) return const [];
      rethrow;
    }
  }

  @override
  Future<AppFsEntry?> stat(AppRoot root, String path) async {
    try {
      final v = await _call('fs.stat', root, path);
      return _entry((v as Map).cast<String, dynamic>(), name: path.split('/').last);
    } catch (e) {
      if (_missing(e)) return null;
      rethrow;
    }
  }

  @override
  Future<void> delete(AppRoot root, String path, {bool recursive = false}) async {
    try {
      await _call('fs.delete', root, path, {'recursive': recursive});
    } catch (e) {
      if (!_missing(e)) rethrow;
    }
  }

  @override
  Future<void> rename(AppRoot root, String from, String to) async {
    await _transport.call('fs.rename', {'root': root.name, 'from': from, 'to': to});
  }

  Map<String, String>? _roots;

  @override
  Future<String> rootPath(AppRoot root) async {
    final r = _roots ??= ((await _transport.call('fs.roots', const {})) as Map).cast<String, String>();
    return r[root.name]!;
  }

  @override
  Future<void> mkdir(AppRoot root, String path) async {
    if (path.isEmpty) return; // the roots are the server's, and always there
    await _call('fs.mkdir', root, path);
  }

  // {name?, isDir, size, mtime in ms since 1970}; fs.stat has no name, so the caller gives it.
  static AppFsEntry _entry(Map<String, dynamic> j, {String name = ''}) => AppFsEntry(
        name: (j['name'] ?? name) as String,
        isDir: j['isDir'] as bool,
        size: (j['size'] as num).toInt(),
        mtime: DateTime.fromMillisecondsSinceEpoch((j['mtime'] as num).toInt()),
      );
}
