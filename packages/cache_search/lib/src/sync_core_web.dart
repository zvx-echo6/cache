// Web build: the sync engine is the Rust core, which a browser does not have. Same public API as sync_core_io.dart; every call throws.
class SyncCore {
  SyncCore._();

  /// Starts the engine with [config]. Throws on the web.
  static Future<SyncCore> open(Map<String, Object?> config, {String? libraryPath}) async => throw UnsupportedError('web: SyncCore.open');

  /// One method with [args]. Throws on the web.
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) async => throw UnsupportedError('web: SyncCore.call');

  Future<void> close() async => throw UnsupportedError('web: SyncCore.close');
}
