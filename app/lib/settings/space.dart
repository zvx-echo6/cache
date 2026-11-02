import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../browse/zim_download.dart' show FreeSpace, freeBytesOnDisk;

const int _gb = 1 << 30;

/// The space Cache always leaves for the phone: 10% of the storage, at least 5 GB and at most 20 GB. With the size of the storage
/// unknown it is the most, 20 GB.
int reserveFor(int? totalBytes) => totalBytes == null ? 20 * _gb : (totalBytes ~/ 10).clamp(5 * _gb, 20 * _gb);

/// The size of the file system holding [dir], or null when it cannot be told.
typedef TotalSpace = int? Function(String dir);

/// The size of the storage holding [dir]: statvfs on Android and Linux, the volume's total capacity on iOS (a native helper beside
/// the free-space one). Null when it cannot be told.
int? totalBytesOnDisk(String dir) {
  final path = dir.toNativeUtf8();
  try {
    if (Platform.isIOS) {
      final total = ffi.DynamicLibrary.process()
          .lookupFunction<ffi.Int64 Function(ffi.Pointer<Utf8>), int Function(ffi.Pointer<Utf8>)>('cache_total_bytes_on_disk');
      final t = total(path);
      return t <= 0 ? null : t;
    }
    if (!(Platform.isAndroid || Platform.isLinux)) return null;
    if (ffi.Abi.current() != ffi.Abi.androidArm64 &&
        ffi.Abi.current() != ffi.Abi.androidX64 &&
        ffi.Abi.current() != ffi.Abi.linuxArm64 &&
        ffi.Abi.current() != ffi.Abi.linuxX64) {
      return null;
    }
    // struct statvfs on 64-bit: f_bsize, f_frsize, f_blocks, ... (unsigned 64-bit each).
    final buf = calloc<ffi.Uint64>(32);
    try {
      final statvfs = ffi.DynamicLibrary.process()
          .lookupFunction<ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint64>), int Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint64>)>('statvfs');
      if (statvfs(path, buf) != 0) return null;
      final t = buf[1] * buf[2];
      return t <= 0 ? null : t;
    } finally {
      calloc.free(buf);
    }
  } catch (_) {
    return null;
  } finally {
    calloc.free(path);
  }
}

/// The phone's storage as a download sees it: what is free, what Cache leaves for the phone, and what is left to use.
class Space {
  const Space({required this.free, required this.reserve});

  /// Reads the storage holding [dir].
  factory Space.of(String dir, {FreeSpace freeSpace = freeBytesOnDisk, TotalSpace totalSpace = totalBytesOnDisk}) =>
      Space(free: freeSpace(dir), reserve: reserveFor(totalSpace(dir)));

  /// Free bytes (on iOS the space available for important use), or null when the phone cannot say.
  final int? free;

  /// What Cache never uses ([reserveFor]).
  final int reserve;

  /// What a download may use; null when the free space is unknown.
  int? get usable => free == null ? null : (free! - reserve).clamp(0, free!);

  /// How many more bytes are needed before [bytes] fit; 0 when they fit or the free space is unknown.
  int shortBy(int bytes) => usable == null ? 0 : (bytes - usable!).clamp(0, bytes);
}

/// A [FreeSpace] that leaves the reserve out: downloads that check free space with it never use the space kept for the phone.
int? usableBytesOnDisk(String dir) => Space.of(dir).usable;
