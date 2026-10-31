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
    await _call('fs.write', root, path, {'data': text});
  }

  @override
  Future<void> writeBytesAtomic(AppRoot root, String path, List<int> bytes) async {
    await _call('fs.write', root, path, {'data': bytes is Uint8List ? bytes : Uint8List.fromList(bytes)});
  }

  @override
  void writeStringAtomicSync(AppRoot root, String path, String text) {
    _queue = _queue.then((_) => writeStringAtomic(root, path, text)).catchError((Object _) {});
  }

  @override
  Future<bool> exists(AppRoot root, String path) async {
    try {
      final v = await _call('fs.exists', root, path);
      return v == true || (v is Map && v['exists'] == true);
    } catch (e) {
      if (_missing(e)) return false;
      rethrow;
    }
  }

  @override
  Future<List<AppFsEntry>> list(AppRoot root, String path) async {
    try {
      final v = await _call('fs.list', root, path);
      final items = v is Map ? v['entries'] : v;
      return [for (final e in (items as List? ?? const [])) _entry((e as Map).cast<String, dynamic>())];
    } catch (e) {
      if (_missing(e)) return const [];
      rethrow;
    }
  }

  @override
  Future<AppFsEntry?> stat(AppRoot root, String path) async {
    try {
      final v = await _call('fs.stat', root, path);
      if (v is! Map || v['exists'] == false) return null;
      return _entry(v.cast<String, dynamic>(), fallbackName: path.split('/').last);
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
  Future<void> mkdir(AppRoot root, String path) async {
    if (path.isEmpty) return; // the roots are the server's, and always there
    await _call('fs.mkdir', root, path);
  }

  static AppFsEntry _entry(Map<String, dynamic> j, {String fallbackName = ''}) => AppFsEntry(
        name: (j['name'] ?? fallbackName).toString(),
        isDir: j['isDir'] == true,
        size: (j['size'] as num?)?.toInt() ?? 0,
        mtime: _time(j['mtime']),
      );

  // Milliseconds or seconds since 1970, or an ISO 8601 text.
  static DateTime _time(Object? v) {
    if (v is num) {
      final n = v.toInt();
      return DateTime.fromMillisecondsSinceEpoch(n < 100000000000 ? n * 1000 : n);
    }
    if (v is String) return DateTime.tryParse(v) ?? DateTime.fromMillisecondsSinceEpoch(0);
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}
