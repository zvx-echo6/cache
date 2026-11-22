// Web build: the region engine is the Rust core on Cache Server, so every call goes to the server's `/api/core` (the helper's
// `regions.*` ops, server/helper/bin/regions_ops.dart). Same public API as regions_core_io.dart. The engine and its downloads are
// the server's: they go on with no tab open, and the config the app passes (a phone's folders) is not used.
import 'core_transport.dart';
import 'errors.dart';
import 'transport_http.dart';

class RegionsCore {
  RegionsCore._(this._transport);

  final CoreTransport _transport;
  bool _closed = false;

  /// Makes sure the server's region engine is open. [config] is ignored: the server opens it on its own folders. Throws a
  /// [CacheSearchException] (`unavailable`) when the server's core has no region engine.
  /// [transport] is for tests; the app reaches the server's `/api/core`.
  static Future<RegionsCore> open(Map<String, Object?> config, {CoreTransport? transport}) async {
    final t = transport ?? HttpTransport();
    try {
      await t.call('regions.open', const {});
    } catch (_) {
      await t.close();
      rethrow;
    }
    return RegionsCore._(t);
  }

  /// One method with [args]; the answer, or a [CacheSearchException] with the engine's reason. Besides the engine's methods the
  /// server answers `offroad_fetch`, `offroad_status`, `offroad_cancel` and `offroad_remove` (the off-road packs it downloads).
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) async {
    if (_closed) throw const CacheSearchException('regions', 'Regions are closed');
    final r = await _transport.call('regions.call', {'method': method, 'args': args});
    if (r is! Map) throw const CacheSearchException('regions', 'No answer from the regions engine');
    return r.cast<String, dynamic>();
  }

  /// Lets go of this tab's connection; the server's engine stays open.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _transport.close();
  }
}
