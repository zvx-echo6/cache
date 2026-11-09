import 'dart:typed_data';

import '../../app_fs.dart';

/// The libraries' files on the device, for the browser's own install procedure (LibrariesState on the web): every path is a path on
/// the device (what the search core's jobs take), and every operation is an [AppFs] call on the docs root.
class DeviceFiles {
  DeviceFiles(this.fs);

  final AppFs fs;
  String? _docs;

  /// The docs root on the device.
  Future<String> docsRoot() async => _docs ??= await fs.rootPath(AppRoot.docs);

  /// The libraries folder on the device.
  Future<String> librariesBase() async => '${await docsRoot()}/libraries';

  Future<String> _rel(String abs) async {
    final root = await docsRoot();
    if (!abs.startsWith('$root/')) throw ArgumentError('$abs is not in the documents folder');
    return abs.substring(root.length + 1);
  }

  Future<void> mkdirs(String abs) async => fs.mkdir(AppRoot.docs, await _rel(abs));

  Future<void> rename(String from, String to) async => fs.rename(AppRoot.docs, await _rel(from), await _rel(to));

  Future<bool> exists(String abs) async => fs.exists(AppRoot.docs, await _rel(abs));

  /// Deletes a file or a folder with all in it; a problem is only logged by the caller's choice, never thrown.
  Future<void> deleteQuietly(String abs) async {
    try {
      await fs.delete(AppRoot.docs, await _rel(abs), recursive: true);
    } catch (_) {}
  }

  Future<String?> readText(String abs) async => fs.readString(AppRoot.docs, await _rel(abs));

  Future<Uint8List?> readBytes(String abs) async => fs.readBytes(AppRoot.docs, await _rel(abs));

  Future<void> writeText(String abs, String text) async => fs.writeStringAtomic(AppRoot.docs, await _rel(abs), text);

  Future<void> writeBytes(String abs, List<int> bytes) async => fs.writeBytesAtomic(AppRoot.docs, await _rel(abs), bytes);

  /// The names of the folders directly inside [abs].
  Future<List<String>> folderNames(String abs) async => [for (final e in await fs.list(AppRoot.docs, await _rel(abs))) if (e.isDir) e.name];
}
