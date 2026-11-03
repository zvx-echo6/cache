import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:saf_util/saf_util.dart';

import 'folder.dart';
import 'saf_stream_shim.dart';
import '../../platform.dart' as plat;

/// Folders the person picks for Obsidian or Logseq, kept across restarts:
/// - Android: a Storage Access Framework tree with a persisted permission (`content://...`), read and written through SAF;
/// - iOS: a security-scoped bookmark (`bookmark:<base64>`), resolved by the app (AppDelegate.swift, channel `co.cache/folders`)
///   to a path Cache may use while it runs;
/// - elsewhere: a plain path.
const MethodChannel _ios = MethodChannel('co.cache/folders');

/// Lets the person choose a folder; its stored form and its name, or null when none was chosen.
Future<({String path, String display})?> pickSyncFolder() async {
  if (plat.isAndroid) {
    final d = await SafUtil().pickDirectory(writePermission: true, persistablePermission: true);
    return d == null ? null : (path: d.uri, display: d.name);
  }
  if (plat.isIOS) {
    final r = await _ios.invokeMapMethod<String, dynamic>('pick');
    if (r == null || r['bookmark'] is! String) return null;
    return (path: 'bookmark:${r['bookmark']}', display: '${r['name'] ?? 'Folder'}');
  }
  final p = await FilePicker.getDirectoryPath();
  return p == null ? null : (path: p, display: p.split(RegExp(r'[\\/]')).where((x) => x.isNotEmpty).lastOrNull ?? p);
}

/// The folder a stored path names.
Future<SyncFolder> openSyncFolder(String path) async {
  if (path.startsWith('content://')) return SafFolder(path);
  if (path.startsWith('bookmark:')) {
    final r = await _ios.invokeMapMethod<String, dynamic>('resolve', path.substring(9));
    final p = r?['path'];
    if (p is! String) throw const FileSystemException("Can't reach the folder");
    return IoFolder(p);
  }
  return IoFolder(path);
}

/// A folder through Android's Storage Access Framework (saf_util for the tree, saf_stream for the bytes). A write keeps a
/// temporary copy of the new bytes beside the target until the target holds them (see [writeBytes]).
class SafFolder implements SyncFolder {
  SafFolder(this.root, {SafUtil? util, SafStream? stream})
      : _util = util ?? SafUtil(),
        _stream = stream ?? SafStream();

  final String root;
  final SafUtil _util;
  final SafStream _stream;

  @override
  String get display => treeName(root);

  /// The folder's name from a tree URI (`.../tree/primary%3ADocuments%2FVault` -> `Vault`).
  static String treeName(String uri) {
    final last = Uri.decodeComponent(uri.split('/').last);
    return last.split(RegExp(r'[/:]')).where((p) => p.isNotEmpty).lastOrNull ?? last;
  }

  List<String> _parts(String path) => [for (final p in path.split('/')) if (p.isNotEmpty) p];

  @override
  Future<bool> reachable() async {
    try {
      return await _util.exists(root, true);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<FolderFile>> list(String dir) async {
    final parts = _parts(dir);
    final start = parts.isEmpty ? await _util.documentFileFromUri(root, true) : await _util.child(root, parts);
    if (start == null || !start.isDir) return const [];
    final out = <FolderFile>[];
    Future<void> walk(String uri, String prefix) async {
      for (final f in await _util.list(uri)) {
        if (f.name.startsWith('.') && f.name != '.cache') continue;
        final rel = prefix.isEmpty ? f.name : '$prefix/${f.name}';
        if (f.isDir) {
          await walk(f.uri, rel);
        } else {
          out.add(FolderFile(rel, f.lastModified, f.length));
        }
      }
    }

    await walk(start.uri, parts.join('/'));
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  @override
  Future<Uint8List?> readBytes(String path) async {
    final f = await _util.child(root, _parts(path));
    if (f == null || f.isDir) return null;
    return _stream.readFileBytes(f.uri);
  }

  @override
  Future<String?> readText(String path) async {
    final b = await readBytes(path);
    return b == null ? null : utf8.decode(b, allowMalformed: true).replaceAll('\r\n', '\n');
  }

  /// The last write that had to fall back to the temporary copy (null when none did).
  String? lastWriteIssue;

  /// A file that is not there yet is made as a temporary file that is then renamed. A file that is there is written in place:
  /// the same document, truncated and written ("wt"), because Obsidian on Android does not notice a file replaced by another
  /// one (a delete and a rename) until it restarts, so Obsidian Sync never sent Cache's change (Pixel, 2026-11-02). The new
  /// bytes go to a temporary file first and stay there until the document reads back exactly as written; when anything
  /// fails, the temporary file replaces the document (whole, as before) and the error is thrown.
  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    final parts = _parts(path);
    final name = parts.removeLast();
    final dir = parts.isEmpty ? root : (await _util.mkdirp(root, parts)).uri;
    final tmp = '.$name.cache-tmp';
    final mime = name.endsWith('.md') ? 'text/markdown' : (name.endsWith('.jpg') ? 'image/jpeg' : 'application/octet-stream');
    final written = await _stream.writeFileBytes(dir, tmp, mime, bytes, overwrite: true);
    final old = await _util.child(dir, [name]);
    if (old == null) {
      await _util.rename(written.uri.toString(), false, name);
      return;
    }
    try {
      await _stream.writeFileUriBytes(old.uri, bytes);
      final back = await _stream.readFileBytes(old.uri);
      if (!_same(back, bytes)) throw FileSystemException('It did not read back as written', path);
    } catch (e) {
      lastWriteIssue = '$path: $e';
      try {
        final now = await _util.child(dir, [name]);
        if (now != null) await _util.delete(now.uri, false);
        await _util.rename(written.uri.toString(), false, name);
      } catch (r) {
        throw FileSystemException('Could not write it in place ($e) or put it back from $tmp ($r)', path);
      }
      throw FileSystemException('Could not write it in place ($e); it was put back from the temporary copy', path);
    }
    await _util.delete(written.uri.toString(), false);
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Future<void> writeText(String path, String text) => writeBytes(path, Uint8List.fromList(utf8.encode(text)));

  @override
  Future<void> delete(String path) async {
    final f = await _util.child(root, _parts(path));
    if (f != null) await _util.delete(f.uri, f.isDir);
  }

  @override
  Future<bool> exists(String path) async => await _util.child(root, _parts(path)) != null;
}
