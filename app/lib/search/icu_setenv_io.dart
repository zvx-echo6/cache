import 'dart:ffi';

import 'package:ffi/ffi.dart';

void libcSetenv(String name, String value) {
  final f = DynamicLibrary.process().lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, Pointer<Utf8>, int)>('setenv');
  using((a) => f(name.toNativeUtf8(allocator: a), value.toNativeUtf8(allocator: a), 1));
}
