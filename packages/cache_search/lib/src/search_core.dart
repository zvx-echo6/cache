import 'dart:typed_data';

import 'core_dispatch.dart';
import 'core_transport.dart';
import 'errors.dart';
import 'map_models.dart';
import 'models.dart';
import 'native.dart';
import 'transport_select.dart';

export 'core_dispatch.dart' show CsNativeFactory;

CsNative _openNative() => FfiCsNative.open();

/// The search core for the UI. Every call goes through a [CoreTransport] to the core's [CoreDispatcher]: on the phone a
/// long-lived background isolate that owns the handle, in the browser HTTPS to Cache for Linux's helper.
class SearchCore {
  SearchCore._(this._transport);

  /// Starts the transport and opens the core with [sources]. Throws a [CacheSearchException] if the native
  /// library is missing on this platform or cs_open fails. [extra] holds the other sections of the cs_open config
  /// (user, live, places, routing, ...), see cache_search.h.
  static Future<SearchCore> open(List<SourceConfig> sources, {Map<String, dynamic>? extra, CsNativeFactory native = _openNative}) async {
    final core = SearchCore._(await openDefaultTransport(native));
    try {
      await core._call('open', {'sources': jsonSources(sources), 'extra': extra});
    } catch (_) {
      await core.close();
      rethrow;
    }
    return core;
  }

  final CoreTransport _transport;
  bool _closed = false;

  static List<Map<String, dynamic>> jsonSources(List<SourceConfig> s) => [for (final x in s) x.toJson()];

  Future<dynamic> _call(String op, [Map<String, dynamic> args = const {}]) {
    if (_closed) return Future.error(const CacheSearchException('internal', 'The search core is closed'));
    return _transport.call(op, args);
  }

  Future<Map<String, dynamic>> version() async => (await _call('version') as Map).cast<String, dynamic>();

  /// Replaces the source list (a ZIM was added or removed).
  /// Replaces the source list; [extra] are the config fields cs_set_sources takes again each time (`indexes_dir`).
  Future<void> setSources(List<SourceConfig> sources, {Map<String, dynamic>? extra}) =>
      _call('setSources', {'sources': jsonSources(sources), 'extra': extra});

  Future<List<SourceStatus>> status() async => [
        for (final s in await _call('status') as List) SourceStatus.fromJson((s as Map).cast<String, dynamic>()),
      ];

  /// Snapshots the core found unusable and removed on this device ([SearchEngine.rejectedSnapshots]).
  Future<List<RejectedSnapshot>> rejectedSnapshots() async => [
        for (final r in await _call('rejected') as List) RejectedSnapshot.fromJson((r as Map).cast<String, dynamic>()),
      ];

  Future<SearchResponse> search(String query, {int k = 5, int offset = 0, List<String>? sources, QueryVector? queryVector}) async =>
      SearchResponse.fromJson(((await _call('search', {
        'query': query,
        'k': k,
        'offset': offset,
        'sources': sources,
        'queryVector': queryVector?.toJson(),
      })) as Map)
          .cast<String, dynamic>());

  Future<ReadResult> read(String address, {int maxChars = 6000}) async =>
      ReadResult.fromJson(((await _call('read', {'address': address, 'maxChars': maxChars})) as Map).cast<String, dynamic>());

  Future<ZimBytes> zimGet(String address) async {
    final r = await _call('zimGet', {'address': address}) as List;
    return ZimBytes(r[0] as Uint8List, r[1] as String);
  }

  /// Cache for Linux only (the phone's core does not have this call): what the server's own index jobs are doing, by source path:
  /// `fraction` (0..1, or null while the total is not known) for a source being indexed, `error` for one whose index failed.
  Future<Map<String, ({double? fraction, String? error})>> indexState() async => {
        for (final e in ((await _call('index.state')) as Map).entries)
          e.key as String: (
            fraction: ((e.value as Map)['fraction'] as num?)?.toDouble(),
            error: (e.value as Map)['error'] as String?,
          ),
      };

  Future<String> zimMainPage(String zimId) async => (await _call('zimMainPage', {'zimId': zimId})) as String;

  Future<List<Suggestion>> suggest(String prefix, {int k = 10, List<String>? sources}) async => [
        for (final s in await _call('suggest', {'prefix': prefix, 'k': k, 'sources': sources}) as List)
          Suggestion.fromJson((s as Map).cast<String, dynamic>()),
      ];

  // ---- the map (cs_map_*) and saved places ----

