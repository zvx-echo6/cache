import 'dart:convert';

import 'errors.dart';
import 'map_models.dart';
import 'models.dart';
import 'native.dart';

Map<String, dynamic> _object(String json) => (jsonDecode(json) as Map).cast<String, dynamic>();

/// Synchronous, typed use of the core: JSON in and out, every error raised from cs_last_error. Calls can
/// block, so the app uses it through [SearchCore], which runs it in a background isolate; a handle is used
/// from one thread at a time.
class SearchEngine {
  SearchEngine(this.native, this._handle);

  /// Opens the core with [sources] (cs_open). Returns at once; libraries open in the background.
  factory SearchEngine.open(CsNative native, List<SourceConfig> sources, {Map<String, dynamic>? extra}) {
    final h = native.open(jsonEncode(openConfigJson(sources, extra: extra)));
    if (h == 0) throw CacheSearchException.fromJson(native.lastError(0));
    return SearchEngine(native, h);
  }

  final CsNative native;
  int _handle;

  bool get isOpen => _handle != 0;

  int get _h {
    if (_handle == 0) throw const CacheSearchException('internal', 'The search core is closed');
    return _handle;
  }

  /// The result string of a call, or the core's error as an exception.
  String _ok(String? s) => s ?? (throw CacheSearchException.fromJson(native.lastError(_h)));

  /// {"version":..,"index_format":..}
  Map<String, dynamic> version() => _object(native.version() ?? '{}');

  /// Replaces the source list (a ZIM was added or removed).
  void setSources(List<SourceConfig> sources) {
    if (native.setSources(_h, jsonEncode(openConfigJson(sources))) < 0) {
      throw CacheSearchException.fromJson(native.lastError(_h));
    }
  }

  List<SourceStatus> status() => [
        for (final s in (_object(_ok(native.status(_h)))['sources'] as List? ?? const []))
          SourceStatus.fromJson((s as Map).cast<String, dynamic>()),
      ];

  SearchResponse search(String query, {int k = 5, int offset = 0, List<String>? sources, QueryVector? queryVector}) {
    final options = {
      'k': k,
      'offset': offset,
      'sources': sources,
      'query_vector': queryVector?.toJson(),
    };
    return SearchResponse.fromJson(_object(_ok(native.search(_h, query, jsonEncode(options)))));
  }

  /// The text for an address, cut at a paragraph end to [maxChars] (about 6,000 is 1,500 tokens).
  ReadResult read(String address, {int maxChars = 6000}) =>
      ReadResult.fromJson(_object(_ok(native.read(_h, address, maxChars))));

  /// Raw bytes of a ZIM entry (HTML, CSS, images), following redirects.
  ZimBytes zimGet(String address) =>
      native.zimGet(_h, address) ?? (throw CacheSearchException.fromJson(native.lastError(_h)));

  /// The address of a ZIM's main page.
  String zimMainPage(String zimId) => _object(_ok(native.zimMainPage(_h, zimId)))['address'] as String;

  List<Suggestion> suggest(String prefix, {int k = 10, List<String>? sources}) => [
        for (final s in (_object(_ok(native.suggest(_h, prefix, jsonEncode({'k': k, 'sources': sources}))))['suggestions'] as List? ?? const []))
          Suggestion.fromJson((s as Map).cast<String, dynamic>()),
      ];

  /// The phone's GPS fix, for the tools that default to "where I am" (cs_set_location). [fixedAt] is ISO 8601 with an offset.
  void setLocation(double lat, double lon, {double accuracyM = -1, required String fixedAt}) {
    if (native.setLocation(_h, lat, lon, accuracyM, fixedAt) < 0) throw CacheSearchException.fromJson(native.lastError(_h));
  }

  void clearLocation() {
    if (native.clearLocation(_h) < 0) throw CacheSearchException.fromJson(native.lastError(_h));
  }

  /// Web search settings (cs_set_web); [provider] null turns it off. [online] is the app's own view of the connection.
  void setWeb({String? provider, String? key, required bool online}) {
    if (native.setWeb(_h, provider, key, online) < 0) throw CacheSearchException.fromJson(native.lastError(_h));
  }

  /// The function schemas of the tools available now (cs_tool_schemas), each {"type":"function","function":{...}}.
  List<Map<String, dynamic>> toolSchemas() =>
      [for (final t in jsonDecode(_ok(native.toolSchemas(_h))) as List) (t as Map).cast<String, dynamic>()];

