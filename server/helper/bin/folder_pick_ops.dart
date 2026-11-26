import 'dart:async';
import 'dart:io';

import '../../../packages/cache_search/lib/src/errors.dart';
import 'line_protocol.dart';

/// The `devfs.*` ops: the browser's folder picker for notes folders (Obsidian, Logseq). The person picks a folder of the computer
/// Cache runs on, as they do on a phone; the browser cannot hand over a path, so it asks the helper to list folders and shows
/// them in Cache's own picker. Not limited to the `support` and `docs` roots of `fs.*`: it lists whatever the user Cache runs as
/// can read, from the home folder up to "/". It lists subfolders only, and changes nothing.
///
///   devfs.list {path?} -> {path, home, parent, kind, folders:[{name, kind, readable}]}
///
/// `path` is absolute (null starts at the home folder); `.` and `..` in it are resolved. `parent` is null at "/". `kind` is
/// `obsidian` (the folder has `.obsidian`), `logseq` (it has `logseq/config.edn`) or `none`; `folders` are the subfolders, sorted by
/// name, hidden ones (a name that starts with ".") left out, each with its own kind and whether Cache can open it. Errors: bad_path
/// (not absolute), not_found, io_error (the folder cannot be read).
class FolderPickOps implements OpHandler {
  FolderPickOps({String? home}) : home = _homeOrRoot(_clean(home ?? Platform.environment['HOME'] ?? '/'));

  /// The home folder of the user Cache runs as ("/" when it has none: a system account's HOME=/nonexistent, or a home that is
  /// not a folder), so the picker always opens somewhere.
  final String home;

  static String _homeOrRoot(String path) => FileSystemEntity.isDirectorySync(path) ? path : '/';

  @override
  bool handles(String op) => op == 'devfs.list';

  @override
  Future<Object?> handle(String op, Map<String, dynamic> args) async {
    final wanted = args['path'];
    final String path;
    if (wanted == null || (wanted is String && wanted.isEmpty)) {
      path = home;
    } else if (wanted is String && wanted.startsWith('/')) {
      path = _clean(wanted);
    } else {
      throw const CacheSearchException('bad_path', 'An absolute folder path is needed');
    }
    final dir = Directory(path);
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) throw const CacheSearchException('not_found', 'There is no such folder');
    if (!dir.existsSync()) throw const CacheSearchException('io_error', 'That is not a folder');
    final List<FileSystemEntity> kids;
    try {
      kids = dir.listSync(followLinks: false);
    } on FileSystemException catch (e) {
      throw CacheSearchException('io_error', e.osError?.message ?? e.message);
    }
    final folders = <Map<String, Object?>>[];
    for (final k in kids) {
      final name = k.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
      if (name.isEmpty || name.startsWith('.')) continue;
      if (!FileSystemEntity.isDirectorySync(k.path)) continue;
      folders.add({'name': name, 'kind': kindOf(k.path), 'readable': await _readable(k.path)});
    }
    folders.sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
    return {'path': path, 'home': home, 'parent': _parent(path), 'kind': kindOf(path), 'folders': folders};
  }

  /// `obsidian`, `logseq` or `none`: what the folder at [path] is as a notes folder.
  static String kindOf(String path) {
    if (FileSystemEntity.isDirectorySync('$path/.obsidian')) return 'obsidian';
    if (FileSystemEntity.isFileSync('$path/logseq/config.edn')) return 'logseq';
    return 'none';
  }

  /// Whether Cache can open the folder (list it). A folder anyone may read and enter is; for the others (a home folder of another
  /// user, /root) it is tried by listing up to the first entry. (Listing every folder of "/" to find out would take seconds:
  /// /proc and /sys are huge.)
  static Future<bool> _readable(String path) async {
    if (FileStat.statSync(path).mode & 5 == 5) return true;
    try {
      await Directory(path).list(followLinks: false).isEmpty;
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static String? _parent(String path) {
    if (path == '/') return null;
    final i = path.lastIndexOf('/');
    return i <= 0 ? '/' : path.substring(0, i);
  }

  /// [path] with `.`, `..`, empty parts and a trailing "/" taken out ("/" stays "/").
  static String _clean(String path) {
    final out = <String>[];
    for (final p in path.split('/')) {
      if (p.isEmpty || p == '.') continue;
      if (p == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(p);
    }
    return '/${out.join('/')}';
  }
}