  /// The map's search box. [query] is a place name, a category, coordinates in any format, or a meaning; [near] is the
  /// map centre or the GPS fix (distances and ranking are from it). [meaning] false skips the vector step (fast, for
  /// results as you type); [queryVector] is the query as the app's embedder made it.
  Future<MapSearchResponse> mapSearch(String query, {GeoPoint? near, int limit = 10, bool meaning = true, MapQueryVector? queryVector}) async =>
      MapSearchResponse.fromJson(((await _call('mapSearch', {
        'request': {
          'query': query,
          if (near != null) 'near': near.toJson(),
          'limit': limit,
          'meaning': meaning,
          'query_vector': ?queryVector?.toJson(),
        },
      })) as Map)
          .cast<String, dynamic>());

  /// The complete route. [to] and [from] are ends (`{"id"?, "lat", "lon", "name"?}`, from a [MapPlace.toEnd]); no [from]
  /// is the core's last GPS fix. A route that cannot be made is a [MapRoute] with `ok` false and its errors.
  Future<MapRoute> mapRoute({Map<String, dynamic>? from, required Map<String, dynamic> to, List<Map<String, dynamic>> via = const [], String mode = 'drive', String? landAccess, int alternatives = 2}) async =>
      MapRoute.fromJson(((await _call('mapRoute', {
        'request': {
          'from': ?from,
          'to': to,
          if (via.isNotEmpty) 'via': via,
          'mode': mode,
          'land_access': ?landAccess,
          'alternatives': alternatives,
        },
      })) as Map)
          .cast<String, dynamic>());

  /// Retrieves a retained exact route; never computes a replacement route.
  Future<MapRoute> mapRouteById(String routeId) async => MapRoute.fromJson(
      ((await _call('mapRoute', {'request': {'route_id': routeId}})) as Map).cast<String, dynamic>());

  /// Where a fix is on a route. Sends [route] too, so the core finds the route again after a restart.
  Future<MapProgress> mapProgress(MapRoute route, {required double lat, required double lon, double? accuracyM, DateTime? now, bool reset = false, double? offRouteM, int? offRouteFixes, bool sendRoute = false}) async =>
      MapProgress.fromJson(((await _call('mapProgress', {
        'request': {
          'route_id': route.routeId,
          if (sendRoute) 'route': route.raw,
          'lat': lat,
          'lon': lon,
          'accuracy_m': ?accuracyM,
          if (now != null) 'now': rfc3339(now),
          if (reset) 'reset': true,
          'off_route_m': ?offRouteM,
          'off_route_fixes': ?offRouteFixes,
        },
      })) as Map)
          .cast<String, dynamic>());

  /// Makes the next search read the places again (cs_places_refresh): after a region's places were merged or removed, and
  /// when the sources are refreshed. [packs], when given, replaces the single-region packs. `{"ok", "packs", "merged"}`.
  Future<Map<String, dynamic>> refreshPlaces({List<String>? packs}) => _map('placesRefresh', {'packs': packs});

  Future<List<SavedPlaceRecord>> savedPlaces() async => [
        for (final p in await _call('savedPlaces') as List) SavedPlaceRecord.fromJson((p as Map).cast<String, dynamic>()),
      ];

  Future<SavedPlaceRecord> savePlace({String? key, required String name, required double lat, required double lon, String? label}) async =>
      SavedPlaceRecord.fromJson(((await _call('savePlace', {'place': {'key': ?key, 'name': name, 'lat': lat, 'lon': lon, 'label': ?label}})) as Map).cast<String, dynamic>());

  Future<void> deleteSavedPlace(String key) => _call('deleteSavedPlace', {'key': key});

  /// A new [n] numbering for one chat. Free it with [CoreConversation.free].
  Future<CoreConversation> newConversation() async => CoreConversation._(this, (await _call('convNew')) as int);

  /// A conversation continued from [CoreConversation.export]'s output, with the same numbering.
  Future<CoreConversation> importConversation(String json) async =>
      CoreConversation._(this, (await _call('convImport', {'json': json})) as int);

  /// The phone's GPS fix for the tools that default to "where I am" (cs_set_location). [fixedAt] is ISO 8601 with an offset.
  Future<void> setLocation(double lat, double lon, {double accuracyM = -1, required String fixedAt}) =>
      _call('setLocation', {'lat': lat, 'lon': lon, 'accuracy': accuracyM, 'fixedAt': fixedAt});

  Future<void> clearLocation() => _call('clearLocation');