  /// Runs one tool call (cs_tool). A failure of the tool is not an exception: its content is the error JSON.
  ToolOutput tool(ConversationNumbers conv, String name, Map<String, dynamic> args, {required String now}) =>
      ToolOutput.fromJson(_object(_ok(native.tool(_h, conv.handle, name, jsonEncode(args), now))));

  Map<String, dynamic> placesList() => _object(_ok(native.placesList(_h)));
  Map<String, dynamic> placeSave(Map<String, dynamic> place) => _object(_ok(native.placeSave(_h, jsonEncode(place))));
  Map<String, dynamic> placeDelete(String key) => _object(_ok(native.placeDelete(_h, key)));

  Map<String, dynamic> liveSources() => _object(_ok(native.live(_h, 'sources', '')));
  Map<String, dynamic> liveFetch(Map<String, dynamic> request) => _object(_ok(native.live(_h, 'fetch', jsonEncode(request))));
  Map<String, dynamic> liveGet(Map<String, dynamic> request) => _object(_ok(native.live(_h, 'get', jsonEncode(request))));

  CsLiveNative get _liveNative {
    final n = native is CsLiveNative ? native as CsLiveNative : null;
    if (n != null && n.hasLivePolicy) return n;
    throw const CacheSearchException('unsupported', 'This build of the core cannot take a fetch policy or keys yet');
  }

  /// cs_live_set_fetch_policy: `{"online","allow_metered","metered","enabled_sources":[ids]}`; null clears it (every fetch is denied).
  void liveSetFetchPolicy(Map<String, dynamic>? policy) {
    if (_liveNative.liveSetFetchPolicy(_h, policy == null ? null : jsonEncode(policy)) < 0) {
      throw CacheSearchException.fromJson(native.lastError(_h));
    }
  }

  /// cs_live_set_key: one source's key, kept in the core's memory only; null forgets it.
  void liveSetKey(String sourceId, String? key) {
    if (_liveNative.liveSetKey(_h, sourceId, key) < 0) throw CacheSearchException.fromJson(native.lastError(_h));
  }

  /// cs_live_preview (needs no handle): checks a connector definition (`check_only`), or downloads once with it.
  Map<String, dynamic> livePreview(Map<String, dynamic> request) {
    final r = _liveNative.livePreview(jsonEncode(request));
    return _object(r ?? (throw CacheSearchException.fromJson(native.lastError(0))));
  }

  /// The map layer engine (cs_layers_*): [op] is list, refresh, save, remove, server, plan, delete or clear_cache.
  Map<String, dynamic> layers(String op, [String? arg]) => _object(_ok(native.layers(_h, op, arg)));

  // ---- the map: search, route, guidance (cs_map_*), and saved places ----

  CsMapNative get _map {
    final n = native is CsMapNative ? native as CsMapNative : null;
    if (n != null && n.hasMap) return n;
    throw const CacheSearchException('unsupported', 'This build of the core has no map search or routing yet');
  }

  CsMapNative get _saved {
    final n = native is CsMapNative ? native as CsMapNative : null;
    if (n != null && n.hasSavedPlaces) return n;
    throw const CacheSearchException('unsupported', 'This build of the core cannot save places yet');
  }

  /// cs_map_search: `{"query", "near"?: {"lat","lon"}, "limit"?, "meaning"?, "query_vector"?}` as the raw JSON object.
  Map<String, dynamic> mapSearchRaw(Map<String, dynamic> request) => _object(_ok(_map.mapSearch(_h, jsonEncode(request))));

  /// cs_map_route: `{"from"?, "to", "via"?, "mode"?, "land_access"?, "alternatives"?}` as the raw JSON object.
  Map<String, dynamic> mapRouteRaw(Map<String, dynamic> request) => _object(_ok(_map.mapRoute(_h, jsonEncode(request))));

  /// cs_map_progress: `{"route_id"|"route", "lat", "lon", ...}` as the raw JSON object.
  Map<String, dynamic> mapProgressRaw(Map<String, dynamic> request) => _object(_ok(_map.mapProgress(_h, jsonEncode(request))));

