import 'dart:io';

import 'package:flutter/foundation.dart';

import '../browse/zim_download.dart' show FreeSpace, freeBytesOnDisk;
import 'data_kinds.dart';
import 'space.dart';

/// The bytes of every file under [dir] (0 when it does not exist or cannot be read). Links are not followed.
Future<int> directorySize(Directory dir) async {
  var total = 0;
  try {
    if (!await dir.exists()) return 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
  } catch (_) {}
  return total;
}

/// What the app keeps on the phone, by kind ([DataKind], the same list Sharing shares), measured from the files themselves; the free
/// space and what Cache leaves for the phone; and Clean up: unfinished downloads and temporary files, never anything kept.
class StorageUsage extends ChangeNotifier {
  StorageUsage({
    required this.kinds,
    required this.freeIn,
    this.leftovers = _noDirs,
    this.busy = _idle,
    FreeSpace? freeSpace,
    TotalSpace? totalSpace,
  }) : _freeSpace = freeSpace ?? freeBytesOnDisk,
       _totalSpace = totalSpace ?? totalBytesOnDisk;

  /// The kinds Storage lists, in order.
  final List<DataKind> kinds;

  /// A folder on the file system the app writes to, for the free space.
  final Directory? Function() freeIn;

  /// Where unfinished downloads and temporary files collect (partial-download folders, the temporary folder). Clean up empties them.
  final List<Directory?> Function() leftovers;

  /// True while a download runs (its unfinished file is in use, so Clean up waits).
  final bool Function() busy;
  final FreeSpace _freeSpace;
  final TotalSpace _totalSpace;

  static List<Directory?> _noDirs() => const [];
  static bool _idle() => false;

  final Map<String, int> _bytes = {};

  /// Free bytes on the phone, or null when the system cannot say.
  int? freeBytes;

  /// The size of the phone's storage, or null when the system cannot say.
  int? totalBytes;

  /// What Clean up would free.
  int cleanupBytes = 0;
  bool measured = false;
  bool _busy = false;

  /// The bytes of the kind [id] (0 before it is measured).
  int bytesOf(String id) => _bytes[id] ?? 0;

  int get usedBytes => _bytes.values.fold(0, (a, b) => a + b);

  /// What Cache always leaves for the phone (10% of the storage, 5 to 20 GB).
  int get reserveBytes => reserveFor(totalBytes);

  /// Free space alone, which is cheap (the home page shows it).
  void readFree() {
    final d = freeIn();
    final f = d == null ? null : _freeSpace(d.path);
    final t = d == null ? null : _totalSpace(d.path);
    if (f != freeBytes || t != totalBytes) {
      freeBytes = f;
      totalBytes = t;
      notifyListeners();
    }
  }

  Future<int> _sum(List<Directory?> dirs) async {
    var t = 0;
    for (final d in dirs) {
      if (d != null) t += await directorySize(d);
    }
    return t;
  }

  /// Measures every folder.
  Future<void> measure() async {
    if (_busy) return;
    _busy = true;
    try {
      readFree();
      for (final k in kinds) {
        _bytes[k.id] = await _sum(k.folders);
      }
      cleanupBytes = await _sum(leftovers());
      measured = true;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Deletes what is in the leftover folders (not the folders themselves) and measures again. Returns the bytes freed.
  Future<int> cleanUp() async {
    if (busy()) return 0;
    final before = cleanupBytes;
    for (final d in leftovers()) {
      if (d == null) continue;
      try {
        if (!await d.exists()) continue;
        await for (final e in d.list(followLinks: false)) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      } catch (_) {}
    }
    await measure();
    return (before - cleanupBytes).clamp(0, before);
  }
}
