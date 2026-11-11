import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../app_fs.dart';
import '../browse/web/local_files.dart' show pickLocalFile, pickLocalFiles;
import '../platform.dart' as plat;
import '../pdf/pdf_address.dart' show looksLikePdf;
import 'save_bytes.dart';
import 'notebook_model.dart';
import 'notebook_state.dart';

/// A new id for a photo or file (UUIDv4 form).
String newMediaId() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// [bytes] as the Notebook keeps a photo: turned upright, at most 2048 px on the long side, JPEG quality 85, with no EXIF (no
/// position or camera data leaves with it); and its 256 px thumbnail. Null when the bytes are not an image.
({Uint8List photo, Uint8List thumb, int width, int height})? encodePhoto(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  var im = img.bakeOrientation(decoded);
  im.exif = img.ExifData();
  img.Image fit(img.Image s, int max) {
    if (s.width <= max && s.height <= max) return s;
    return s.width >= s.height ? img.copyResize(s, width: max) : img.copyResize(s, height: max);
  }

  im = fit(im, 2048);
  final thumb = fit(im, 256);
  return (photo: img.encodeJpg(im, quality: 85), thumb: img.encodeJpg(thumb, quality: 80), width: im.width, height: im.height);
}

/// Stores [bytes] as a photo in the Notebook's media folder (under [id] when given: a photo that came by sync keeps its id).
Future<NbPhoto?> storePhoto(NotebookState nb, Uint8List bytes, {String? id}) async {
  // A browser has no isolates to run on: it encodes here, then writes the two files on the server.
  final out = plat.isWeb ? encodePhoto(bytes) : await Isolate.run(() => encodePhoto(bytes));
  if (out == null) return null;
  id ??= newMediaId();
  if (plat.isWeb) {
    final fs = nb.webFs;
    await fs.writeBytesAtomic(AppRoot.support, NotebookState.photoRel(id), out.photo);
    await fs.writeBytesAtomic(AppRoot.support, NotebookState.thumbRel(id), out.thumb);
    return NbPhoto(id: id, width: out.width, height: out.height, bytes: out.photo.length);
  }
  final f = await nb.photoFile(id);
  final t = await nb.thumbFile(id);
  await f.parent.create(recursive: true);
  await t.parent.create(recursive: true);
  await f.writeAsBytes(out.photo, flush: true);
  await t.writeAsBytes(out.thumb, flush: true);
  return NbPhoto(id: id, width: out.width, height: out.height, bytes: out.photo.length);
}

/// "Take photo" ([camera]) or "Choose from phone"; null when nothing was taken or chosen.
Future<NbPhoto?> addPhoto(NotebookState nb, {required bool camera}) async {
  final x = await ImagePicker().pickImage(source: camera ? ImageSource.camera : ImageSource.gallery);
  if (x == null) return null;
  return storePhoto(nb, await x.readAsBytes());
}

/// A file from the phone (a scan, a PDF) copied into the Notebook's media folder with its own name.
Future<NbFile?> addFile(NotebookState nb) async {
  if (plat.isWeb) {
    // The browser's own chooser (call it straight from the tap); the bytes are written on the server.
    final picked = await pickLocalFile();
    if (picked == null) return null;
    final bytes = await picked.readAll();
    final id = newMediaId();
    await nb.webFs.writeBytesAtomic(AppRoot.support, NotebookState.attachedRel(id), bytes);
    return NbFile(id: id, name: picked.name, bytes: bytes.length);
  }
  final picked = await FilePicker.pickFile();
  if (picked == null || picked.path == null) return null;
  try {
    final id = newMediaId();
    final dest = await nb.attachedFile(id);
    await dest.parent.create(recursive: true);
    await File(picked.path!).copy(dest.path);
    return NbFile(id: id, name: picked.name, bytes: await dest.length());
  } finally {
    try {
      await FilePicker.clearTemporaryFiles();
    } catch (_) {}
  }
}

