import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'pdf_address.dart';

/// Where a PDF was opened from: what "Gone" and "Damaged" offer to do about it.
enum PdfFrom { library, notebook, storage }

/// A PDF to show: a file on the device, or a PDF entry inside a ZIM (copied to a temporary file first, because the viewer
/// reads a file).
sealed class PdfSource {
  const PdfSource({required this.title, required this.from});

  /// The top bar's title: the file name without ".pdf".
  final String title;
  final PdfFrom from;
}

/// A PDF file on the device (a notebook's attached file, a file from Storage).
class PdfFileSource extends PdfSource {
  const PdfFileSource(this.path, {required super.title, super.from = PdfFrom.storage});

  final String path;
}

/// A PDF entry of a ZIM, by its `zim:<uuid>/<path>` address (any `#page=N` is the page to open at, not part of the entry).
class PdfZimSource extends PdfSource {
  PdfZimSource({required String address, required this.read, required super.title, this.tempDir})
      : address = withoutFragment(address),
        super(from: PdfFrom.library);

  final String address;

  /// The entry's bytes (the search core's cs_zim_get); throws [PdfGone] when the ZIM has no such entry.
  final Future<List<int>> Function(String address) read;

  /// Where the copy goes; the app's temporary folder when null.
  final Future<Directory> Function()? tempDir;
}

/// The copy did not fit on the device: [bytes] is the room it needs.
class PdfNoSpace implements Exception {
  const PdfNoSpace(this.bytes);

  final int bytes;
}

/// The entry or file is not there any more.
class PdfGone implements Exception {
  const PdfGone();
}

/// The temporary copy of a ZIM's PDF entry, removed when the reader closes ([dispose]).
class PdfTempCopy {
  PdfTempCopy._(this.file);

  final File file;

  /// Writes [bytes] to a new file in [dir]/pdf-reader, in pieces, reporting progress (0 to 1). A full device gives
  /// [PdfNoSpace]; the half-written file is removed. Copies left behind by an earlier run (the app was closed while reading)
  /// are removed first.
  static Future<PdfTempCopy> write(List<int> bytes, Directory dir, {void Function(double done)? progress, bool Function()? cancelled}) async {
    final folder = Directory('${dir.path}/pdf-reader');
    await folder.create(recursive: true);
    await _sweep(folder);
    final file = File('${folder.path}/${DateTime.now().microsecondsSinceEpoch}.pdf');
    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.write);
      const chunk = 4 << 20;
      for (var at = 0; at < bytes.length; at += chunk) {
        if (cancelled?.call() ?? false) throw const _Cancelled();
        final end = at + chunk < bytes.length ? at + chunk : bytes.length;
        await raf.writeFrom(bytes, at, end);
        progress?.call(end / bytes.length);
      }
      await raf.flush();
      await raf.close();
      raf = null;
      return PdfTempCopy._(file);
    } catch (e) {
      try {
        await raf?.close();
      } catch (_) {}
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      if (e is FileSystemException && isNoSpace(e)) throw PdfNoSpace(bytes.length);
      rethrow;
    }
  }

  /// Removes copies older than an hour (a reader open now has a newer one).
  static Future<void> _sweep(Directory folder) async {
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    try {
      await for (final f in folder.list()) {
        if (f is File && (await f.stat()).modified.isBefore(cutoff)) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> dispose() async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// True when a write failed because the device is full (ENOSPC on Android, iOS, macOS and Linux; ERROR_DISK_FULL and
/// ERROR_HANDLE_DISK_FULL on Windows).
bool isNoSpace(FileSystemException e) {
  final code = e.osError?.errorCode;
  if (code == null) return false;
  if (Platform.isWindows) return code == 112 || code == 39;
  return code == 28;
}

/// Gets a PDF ready to open: a file is checked to be there; a ZIM entry is read and copied to a temporary file. [onCopying] is
/// called when a copy starts and with its progress. The returned copy (null for a file) is the caller's to dispose.
Future<(String path, PdfTempCopy? copy)> preparePdf(
  PdfSource source, {
  void Function(double? progress)? onCopying,
  bool Function()? cancelled,
}) async {
  switch (source) {
    case PdfFileSource(:final path):
      if (!await File(path).exists()) throw const PdfGone();
      return (path, null);
    case PdfZimSource():
      onCopying?.call(null);
      final bytes = await source.read(source.address);
      if (cancelled?.call() ?? false) throw const PdfCancelled();
      final dir = await (source.tempDir ?? getTemporaryDirectory)();
      try {
        final copy = await PdfTempCopy.write(bytes, dir, progress: onCopying, cancelled: cancelled);
        return (copy.file.path, copy);
      } on _Cancelled {
        throw const PdfCancelled();
      }
  }
}

/// The person cancelled while the PDF was being got ready.
class PdfCancelled implements Exception {
  const PdfCancelled();
}
