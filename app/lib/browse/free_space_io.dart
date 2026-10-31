import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import '../platform.dart' as plat;

/// iOS uses a native helper compiled against its platform statvfs headers.
/// Android and Linux use libc directly (64-bit). Null on failure or unsupported platforms; the download relies on the
/// write failing cleanly when the disk is full.
int? freeBytesOnDisk(String dir) {
  if (plat.isIOS) {
    final path = dir.toNativeUtf8();
    try {
      final freeBytes = ffi.DynamicLibrary.process()
          .lookupFunction<
            ffi.Int64 Function(ffi.Pointer<Utf8>),
            int Function(ffi.Pointer<Utf8>)
          >('cache_free_bytes_on_disk');
      final available = freeBytes(path);
      return available < 0 ? null : available;
    } catch (_) {
      return null;
    } finally {
      calloc.free(path);
    }
  }
  if (!(plat.isAndroid || plat.isLinux)) return null;
  if (ffi.Abi.current() != ffi.Abi.androidArm64 &&
      ffi.Abi.current() != ffi.Abi.androidX64 &&
      ffi.Abi.current() != ffi.Abi.linuxArm64 &&
      ffi.Abi.current() != ffi.Abi.linuxX64) {
    return null;
  }
  final path = dir.toNativeUtf8();
  // struct statvfs on 64-bit: f_bsize, f_frsize, f_blocks, f_bfree, f_bavail (unsigned 64-bit each), then more.
  final buf = calloc<ffi.Uint64>(32);
  try {
    final statvfs = ffi.DynamicLibrary.process()
        .lookupFunction<
          ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint64>),
          int Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint64>)
        >('statvfs');
    if (statvfs(path, buf) != 0) return null;
    final frsize = buf[1];
    final bavail = buf[4];
    return frsize * bavail;
  } catch (_) {
    return null;
  } finally {
    calloc.free(path);
    calloc.free(buf);
  }
}