  /// Web search settings (cs_set_web); [provider] null turns it off.
  Future<void> setWeb({String? provider, String? key, required bool online}) =>
      _call('setWeb', {'provider': provider, 'key': key, 'online': online});

  /// Installs the act tool's action definitions (cs_act_set_definitions), replacing the earlier set; the install report.
  Future<Map<String, dynamic>> actSetDefinitions(List<Map<String, dynamic>> definitions) => _map('actSetDefinitions', {'defs': definitions});

  /// The modules switched off (cs_act_set_modules_off).
  Future<void> actSetModulesOff(List<String> modules) => _call('actSetModulesOff', {'modules': modules});

  /// The checks and place resolution of an act call, kept with a confirm card (cs_act_resolve).
  Future<Map<String, dynamic>> actResolve(String action, Map<String, dynamic> fields) => _map('actResolve', {'action': action, 'fields': fields});

  /// One op of the Notebook (cs_notebook; cache_search.h lists the ops and their answers).
  Future<Map<String, dynamic>> notebook(String op, [Map<String, dynamic> args = const {}]) => _map('notebook', {'op': op, 'args': args});

  /// True when the core has the PDF index calls (cs_zim_pdfs, cs_pdfindex_*).
  Future<bool> hasPdfIndex() async => (await _call('hasPdfIndex')) as bool;

  /// The ZIM's PDF entries (cs_zim_pdfs).
  Future<Map<String, dynamic>> zimPdfs(String zimId) => _map('zimPdfs', {'zimId': zimId});

  /// One handle-less PDF call: the build session (`open`, `add`, `reuse`, `skip`, `close`, `discard`) or `chunk` (cs_pdf_chunk);
  /// see cache_search.h.
  Future<Map<String, dynamic>> pdfIndex(String op, {int session = 0, Map<String, dynamic>? args}) =>
      _map('pdfIndex', {'op': op, 'session': session, 'args': args});

  /// True when the core has cs_captions_search.
  Future<bool> hasCaptionsSearch() async => (await _call('hasCaptionsSearch')) as bool;

  /// Saved videos and ZIM videos matched by caption text (cs_captions_search): {"videos":[...]}.
  Future<Map<String, dynamic>> captionsSearch(String query, {int? k, String? lang}) =>
      _map('captionsSearch', {'request': {'query': query, 'k': ?k, 'lang': ?lang}});

  /// One of the user's map layer and repeater list calls (cs_userlayer*; see [SearchEngine.userLayers]).
  Future<Map<String, dynamic>> userLayers(String call, [String? arg]) => _map('userLayers', {'call': call, 'arg': arg});

  /// The function schemas of the tools available now (cs_tool_schemas).
  Future<List<Map<String, dynamic>>> toolSchemas() async =>
      [for (final t in await _call('toolSchemas') as List) (t as Map).cast<String, dynamic>()];

  Future<Map<String, dynamic>> _map(String op, [Map<String, dynamic> args = const {}]) async =>
      ((await _call(op, args)) as Map).cast<String, dynamic>();

  /// Saved places (cs_places_list, cs_place_save, cs_place_delete).
  Future<Map<String, dynamic>> placesList() => _map('placesList');
  Future<Map<String, dynamic>> placeSave(Map<String, dynamic> place) => _map('placeSave', {'place': place});
  Future<Map<String, dynamic>> placeDelete(String key) => _map('placeDelete', {'key': key});

  /// Live data (cs_live_sources, cs_live_fetch, cs_live_get).
  Future<Map<String, dynamic>> liveSources() => _map('liveSources');
  Future<Map<String, dynamic>> liveFetch(Map<String, dynamic> request) => _map('liveFetch', {'request': request});
  Future<Map<String, dynamic>> liveGet(Map<String, dynamic> request) => _map('liveGet', {'request': request});

  /// The host's grant for network fetches (cs_live_set_fetch_policy): `{"online","allow_metered","metered","enabled_sources":[ids]}`.
  /// Null clears it, and the core fetches nothing. Push it at start and whenever the connection or the settings change.
  Future<void> liveSetFetchPolicy(Map<String, dynamic>? policy) => _call('liveSetFetchPolicy', {'policy': policy});

  /// A source's key (cs_live_set_key), kept in the core's memory only and never read back; null forgets it.
  Future<void> liveSetKey(String sourceId, String? key) => _call('liveSetKey', {'source': sourceId, 'key': key});

