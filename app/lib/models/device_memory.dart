import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

/// The machine's memory in bytes from the system's hw.memsize (iPhone and Mac), or null when it cannot be read. It is read
/// through libc's sysctlbyname: a 64-bit number, no struct, so no platform header is needed.
int? sysctlMemsize() {
  final name = 'hw.memsize'.toNativeUtf8();
  final value = calloc<ffi.Uint64>();
  final len = calloc<ffi.Size>()..value = ffi.sizeOf<ffi.Uint64>();
  try {
    final sysctlbyname = ffi.DynamicLibrary.process()
        .lookupFunction<
          ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Size>, ffi.Pointer<ffi.Void>, ffi.Size),
          int Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Size>, ffi.Pointer<ffi.Void>, int)
        >('sysctlbyname');
    if (sysctlbyname(name, value.cast(), len, ffi.nullptr, 0) != 0) return null;
    return value.value > 0 ? value.value : null;
  } catch (_) {
    return null;
  } finally {
    calloc.free(name);
    calloc.free(value);
    calloc.free(len);
  }
}
