// Web build: the regions engine is the Rust core, which a browser does not have. Same public API as regions_core_io.dart; every call throws.
class RegionsCore {
  RegionsCore._();

  /// Opens the engine with [config]. Throws on the web.
  static Future<RegionsCore> open(Map<String, Object?> config) async => throw UnsupportedError('web: RegionsCore.open');

  /// One method with [args]. Throws on the web.
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) async => throw UnsupportedError('web: RegionsCore.call');

  Future<void> close() async => throw UnsupportedError('web: RegionsCore.close');
}