  MapSearchResponse mapSearch(Map<String, dynamic> request) => MapSearchResponse.fromJson(mapSearchRaw(request));
  MapRoute mapRoute(Map<String, dynamic> request) => MapRoute.fromJson(mapRouteRaw(request));
  MapProgress mapProgress(Map<String, dynamic> request) => MapProgress.fromJson(mapProgressRaw(request));

  List<SavedPlaceRecord> savedPlaces() => [
        for (final p in (_object(_ok(_saved.placesList(_h)))['places'] as List? ?? const []))
          SavedPlaceRecord.fromJson((p as Map).cast<String, dynamic>()),
      ];

  /// cs_place_save: `{"key"?, "name", "lat", "lon", "label"?}`; returns the saved place.
  SavedPlaceRecord savePlace(Map<String, dynamic> place) {
    final r = _object(_ok(_saved.placeSave(_h, jsonEncode(place))));
    return SavedPlaceRecord.fromJson(r['place'] is Map ? (r['place'] as Map).cast<String, dynamic>() : r);
  }

  void deleteSavedPlace(String key) => _ok(_saved.placeDelete(_h, key));

  void close() {
    if (_handle != 0) native.close(_handle);
    _handle = 0;
  }
}

/// One chat's [n] numbering (cs_conv).
class ConversationNumbers {
  ConversationNumbers(this.native, this._conv);

  factory ConversationNumbers.create(CsNative native) {
    final c = native.conversationNew();
    if (c == 0) throw CacheSearchException.fromJson(native.lastError(0));
    return ConversationNumbers(native, c);
  }

  /// A conversation from [json], the output of [export] (cs_conversation_import).
  factory ConversationNumbers.import(CsNative native, String json) {
    final c = native.conversationImport(json);
    if (c == 0) throw CacheSearchException.fromJson(native.lastError(0));
    return ConversationNumbers(native, c);
  }

  final CsNative native;
  int _conv;

  /// The native conversation, for cs_tool.
  int get handle => _c;

  /// The conversation's whole state as JSON, to save a chat and continue it later (cs_conversation_export).
  String export() => native.conversationExport(_c) ?? (throw CacheSearchException.fromJson(native.lastError(0)));

  int get _c {
    if (_conv == 0) throw const CacheSearchException('internal', 'The conversation is closed');
    return _conv;
  }

  /// Numbers [results] (search hits, or any list of {address,title,snippet}) and returns the exact tool
  /// message plus the id map so far.
  FormattedResults format(List<Map<String, dynamic>> results) {
    final s = native.format(_c, jsonEncode(results));
    if (s == null) throw CacheSearchException.fromJson(native.lastError(0));
    return FormattedResults.fromJson(_object(s));
  }

  /// The id map so far, for the citation check.
  List<ConversationId> ids() {
    final s = native.conversationIds(_c);
    if (s == null) throw CacheSearchException.fromJson(native.lastError(0));
    return FormattedResults.fromJson({'ids': _object(s)['ids']}).ids;
  }

  void free() {
    if (_conv != 0) native.conversationFree(_conv);
    _conv = 0;
  }
}

/// A long job (index_zim, index_library, update_library, library_manifest).
class CoreJob {
  CoreJob(this.native, this._job);

  /// [kind] is the job kind and [params] its parameters, for example kind "index_zim" with
  /// {"zim_path","index_dir","heap_mb":200}.
  factory CoreJob.start(CsNative native, String kind, Map<String, dynamic> params) {
    final j = native.jobStart(kind, jsonEncode(params));
    if (j == 0) throw CacheSearchException.fromJson(native.lastError(0));
    return CoreJob(native, j);
  }

  final CsNative native;
  int _job;

  int get _j {
    if (_job == 0) throw const CacheSearchException('internal', 'The job is freed');
    return _job;
  }

  JobProgress progress() {
    final s = native.jobProgress(_j);
    if (s == null) throw CacheSearchException.fromJson(native.lastError(0));
    return JobProgress.fromJson(_object(s));
  }

  /// Asks the job to stop at its next checkpoint; poll [progress] until it says cancelled.
  void cancel() {
    if (native.jobCancel(_j) < 0) throw CacheSearchException.fromJson(native.lastError(0));
  }

  /// Frees a job that is done, cancelled or failed.
  void free() {
    if (_job != 0) native.jobFree(_job);
    _job = 0;
  }
}
