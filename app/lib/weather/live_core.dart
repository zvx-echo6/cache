import 'package:cache_search/cache_search.dart';

/// What the weather and alerts part of the app asks of the search core, behind a seam so it can be tested without the core.
abstract class LiveCore {
  /// cs_live_sources: the definitions the core has registered (`sources`) and the files it could not read (`errors`).
  Future<Map<String, dynamic>> sources();

  /// cs_live_fetch.
  Future<Map<String, dynamic>> fetch(Map<String, dynamic> request);

  /// cs_live_get: the stored data, expired or not.
  Future<Map<String, dynamic>> get(Map<String, dynamic> request);

  /// cs_live_set_fetch_policy; null clears it.
  Future<void> setFetchPolicy(Map<String, dynamic>? policy);

  /// cs_live_set_key (memory only in the core); null forgets it.
  Future<void> setKey(String sourceId, String? key);

  /// cs_live_preview with check_only: throws [CacheSearchException] naming every problem when the definition is refused.
  Future<void> check(String definitionText);

  /// cs_live_preview: one real download with a definition and a key, storing nothing.
  Future<Map<String, dynamic>> preview(Map<String, dynamic> request);

  /// The saved places.
  Future<List<SavedPlaceRecord>> savedPlaces();
}

/// The real thing: the search core, once it has opened.
class SearchLiveCore implements LiveCore {
  SearchLiveCore(this._open);

  final Future<SearchCore?> Function() _open;

  Future<SearchCore> _core() async => await _open() ?? (throw StateError('The search core is not available'));

  @override
  Future<Map<String, dynamic>> sources() async => (await _core()).liveSources();

  @override
  Future<Map<String, dynamic>> fetch(Map<String, dynamic> request) async => (await _core()).liveFetch(request);

  @override
  Future<Map<String, dynamic>> get(Map<String, dynamic> request) async => (await _core()).liveGet(request);

  @override
  Future<void> setFetchPolicy(Map<String, dynamic>? policy) async => (await _core()).liveSetFetchPolicy(policy);

  @override
  Future<void> setKey(String sourceId, String? key) async => (await _core()).liveSetKey(sourceId, key);

  @override
  Future<void> check(String definitionText) async {
    await (await _core()).liveCheck(definitionText);
  }

  @override
  Future<Map<String, dynamic>> preview(Map<String, dynamic> request) async => (await _core()).livePreview(request);

  @override
  Future<List<SavedPlaceRecord>> savedPlaces() async => (await _core()).savedPlaces();
}
