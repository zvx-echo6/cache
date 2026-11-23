import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'app_fs_base.dart';
import 'files.dart' as files;
import 'platform/app_log.dart';
import 'platform/backup_scope.dart';
import 'platform.dart' as plat;

AppFs createAppFs({Directory? supportOverride, Directory? docsOverride}) =>
    IoAppFs(supportOverride: supportOverride, docsOverride: docsOverride);

Future<String> appSupportPath() async => (await getApplicationSupportDirectory()).path;
Future<String> appDocumentsPath() async => (await getApplicationDocumentsDirectory()).path;
Future<String> appFilesPath() async =>
    ((plat.isAndroid ? await getExternalStorageDirectory() : null) ?? await getApplicationDocumentsDirectory()).path;
Future<String> appTempPath() async => (await getTemporaryDirectory()).path;

/// The phone (and desktop) side: today's dart:io code. The roots are found the way the app always found them (the application
/// support folder; the external-storage folder on Android, else the documents folder), and files are written with files.dart.
class IoAppFs implements AppFs {
  /// [flagger] and [onIOS] are the tests' stand-ins: the iPhone backup flag (see backup_scope.dart) and whether this is an iPhone.
  IoAppFs({this.supportOverride, this.docsOverride, BackupFlagger? flagger, bool? onIOS})
      : _flagger = (onIOS ?? plat.isIOS) ? (flagger ?? const ChannelBackupFlagger()) : null;

  final Directory? supportOverride;
  final Directory? docsOverride;

  /// iPhone only: a write that replaces a file drops its backup-exclusion flag, so a file that is not on the backup allow-list is
  /// flagged again after the write. A flag that fails is logged and never fails the write.
  final BackupFlagger? _flagger;

  Future<void> _flagAfter(AppRoot root, String path, String full) async {
    final f = _flagger;
    if (f == null) return;
    if (root == AppRoot.support && isBackedUp(path)) return;
    try {
      await f.flagIfPresent(full);
    } catch (e) {
      logError('Backup: a file could not be kept out of phone backups', error: e, detail: full);
    }
  }
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
  Future<void> writeStringAtomic(AppRoot root, String path, String text) async {
    final full = await _path(root, path);
    await files.writeStringAtomic(File(full), text);
    await _flagAfter(root, path, full);
  }

  @override
  Future<void> writeBytesAtomic(AppRoot root, String path, List<int> bytes) async {
    final full = await _path(root, path);
    await files.writeBytesAtomic(File(full), bytes);
    await _flagAfter(root, path, full);
  }

  @override
  Future<void> writeString(AppRoot root, String path, String text) async {
    final full = await _path(root, path);
    File(full).writeAsStringSync(text);
    await _flagAfter(root, path, full);
  }

  @override
  Future<void> writeStringViaTmp(AppRoot root, String path, String text) async {
    final f = File(await _path(root, path));
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(f.path);
    await _flagAfter(root, path, f.path);
  }

  @override
  Future<void> copy(AppRoot root, String from, String to) async {
    final src = File(await _path(root, from));
    if (!src.existsSync()) return;
    final dst = await _path(root, to);
    src.copySync(dst);
    await _flagAfter(root, to, dst);
  }

  @override
  void writeStringAtomicSync(AppRoot root, String path, String text) {
    final dir = _resolved(root);
    if (dir == null) throw StateError('The ${root.name} folder has not been used yet');
    final full = _join(dir, path);
    files.writeStringAtomicSync(File(full), text);
    if (_flagger != null) unawaited(_flagAfter(root, path, full));
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
  Future<void> rename(AppRoot root, String from, String to) async {
    final src = await _path(root, from);
    final dst = await _path(root, to);
    if (await FileSystemEntity.type(src) == FileSystemEntityType.directory) {
      await Directory(src).rename(dst);
    } else {
      await File(src).rename(dst);
    }
  }

  @override
  Future<String> rootPath(AppRoot root) async => (await _root(root)).path;

  @override
  Future<void> mkdir(AppRoot root, String path) async {
    await Directory(await _path(root, path)).create(recursive: true);
  }
}
