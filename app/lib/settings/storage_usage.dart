import 'dart:io';

import 'package:flutter/foundation.dart';

import '../browse/zim_download.dart' show FreeSpace, freeBytesOnDisk;

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

/// What the app keeps on the phone, by kind, measured from the files themselves.
class StorageUsage extends ChangeNotifier {
  StorageUsage({required this.library, required this.maps, required this.models, required this.videos, required this.freeIn, FreeSpace? freeSpace})
    : _freeSpace = freeSpace ?? freeBytesOnDisk;

  /// The folders that hold each kind (read when measuring, because some are only known once the app has started).
  final List<Directory?> Function() library;
  final List<Directory?> Function() maps;
  final List<Directory?> Function() models;
  final List<Directory?> Function() videos;

  /// A folder on the file system the app writes to, for the free space.
  final Directory? Function() freeIn;
  final FreeSpace _freeSpace;

  int libraryBytes = 0;
  int mapsBytes = 0;
  int modelsBytes = 0;
  int videosBytes = 0;

  /// Free bytes on the phone, or null when the system cannot say.
  int? freeBytes;
  bool measured = false;
  bool _busy = false;

  int get usedBytes => libraryBytes + mapsBytes + modelsBytes + videosBytes;

  /// Free space alone, which is cheap (the home page shows it).
  void readFree() {
    final d = freeIn();
    final f = d == null ? null : _freeSpace(d.path);
    if (f != freeBytes) {
      freeBytes = f;
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
      libraryBytes = await _sum(library());
      mapsBytes = await _sum(maps());
      modelsBytes = await _sum(models());
      videosBytes = await _sum(videos());
      measured = true;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
