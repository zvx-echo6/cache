import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../packages/cache_search/lib/src/errors.dart';
import 'line_protocol.dart';

/// The `fs.*` ops: the browser's only way to the app's files, which live on the server. Not core ops; the helper answers them
/// before the core dispatcher. Two roots, `support` and `docs` (the app's support and documents folders on the server). A path is
/// relative to its root, uses "/" and must stay inside it: absolute paths, drive letters, backslashes and ".." are refused
/// (`bad_path`), and so is anything whose real location (symlinks resolved) is outside the root.
///
/// Ops (args by name; `root` is "support" or "docs"):
///   fs.read {root,path} -> bytes       fs.readString {root,path} -> string      fs.write {root,path,bytes|string} -> null
///   fs.list {root,path} -> [{name,isDir,size,mtime (ms since epoch)}]           fs.stat {root,path} -> {isDir,size,mtime}
///   fs.exists {root,path} -> bool      fs.delete {root,path,recursive?} -> bool (false: nothing was there)
///   fs.mkdir {root,path} -> null (also makes parents)
///   fs.rename {root,from,to} -> null   a file or a folder moves inside the root, as dart:io renames it (a file replaces a file;
///       a folder replaces only an empty folder); missing parents of `to` are not made. not_found when `from` is not there.
///   fs.roots {} -> {support,docs}      the absolute paths of the two roots, for core jobs that take device paths
/// A write goes to a temp file beside the target and is renamed over it, and makes missing parent folders. Errors: not_found,
/// bad_path, io_error.
class FsOps implements OpHandler {
  FsOps({required this.support, required this.docs});

  final Directory support;
  final Directory docs;

  @override
  bool handles(String op) => op.startsWith('fs.');

  @override
  Object? handle(String op, Map<String, dynamic> a) {
    if (op == 'fs.roots') return {'support': support.absolute.path, 'docs': docs.absolute.path};
    final root = _root(a['root']);
    if (op == 'fs.rename') return _rename(root, a);
    final rel = _segments(a['path']);
    switch (op) {
      case 'fs.read':
        final f = _target(root, rel, needFile: true);
        return _io(() => f.readAsBytesSync());
      case 'fs.readString':
        final f = _target(root, rel, needFile: true);
        final bytes = _io(() => f.readAsBytesSync());
        try {
          return utf8.decode(bytes);
        } on FormatException {
          throw const CacheSearchException('io_error', 'The file is not UTF-8 text');
        }
      case 'fs.write':
        if (rel.isEmpty) throw const CacheSearchException('bad_path', 'A file path is needed');
        final data = a['bytes'] ?? a['string'];
        final Uint8List bytes;
        if (data is Uint8List) {
          bytes = data;
        } else if (data is String) {
          bytes = Uint8List.fromList(utf8.encode(data));
        } else {
          throw const CacheSearchException('bad_path', 'fs.write needs "bytes" or "string"');
        }
        final dest = _target(root, rel, mustExist: false);
        _io(() {
          dest.parent.createSync(recursive: true);
          _checkInside(root, dest.parent.path); // the parents just made are confined too
          if (FileSystemEntity.typeSync(dest.path, followLinks: false) == FileSystemEntityType.directory) {
            throw const FileSystemException('is a directory');
          }
          final tmp = File('${dest.parent.path}/.${dest.uri.pathSegments.last}.$pid.tmp');
          try {
            final h = tmp.openSync(mode: FileMode.write);
            try {
              h.writeFromSync(bytes);
              h.flushSync();
            } finally {
              h.closeSync();
            }
            tmp.renameSync(dest.path);
          } catch (_) {
            try {
              if (tmp.existsSync()) tmp.deleteSync();
            } catch (_) {}
            rethrow;
          }
        });
        return null;
      case 'fs.list':
        final d = _dirTarget(root, rel);
        if (!d.existsSync()) throw CacheSearchException('not_found', 'No such folder: ${rel.join('/')}');
        return _io(() {
          final out = <Map<String, Object?>>[];
          for (final e in d.listSync(followLinks: false)) {
            final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
            var isDir = e is Directory;
            if (e is Link) {
              // A link is listed only if it resolves to something inside the root.
              try {
                _checkInside(root, e.resolveSymbolicLinksSync());
              } on CacheSearchException {
                continue;
              }
              isDir = FileSystemEntity.isDirectorySync(e.path);
            }
            final st = FileStat.statSync(e.path);
            out.add({'name': name, 'isDir': isDir, 'size': isDir ? 0 : st.size, 'mtime': st.modified.millisecondsSinceEpoch});
          }
          out.sort((x, y) => (x['name'] as String).compareTo(y['name'] as String));
          return out;
        });
      case 'fs.stat':
        final e = _entity(root, rel);
        final st = FileStat.statSync(e.path);
        if (st.type == FileSystemEntityType.notFound) throw CacheSearchException('not_found', 'No such file: ${rel.join('/')}');
        final isDir = st.type == FileSystemEntityType.directory;
        return {'isDir': isDir, 'size': isDir ? 0 : st.size, 'mtime': st.modified.millisecondsSinceEpoch};
      case 'fs.exists':
        return FileStat.statSync(_entity(root, rel).path).type != FileSystemEntityType.notFound;
      case 'fs.delete':
        if (rel.isEmpty) throw const CacheSearchException('bad_path', 'The root itself cannot be deleted');
        // Only the parent is checked: deleting a link removes the link, never what it points at.
        final p = _join(root, rel);
        _checkInside(root, Directory(p).parent.path);
        final type = FileSystemEntity.typeSync(p, followLinks: false);
        final FileSystemEntity e = type == FileSystemEntityType.directory
            ? Directory(p)
            : type == FileSystemEntityType.link
                ? Link(p)
                : File(p);
        if (type == FileSystemEntityType.notFound) return false;
        final recursive = a['recursive'] == true;
        _io(() {
          if (type == FileSystemEntityType.directory) {
            e.deleteSync(recursive: recursive);
          } else {
            e.deleteSync(); // a file, or a link (the link only, never what it points at)
          }
        });
        return true;
      case 'fs.mkdir':
        final d = _dirTarget(root, rel);
        _io(() => d.createSync(recursive: true));
        _checkInside(root, d.path);
        return null;
      default:
        throw CacheSearchException('internal', 'Unknown call $op');
    }
  }

