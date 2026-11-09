// dart:ffi binding of the road-tiles-by-region functions (cs_regions_* in native/include/cache_search.h, docs/REGIONS.md).
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'errors.dart';

typedef _OpenC = Pointer<Void> Function(Pointer<Utf8>);
typedef _CallC = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _CloseC = Void Function(Pointer<Void>);
typedef _Close = void Function(Pointer<Void>);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _Free = void Function(Pointer<Utf8>);
typedef _ErrC = Pointer<Utf8> Function(Pointer<Void>);

DynamicLibrary _openLib() {
  if (Platform.isAndroid || Platform.isLinux) return DynamicLibrary.open('libcache_search.so');
  if (Platform.isWindows) return DynamicLibrary.open('cache_search.dll');
  if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

String? _take(DynamicLibrary lib, Pointer<Utf8> p) {
  if (p == nullptr) return null;
  final s = p.toDartString();
  lib.lookupFunction<_FreeC, _Free>('cs_free_string')(p);
  return s;
}

/// The regions engine: downloaded regions' road tiles, the tiles fetched for routes planned online, and updates, all in the
/// Rust core. Every call runs off the UI thread (`plan` and `add` may fetch the index first). The core keeps one engine per
/// folder, so opening it here and naming the same folder in the search core's "regions" section share it.
class RegionsCore {
  RegionsCore._(this._address);

  final int _address;
  bool _closed = false;

  /// Opens the engine with [config] (`dir`, and the optional `base_url`, `stream_cap_bytes`, `user_agent`, `reserve_bytes`).
  static Future<RegionsCore> open(Map<String, Object?> config) async {
    final cfg = jsonEncode(config);
    final address = await Isolate.run(() {
      final lib = _openLib();
      final open = lib.lookupFunction<_OpenC, _OpenC>('cs_regions_open');
      final p = using((a) => open(cfg.toNativeUtf8(allocator: a)));
      if (p == nullptr) {
        final err = _take(lib, lib.lookupFunction<_ErrC, _ErrC>('cs_last_error')(nullptr));
        throw CacheSearchException.fromJson(err);
      }
      return p.address;
    });
    return RegionsCore._(address);
  }

  /// One method with [args]; the answer, or a [CacheSearchException] with the engine's reason.
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) async {
    if (_closed) throw CacheSearchException('regions', 'Regions are closed');
    final address = _address;
    final a = jsonEncode(args);
    final out = await Isolate.run(() {
      final lib = _openLib();
      final call = lib.lookupFunction<_CallC, _CallC>('cs_regions_call');
      return using((al) => _take(lib, call(Pointer<Void>.fromAddress(address), method.toNativeUtf8(allocator: al), a.toNativeUtf8(allocator: al))));
    });
    final j = out == null ? null : jsonDecode(out);
    if (j is! Map<String, dynamic>) throw CacheSearchException('regions', 'No answer from the regions engine');
    if (j['error'] is String) throw CacheSearchException((j['code'] as String?) ?? 'regions', j['error'] as String);
    return j;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final address = _address;
    await Isolate.run(() {
      final lib = _openLib();
      lib.lookupFunction<_CloseC, _Close>('cs_regions_close')(Pointer<Void>.fromAddress(address));
    });
  }
}