/// Lets the person choose a file and runs [use] on it while the picker's copy exists (it is cleared after); null when nothing
/// was chosen. Any file can be chosen: the core says when it is not one it reads.
Future<T?> withPickedFile<T>(Future<T> Function(String path, String name) use) async {
  if (plat.isWeb) {
    final picked = await pickLocalFile();
    if (picked == null) return null;
    return withStagedFiles([(name: picked.name, bytes: await picked.readAll())], (paths) => use(paths.first, picked.name));
  }
  final picked = await FilePicker.pickFile();
  if (picked == null || picked.path == null) return null;
  try {
    return await use(picked.path!, picked.name);
  } finally {
    try {
      await FilePicker.clearTemporaryFiles();
    } catch (_) {}
  }
}

/// Like [withPickedFile] with one or more files (a repeater list can be a KML and a CSV together).
Future<T?> withPickedFiles<T>(Future<T> Function(List<String> paths) use) async {
  if (plat.isWeb) {
    final picked = await pickLocalFiles();
    if (picked.isEmpty) return null;
    return withStagedFiles([for (final f in picked) (name: f.name, bytes: await f.readAll())], use);
  }
  final picked = await FilePicker.pickFiles();
  final paths = [for (final f in picked) ?f.path];
  if (paths.isEmpty) return null;
  try {
    return await use(paths);
  } finally {
    try {
      await FilePicker.clearTemporaryFiles();
    } catch (_) {}
  }
}

/// A browser's picked bytes handed to the core, which reads files by path: they are written under `import-tmp/` in the server's
/// support folder (the folder the core runs next to), [use] gets their paths there, and they are removed after.
Future<T> withStagedFiles<T>(List<({String name, Uint8List bytes})> files, Future<T> Function(List<String> paths) use, {AppFs? fs}) async {
  fs ??= createAppFs();
  final dir = 'import-tmp/${newMediaId()}';
  try {
    final root = await fs.rootPath(AppRoot.support);
    final paths = <String>[];
    for (var i = 0; i < files.length; i++) {
      // Only the file's own name (the core goes by its extension); the folder keeps files of one pick apart.
      final base = files[i].name.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
      final rel = '$dir/$i/${base.isEmpty ? 'file' : base}';
      // Writing does not make the folders it writes into.
      await fs.mkdir(AppRoot.support, '$dir/$i');
      await fs.writeBytesAtomic(AppRoot.support, rel, files[i].bytes);
      paths.add('$root/$rel');
    }
    return await use(paths);
  } finally {
    try {
      await fs.delete(AppRoot.support, dir, recursive: true);
    } catch (_) {}
  }
}

/// Opens an attached file in another app (through the share sheet, under its own name).
Future<void> openFile(NotebookState nb, NbFile f) async {
  if (plat.isWeb) {
    // A browser has no share sheet: the file goes to the person as a download (a PDF opens in a new tab).
    final bytes = await nb.attachedBytes(f.id);
    if (bytes == null) throw const FileSystemException('This file is no longer on the server');
    final pdf = (f.mime ?? '').toLowerCase().startsWith('application/pdf') || f.name.toLowerCase().endsWith('.pdf') || looksLikePdf(bytes);
    saveBytesInBrowser(f.name, pdf ? 'application/pdf' : (f.mime ?? 'application/octet-stream'), bytes, inTab: pdf);
    return;
  }
  final file = await nb.attachedFile(f.id);
  await SharePlus.instance.share(ShareParams(files: [XFile(file.path, name: f.name, mimeType: f.mime)], fileNameOverrides: [f.name]));
}

/// Deletes the files of photos and files that were never saved with an entry (taken out before the entry was saved).
Future<void> discardUnsaved(NotebookState nb, {Iterable<NbPhoto> photos = const [], Iterable<NbFile> files = const []}) async {
  if (plat.isWeb) {
    for (final p in photos) {
      for (final rel in [NotebookState.photoRel(p.id), NotebookState.thumbRel(p.id)]) {
        try {
          await nb.webFs.delete(AppRoot.support, rel);
        } catch (_) {}
      }
    }
    for (final x in files) {
      try {
        await nb.webFs.delete(AppRoot.support, NotebookState.attachedRel(x.id));
      } catch (_) {}
    }
    return;
  }
  for (final p in photos) {
    for (final f in [await nb.photoFile(p.id), await nb.thumbFile(p.id)]) {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }
  for (final x in files) {
    try {
      final f = await nb.attachedFile(x.id);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}
