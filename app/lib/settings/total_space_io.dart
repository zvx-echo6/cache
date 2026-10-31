import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import '../platform.dart' as plat;

/// The size of the storage holding [dir]: statvfs on Android and Linux, the volume's total capacity on iOS (a native helper beside
/// the free-space one). Null when it cannot be told.
int? totalBytesOnDisk(String dir) {
  final path = dir.toNativeUtf8();
  try {
    if (plat.isIOS) {
      final total = ffi.DynamicLibrary.process()
          .lookupFunction<ffi.Int64 Function(ffi.Pointer<Utf8>), int Function(ffi.Pointer<Utf8>)>('cache_total_bytes_on_disk');
      final t = total(path);
      return t <= 0 ? null : t;
    }
    if (!(plat.isAndroid || plat.isLinux)) return null;
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
