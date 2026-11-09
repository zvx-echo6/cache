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
  int setSources(int handle, String configJson) {
    calls.add('setSources:$configJson');
    return setSourcesResult;
  }

  int setSourcesResult = 0;

  @override
  int setWeb(int handle, String? provider, String? key, bool online) {
    calls.add('setWeb:$provider:$key:$online');
    return 0;
  }

  /// When set, the status the core reports now (a test changes it as the "index" gets built).
  String? Function()? statusFn;

  @override
  String? status(int handle) => statusFn != null ? statusFn!() : replies['status'];

  /// Jobs: `jobStart` fails with [startError] (a core error JSON) when set; `jobProgress` answers these in order, then repeats the last.
  String? startError;
  int nextJob = 100;
  final List<String> progressScript = [];

  @override
  int jobStart(String kind, String paramsJson) {
    if (startError != null) {
      error = startError;
      return 0;
    }
    calls.add('jobStart:$kind:$paramsJson');
    return nextJob++;
  }

  @override
  String? jobProgress(int job) => progressScript.length > 1 ? progressScript.removeAt(0) : progressScript.single;
  @override
  int jobCancel(int job) => 0;
  @override
  void jobFree(int job) => calls.add('jobFree:$job');
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
