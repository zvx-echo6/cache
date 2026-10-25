// Hand-written dart:ffi binding of the C API in src/cache_llama.h.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _LoadC = Pointer<Void> Function(Pointer<Utf8>, Int32, Int32, Pointer<Utf8>, Int32);
typedef _Load = Pointer<Void> Function(Pointer<Utf8>, int, int, Pointer<Utf8>, int);
typedef _BufC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32);
typedef _Buf = int Function(Pointer<Void>, Pointer<Utf8>, int);
typedef _StartC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _Start = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int);
typedef _IntHC = Int32 Function(Pointer<Void>);
typedef _IntH = int Function(Pointer<Void>);
typedef _VoidHC = Void Function(Pointer<Void>);
typedef _VoidH = void Function(Pointer<Void>);

/// Thin typed wrapper over the native library. Every method is a direct call.
class CacheLlamaBindings {
  CacheLlamaBindings(DynamicLibrary lib)
      : clLoad = lib.lookupFunction<_LoadC, _Load>('cl_load'),
        clInfo = lib.lookupFunction<_BufC, _Buf>('cl_info'),
        clStart = lib.lookupFunction<_StartC, _Start>('cl_start'),
        clNext = lib.lookupFunction<_BufC, _Buf>('cl_next'),
        clPartial = lib.lookupFunction<_BufC, _Buf>('cl_partial'),
        clFinish = lib.lookupFunction<_BufC, _Buf>('cl_finish'),
        clPromptTokens = lib.lookupFunction<_IntHC, _IntH>('cl_prompt_tokens'),
        clGeneratedTokens = lib.lookupFunction<_IntHC, _IntH>('cl_generated_tokens'),
        clStop = lib.lookupFunction<_VoidHC, _VoidH>('cl_stop'),
        clFree = lib.lookupFunction<_VoidHC, _VoidH>('cl_free');

  /// Opens the native library of the current platform.
  factory CacheLlamaBindings.open() {
    final DynamicLibrary lib;
    if (Platform.isAndroid || Platform.isLinux) {
      lib = DynamicLibrary.open('libcache_llama.so');
    } else if (Platform.isIOS || Platform.isMacOS) {
      lib = DynamicLibrary.process();
    } else if (Platform.isWindows) {
      lib = DynamicLibrary.open('cache_llama.dll');
    } else {
      throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
    }
    return CacheLlamaBindings(lib);
  }

  final _Load clLoad;
  final _Buf clInfo;
  final _Start clStart;
  final _Buf clNext;
  final _Buf clPartial;
  final _Buf clFinish;
  final _IntH clPromptTokens;
  final _IntH clGeneratedTokens;
  final _VoidH clStop;
  final _VoidH clFree;
}