  Object? _rename(Directory root, Map<String, dynamic> a) {
    final from = _segments(a['from']);
    final to = _segments(a['to']);
    if (from.isEmpty || to.isEmpty) throw const CacheSearchException('bad_path', 'The root itself cannot be renamed');
    final src = _join(root, from);
    final dst = _join(root, to);
    // Only the parents are checked: a link is moved as itself, never what it points at.
    _checkInside(root, Directory(src).parent.path);
    _checkInside(root, Directory(dst).parent.path);
    final type = FileSystemEntity.typeSync(src, followLinks: false);
    if (type == FileSystemEntityType.notFound) throw CacheSearchException('not_found', 'No such file: ${from.join('/')}');
    _io(() {
      if (type == FileSystemEntityType.directory) {
        Directory(src).renameSync(dst);
      } else if (type == FileSystemEntityType.link) {
        Link(src).renameSync(dst);
      } else {
        File(src).renameSync(dst);
      }
    });
    return null;
  }

  Directory _root(Object? name) {
    if (name == 'support') return support;
    if (name == 'docs') return docs;
    throw const CacheSearchException('bad_path', 'root is "support" or "docs"');
  }

  /// The normalized segments of a relative path ("" and "." mean the root: no segments).
  static List<String> _segments(Object? path) {
    if (path == null) return const [];
    if (path is! String) throw const CacheSearchException('bad_path', 'path is a string');
    if (path.contains('\u0000') || path.contains('\\') || path.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(path)) {
      throw const CacheSearchException('bad_path', 'A path is relative and uses "/"');
    }
    final out = <String>[];
    for (final s in path.split('/')) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') throw const CacheSearchException('bad_path', 'A path may not contain ".."');
      out.add(s);
    }
    return out;
  }

  String _join(Directory root, List<String> rel) => rel.isEmpty ? root.path : '${root.path}/${rel.join('/')}';

  /// The real location must be inside the real root (symlinks resolved): for the target if it exists, else for its nearest
  /// existing ancestor.
  void _checkInside(Directory root, String path) {
    final realRoot = _io(() => root.resolveSymbolicLinksSync());
    var probe = path;
    String real;
    while (true) {
      if (FileSystemEntity.typeSync(probe, followLinks: false) != FileSystemEntityType.notFound) {
        real = _io(() => File(probe).resolveSymbolicLinksSync());
        break;
      }
      final up = Directory(probe).parent.path;
      if (up == probe) throw const CacheSearchException('bad_path', 'The path is outside the folder');
      probe = up;
    }
    final sep = Platform.pathSeparator;
    bool same(String x, String y) => Platform.isWindows ? x.toLowerCase() == y.toLowerCase() : x == y;
    final prefix = realRoot.endsWith(sep) ? realRoot : '$realRoot$sep';
    final inside = same(real, realRoot) || (Platform.isWindows ? real.toLowerCase().startsWith(prefix.toLowerCase()) : real.startsWith(prefix));
    if (!inside) throw const CacheSearchException('bad_path', 'The path is outside the folder');
  }

  FileSystemEntity _entity(Directory root, List<String> rel) {
    final p = _join(root, rel);
    _checkInside(root, p);
    return FileSystemEntity.isDirectorySync(p) ? Directory(p) : File(p);
  }

  Directory _dirTarget(Directory root, List<String> rel) {
    final p = _join(root, rel);
    _checkInside(root, p);
    return Directory(p);
  }

  File _target(Directory root, List<String> rel, {bool needFile = false, bool mustExist = true}) {
    if (rel.isEmpty) throw const CacheSearchException('bad_path', 'A file path is needed');
    final p = _join(root, rel);
    _checkInside(root, p);
    final f = File(p);
    if (mustExist && needFile) {
      final t = FileSystemEntity.typeSync(p);
      if (t == FileSystemEntityType.notFound) throw CacheSearchException('not_found', 'No such file: ${rel.join('/')}');
      if (t == FileSystemEntityType.directory) throw CacheSearchException('io_error', '${rel.join('/')} is a folder');
    }
    return f;
  }

  T _io<T>(T Function() f) {
    try {
      return f();
    } on FileSystemException catch (e) {
      final code = e.osError?.errorCode;
      if (code == 2 || (Platform.isWindows && code == 3)) {
        throw CacheSearchException('not_found', e.message);
      }
      throw CacheSearchException('io_error', e.message);
    }
  }
}
