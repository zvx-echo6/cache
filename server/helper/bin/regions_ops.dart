import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../../packages/cache_search/lib/src/errors.dart';
import 'line_protocol.dart';
import 'offroad_packs.dart';

/// The core's region engine (`cs_regions_*`, docs/REGIONS.md) as plain calls: one method with JSON arguments, its JSON answer.
abstract class RegionsEngine {
  /// The answer, or null when the engine gave none.
  String? call(String method, String argsJson);
}

typedef _OpenC = Pointer<Void> Function(Pointer<Utf8>);
typedef _CallC = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _Free = void Function(Pointer<Utf8>);
typedef _ErrC = Pointer<Utf8> Function(Pointer<Void>);

/// The engine of the core library the helper has open. The core keeps one engine per folder in the process, so opening it here with
/// the folder the search core's `regions` section names shares that engine: its downloads are what the router and places read.
class FfiRegionsEngine implements RegionsEngine {
  FfiRegionsEngine._(this._lib, this._handle);

  final DynamicLibrary _lib;
  final Pointer<Void> _handle;

  /// Opens the engine with [config] (`dir`, `base_url`, ...). Throws a [CacheSearchException] with the engine's reason.
  static FfiRegionsEngine open(DynamicLibrary lib, Map<String, Object?> config) {
    final _OpenC open;
    try {
      open = lib.lookupFunction<_OpenC, _OpenC>('cs_regions_open');
    } on ArgumentError {
      throw const CacheSearchException('unavailable', "This server's core has no region engine");
    }
    final cfg = jsonEncode(config);
    final p = using((a) => open(cfg.toNativeUtf8(allocator: a)));
    if (p == nullptr) {
      final err = _take(lib, lib.lookupFunction<_ErrC, _ErrC>('cs_last_error')(nullptr));
      throw CacheSearchException.fromJson(err);
    }
    return FfiRegionsEngine._(lib, p);
  }

  static String? _take(DynamicLibrary lib, Pointer<Utf8> p) {
    if (p == nullptr) return null;
    final s = p.toDartString();
    lib.lookupFunction<_FreeC, _Free>('cs_free_string')(p);
    return s;
  }

  @override
  String? call(String method, String argsJson) {
    final call = _lib.lookupFunction<_CallC, _CallC>('cs_regions_call');
    return using((a) => _take(_lib, call(_handle, method.toNativeUtf8(allocator: a), argsJson.toNativeUtf8(allocator: a))));
  }
}

/// The browser's way to the region engine, which lives on the server:
///
///   regions.open {}                    -> {"ok": true} (the engine is open; `unavailable` when this core has none)
///   regions.call {method, args}        -> the engine's answer (docs/REGIONS.md), or its error as a [CacheSearchException]
///   regions.close {}                   -> null (the engine is the server's: nothing to close)
///
/// Methods: the engine's own (`status`, `plan`, `add`, `remove`, `stream`, `set_policy`, `check_update`, `update`) and the server's
/// off-road pack downloads (the phone downloads those itself, into the same folder; [OffroadPacks]):
///   offroad_fetch {path, url, bytes, sha256}  -> {"state": "running"|"ready"|"held"}
///   offroad_status {paths: [..]}              -> {"packs": {"<path>": {on_disk, running, done, total, error}}}
///   offroad_cancel {path}                     offroad_remove {path}
/// The downloads are the server's, so they go on with no browser open. [afterOpen] (called when the search core has opened) gives
/// the engine the person's Pause from `<support>/regions-app.json` (the engine does not keep it) and carries on the packs the
/// regions kept there still miss.
class RegionsOps implements OpHandler {
  RegionsOps(this.support, {required this.open, required this.config, OffroadPacks? packs, this.log})
      : packs = packs ?? OffroadPacks(Directory('${support.path}/regions/offroad'), log: log);

  final Directory support;
  final OffroadPacks packs;

  /// Opens the engine (the helper's own handle on the shared one).
  final RegionsEngine Function(Map<String, Object?> config) open;
  final Map<String, Object?> config;
  final void Function(String message)? log;

  RegionsEngine? _engine;

  static const Set<String> _engineMethods = {'status', 'plan', 'add', 'remove', 'stream', 'set_policy', 'check_update', 'update'};

  RegionsEngine _eng() => _engine ??= open(config);

  @override
  bool handles(String op) => op.startsWith('regions.');

  @override
  Object? handle(String op, Map<String, dynamic> a) {
    switch (op) {
      case 'regions.open':
        _eng();
        return {'ok': true};
      case 'regions.close':
        return null;
      case 'regions.call':
        final method = a['method'];
        if (method is! String) throw const CacheSearchException('bad_json', 'regions.call needs a "method"');
        final args = a['args'];
        return _call(method, args is Map ? args.cast<String, dynamic>() : const {});
      default:
        throw CacheSearchException('internal', 'Unknown call $op');
    }
  }

  Object? _call(String method, Map<String, dynamic> args) {
    switch (method) {
      case 'offroad_fetch':
        return packs.fetch(args);
      case 'offroad_status':
        return {'packs': packs.status((args['paths'] as List?) ?? const [])};
      case 'offroad_cancel':
        packs.fileOf(args['path']);
        packs.cancel(args['path'] as String);
        return {'ok': true};
      case 'offroad_remove':
        packs.remove(args['path']);
        return {'ok': true};
    }
    if (!_engineMethods.contains(method)) throw CacheSearchException('bad_method', 'No such regions method: $method');
    final out = _eng().call(method, jsonEncode(args));
    final Object? j = out == null ? null : jsonDecode(out);
    if (j is! Map<String, dynamic>) throw const CacheSearchException('regions', 'No answer from the regions engine');
    if (j['error'] is String) throw CacheSearchException((j['code'] as String?) ?? 'regions', j['error'] as String);
    if (method == 'set_policy' && args['hold'] is bool) {
      packs.held = args['hold'] as bool;
      if (packs.held) packs.cancelAll();
    }
    return j;
  }

  /// The person's Pause and the packs left to fetch, from `<support>/regions-app.json` (written by the app, regions_state.dart):
  /// `{"held": true, "regions": {"<id>": {"offroad": [{path, url, bytes, sha256}]}}}`. Called after the search core opened, so the
  /// engine is the shared one. Never throws: a failure is logged.
  void afterOpen() {
    try {
      final f = File('${support.path}/regions-app.json');
      Map<String, dynamic> app = const {};
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync());
        if (j is Map<String, dynamic>) app = j;
      }
      final held = app['held'] == true;
      try {
        _eng().call('set_policy', jsonEncode({'network': true, 'hold': held}));
      } on CacheSearchException catch (e) {
        log?.call('regions: no region engine (${e.message})');
        return;
      }
      packs.held = held;
      if (held) return;
      var n = 0;
      for (final r in ((app['regions'] as Map?) ?? const {}).values) {
        for (final p in ((r as Map?)?['offroad'] as List?) ?? const []) {
          if (p is! Map) continue;
          try {
            final res = packs.fetch(p.cast<String, dynamic>());
            if (res['state'] == 'running') n++;
          } on CacheSearchException catch (e) {
            log?.call('regions: skipped a pack (${e.message})');
          }
        }
      }
      log?.call('regions: engine ready, held=$held, $n off-road pack(s) carried on');
    } catch (e) {
      log?.call('regions: could not read regions-app.json ($e)');
    }
  }
}
