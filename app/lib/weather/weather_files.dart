import 'dart:io';

import '../app_fs.dart';
import '../files.dart';
import '../platform/app_log.dart';

/// A folder of small text files as the weather part reads and writes them: addressed by a relative path ('/'-separated), read and
/// written without waiting. On a phone it is plain dart:io ([IoFiles]); in a browser the files are on Cache Server and the folder is
/// held in memory from a read at start, with every change sent on in order ([AppFsFiles]).
abstract class WeatherFiles {
  /// The text of the file; null when there is none.
  String? read(String rel);

  /// Whole or not at all; makes the folders above it.
  void write(String rel, String text);

  /// A file or a folder.
  bool exists(String rel);

  /// A file, or a folder and everything in it; nothing happens when it is not there.
  void delete(String rel);

  /// Moves a folder to [to] (which is not there).
  void rename(String from, String to);

  /// The names of the folders directly inside [rel] ('' is the root); empty when there are none.
  List<String> folders(String rel);

  /// Makes the folder and the ones above it.
  void makeFolder(String rel);

  /// Reads the file again from where it is kept: another process (the server's own timer) may have written it. Nothing on a phone.
  Future<void> reload(String rel);

  /// Completes when every change made so far has reached where the files are kept (at once on a phone, where a write is done when it
  /// returns). The core reads the source folder itself, so what it should find there is waited for before it is asked.
  Future<void> flush();
}

/// The phone: dart:io on [root], the same calls the code made before this seam.
class IoFiles implements WeatherFiles {
  IoFiles(this.root);

  final Directory root;

  String _p(String rel) => rel.isEmpty ? root.path : '${root.path}/$rel';

  @override
  String? read(String rel) {
    final f = File(_p(rel));
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  @override
  void write(String rel, String text) {
    final f = File(_p(rel));
    f.parent.createSync(recursive: true);
    writeStringAtomicSync(f, text);
  }

  @override
  bool exists(String rel) => FileSystemEntity.typeSync(_p(rel)) != FileSystemEntityType.notFound;

  @override
  void delete(String rel) {
    final p = _p(rel);
    switch (FileSystemEntity.typeSync(p)) {
      case FileSystemEntityType.directory:
        Directory(p).deleteSync(recursive: true);
      case FileSystemEntityType.notFound:
        break;
      default:
        File(p).deleteSync();
    }
  }

  @override
  void rename(String from, String to) => Directory(_p(from)).renameSync(_p(to));

  @override
  List<String> folders(String rel) {
    final d = Directory(_p(rel));
    if (!d.existsSync()) return const [];
    return [for (final e in d.listSync().whereType<Directory>()) e.path.split(Platform.pathSeparator).last];
  }

  @override
  void makeFolder(String rel) => Directory(_p(rel)).createSync(recursive: true);

  @override
  Future<void> reload(String rel) async {}

  @override
  Future<void> flush() async {}
}

/// The browser: a folder on Cache Server ([base] inside [root]) reached through [AppFs]. [open] reads the whole folder once; after
/// that reads are answered from memory and each change is queued behind the earlier ones (an error is logged, as a write that
/// could not be kept is not something the screen can wait for).
class AppFsFiles implements WeatherFiles {
  AppFsFiles._(this._fs, this._root, this._base);

  final AppFs _fs;
  final AppRoot _root;
  final String _base;
  final Map<String, String> _files = {};
  final Set<String> _dirs = {''};
  Future<void> _queue = Future.value();

  static Future<AppFsFiles> open(AppFs fs, AppRoot root, String base) async {
    final f = AppFsFiles._(fs, root, base);
    await fs.mkdir(root, base);
    await f._load('');
    return f;
  }

  String _a(String rel) => rel.isEmpty ? _base : '$_base/$rel';

  Future<void> _load(String rel) async {
    final entries = await _fs.list(_root, _a(rel));
    final nested = <Future<void>>[];
    final reads = <Future<void>>[];
    for (final e in entries) {
      final child = rel.isEmpty ? e.name : '$rel/${e.name}';
      if (e.isDir) {
        _addDirs(child);
        nested.add(_load(child));
      } else {
        reads.add(() async {
          final text = await _fs.readString(_root, _a(child));
          if (text != null) _files[child] = text;
        }());
      }
    }
    await Future.wait([...nested, ...reads]);
  }

  void _addDirs(String rel) {
    var at = '';
    for (final part in rel.split('/')) {
      if (part.isEmpty) continue;
      at = at.isEmpty ? part : '$at/$part';
      _dirs.add(at);
    }
  }

  void _later(Future<void> Function() op) {
    _queue = _queue.then((_) => op()).catchError((Object e) {
      logError('Weather file', error: e);
    });
  }

  @override
  Future<void> flush() => _queue;

  @override
  String? read(String rel) => _files[rel];

  @override
  void write(String rel, String text) {
    _files[rel] = text;
    final i = rel.lastIndexOf('/');
    if (i > 0) _addDirs(rel.substring(0, i));
    _later(() => _fs.writeStringAtomic(_root, _a(rel), text));
  }

  @override
  bool exists(String rel) => _files.containsKey(rel) || _dirs.contains(rel);

  @override
  void delete(String rel) {
    if (rel.isEmpty) return;
    final found = exists(rel);
    _files.removeWhere((k, _) => k == rel || k.startsWith('$rel/'));
    _dirs.removeWhere((d) => d == rel || d.startsWith('$rel/'));
    if (found) _later(() => _fs.delete(_root, _a(rel), recursive: true));
  }

  @override
  void rename(String from, String to) {
    for (final k in _files.keys.where((k) => k.startsWith('$from/')).toList()) {
      _files['$to/${k.substring(from.length + 1)}'] = _files.remove(k)!;
    }
    for (final d in _dirs.where((d) => d == from || d.startsWith('$from/')).toList()) {
      _dirs.remove(d);
      _dirs.add(d == from ? to : '$to/${d.substring(from.length + 1)}');
    }
    _addDirs(to);
    _later(() => _fs.rename(_root, _a(from), _a(to)));
  }

  @override
  List<String> folders(String rel) {
    final prefix = rel.isEmpty ? '' : '$rel/';
    return [
      for (final d in _dirs)
        if (d.isNotEmpty && d.startsWith(prefix) && !d.substring(prefix.length).contains('/')) d.substring(prefix.length),
    ];
  }

  @override
  void makeFolder(String rel) {
    if (rel.isEmpty || _dirs.contains(rel)) return;
    _addDirs(rel);
    _later(() => _fs.mkdir(_root, _a(rel)));
  }

  @override
  Future<void> reload(String rel) async {
    await _queue;
    try {
      final text = await _fs.readString(_root, _a(rel));
      if (text == null) {
        _files.remove(rel);
      } else {
        _files[rel] = text;
      }
    } catch (e) {
      logError('Weather file', error: e);
    }
  }
}
