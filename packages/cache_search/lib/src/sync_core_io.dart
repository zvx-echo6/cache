// dart:ffi binding of the sharing and sync functions (cs_sync_* in native/include/cache_search.h).
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

/// The core library: [path] when given (the Cache Server helper, which is told the library's full path), else the platform's name.
DynamicLibrary _openLib([String? path]) {
  if (path != null) return DynamicLibrary.open(path);
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

/// The sync engine: identity, links, shared folders and transfers, all in the Rust core. Every call runs off the UI thread (a
/// call such as `link` waits for the other device).
class SyncCore {
  SyncCore._(this._address, this._path);

  final int _address;
  final String? _path;
  bool _closed = false;

  /// Starts the engine with [config] (`dir`, `name`, and the optional discovery and relay settings). [libraryPath] is the full path of
  /// the core library, for a host that was given it (the Cache Server helper); the apps leave it out and the platform's name is used.
  static Future<SyncCore> open(Map<String, Object?> config, {String? libraryPath}) async {
    final cfg = jsonEncode(config);
    final address = await Isolate.run(() {
      final lib = _openLib(libraryPath);
      final open = lib.lookupFunction<_OpenC, _OpenC>('cs_sync_open');
      final p = using((a) => open(cfg.toNativeUtf8(allocator: a)));
      if (p == nullptr) {
        final err = _take(lib, lib.lookupFunction<_ErrC, _ErrC>('cs_last_error')(nullptr));
        throw CacheSearchException.fromJson(err);
      }
      return p.address;
    });
    return SyncCore._(address, libraryPath);
  }

  /// One method with [args]; the answer, or a [CacheSearchException] with the engine's reason.
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) async {
    if (_closed) throw CacheSearchException('sync', 'Sharing is stopped');
    final address = _address;
    final path = _path;
    final a = jsonEncode(args);
    final out = await Isolate.run(() {
      final lib = _openLib(path);
      final call = lib.lookupFunction<_CallC, _CallC>('cs_sync_call');
      return using((al) => _take(lib, call(Pointer<Void>.fromAddress(address), method.toNativeUtf8(allocator: al), a.toNativeUtf8(allocator: al))));
    });
    final j = out == null ? null : jsonDecode(out);
    if (j is! Map<String, dynamic>) throw CacheSearchException('sync', 'No answer from the sync engine');
    if (j['error'] is String) throw CacheSearchException('sync', j['error'] as String);
    return j;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final address = _address;
    final path = _path;
    await Isolate.run(() {
      final lib = _openLib(path);
      lib.lookupFunction<_CloseC, _Close>('cs_sync_close')(Pointer<Void>.fromAddress(address));
    });
  }
}
