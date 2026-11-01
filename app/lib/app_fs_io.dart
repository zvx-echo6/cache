import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'app_fs_base.dart';
import 'files.dart' as files;
import 'platform.dart' as plat;

AppFs createAppFs({Directory? supportOverride, Directory? docsOverride}) =>
    IoAppFs(supportOverride: supportOverride, docsOverride: docsOverride);

/// The phone (and desktop) side: today's dart:io code. The roots are found the way the app always found them (the application
/// support folder; the external-storage folder on Android, else the documents folder), and files are written with files.dart.
class IoAppFs implements AppFs {
  IoAppFs({this.supportOverride, this.docsOverride});

  final Directory? supportOverride;
  final Directory? docsOverride;
  Directory? _support;
  Directory? _docs;

  Future<Directory> _root(AppRoot root) async {
    switch (root) {
      case AppRoot.support:
        return _support ??= supportOverride ?? await getApplicationSupportDirectory();
      case AppRoot.docs:
        return _docs ??= docsOverride ??
            (plat.isAndroid ? await getExternalStorageDirectory() : null) ??
            await getApplicationDocumentsDirectory();
    }
  }

  Directory? _resolved(AppRoot root) => root == AppRoot.support ? _support : _docs;

  static String _join(Directory root, String path) => path.isEmpty ? root.path : '${root.path}/$path';

  Future<String> _path(AppRoot root, String path) async => _join(await _root(root), path);

  @override
  Future<String?> readString(AppRoot root, String path) async {
    final f = File(await _path(root, path));
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  @override
  Future<Uint8List?> readBytes(AppRoot root, String path) async {
    final f = File(await _path(root, path));
    return f.existsSync() ? f.readAsBytesSync() : null;
  }

  @override
  Future<void> writeStringAtomic(AppRoot root, String path, String text) async =>
      files.writeStringAtomic(File(await _path(root, path)), text);

  @override
  Future<void> writeBytesAtomic(AppRoot root, String path, List<int> bytes) async =>
      files.writeBytesAtomic(File(await _path(root, path)), bytes);

  @override
  Future<void> writeString(AppRoot root, String path, String text) async =>
      File(await _path(root, path)).writeAsStringSync(text);

  @override
  Future<void> writeStringViaTmp(AppRoot root, String path, String text) async {
    final f = File(await _path(root, path));
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<void> copy(AppRoot root, String from, String to) async {
    final src = File(await _path(root, from));
    if (src.existsSync()) src.copySync(await _path(root, to));
  }

  @override
  void writeStringAtomicSync(AppRoot root, String path, String text) {
    final dir = _resolved(root);
    if (dir == null) throw StateError('The ${root.name} folder has not been used yet');
    files.writeStringAtomicSync(File(_join(dir, path)), text);
  }

  @override
  Future<bool> exists(AppRoot root, String path) async =>
      FileSystemEntity.typeSync(await _path(root, path)) != FileSystemEntityType.notFound;

  @override
  Future<List<AppFsEntry>> list(AppRoot root, String path) async {
    final dir = Directory(await _path(root, path));
    if (!await dir.exists()) return const [];
    final out = <AppFsEntry>[];
    await for (final e in dir.list(followLinks: false)) {
      final s = await e.stat();
      out.add(AppFsEntry(
        name: e.path.split(RegExp(r'[\\/]')).last,
        isDir: s.type == FileSystemEntityType.directory,
        size: s.size,
        mtime: s.modified,
      ));
    }
    return out;
  }

  @override
  Future<AppFsEntry?> stat(AppRoot root, String path) async {
    final p = await _path(root, path);
    final s = FileStat.statSync(p);
    if (s.type == FileSystemEntityType.notFound) return null;
    return AppFsEntry(
      name: p.split(RegExp(r'[\\/]')).last,
      isDir: s.type == FileSystemEntityType.directory,
      size: s.size,
      mtime: s.modified,
    );
  }

  @override
  Future<void> delete(AppRoot root, String path, {bool recursive = false}) async {
    final p = await _path(root, path);
    final type = await FileSystemEntity.type(p);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.directory) {
      await Directory(p).delete(recursive: recursive);
    } else {
      await File(p).delete();
    }
  }

  @override
  Future<void> mkdir(AppRoot root, String path) async {
    await Directory(await _path(root, path)).create(recursive: true);
  }
}
