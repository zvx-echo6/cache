import '../../../packages/cache_search/lib/src/native_api.dart';

/// A stand-in for the native library, as in packages/cache_search/test/engine_test.dart (FakeNative): answers from canned
/// JSON. Only the members these tests reach are written; anything else throws through noSuchMethod.
class FakeNative implements CsNative, CsLiveNative {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  final Map<String, String?> replies = {};
  final List<String> calls = [];
  String? error;
  int openResult = 7;
  ZimBytes? zim;

  @override
  String? version() => replies['version'];
  @override
  int open(String configJson) {
    calls.add('open:$configJson');
    return openResult;
  }

  @override
  String? status(int handle) => replies['status'];
  @override
  String? lastError(int handle) => error;
  @override
  void close(int handle) => calls.add('close:$handle');
  @override
  String? search(int handle, String query, String optionsJson) {
    calls.add('search:$query:$optionsJson');
    return replies['search'];
  }

  @override
  String? read(int handle, String address, int maxChars) => replies['read'];
  @override
  ZimBytes? zimGet(int handle, String address) => zim;
}