  /// Checks a connector definition without downloading (cs_live_preview with `check_only`): `{"valid":true,"source":{...},
  /// "requests":[...],"warnings":[...]}`, or a [CacheSearchException] whose message names every problem field.
  Future<Map<String, dynamic>> liveCheck(Object definition) => _map('livePreview', {'request': {'definition': definition, 'check_only': true}});

  /// Downloads once with a definition (cs_live_preview): to check a key, and for a connector's author. Nothing is stored.
  Future<Map<String, dynamic>> livePreview(Map<String, dynamic> request) => _map('livePreview', {'request': request});

  /// The map layer engine (cs_layers_*): [op] is list, refresh, save, remove, server, plan, delete or clear_cache; [arg]
  /// is that call's one string (see cache_search.h).
  Future<Map<String, dynamic>> layers(String op, [String? arg]) => _map('layers', {'op': op, 'arg': arg});

  /// Starts a long job: kind "index_zim" with {"zim_path","index_dir","heap_mb"} and so on (see cache_search.h).
  Future<CoreJobHandle> startJob(String kind, Map<String, dynamic> params) async =>
      CoreJobHandle._(this, (await _call('jobStart', {'kind': kind, 'params': params})) as int);

  /// Closes the core and ends the worker.
  Future<void> close() async {
    if (_closed) return;
    try {
      await _call('close');
    } catch (_) {}
    _closed = true;
    await _transport.close();
  }
}

/// One chat's [n] numbering, owned by the core's worker.
class CoreConversation {
  CoreConversation._(this._core, this._id);

  final SearchCore _core;
  final int _id;
  bool _freed = false;

  /// Numbers [results] (search hits as [SearchHit.toFormatJson], or any {address,title,snippet}) and
  /// returns the exact tool message and the id map so far.
  Future<FormattedResults> format(List<Map<String, dynamic>> results) async =>
      FormattedResults.fromJson(((await _core._call('convFormat', {'conv': _id, 'results': results})) as Map).cast<String, dynamic>());

  /// The id map so far, for the citation check.
  Future<List<ConversationId>> ids() async => [
        for (final i in await _core._call('convIds', {'conv': _id}) as List) ConversationId.fromJson((i as Map).cast<String, dynamic>()),
      ];

  /// Runs one tool call in this conversation (cs_tool); its sources are numbered here. A failure of the tool comes back
  /// as its error JSON in [ToolOutput.content], not as an exception. [now] is the local time, ISO 8601 with an offset.
  Future<ToolOutput> tool(String name, Map<String, dynamic> args, {required String now}) async => ToolOutput.fromJson(
      ((await _core._call('convTool', {'conv': _id, 'name': name, 'args': args, 'now': now})) as Map).cast<String, dynamic>());

  /// The host's reply to an act call's host_run (cs_act_finish): the exact tool message for the model.
  Future<String> actFinish(String runId, Map<String, dynamic> reply) async =>
      (await _core._call('convActFinish', {'conv': _id, 'run_id': runId, 'reply': reply})) as String;

  /// A confirm card's outcome (cs_act_outcome): the exact content of the system message for the model.
  Future<String> actOutcome(Map<String, dynamic> outcome) async => (await _core._call('convActOutcome', {'conv': _id, 'outcome': outcome})) as String;

  /// The conversation's whole state as JSON (cs_conversation_export).
  Future<String> export() async => (await _core._call('convExport', {'conv': _id})) as String;

  Future<void> free() async {
    if (_freed) return;
    _freed = true;
    try {
      await _core._call('convFree', {'conv': _id});
    } catch (_) {}
  }
}

/// A running or finished job.
class CoreJobHandle {
  CoreJobHandle._(this._core, this._id);

  final SearchCore _core;
  final int _id;
  bool _freed = false;

  Future<JobProgress> progress() async =>
      JobProgress.fromJson(((await _core._call('jobProgress', {'job': _id})) as Map).cast<String, dynamic>());

  Future<void> cancel() => _core._call('jobCancel', {'job': _id});

  /// Changes the job's pace now (cs_job_set; see [CoreJob.set]); null when the core has no cs_job_set.
  Future<Map<String, dynamic>?> set(Map<String, Object?> pace) async =>
      ((await _core._call('jobSet', {'job': _id, 'pace': pace})) as Map?)?.cast<String, dynamic>();

  /// Frees a job that is done, cancelled or failed.
  Future<void> free() async {
    if (_freed) return;
    _freed = true;
    try {
      await _core._call('jobFree', {'job': _id});
    } catch (_) {}
  }
}
